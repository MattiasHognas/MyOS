# The MyOS syscall ABI

MyOS's native syscall ABI is **Linux's x86-64 ABI**: the same instruction,
registers, numbers, error values and struct layouts. MyOS's own programs and
programs built for Linux make the same calls; there is no translation layer.
Only the 64-bit `syscall` interface exists: no `int 0x80`, no x32 numbers.

MyOS implements a small part of it so far. This page lists what exists and
where it differs from Linux; for everything else the Linux manual pages
(`man 2 syscall`, `man 2 read`, ...) describe the behaviour to expect.

The numbers, error values and flags live in one file,
[`src/abi/linux.zig`](../src/abi/linux.zig), which both the kernel and the
user runtime (`app/lib.zig`, as the module `abi`) import.

## Calling convention

| | Register |
| --- | --- |
| Syscall number | `rax` |
| Arguments 1-6 | `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9` |
| Result | `rax` |
| Clobbered | `rcx` (holds the return address), `r11` (holds RFLAGS) |
| Preserved | everything else: `rbx`, `rbp`, `rsp`, `r12`-`r15`, and the argument registers `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9` |

The call is made with the `syscall` instruction. The fourth argument is in
`r10`, not `rcx` as in the function-call ABI, because `syscall` itself
overwrites `rcx`.

- **Flags.** RFLAGS is preserved, except that NT and IOPL, which a program
  has no use for, are cleared. During the call the kernel runs with TF, IF,
  DF, IOPL, NT and AC cleared. A program that single-steps (TF set) gets its
  trap after the instruction that follows the `syscall`, as on Linux.
- **Stack.** The kernel never reads or writes the user stack and does not
  care how `rsp` is aligned; there is no red-zone problem.
- **Extended registers.** x87, SSE and AVX registers are preserved across
  syscalls, interrupts and thread switches.
- **Segment bases.** FS and GS are the program's own (both bases are 0;
  nothing can set them yet). The kernel's GS base is never visible.

A program must not rely on `rcx` and `r11` holding the values named above;
that is what Linux does too, and what `tests/user/checked.zig` checks, so
no kernel value can reach a program through them.

## Results and errors

A call returns a value, or a negated error number: results from `-4095` to
`-1` (as a signed number) are errors, everything else is a value. There is
no `errno` variable in the kernel ABI; a libc builds one from this.

| Error | Number | When |
| --- | --- | --- |
| `ENOENT` | 2 | No file at the path; empty path |
| `ENOEXEC` | 8 | `execve`: the file is not a program MyOS can load |
| `EBADF` | 9 | Descriptor not open, or not open for this use |
| `EAGAIN` | 11 | `fork`: the caller, or a process above it, has as many descendants as it may |
| `ENOMEM` | 12 | Out of memory; `execve`: the program is larger than the memory limit |
| `EFAULT` | 14 | A pointer is outside user space, not mapped, or (for output) not writable |
| `EINVAL` | 22 | Invalid argument (reserved; no call returns it yet) |
| `EMFILE` | 24 | The process has as many descriptors as its limit allows |
| `EROFS` | 30 | Opening for writing, or creating: every filesystem is read-only |
| `ENAMETOOLONG` | 36 | Path longer than 255 bytes |
| `ENOSYS` | 38 | Unknown syscall number |

A bad pointer never kills the process: the call fails with `EFAULT`. If a
`read` or `write` buffer is usable at the start and bad further on, the call
transfers what it can and returns the short count, as Linux does.

## Syscalls

Linux calls, with Linux's numbers:

| Number | Call | Notes |
| --- | --- | --- |
| 0 | `read(fd, buf, count)` | Files, pipes, the terminal. The terminal gives one line once Enter is typed (with line editing on), or each key at once (off); 0 after Ctrl+D on an empty line. A pipe gives what it holds, waiting only while it is empty and has a writer; 0 at its end. `/dev/null` is at its end at once, the random devices give random bytes. |
| 1 | `write(fd, buf, count)` | The console (serial port and screen), which descriptors 0, 1 and 2 start out as; files opened for writing (in `/tmp`), at the descriptor's offset or at the end with `O_APPEND`; pipes; `/dev/null` and the random devices, which throw it away. A pipe takes all of it, waiting for room; `EPIPE` when no reader is left (no `SIGPIPE` yet). `ENOSPC`, `EFBIG`. |
| 2 | `open(path, flags, mode)` | In `/tmp`, which can be written: `O_CREAT` (with `O_EXCL`: `EEXIST`), `O_TRUNC`, `O_APPEND`, any access mode. Elsewhere opening for writing or creating is `EROFS`. `/dev/null`, `/dev/urandom` and `/dev/random` may be opened for writing. The text files of `/proc` (see below) are made when they are opened. A directory is opened for reading only (`EISDIR`), to be listed or to start paths from; `O_DIRECTORY` or a slash at the end of the path on anything else is `ENOTDIR`. `O_NONBLOCK` is kept; `mode` and other flags are ignored: there are no permissions. |
| 3 | `close(fd)` | Any open descriptor, the standard ones too. What it referred to goes with its last descriptor. |
| 4 | `stat(path, statbuf)` | `newfstatat` for a path. |
| 5 | `fstat(fd, statbuf)` | The console is a character device, a pipe a FIFO, an open file a regular file with its size. Two descriptors or paths are the same file if device and inode number are equal. |
| 6 | `lstat(path, statbuf)` | `stat` without following a link at the end. |
| 7 | `poll(fds, nfds, timeout)` | The console is writable, a file readable, a pipe when it has bytes or room; `POLLHUP` and `POLLERR` for a pipe whose other end is closed, `POLLNVAL` for a descriptor that is not open. Waits until a pipe, the terminal or an eventfd reports a change, and looks again then. |
| 8 | `lseek(fd, offset, whence)` | Open files; a directory only back to its start (`SEEK_SET`, 0); `ESPIPE` for the console and pipes. |
| 9 | `mmap(addr, length, prot, flags, fd, offset)` | Anonymous memory, files of the image and memory files (`memfd_create`): a private mapping gets each page from the file when it is first touched and keeps its changes to itself. A shared mapping of a memory file maps its pages themselves: every mapping of it, in this process and in children made by `fork`, and the descriptor see the same memory (writable only from a descriptor open for writing, `EACCES`; not with a seal against writing, `EPERM`); `MAP_SHARED \| MAP_ANONYMOUS` is memory of its own that children share. A shared mapping of another file may only be read (`EACCES`). A page wholly past the end of the file kills the program that touches it. `MAP_FIXED`, `MAP_FIXED_NOREPLACE`, hints, `MAP_NORESERVE`; `MAP_DENYWRITE` is ignored. `ENODEV` for a descriptor that is not a file, and for a file in `/tmp`: what can change cannot be mapped yet. |
| 10 | `mprotect(addr, length, prot)` | `ENOMEM` if part of the range is not mapped. Memory may be writable and executable at once. |
| 11 | `munmap(addr, length)` | Any part of any mappings; unmapping what is not mapped succeeds. |
| 12 | `brk(addr)` | Returns the new end of the heap, or the old one if it cannot move. |
| 13 | `rt_sigaction(sig, act, oldact, size)` | What a signal does: default, ignore, or a handler with `SA_SIGINFO`, `SA_ONSTACK`, `SA_RESTART`, `SA_NODEFER`, `SA_RESETHAND` and `sa_mask`. A handler needs `SA_RESTORER` (C libraries always set it); without, delivering to it kills the program, as on Linux. `EINVAL` for `SIGKILL` and `SIGSTOP`. |
| 14 | `rt_sigprocmask(how, set, oldset, size)` | The thread's blocked signals; `SIGKILL` and `SIGSTOP` cannot be blocked. A signal unblocked here is delivered as the call returns. |
| 15 | `rt_sigreturn()` | Back from a handler: registers, signal mask, alternate stack and FP state as the frame says, with what the handler changed in it. Selectors are user mode's whatever it says, flags only user-settable ones, the return address checked like any; an FP image cannot make the kernel fault. A frame that cannot be read kills the program. |
| 16 | `ioctl(fd, request, arg)` | The terminal: `TCGETS`, `TCSETS`, `TCSETSW`, `TCSETSF` (line editing, echo, Ctrl+C, CR to newline; other settings are ignored), `TIOCGWINSZ` (80 by 25), `FIONREAD`, `TCFLSH`, `TIOCSPGRP` and `TIOCGPGRP` (the foreground process group, which Ctrl+C, Ctrl+\\ and Ctrl+Z send `SIGINT`, `SIGQUIT` and `SIGTSTP` to; until one is set, the caller's group; it has none again when the group's last process ends). A process in the background that reads the terminal gets `SIGTTIN` and `EINTR` (`EIO` if it blocks or ignores `SIGTTIN`), and one that sets the foreground group `SIGTTOU` unless it blocks or ignores that. `EINVAL` for other requests; `ENOTTY` for every descriptor that is not the terminal (how a C library finds out that its output is not one), `EBADF` otherwise. |
| 17 | `pread64(fd, buf, count, offset)` | |
| 18 | `pwrite64(fd, buf, count, offset)` | `write` to a file at an offset; the descriptor's own stays. |
| 19 | `readv(fd, iov, iovcnt)` | `read` into up to 1024 buffers. |
| 20 | `writev(fd, iov, iovcnt)` | `write` from up to 1024 buffers. |
| 21 | `access(path, mode)` | Files can be read and run, not written (`EROFS`). |
| 22 | `pipe(fds)` | See `pipe2`. |
| 24 | `sched_yield()` | |
| 25 | `mremap(old, old_size, new_size, flags, new)` | Shrinks a mapping, or grows it into free addresses after it (a file's mapping goes on in the file). With `MREMAP_MAYMOVE` it moves where it cannot grow, also from the middle of a mapping, and with `MREMAP_FIXED` to `new` (unmapping what is there): the pages move, not their contents. `EFAULT` if the old range is not one mapping; `EINVAL` for `MREMAP_FIXED` alone or a new range overlapping the old; `ENOMEM` without room or leave to move. Not: `MREMAP_DONTUNMAP`. |
| 28 | `madvise(addr, length, advice)` | `MADV_DONTNEED` and `MADV_FREE` give the pages back at once: they read as zeroes afterwards. Other advice is accepted and ignored. |
| 32 | `dup(fd)` | The lowest free descriptor, for the same open file: they share its offset. |
| 33 | `dup2(old, new)` | Closes what `new` was. |
| 34 | `pause()` | Waits for a signal to be handled; `EINTR`. |
| 35 | `nanosleep(req, rem)` | Whole timer ticks (10 ms) while more than a tick is left, so a sleep ends at most a tick late; under 2 ms left the CPU goes to others until the deadline, so short sleeps are short. A signal ends it with `EINTR`, and what was left is written at `rem`. |
| 39 | `getpid()` | The ID of the process's first thread. |
| 41 | `socket(domain, type, protocol)` | No networking yet: `EAFNOSUPPORT`. |
| 56 | `clone(flags, stack, ptid, ctid, tls)` | With `CLONE_THREAD` a new thread (it must come with `CLONE_VM` and `CLONE_SIGHAND`): `CLONE_SETTLS`, `CLONE_PARENT_SETTID`, `CLONE_CHILD_SETTID` and `CLONE_CHILD_CLEARTID` are honoured. Without it, a new process as `fork` makes, the low byte of `flags` the signal its parent gets when it ends; `CLONE_VFORK` holds the caller until the child calls `execve` or ends. `CLONE_VM` without `CLONE_THREAD` gets a copy of the memory, not the same memory (Linux shares it; `vfork` and `posix_spawn` work either way, but what the child writes before `execve` stays its own). `EINVAL` for sharing the descriptor table or the signal actions between processes. |
| 57 | `fork()` | A new process: a copy of the caller's memory (every page copied: no copy-on-write yet), the same open files (descriptors and their close-on-exec flags copied), working directory, signal actions, mask and alternate stack, and limits; one thread with the caller's registers, returning 0. The parent gets the child's ID, and `SIGCHLD` when it ends. `EAGAIN` past the descendant limit, `ENOMEM`. |
| 58 | `vfork()` | `fork` that holds the caller until the child calls `execve` or ends. |
| 59 | `execve(path, argv, envp)` | Replaces the program of the calling process. The new one is loaded first: on an error the old one goes on as it was. Then the process's other threads end; it keeps its ID, parent, children, descriptors (but those marked close-on-exec), working directory, signal mask, pending signals and limits. Signal handlers go back to the default (ignored signals stay ignored); the alternate stack, FS and GS base and extended state are cleared; a parent waiting in `vfork` goes on. A file that starts with `#!` runs its interpreter with the file as an argument (one level, as on Linux). `ENOENT`, `ENOEXEC`, `E2BIG`, `EFAULT`, `ENOMEM`, `EINTR` (another thread replaced or ended the process first). |
| 60 | `exit(status)` | Ends the calling thread. The last thread's status is the process's: the parent sees `status & 0xff`. |
| 61 | `wait4(pid, status, options, rusage)` | Collects a child that has ended, any (`pid` -1), the one given, any in the caller's process group (0) or in the group `-pid`, and writes its status as Linux does (`code << 8`, or the signal that ended it; a fault the kernel killed it for counts as that fault's signal). An ended child is a zombie until then, or until its parent ends. `WNOHANG` returns 0 if none has ended; `WUNTRACED` also reports a child that stopped (`(sig << 8) | 0x7f`) and `WCONTINUED` one that was continued (`0xffff`), each once. `rusage` is zeroes. `ECHILD`, `EINTR`, `EINVAL`, `EFAULT`. |
| 62 | `kill(pid, sig)` | Any process by its ID; `-1`: every process but `init` and the caller, then the caller; `0`: the caller's process group; `-pgid`: that group. Any of the process's threads that does not block the signal takes it. Signal 0 checks. An ended process not yet collected takes nothing, without an error. `ESRCH`, `EINVAL`. |
| 63 | `uname(buf)` | Says `Linux`, release `6.1.0-myos`, machine `x86_64`: programs built for Linux check. |
| 72 | `fcntl(fd, cmd, arg)` | `F_DUPFD` and `F_DUPFD_CLOEXEC` (the lowest free descriptor from `arg` up), `F_GETFL`, `F_SETFL` (only `O_NONBLOCK` changes), `F_GETFD`; `F_SETFD` is accepted and changes nothing: there is no exec. `F_ADD_SEALS` and `F_GET_SEALS` on a memory file: `F_SEAL_SEAL`, `SHRINK`, `GROW`, `WRITE` (`EBUSY` while a shared mapping that may write exists), `FUTURE_WRITE`; `EPERM` once sealed against seals, or for a descriptor not open for writing; `EINVAL` on another file. |
| 73 | `flock(fd, operation)` | An advisory lock on the whole file, held by the open file (shared by duplicates and across `fork`): `LOCK_SH`, `LOCK_EX`, `LOCK_UN`; it waits for a lock in the way unless `LOCK_NB` (`EWOULDBLOCK`). Given up when the open file's last descriptor closes; changing its kind gives up the old one first, as on Linux. |
| 74 | `fsync(fd)` | Nothing is ever waiting to be written: 0. |
| 75 | `fdatasync(fd)` | The same. |
| 76 | `truncate(path, length)` | `ftruncate` by path. |
| 77 | `ftruncate(fd, length)` | A file open for writing: cut short, or grown with zeroes that take no memory. `EINVAL` otherwise; `EFBIG` past 1 GiB. |
| 79 | `getcwd(buf, size)` | The working directory, with its NUL; returns the length including it. `ERANGE` if it does not fit. |
| 80 | `chdir(path)` | `ENOTDIR` for what is no directory. A child starts in its parent's directory. |
| 81 | `fchdir(fd)` | To the directory a descriptor is open on. |
| 82 | `rename(old, new)` | A file or a directory with all in it; a file of the new name, or an empty directory, is replaced. Within one filesystem (`EXDEV`); `EINVAL` into itself; `EBUSY` for a mount point. |
| 83 | `mkdir(path, mode)` | `EEXIST`, `ENOENT`, `ENOTDIR`, `EROFS`. |
| 84 | `rmdir(path)` | An empty directory: `ENOTEMPTY`, `ENOTDIR`, `EBUSY` for a mount point. |
| 87 | `unlink(path)` | Takes the name away; the file lives while it is open. `EISDIR`, `EROFS`, `ENOENT`. |
| 89 | `readlink(path, buf, size)` | What a symbolic link points to, cut to `size`: the links of the image (`/bin` and the rest) and `/proc/self/exe`. `EINVAL` for anything else that exists, `ENOENT` otherwise. |
| 91 | `fchmod(fd, mode)` | No permissions exist: accepted for a file that can be written, `EROFS` otherwise. |
| 96 | `gettimeofday(tv, tz)` | |
| 99 | `sysinfo(info)` | Memory in bytes (total and free), uptime, number of processes. No swap, no load averages. |
| 109 | `setpgid(pid, pgid)` | Puts the caller or one of its children (`pid` 0: the caller) in the group `pgid` (0: its own ID), which must be its own ID or a group of the same session. A session leader stays in its group. `EPERM`, `ESRCH`, `EINVAL`. |
| 110 | `getppid()` | The parent's process ID; an orphan's new parent's; 0 for none. |
| 111 | `getpgrp()` | The caller's process group. |
| 112 | `setsid()` | A new session and group, led by the caller; `EPERM` for a group leader. There is one terminal, which stays where it is. |
| 121 | `getpgid(pid)` | A process's group (0: the caller's); `ESRCH`. |
| 124 | `getsid(pid)` | A process's session (0: the caller's); `ESRCH`. A process starts in its parent's group and session, or in its own if the kernel started it. |
| 127 | `rt_sigpending(set, size)` | The signals waiting that the thread blocks. |
| 128 | `rt_sigtimedwait(set, info, timeout, size)` | Takes a pending signal of `set` (the thread's or its process's, the lowest first) without running a handler, writes its `siginfo`, and returns it; waits for one until `timeout` (`EAGAIN`; for ever without one, at once for zero). While it waits the set is taken out of the thread's mask, so that a signal of it sent to the process comes to this thread. `EINTR` for a signal outside the set that a handler took. |
| 129 | `rt_sigqueueinfo(tgid, sig, info)` | Sends `sig` to the process with the caller's `siginfo` (`sigqueue`: `SI_QUEUE` and a value). A real-time signal is queued as often as it is sent, up to `RLIMIT_SIGPENDING` (1024) in the receiving process (`EAGAIN`). `EPERM` for an `si_code` of 0 or above, or `SI_TKILL`, to another process. |
| 130 | `rt_sigsuspend(mask, size)` | Waits with `mask` blocked instead until a signal is handled; the old mask is back after the handler. `EINTR`. |
| 131 | `sigaltstack(ss, old_ss)` | The thread's alternate signal stack, used by handlers with `SA_ONSTACK`; reported as `SS_ONSTACK` while in use. |
| 137 | `statfs(path, buf)` | One filesystem, in memory and read-only, reported as `tmpfs`. `ENOENT` for a path that does not exist. |
| 142 | `sched_setparam(pid, param)` | One policy, `SCHED_OTHER`, with priority 0: that may be set, anything else is `EINVAL`. `pid` is 0 or a thread of the calling process. |
| 143 | `sched_getparam(pid, param)` | Priority 0. |
| 144 | `sched_setscheduler(pid, policy, param)` | As `sched_setparam`. |
| 145 | `sched_getscheduler(pid)` | `SCHED_OTHER`. |
| 146 | `sched_get_priority_max(policy)` | 0 for `SCHED_OTHER`; `EINVAL` for the real-time policies, which do not exist here. |
| 147 | `sched_get_priority_min(policy)` | The same. |
| 149 | `mlock(addr, length)` | Memory is never paged out: succeeds for a range that is all mapped, `ENOMEM` otherwise. |
| 150 | `munlock(addr, length)` | The same. |
| 157 | `prctl(option, ...)` | No option is supported: `EINVAL`. |
| 158 | `arch_prctl(code, addr)` | `ARCH_SET_FS`, `ARCH_SET_GS`, `ARCH_GET_FS`, `ARCH_GET_GS`: the thread's FS and GS base, kept across switches, also when the program sets them itself with `wrfsbase`/`wrgsbase` (FSGSBASE, on where the CPU has it). A base outside user space is `EPERM`. |
| 186 | `gettid()` | |
| 200 | `tkill(tid, sig)` | As `tgkill` with the calling process. |
| 201 | `time(tloc)` | Seconds of the real-time clock. |
| 202 | `futex(addr, op, val, timeout, addr2, val3)` | `FUTEX_WAIT`, `FUTEX_WAKE`, `FUTEX_WAIT_BITSET`, `FUTEX_WAKE_BITSET`, `FUTEX_REQUEUE`, `FUTEX_CMP_REQUEUE`, with or without `FUTEX_PRIVATE_FLAG` and `FUTEX_CLOCK_REALTIME`. Only within one process. Timeouts have the timer's resolution and never end early. |
| 203 | `sched_setaffinity(pid, size, mask)` | Accepted if the mask has a CPU that is up, and changes nothing: threads run on any CPU. |
| 204 | `sched_getaffinity(pid, size, mask)` | Every CPU that is up; 8 bytes. `EINVAL` for a size below 8, `ESRCH` for a thread not of the caller's process. |
| 217 | `getdents64(fd, buf, count)` | The next entries of a directory as `struct linux_dirent64`, "." and ".." first; 0 at the end. `EINVAL` if not one entry fits. |
| 218 | `set_tid_address(ptr)` | Returns the thread ID. When the thread exits, zero is written to `ptr` and one futex waiter on it is woken. |
| 228 | `clock_gettime(clock, ts)` | `CLOCK_MONOTONIC` (and `_RAW`, `_COARSE`, `CLOCK_BOOTTIME`): time since boot, from the TSC where it is invariant and the HPET otherwise. `CLOCK_REALTIME` (and `_COARSE`): the RTC's date at boot plus that. The CPU-time clocks give time since boot, an upper bound: CPU time is not counted yet. `EINVAL` for other clocks. |
| 230 | `clock_nanosleep(clock, flags, req, rem)` | With `TIMER_ABSTIME` too. |
| 231 | `exit_group(status)` | Ends the process: every thread, wherever it is. |
| 232 | `epoll_wait(epfd, events, max, timeout)` | The watched descriptors that are ready, waiting up to `timeout` ms (for ever if negative). Readiness is looked at again when a watched kind of object reports a change. `EPOLLET` reports a ready file once, and again only after its object has changed; `EPOLLONESHOT` works. A watch is on the open file: closing the descriptor, or reusing its number for another file, ends it. A signal ends the wait with `EINTR`. |
| 233 | `epoll_ctl(epfd, op, fd, event)` | `EPOLL_CTL_ADD`, `MOD`, `DEL`. The open file the descriptor is on is watched: closing the descriptor, or the number coming to stand for another file, ends the watch (Linux keeps it while another descriptor still has the file, after a `dup`). `EPERM` for files and directories (always ready), `EINVAL` for an epoll instance (not inside another yet). |
| 234 | `tgkill(tgid, tid, sig)` | A thread of the calling process (`ESRCH` otherwise). |
| 239 | `get_mempolicy(mode, nodemask, maxnode, addr, flags)` | One memory node, the default policy: mode 0 and an empty mask. No flags. |
| 257 | `openat(dirfd, path, flags, mode)` | `open` with a relative path starting at the directory `dirfd` is open on, or at the working directory for `AT_FDCWD`. `ENOTDIR` if `dirfd` is open on something else, `EBADF` if it is not open; neither matters for an absolute path. |
| 258 | `mkdirat(dirfd, path, mode)` | As `mkdir`. |
| 259 | `mknodat(dirfd, path, mode, dev)` | Devices and FIFOs cannot be made: `EPERM`, or `EROFS` where nothing can. |
| 262 | `newfstatat(dirfd, path, statbuf, flags)` | `stat` by path, relative as for `openat`; of the descriptor itself with an empty path and `AT_EMPTY_PATH`. Files, directories, the `/proc` and `/dev` entries; `AT_SYMLINK_NOFOLLOW` shows `/proc/self/exe` as the link it is. |
| 263 | `unlinkat(dirfd, path, flags)` | `unlink`, or `rmdir` with `AT_REMOVEDIR`. |
| 264 | `renameat(olddirfd, old, newdirfd, new)` | As `rename`. |
| 267 | `readlinkat(dirfd, path, buf, size)` | As `readlink`. |
| 269 | `faccessat(dirfd, path, mode)` | As `access`. |
| 273 | `set_robust_list(head, size)` | Accepted and not used: a thread that dies takes its process with it. |
| 281 | `epoll_pwait(epfd, events, max, timeout, sigmask, size)` | `epoll_wait` with `sigmask` blocked meanwhile. |
| 282 | `signalfd(fd, mask, size)` | See `signalfd4`. |
| 284 | `eventfd(initval)` | See `eventfd2`. |
| 289 | `signalfd4(fd, mask, size, flags)` | A descriptor for the signals of `mask` (`fd` -1), or a new mask for the signalfd `fd`. A read takes the reader's pending signals of the mask as `rt_sigtimedwait` does, a `signalfd_siginfo` record (128 bytes) for each, as many as fit (`EINVAL` for less than one); it waits unless `SFD_NONBLOCK`. Readable to `poll` and `epoll` while one is pending. `SFD_CLOEXEC`. |
| 290 | `eventfd2(initval, flags)` | A 64-bit counter: a write adds, a read takes all (one with `EFD_SEMAPHORE`) and waits while it is zero unless `EFD_NONBLOCK`. |
| 291 | `epoll_create1(flags)` | A new instance; `epoll_create(size)` (213) the same. |
| 292 | `dup3(old, new, flags)` | `dup2`, with `EINVAL` if `old` is `new`. |
| 293 | `pipe2(fds, flags)` | A pipe of 4096 bytes (Linux: 65536); a write of up to that is not mixed with another. `O_NONBLOCK`; `O_CLOEXEC` is accepted. |
| 295 | `preadv(fd, iov, count, offset)` | `pread64` into each buffer in turn, from `offset`; the file offset stays. `ESPIPE` for what is not a file. |
| 296 | `pwritev(fd, iov, count, offset)` | The same for `pwrite64`. |
| 297 | `rt_tgsigqueueinfo(tgid, tid, sig, info)` | `rt_sigqueueinfo` to a thread of the caller's process. |
| 302 | `prlimit64(pid, resource, new, old)` | The calling process's limits: `RLIMIT_DATA` is its memory limit (in bytes, whole pages), `RLIMIT_NOFILE` its descriptors, `RLIMIT_NPROC` the processes alive below it (Linux counts per user); the others are kept and reported as set (`RLIMIT_STACK` 8 MiB, the rest unlimited), not enforced. A limit may be set up to its ceiling, and the ceiling lowered, never raised (`EPERM`). `EINVAL` for a resource above 15 or `cur` above `max`, `ESRCH` for another process. `getrlimit` (97) and `setrlimit` (160) are the same for the caller. |
| 316 | `renameat2(olddirfd, old, newdirfd, new, flags)` | As `rename`; no flags (`EINVAL`). |
| 318 | `getrandom(buf, len, flags)` | Never blocks, so `GRND_NONBLOCK`, `GRND_RANDOM` and `GRND_INSECURE` change nothing; `EINVAL` for other flags. |
| 319 | `memfd_create(name, flags)` | A file in memory only (`memfd.zig`), open for reading and writing, of size 0: written, read, sized with `ftruncate`, mapped (shared or private); it goes when its last descriptor and mapping do. `MFD_CLOEXEC`, `MFD_ALLOW_SEALING` (without it the file comes sealed against seals), `MFD_NOEXEC_SEAL` and `MFD_EXEC` are accepted; `EINVAL` for `MFD_HUGETLB`, other flags, or a name over 249 bytes. `/proc/self/maps` shows its mappings as `/memfd:NAME (deleted)`. Shrinking a file leaves pages already mapped past the new end in their mappings (Linux takes them out). |
| 322 | `execveat(dirfd, path, argv, envp, flags)` | `execve` with `path` relative to `dirfd`; `flags` must be 0. |
| 324 | `membarrier(cmd, flags, cpu)` | `MEMBARRIER_CMD_QUERY`, `REGISTER_PRIVATE_EXPEDITED` and `PRIVATE_EXPEDITED`, which interrupts the CPUs that run the caller's address space. What a garbage collector uses to stop paying for barriers in every thread. |
| 327 | `preadv2(fd, iov, count, offset, flags)` | `preadv`, or `readv` with offset -1; `flags` must be 0 (`EOPNOTSUPP`). |
| 328 | `pwritev2(fd, iov, count, offset, flags)` | The same for writing. |
| 332 | `statx(dirfd, path, flags, mask, buf)` | What `newfstatat` says, in `struct statx`, every basic field filled whatever `mask` asks (no birth time). The Zig standard library uses it. |
| 309 | `getcpu(cpu, node, cache)` | The CPU the caller runs on, node 0; either pointer may be null. Also in the vDSO. |
| 334 | `rseq(area, len, flags, sig)` | Registers the calling thread's 32-byte area (aligned to 32): the kernel writes the CPU's number into `cpu_id_start` and `cpu_id` whenever the thread is switched onto a CPU, and a thread switched out or given a signal inside the critical section named by `rseq_cs` goes on at the section's abort address (whose 4 bytes before must be `sig`), as on Linux; a bad area or section ends the process (`SIGSEGV`). `RSEQ_FLAG_UNREGISTER` takes it back (`EPERM` for another signature). Same registration twice `EBUSY`, another one `EINVAL`. Kept by a forked child, not by a thread or a child sharing the memory; cleared by `execve`. |
| 435 | `clone3(args, size)` | `clone` with its arguments in a structure, under the same rules (threads, and processes with `exit_signal`). Fields past the first version of the structure must be zero. |
| 439 | `faccessat2(dirfd, path, mode, flags)` | As `access`; `AT_EACCESS`, `AT_SYMLINK_NOFOLLOW`, `AT_EMPTY_PATH` accepted, `EINVAL` for other flags. |
| 441 | `epoll_pwait2(epfd, events, max, timeout_ts, sigmask, size)` | `epoll_pwait` with the timeout as a `timespec`. |

There are no calls of MyOS's own any more: the two there were
(`myos_getchar` and `myos_run`, at `0x4D5900` and `0x4D5901`) gave way to
`read` on the terminal and to `fork` and `execve`, and their numbers stay
unused. The test kernel answers a few numbers above `0x4D5A00` of its own.

Every other number returns `ENOSYS`.

### Differences from Linux to know about

- **Paths** are as on Linux: at most 4095 bytes (`PATH_MAX` 4096), a name
  at most 255, relative to the working directory or to a descriptor.
- **Threads** share their process's address space, descriptors and signal
  handlers, and each has its own registers, FS and GS base and signal
  mask. `getpid` is the same in all of them, `gettid` different.
- **Descriptors.** A process may have 1024, Linux's default; its table
  starts with 32 slots and doubles as higher ones are used. It starts
  with 0, 1 and 2 open on the
  console; they can be closed, duplicated and replaced like any other.
  `open`, `dup` and `pipe2` return the lowest free one. A child made by
  `fork` gets copies of them, on the same open files (and their offsets);
  `execve` closes those marked close-on-exec and keeps the others.
- **The terminal.** Descriptors 0, 1 and 2 start out on it. Keys come
  from the keyboard and the serial line. With line editing on (the
  default) a line is shown as it is typed and handed over on Enter;
  backspace, Ctrl+U and Ctrl+D work as on Linux. Ctrl+C throws the line
  away and sends `SIGINT` to the program the shell is running: it ends
  with exit status 130, unless it handles or ignores the signal.
  When the shell gets the terminal back, the settings are put back.
- **Symbolic links** are followed in every part of a path, at most 40
  of them (`ELOOP`); not in the last part for `lstat`, `readlink`,
  `unlink`, `rename` and `open` with `O_NOFOLLOW` (`ELOOP`). Paths are
  made plain before links are followed, so ".." after a link goes back
  to where the link is, not up from where it points, as Linux has it.
  The image has the links of a merged `/usr`; none can be made yet.
- **Paths** are at most 4095 bytes, each name in them at most 255
  (`ENAMETOOLONG`). A relative path starts at the working directory, or
  at a directory descriptor for the `...at` calls. "." and ".." and
  doubled slashes are resolved before anything is looked up, ".." at the
  root staying there; a slash at the end asks for a directory.
- **Directories** are not stored in the image's filesystem: a path is a
  directory if a file is somewhere below it. They are opened, listed
  (`getdents64`), and made the working directory. Filesystems are mounted
  at paths (`vfs.mount`): the image at the root, which cannot be changed,
  and a filesystem in memory at `/tmp`, which can, holds at most half the
  machine's memory, and is empty again after a restart. A file there is
  at most 1 GiB. There are no owners and no permissions.
- **`/proc`, `/sys` and `/dev`.** A process finds a few things about
  itself and the machine as files, in Linux's format: `/proc/self/exe` (a
  link to its program), `/proc/self/maps` (its mappings; a C library finds
  the main thread's stack there), `/proc/self/stat`, `/proc/meminfo`,
  `/proc/cpuinfo`, `/proc/self/mountinfo`, `/proc/self/cgroup`,
  `/sys/devices/system/cpu/online` (`possible`, `present`: "0-3"), and
  the caches in `/sys/devices/system/cpu/cpu0/cache/index*` (`level`,
  `size`, `type`, ...: what the .NET collector sizes itself by); `self`
  may be its own process ID, and every process has a directory by its ID
  (`stat`, `cmdline`, `comm`). There are no control groups, but
  `/sys/fs/cgroup` is laid out as the root of a cgroup v2 hierarchy whose
  `memory.max` is the reader's memory limit and `memory.current` its use,
  for runtimes that size themselves by them.
  `/dev/null`, `/dev/urandom` and `/dev/random` are devices.
- **Counts** above `0x7ffff000` are shortened to that, as on Linux.
- **Limits.** Every process has limits, inherited from the process that
  started it: memory (its program, stack, page tables and kernel stack;
  three quarters of the machine's for a process nothing else started),
  1024 descriptors, and 1024 processes alive below it. A process reads and
  lowers them with `prlimit64`, `getrlimit` and `setrlimit`.
- **Arguments and environment** of a new program may take 8 KiB on its
  stack together, the auxiliary vector included, and be 256 strings (on
  Linux: a quarter of the stack limit, 2 MiB by default).
- **Memory is given on first touch.** `mmap` and `brk` reserve address
  space; a page exists once it is read or written. A reservation of any
  size succeeds and costs nothing (there is no overcommit limit), and a
  process pays, against its limit, for the pages it has touched and the
  page tables for them.
- **Running out of memory** fails the system call that needed it with
  `ENOMEM`. A program that touches a page it cannot be given (it is at
  its limit, or the machine has none left) is killed, like any fault it
  cannot continue from; nothing else is killed to make room.
- **Signals** are delivered as on Linux, on the way back to user mode
  after a system call or an interrupt: the handler gets Linux's frame
  (`rt_sigframe`: return address, `ucontext` with the registers and the
  mask, `siginfo`, the XSAVE state with Linux's markers), on the
  alternate stack if it asks for it. A fault in ring 3 becomes `SIGSEGV`
  (`SEGV_MAPERR` or `SEGV_ACCERR`, the address in `si_addr`), `SIGFPE`,
  `SIGILL`, `SIGBUS` or `SIGTRAP` for a program that handles it, and
  `int3` is a breakpoint from user mode. A blocking call a signal ends
  returns `EINTR`, or with `SA_RESTART` (for `read`, `write`, `futex`,
  `ioctl`, `open` and the like) is made again; if no handler ran it is
  always made again. A signal no handler catches ends the process with
  status 128 + its number; one that ignores by default (`SIGCHLD`,
  `SIGURG`, `SIGWINCH`) does nothing.
  `SIGSTOP`, and `SIGTSTP`, `SIGTTIN` and `SIGTTOU` that no handler
  takes, stop the whole process until `SIGCONT` comes, which continues it
  as it is sent; signals sent meanwhile wait, `SIGKILL` excepted. Sending
  a stop signal throws away a pending `SIGCONT`, and `SIGCONT` the
  pending stop signals. The parent hears of both through `wait4` and
  `SIGCHLD` (unless `SA_NOCLDSTOP`). The terminal's stop signals are
  thrown away for an orphaned process group. Real-time signals (32 to 64)
  are queued, each one sent delivered with its `siginfo`; a standard
  signal sent while pending is one, with the details of the first
  sender. Signals that waited for a handler to return are delivered as
  `rt_sigreturn` returns.
- **A process the kernel kills** for a fault it does not handle ends
  with status 255.

## Program start

A program is entered at its ELF entry point in ring 3 the way Linux enters
one, with:

- all general-purpose registers zero, RFLAGS `0x202` (interrupts on);
- a stack whose top is at a random page in a 16 GiB range below
  `0x7fffffff0000`, different for every process. It may grow to 8 MiB,
  and gets its pages as it is used;
- `rsp` on a 16-byte boundary, pointing at the initial stack described
  below, which ends a random distance below the top of the stack;
- FS and GS base zero, until the program sets them with `arch_prctl` (or
  `wrfsbase`/`wrgsbase`, where `AT_HWCAP2` says it may);
- memory that holds nothing from before: `.bss` and the rest of the stack
  are zero;
- clean extended state: x87 control word `0x37f`, MXCSR `0x1f80`, all x87,
  SSE and AVX registers zero.

SSE and SSE2 are always available. AVX is available when CPUID reports
`OSXSAVE` and AVX and `xgetbv` shows bits 1 and 2 of XCR0 set: the usual
check, which `tests/user/fpu_regs.zig` shows. AVX-512 is never enabled.

### The initial stack

From `rsp` upwards, in 8-byte words, as on Linux:

| What | |
| --- | --- |
| `argc` | number of arguments |
| `argv[0]` ... `argv[argc-1]`, `NULL` | pointers to the argument strings |
| `envp[0]` ..., `NULL` | pointers to the environment strings (`NAME=value`) |
| auxiliary vector | pairs of key and value, ended by `AT_NULL` (0) |
| ... | the strings and data the above point to |

A program started without arguments gets the path it was started under as
`argv[0]`. The auxiliary vector has:

| Key | Value |
| --- | --- |
| `AT_PHDR` (3), `AT_PHENT` (4), `AT_PHNUM` (5) | address, entry size and number of the program headers in memory. `AT_PHDR` is 0 if the program was linked so that its headers are not part of a loaded segment. A C library finds its thread-local data through these; the kernel does not set that up |
| `AT_PAGESZ` (6) | 4096 |
| `AT_BASE` (7) | 0: there is no ELF interpreter |
| `AT_FLAGS` (8) | 0 |
| `AT_ENTRY` (9) | the entry point |
| `AT_UID` (11), `AT_EUID` (12), `AT_GID` (13), `AT_EGID` (14) | 0: there are no users yet |
| `AT_PLATFORM` (15) | address of the string `x86_64` |
| `AT_HWCAP` (16) | CPUID leaf 1, EDX |
| `AT_HWCAP2` (26) | `HWCAP2_FSGSBASE` (bit 1) where the CPU has FSGSBASE: the program may use `rdfsbase`, `wrfsbase`, `rdgsbase` and `wrgsbase` |
| `AT_CLKTCK` (17) | 100 |
| `AT_SECURE` (23) | 0 |
| `AT_RANDOM` (25) | address of 16 random bytes, new for every process |
| `AT_EXECFN` (31) | address of the path the program was started under |
| `AT_SYSINFO_EHDR` (33) | address of the vDSO |

The vDSO is an ELF image (`linux-vdso.so.1`, symbols of version
`LINUX_2.6`) with `__vdso_clock_gettime`, `__vdso_gettimeofday` and
`__vdso_time` (and the names without the prefix): they read the clock from
the page below the image (`[vvar]` in `/proc/self/maps`) without a system
call, for the realtime, monotonic and boot-time clocks and their coarse
forms, and make the system call for the others or where the TSC is not
the clock. Both pages are shared by every process and cannot be made
writable (`mprotect`: `EACCES`). `__vdso_getcpu` (and `getcpu`) reads
the CPU's number with `RDPID`, or `RDTSCP` where there is no `RDPID`, from
`TSC_AUX`, which each CPU sets to its number as Linux does; without either
it makes the system call.

A program that sets up thread-local storage does so itself, from its
`PT_TLS` program header, and tells the kernel where with
`arch_prctl(ARCH_SET_FS)`. That is what a statically linked C library
does first.

## How the kernel implements it

- `src/arch/x86_64/syscall.zig`: the entry and exit assembly, with a
  step-by-step account of the stack, GS base and interrupt state.
- `src/arch/x86_64/sysret.zig`: whether a return can use `sysretq`, needs
  `iretq`, or is impossible (the process is killed).
- `src/arch/x86_64/percpu.zig`: the per-CPU area behind the kernel's GS base.
- `src/arch/x86_64/fpu.zig`: saving and restoring x87/SSE/AVX state.
- `src/kernel/syscall.zig`: the calls themselves.

To add a call, see [development](development.md#adding-a-syscall).
