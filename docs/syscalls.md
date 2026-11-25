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
| 0 | `read(fd, buf, count)` | Regular files only. Descriptor 0 is not readable yet (`EBADF`); use `myos_getchar`. |
| 1 | `write(fd, buf, count)` | Descriptors 1 and 2 only, both the console (serial port and screen). Files cannot be written (`EBADF`). |
| 2 | `open(path, flags, mode)` | Read-only: the access mode in `flags` must be `O_RDONLY`. Other flags and `mode` are ignored, except that `O_CREAT` on a missing file gives `EROFS`. |
| 3 | `close(fd)` | Closing 0, 1 or 2 succeeds and does nothing. |
| 7 | `poll(fds, nfds, timeout)` | Console output is always writable, open files always readable, descriptor 0 never; a descriptor that is not open gets `POLLNVAL`. With nothing ready it waits out the timeout and returns 0. |
| 9 | `mmap(addr, length, prot, flags, fd, offset)` | Anonymous memory only (`MAP_ANONYMOUS` with `MAP_PRIVATE` or `MAP_SHARED`; a file is `ENODEV`). `MAP_FIXED`, `MAP_FIXED_NOREPLACE`, and an address hint that is used if it is free; otherwise placed top down. `MAP_NORESERVE` and `MAP_STACK` are accepted. The memory is given page by page as it is touched. |
| 10 | `mprotect(addr, length, prot)` | `ENOMEM` if part of the range is not mapped. Memory may be writable and executable at once. |
| 11 | `munmap(addr, length)` | Any part of any mappings; unmapping what is not mapped succeeds. |
| 12 | `brk(addr)` | Returns the new end of the heap, or the old one if it cannot move. |
| 13 | `rt_sigaction(sig, act, oldact, size)` | Recorded and read back. No signal is delivered yet (milestone 8): a fault still ends the process. |
| 14 | `rt_sigprocmask(how, set, oldset, size)` | The thread's blocked signals, recorded. |
| 16 | `ioctl(fd, request, arg)` | No device has requests yet: `ENOTTY` for the standard streams and open files (how a C library finds out that its output is not a terminal), `EBADF` otherwise. |
| 20 | `writev(fd, iov, iovcnt)` | `write` from up to 1024 buffers. Descriptors 1 and 2 only. |
| 24 | `sched_yield()` | |
| 28 | `madvise(addr, length, advice)` | `MADV_DONTNEED` and `MADV_FREE` give the pages back at once: they read as zeroes afterwards. Other advice is accepted and ignored. |
| 60 | `exit(status)` | The parent sees `status & 0xff`. Ends the process (which has one thread). |
| 131 | `sigaltstack(ss, old_ss)` | The thread's alternate signal stack, recorded. |
| 158 | `arch_prctl(code, addr)` | `ARCH_SET_FS`, `ARCH_SET_GS`, `ARCH_GET_FS`, `ARCH_GET_GS`: the thread's FS and GS base, kept across switches. A base outside user space is `EPERM`. |
| 186 | `gettid()` | |
| 218 | `set_tid_address(ptr)` | Returns the thread ID. The address is kept for when threads exist (milestone 7). |
| 231 | `exit_group(status)` | The same as `exit`: a process has one thread. |

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
- **Descriptors.** A process has 16: 0, 1 and 2 are the standard streams,
  so 13 files can be open at once. `open` returns the lowest free one from 3
  up. Descriptors are not inherited by programs started with `myos_run`.
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
