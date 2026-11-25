# What Linux programs ask of the kernel

MyOS runs programs built for Linux, unmodified. This page records what such
programs actually ask for when they start and print one line, measured on
Linux with `strace -f`. It decides the order of work in milestones 4 to 9
([roadmap](todo.md)): a call that every runtime makes before `main` comes
before one that only some program might make later.

The programs are the smallest ones each toolchain produces, statically
linked. `tests/fixtures/` will hold them with the commands that built them
([roadmap 4.3](todo.md#43-fixtures)).

Measured on 2026-11-25 with Zig's bundled musl, Go 1.27 and Rust 1.95. The
.NET Native AOT program and the Rust program linked against musl are still
to be measured; so is which of the calls must really work and which may
fail (the Loupe method, [research](research.md)).

## System calls, by program

| Call | musl C | Rust (static glibc) | Go | Needed for |
| --- | --- | --- | --- | --- |
| `write` | | yes | yes | output |
| `writev` | yes | | | output (musl's `printf`) |
| `exit_group` | yes | yes | yes | ending the process |
| `arch_prctl` (`ARCH_SET_FS`) | yes | yes | yes | thread-local storage |
| `set_tid_address` | yes | yes | | thread exit notification |
| `ioctl` (`TIOCGWINSZ`) | yes | | | is standard output a terminal? `ENOTTY` is a fine answer |
| `brk` | | yes | | glibc's allocator |
| `mmap` (anonymous) | | 1 call, 12 KiB | 14 calls, 1.1 GiB reserved | memory; Go reserves far more than it touches |
| `munmap`, `mprotect` | | yes | | stack guard pages, releasing memory |
| `madvise` | | | yes | giving memory back |
| `rt_sigaction`, `rt_sigprocmask`, `sigaltstack` | | yes | yes | signal handlers, installed at startup |
| `clone` | | | 7 threads | Go starts threads before `main` |
| `futex` | | | yes | every lock and wake-up between threads |
| `gettid` | | yes | yes | |
| `sched_getaffinity` | | yes | yes | how many CPUs there are |
| `nanosleep` | | | yes | |
| `getrandom` | | yes | | hash seeds |
| `prlimit64` | | yes | yes | stack size limit |
| `set_robust_list`, `rseq` | | yes | | may fail with `ENOSYS` |
| `poll` | | yes | | checks that descriptors 0 to 2 are open |
| `openat`, `read`, `pread64`, `close`, `fstat`, `lseek`, `readlinkat`, `fcntl` | | yes | yes | the files below |
| `prctl` (`PR_SET_VMA`) | | | yes | names its mappings; may fail |

## Files they open

| File | Program | What for | If it is missing |
| --- | --- | --- | --- |
| `/proc/self/maps` | Rust | finding the main thread's stack, to guard it | carries on |
| `/proc/self/exe` (link) | Rust | its own path | carries on |
| `/sys/kernel/mm/transparent_hugepage/hpage_pmd_size` | Go | huge page size | assumes none |
| `/proc/self/cgroup`, `/proc/self/mountinfo`, a `cpu.max` file | Go | CPU limit of its container | uses all CPUs |

None of these files has to exist: each program goes on without them.

## What the kernel has to hand over at startup

All three read their arguments, environment and the auxiliary vector from
the initial stack, laid out as Linux does. From the auxiliary vector they
use `AT_PHDR`, `AT_PHNUM` and `AT_PHENT` (to find their thread-local data),
`AT_PAGESZ`, `AT_RANDOM` (stack protector and hash seeds) and `AT_HWCAP`.
None needs a vDSO: without `AT_SYSINFO_EHDR` they make real system calls
for the time.

## What this means for the order of work

1. **The static musl program needs five new calls and the startup stack**,
   and nothing else: milestone 4.
2. **Rust adds memory calls and signals as no-ops**: `brk`, `mmap`,
   `munmap`, `mprotect`, signal setup that only has to be accepted, and a
   handful of calls that may fail. No threads. It is the natural second
   program, ahead of where the roadmap has it.
3. **Go cannot start without threads, futexes and large lazy reservations**
   (1.1 GiB of address space, almost none of it touched): milestones 5 and 7
   in full before its first line of output.
