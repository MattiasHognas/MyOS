# What Linux programs ask of the kernel

MyOS runs programs built for Linux, unmodified. This page records what such
programs actually ask for when they start and print one line, measured on
Linux with `strace -f`. It decides the order of work in milestones 4 to 9
([roadmap](todo.md)): a call that every runtime makes before `main` comes
before one that only some program might make later.

The programs are the smallest ones each toolchain produces, statically
linked. `tests/fixtures/` will hold them with the commands that built them
([roadmap 4.3](todo.md#43-fixtures)).

Measured on 2026-11-25 with Zig's bundled musl, Go 1.27 and Rust 1.95.
Which of the calls must really work and which may fail is still to be
measured (the Loupe method, [research](research.md)).

The .NET Native AOT program (.NET 10, linux-musl, static) was not traced
into the table; it was run on MyOS with every unknown call logged
(`syscall.trace_unknown`) until none was left. Beyond what Go and Rust
use it asked for: `pipe2` (the console setup makes one), `fcntl` with
real descriptors behind 0, 1 and 2, `membarrier` (and `mlock` if that is
missing), `sysinfo`, `statfs` (it looks for control groups), `mremap`
(musl measures the main thread's stack with it, and loops for ever on an
answer other than `EFAULT` below the stack), and `get_mempolicy`. It
opens `/proc/self/mountinfo`, `/proc/self/cgroup`, `/proc/meminfo` and
files under `/sys/devices/system/cpu`, and goes on without them.

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

## What runs

| Program | Status |
| --- | --- |
| C, static, musl | Runs (`tests/fixtures/bin/musl-hello-static`) |
| Rust with std, static, musl, fixed address | Runs (`tests/fixtures/bin/rust-hello-static`) |
| C with pthreads, static, musl | Runs, its threads on several CPUs (`tests/fixtures/bin/musl-threads-static`) |
| C and Rust as static position-independent executables | Run, at a random address (`musl-hello-static-pie`, `rust-hello-static-pie`) |
| Go, static | Runs: the runtime's threads, goroutines on every CPU, a channel, a garbage collection (`tests/fixtures/bin/go-hello-static`). No signal has to be delivered for that; the runtime sends itself some (to preempt goroutines that do not yield) and carries on when they do not arrive |
| .NET Native AOT, static, musl, fixed address | Runs: the runtime, eight managed threads that allocate, a garbage collection that stops them (`tests/fixtures/bin/dotnet-hello-static`). No signal has to be delivered: the collector stops threads through `membarrier` and the checks compiled into managed code |
| C, dynamically linked against glibc | Runs (`tests/fixtures/bin/glibc-hello-dynamic`): the kernel loads `ld-linux-x86-64.so.2`, which maps `libc.so.6` from its file. Loader and library are Debian 13's, unchanged (`scripts/fetch-sysroot.sh`). Beyond a static program it calls `newfstatat`, `access`, `mmap` of a file, `set_robust_list` and `rseq` (which it does without) |
| .NET ahead of time as its tools build it (`dotnet publish -r linux-x64 -p:PublishAot=true`) | Runs (`tests/fixtures/bin/dotnet-hello-aot`): dynamically linked against glibc, position independent. glibc makes its threads with `clone3` |
| .NET as its tools build it (`dotnet publish -r linux-x64 --self-contained`) | The goal ([roadmap 9](todo.md)). Dynamically linked against glibc, which runs; the runtime itself is next, and for the JIT signals |

## What this means for the order of work

1. **The static musl program needs five new calls and the startup stack**,
   and nothing else: milestone 4.
2. **Rust adds memory calls and signals as no-ops**: `brk`, `mmap`,
   `munmap`, `mprotect`, signal setup that only has to be accepted, and a
   handful of calls that may fail. No threads. It is the natural second
   program, ahead of where the roadmap has it.
3. **Go cannot start without threads, futexes and large lazy reservations**
   (1.1 GiB of address space, almost none of it touched): milestones 5 and 7.
   With those it runs. The only call it made that the kernel did not know
   was `prctl`, which it does not need.
