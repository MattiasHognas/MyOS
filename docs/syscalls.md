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
| 24 | `sched_yield()` | |
| 60 | `exit(status)` | The parent sees `status & 0xff`. Ends the process (which has one thread). |
| 186 | `gettid()` | |

MyOS calls with no Linux equivalent yet. Their numbers start at
`0x4D5900`, far above Linux's (which end below 500) and below the x32 bit
(`0x40000000`). Milestone 6 replaces them with Linux calls.

| Number | Call | Notes |
| --- | --- | --- |
| `0x4D5900` | `myos_getchar()` | Block until a key is pressed; returns the character. |
| `0x4D5901` | `myos_run(path)` | Start the program at `path` and wait for it. Returns its exit status (0-255; 255 if the kernel killed it), or an error. |

Every other number returns `ENOSYS`.

### Differences from Linux to know about

- **Paths** are NUL-terminated strings of at most 255 bytes (`PATH_MAX` is
  256 here, 4096 on Linux). They are absolute; there is no current directory.
- **Descriptors.** A process has 16: 0, 1 and 2 are the standard streams,
  so 13 files can be open at once. `open` returns the lowest free one from 3
  up. Descriptors are not inherited by programs started with `myos_run`.
- **Counts** above `0x7ffff000` are shortened to that, as on Linux.
- **Limits.** Every process has limits, inherited from the process that
  started it: 256 MiB of memory for its program and stack, 16 descriptors,
  and 1024 processes alive below it. There are no calls to read or change
  them yet (`getrlimit`, `prlimit`).
- **Running out of memory** fails the call that needed it with `ENOMEM`.
  Nothing is killed to make room.
- **A process the kernel kills** (a fault in ring 3) ends with status 255.
  There are no signals yet (milestone 8).

## Program start

A program is entered at its ELF entry point in ring 3 with:

- all general-purpose registers zero, RFLAGS `0x202` (interrupts on);
- `rsp` 8 below the top of a 16 KiB stack, as if the entry point had been
  called. Linux's initial stack (`argc`, `argv`, the environment and the
  auxiliary vector) comes with milestone 4;
- clean extended state: x87 control word `0x37f`, MXCSR `0x1f80`, all x87,
  SSE and AVX registers zero.

SSE and SSE2 are always available. AVX is available when CPUID reports
`OSXSAVE` and AVX and `xgetbv` shows bits 1 and 2 of XCR0 set: the usual
check, which `tests/user/fpu_regs.zig` shows. AVX-512 is never enabled.

## How the kernel implements it

- `src/arch/x86_64/syscall.zig`: the entry and exit assembly, with a
  step-by-step account of the stack, GS base and interrupt state.
- `src/arch/x86_64/sysret.zig`: whether a return can use `sysretq`, needs
  `iretq`, or is impossible (the process is killed).
- `src/arch/x86_64/percpu.zig`: the per-CPU area behind the kernel's GS base.
- `src/arch/x86_64/fpu.zig`: saving and restoring x87/SSE/AVX state.
- `src/kernel/syscall.zig`: the calls themselves.

To add a call, see [development](development.md#adding-a-syscall).
