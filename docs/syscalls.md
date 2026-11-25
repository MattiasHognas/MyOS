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
| `ENOEXEC` | 8 | `myos_run`: the file is not a program MyOS can load |
| `EBADF` | 9 | Descriptor not open, or not open for this use |
| `EAGAIN` | 11 | `myos_run`: the caller, or a process above it, has as many descendants as it may |
| `ENOMEM` | 12 | Out of memory; `myos_run`: the program is larger than the memory limit |
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
| 0 | `read(fd, buf, count)` | Files and pipes. A pipe gives what it holds, waiting only while it is empty and has a writer; 0 at its end. The console is not readable yet (`EBADF`); use `myos_getchar`. |
| 1 | `write(fd, buf, count)` | The console (serial port and screen), which descriptors 0, 1 and 2 start out as, and pipes. A pipe takes all of it, waiting for room; `EPIPE` when no reader is left (no `SIGPIPE` yet). Files are read-only (`EBADF`). |
| 2 | `open(path, flags, mode)` | Read-only: the access mode in `flags` must be `O_RDONLY`. Other flags and `mode` are ignored, except that `O_CREAT` on a missing file gives `EROFS`. |
| 3 | `close(fd)` | Any open descriptor, the standard ones too. What it referred to goes with its last descriptor. |
| 5 | `fstat(fd, statbuf)` | The console is a character device, a pipe a FIFO, an open file a regular file with its size. Two descriptors or paths are the same file if device and inode number are equal. |
| 7 | `poll(fds, nfds, timeout)` | The console is writable, a file readable, a pipe when it has bytes or room; `POLLHUP` and `POLLERR` for a pipe whose other end is closed, `POLLNVAL` for a descriptor that is not open. Waits by looking again every tick. |
| 8 | `lseek(fd, offset, whence)` | Open files; `ESPIPE` for the console and pipes. |
| 9 | `mmap(addr, length, prot, flags, fd, offset)` | Anonymous memory, and files: a private mapping gets each page from the file when it is first touched and keeps its changes to itself; a shared one may only be read (files cannot be written: `EACCES`). A page wholly past the end of the file kills the program that touches it. `MAP_FIXED`, `MAP_FIXED_NOREPLACE`, hints, `MAP_NORESERVE`; `MAP_DENYWRITE` is ignored. `ENODEV` for a descriptor that is not a file. |
| 10 | `mprotect(addr, length, prot)` | `ENOMEM` if part of the range is not mapped. Memory may be writable and executable at once. |
| 11 | `munmap(addr, length)` | Any part of any mappings; unmapping what is not mapped succeeds. |
| 12 | `brk(addr)` | Returns the new end of the heap, or the old one if it cannot move. |
| 13 | `rt_sigaction(sig, act, oldact, size)` | Recorded and read back. No signal is delivered yet (milestone 8): a fault still ends the process. |
| 14 | `rt_sigprocmask(how, set, oldset, size)` | The thread's blocked signals, recorded. |
| 16 | `ioctl(fd, request, arg)` | No device has requests yet: `ENOTTY` for every open descriptor (how a C library finds out that its output is not a terminal), `EBADF` otherwise. |
| 17 | `pread64(fd, buf, count, offset)` | |
| 20 | `writev(fd, iov, iovcnt)` | `write` from up to 1024 buffers. |
| 21 | `access(path, mode)` | Files can be read and run, not written (`EROFS`). |
| 22 | `pipe(fds)` | See `pipe2`. |
| 24 | `sched_yield()` | |
| 25 | `mremap(old, old_size, new_size, flags, new)` | Shrinks a mapping, or grows it into free addresses after it. Never moves one: `ENOMEM` where Linux would (`MREMAP_MAYMOVE`), as when there is no room. `EFAULT` if the old range is not mapped. |
| 28 | `madvise(addr, length, advice)` | `MADV_DONTNEED` and `MADV_FREE` give the pages back at once: they read as zeroes afterwards. Other advice is accepted and ignored. |
| 32 | `dup(fd)` | The lowest free descriptor, for the same open file: they share its offset. |
| 33 | `dup2(old, new)` | Closes what `new` was. |
| 35 | `nanosleep(req, rem)` | Resolution is one timer tick (10 ms), rounded up. `rem` is never written: nothing interrupts a sleep yet. |
| 39 | `getpid()` | The ID of the process's first thread. |
| 56 | `clone(flags, stack, ptid, ctid, tls)` | New threads only: `flags` must include `CLONE_VM`, `CLONE_SIGHAND` and `CLONE_THREAD` (`EINVAL` otherwise; there is no `fork` yet). `CLONE_SETTLS`, `CLONE_PARENT_SETTID`, `CLONE_CHILD_SETTID` and `CLONE_CHILD_CLEARTID` are honoured. |
| 60 | `exit(status)` | Ends the calling thread. The last thread's status is the process's: the parent sees `status & 0xff`. |
| 62 | `kill(pid, sig)` | The calling process only. Signals are not delivered yet: signal 0 checks; a signal with no handler whose default is to end the process ends it with status 128 + the signal (that is `abort`); anything else is dropped. `tkill` (200) and `tgkill` (234) likewise. |
| 63 | `uname(buf)` | Says `Linux`, release `6.1.0-myos`, machine `x86_64`: programs built for Linux check. |
| 72 | `fcntl(fd, cmd, arg)` | `F_DUPFD` and `F_DUPFD_CLOEXEC` (the lowest free descriptor from `arg` up), `F_GETFL`, `F_SETFL` (only `O_NONBLOCK` changes), `F_GETFD`; `F_SETFD` is accepted and changes nothing: there is no exec. |
| 79 | `getcwd(buf, size)` | Always `/`: there are no directories to change to. |
| 89 | `readlink(path, buf, size)` | There are no symbolic links: `EINVAL` for a file, `ENOENT` otherwise. |
| 96 | `gettimeofday(tv, tz)` | |
| 99 | `sysinfo(info)` | Memory in bytes (total and free), uptime, number of processes. No swap, no load averages. |
| 131 | `sigaltstack(ss, old_ss)` | The thread's alternate signal stack, recorded. |
| 137 | `statfs(path, buf)` | One filesystem, in memory and read-only, reported as `tmpfs`. `ENOENT` for a path that does not exist. |
| 149 | `mlock(addr, length)` | Memory is never paged out: checks the range and succeeds. |
| 150 | `munlock(addr, length)` | The same. |
| 157 | `prctl(option, ...)` | No option is supported: `EINVAL`. |
| 158 | `arch_prctl(code, addr)` | `ARCH_SET_FS`, `ARCH_SET_GS`, `ARCH_GET_FS`, `ARCH_GET_GS`: the thread's FS and GS base, kept across switches. A base outside user space is `EPERM`. |
| 186 | `gettid()` | |
| 202 | `futex(addr, op, val, timeout, addr2, val3)` | `FUTEX_WAIT`, `FUTEX_WAKE`, `FUTEX_WAIT_BITSET`, `FUTEX_WAKE_BITSET`, `FUTEX_REQUEUE`, `FUTEX_CMP_REQUEUE`, with or without `FUTEX_PRIVATE_FLAG` and `FUTEX_CLOCK_REALTIME`. Only within one process. Timeouts have the timer's resolution and never end early. |
| 204 | `sched_getaffinity(pid, size, mask)` | Every CPU that is up; 8 bytes. |
| 218 | `set_tid_address(ptr)` | Returns the thread ID. When the thread exits, zero is written to `ptr` and one futex waiter on it is woken. |
| 228 | `clock_gettime(clock, ts)` | Monotonic clocks count from boot. The real-time clock is time since boot counted from 2026-01-01: there is no clock chip driver yet. CPU-time clocks return time since boot. |
| 230 | `clock_nanosleep(clock, flags, req, rem)` | With `TIMER_ABSTIME` too. |
| 231 | `exit_group(status)` | Ends the process: every thread, wherever it is. |
| 239 | `get_mempolicy(mode, nodemask, maxnode, addr, flags)` | One memory node, the default policy: mode 0 and an empty mask. No flags. |
| 257 | `openat(dirfd, path, flags, mode)` | `AT_FDCWD` or an absolute path. |
| 262 | `newfstatat(dirfd, path, statbuf, flags)` | `stat` by path; of the descriptor itself with an empty path and `AT_EMPTY_PATH`. Paths are absolute, or relative to `AT_FDCWD` (`ENOTDIR` for another descriptor). Only files exist: a directory is `ENOENT`. |
| 267 | `readlinkat(dirfd, path, buf, size)` | As `readlink`. |
| 269 | `faccessat(dirfd, path, mode)` | As `access`. |
| 273 | `set_robust_list(head, size)` | Accepted and not used: a thread that dies takes its process with it. |
| 292 | `dup3(old, new, flags)` | `dup2`, with `EINVAL` if `old` is `new`. |
| 293 | `pipe2(fds, flags)` | A pipe of 4096 bytes (Linux: 65536); a write of up to that is not mixed with another. `O_NONBLOCK`; `O_CLOEXEC` is accepted. |
| 302 | `prlimit64(pid, resource, new, old)` | Reads limits of the calling process (stack 8 MiB, descriptors 16, the rest unlimited). Setting is `EPERM`. |
| 318 | `getrandom(buf, len, flags)` | Never blocks. |
| 324 | `membarrier(cmd, flags, cpu)` | `MEMBARRIER_CMD_QUERY`, `REGISTER_PRIVATE_EXPEDITED` and `PRIVATE_EXPEDITED`, which interrupts every other CPU. What a garbage collector uses to stop paying for barriers in every thread. |
| 334 | `rseq(...)` | Not offered: `ENOSYS`, on purpose. |
| 439 | `faccessat2(dirfd, path, mode, flags)` | As `access`. |

MyOS calls with no Linux equivalent yet. Their numbers start at
`0x4D5900`, far above Linux's (which end below 500) and below the x32 bit
(`0x40000000`). Milestone 6 replaces them with Linux calls.

| Number | Call | Notes |
| --- | --- | --- |
| `0x4D5900` | `myos_getchar()` | Block until a key is pressed; returns the character. |
| `0x4D5901` | `myos_run(path, argv, envp)` | Start the program at `path` with the arguments and environment given as for `execve` (either may be null: then the path is the only argument, and the environment is empty), and wait for it. Returns its exit status (0-255; 255 if the kernel killed it), or an error; `E2BIG` if arguments and environment do not fit. |

Every other number returns `ENOSYS`.

### Differences from Linux to know about

- **Paths** are NUL-terminated strings of at most 255 bytes (`PATH_MAX` is
  256 here, 4096 on Linux). They are absolute; there is no current directory.
- **Threads** share their process's address space, descriptors and signal
  handlers, and each has its own registers, FS and GS base and signal
  mask. `getpid` is the same in all of them, `gettid` different.
- **Descriptors.** A process has 16. It starts with 0, 1 and 2 open on the
  console; they can be closed, duplicated and replaced like any other.
  `open`, `dup` and `pipe2` return the lowest free one. Descriptors are
  not inherited by programs started with `myos_run`.
- **Counts** above `0x7ffff000` are shortened to that, as on Linux.
- **Limits.** Every process has limits, inherited from the process that
  started it: 256 MiB of memory (its program, stack, page tables and kernel
  stack), 16 descriptors,
  and 1024 processes alive below it. There are no calls to read or change
  them yet (`getrlimit`, `prlimit`).
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
- **A process the kernel kills** (a fault in ring 3) ends with status 255.
  Signals are not delivered yet (milestone 8): handlers, masks and
  alternate stacks can be set and read back, which is what language
  runtimes do at startup, but nothing calls a handler.

## Program start

A program is entered at its ELF entry point in ring 3 the way Linux enters
one, with:

- all general-purpose registers zero, RFLAGS `0x202` (interrupts on);
- a stack whose top is at a random page in a 16 GiB range below
  `0x7fffffff0000`, different for every process. It may grow to 8 MiB,
  and gets its pages as it is used;
- `rsp` on a 16-byte boundary, pointing at the initial stack described
  below, which ends a random distance below the top of the stack;
- FS and GS base zero, until the program sets them with `arch_prctl`;
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
| `AT_CLKTCK` (17) | 100 |
| `AT_SECURE` (23) | 0 |
| `AT_RANDOM` (25) | address of 16 random bytes, new for every process |
| `AT_EXECFN` (31) | address of the path the program was started under |

There is no vDSO (`AT_SYSINFO_EHDR`): a program that looks for one makes
real system calls instead.

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
