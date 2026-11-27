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
Which of them must really work and which may fail is measured below
(["Which calls must work"](#which-calls-must-work)).

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

## Which calls must work

Measured on 2026-11-27 with `tools/syscall-survey/survey.sh`, Loupe's
method ([research](research.md)) with nothing but `strace`: each program
runs once as it is, then once for every call it makes with every use of
that call failing with `ENOSYS`, and once with every use faking success
(returning 0). The output and exit status are compared with the plain
run.

- **needed**: the program breaks (crashes, exits differently or hangs)
  both ways. These have to work.
- **may fail**: `ENOSYS` is fine; the call can be left out at first.
- **may be faked**: answering 0 is fine, failing is not.
- **either**: the program does not care: it ends the same, saying the
  same, with the call failing or faked.
- **output**: it ends as before but says something else (fewer CPUs, for
  one). To be judged by what it says.

`exit_group`, `exit` and `execve` are left out. A call no program makes is
not listed.

| Call | C, static musl | C with pthreads, static musl | Rust, static | C, dynamic glibc | Go, static | .NET ahead of time (glibc) | .NET self-contained, JIT |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `access` |  |  |  | either |  | either | may be faked |
| `arch_prctl` | may be faked | **needed** | **needed** | **needed** | **needed** | **needed** | **needed** |
| `bind` |  |  |  |  |  |  | either |
| `brk` |  |  | either | either |  | either | either |
| `clone3` |  |  |  |  |  | may fail | may fail |
| `clone` |  | **needed** |  |  | **needed** |  |  |
| `close` |  |  |  | may be faked | either | may be faked | may be faked |
| `epoll_create1` |  |  |  |  | **needed** |  |  |
| `epoll_ctl` |  |  |  |  | may be faked |  |  |
| `epoll_pwait` |  |  |  |  | may be faked |  |  |
| `eventfd2` |  |  |  |  | **needed** |  |  |
| `fchmod` |  |  |  |  |  |  | either |
| `fcntl` |  |  |  |  | may be faked | **needed** | **needed** |
| `fstat` |  |  |  | **needed** |  | **needed** | **needed** |
| `ftruncate` |  |  |  |  |  |  | may fail |
| `futex` |  | either |  |  | may be faked | may be faked | may be faked |
| `get_mempolicy` |  |  |  |  |  | either | either |
| `getdents64` |  |  |  |  |  | either | either |
| `getpid` |  |  |  |  | **needed** | either | may fail |
| `getrandom` |  |  |  | either |  | either | either |
| `getsid` |  |  |  |  |  |  | either |
| `gettid` |  |  |  |  | **needed** | either | either |
| `ioctl` | either | either |  | either |  | may fail | may fail |
| `listen` |  |  |  |  |  |  | either |
| `lseek` |  |  |  |  |  | either | either |
| `madvise` |  |  |  |  | either | either | either |
| `membarrier` |  |  |  |  |  | either | either |
| `memfd_create` |  |  |  |  |  |  | either |
| `mknodat` |  |  |  |  |  |  | either |
| `mmap` |  | **needed** | **needed** | **needed** | **needed** | **needed** | **needed** |
| `mprotect` |  | **needed** | may be faked | may be faked |  | **needed** | **needed** |
| `munmap` |  | either | either |  |  | either | may be faked |
| `nanosleep` |  |  |  |  | either |  |  |
| `newfstatat` |  |  |  | either |  | either | either |
| `openat` |  |  |  | **needed** | either | **needed** | **needed** |
| `pipe2` |  |  |  |  |  | may be faked | **needed** |
| `poll` |  |  | may be faked |  |  |  | either |
| `prctl` |  |  |  |  | either | either | either |
| `pread64` |  |  |  |  | either |  | either |
| `prlimit64` |  |  |  | either | either | may fail | **needed** |
| `read` |  |  |  | **needed** | either | **needed** | **needed** |
| `readlink` |  |  |  |  |  |  | **needed** |
| `rseq` |  |  |  | either |  | either | either |
| `rt_sigaction` |  |  | may be faked |  | **needed** | **needed** | **needed** |
| `rt_sigprocmask` |  | either | either |  | may be faked | either | either |
| `rt_sigreturn` |  |  |  |  | **needed** | **needed** |  |
| `sched_get_priority_max` |  |  |  |  |  |  | either |
| `sched_get_priority_min` |  |  |  |  |  |  | either |
| `sched_getaffinity` |  |  |  |  | output | either | may fail |
| `sched_getparam` |  |  |  |  |  |  | either |
| `sched_getscheduler` |  |  |  |  |  |  | either |
| `sched_setaffinity` |  |  |  |  |  |  | may be faked |
| `sched_setscheduler` |  |  |  |  |  |  | either |
| `sched_yield` |  |  |  |  | either | either | either |
| `set_robust_list` |  |  |  | either |  | either | either |
| `set_tid_address` | either | either | either | either |  | either | may fail |
| `sigaltstack` |  |  | either |  | **needed** |  | may be faked |
| `socket` |  |  |  |  |  |  | either |
| `stat` |  |  |  |  |  |  | may fail |
| `statfs` |  |  |  |  |  | either | either |
| `sysinfo` |  |  |  |  |  | **needed** | **needed** |
| `tgkill` |  |  |  |  | **needed** |  |  |
| `unlink` |  |  |  |  |  |  | either |
| `write` |  |  | **needed** | **needed** | output | **needed** | **needed** |
| `writev` | **needed** | **needed** |  |  |  |  |  |

What follows for the work: every call marked needed is implemented. Of
those that may fail or may be faked, nothing is left to do for these
programs; they show which calls a smaller kernel could answer with
`ENOSYS` (`set_robust_list`, `rseq`, `clone3` where glibc falls back to
`clone`, `prlimit64`, `getrandom` for glibc, `sched_getaffinity` for
.NET). The table is from the fixtures' hello-world programs: a program
that does more needs more, and is surveyed the same way
(`tools/syscall-survey/survey.sh NAME -- PROGRAM ARGS`).

## What the kernel has to hand over at startup

All three read their arguments, environment and the auxiliary vector from
the initial stack, laid out as Linux does. From the auxiliary vector they
use `AT_PHDR`, `AT_PHNUM` and `AT_PHENT` (to find their thread-local data),
`AT_PAGESZ`, `AT_RANDOM` (stack protector and hash seeds) and `AT_HWCAP`.
None needs a vDSO: without `AT_SYSINFO_EHDR` they make real system calls
for the time. MyOS has one since 9.2 (glibc and Go use it for the clock).

## What runs

| Program | Status |
| --- | --- |
| C, static, musl | Runs (`tests/fixtures/` builds `musl-hello-static`) |
| Rust with std, static, musl, fixed address | Runs (`tests/fixtures/` builds `rust-hello-static`) |
| C with pthreads, static, musl | Runs, its threads on several CPUs (`tests/fixtures/` builds `musl-threads-static`) |
| C and Rust as static position-independent executables | Run, at a random address (`musl-hello-static-pie`, `rust-hello-static-pie`) |
| Go, static | Runs: the runtime's threads, goroutines on every CPU, a channel, a garbage collection (`tests/fixtures/` builds `go-hello-static`). No signal has to be delivered for that; the runtime sends itself some (to preempt goroutines that do not yield) and carries on when they do not arrive |
| .NET Native AOT, static, musl, fixed address | Runs: the runtime, eight managed threads that allocate, a garbage collection that stops them (`tests/fixtures/` builds `dotnet-hello-static`). No signal has to be delivered: the collector stops threads through `membarrier` and the checks compiled into managed code |
| C, dynamically linked against glibc | Runs (`tests/fixtures/` builds `glibc-hello-dynamic`): the kernel loads `ld-linux-x86-64.so.2`, which maps `libc.so.6` from its file. Loader and library are Debian 13's, unchanged (`scripts/fetch-sysroot.sh`). Beyond a static program it calls `newfstatat`, `access`, `mmap` of a file, `set_robust_list` and `rseq` (which it does without) |
| .NET ahead of time as its tools build it (`dotnet publish -r linux-x64 -p:PublishAot=true`) | Runs (`tests/fixtures/` builds `dotnet-hello-aot`): dynamically linked against glibc, position independent. glibc makes its threads with `clone3` |
| .NET as its tools build it (`dotnet publish -r linux-x64 --self-contained`) | Runs (`tests/fixtures/` builds `dotnet-hello-app`): the host program, `libhostfxr`, `libhostpolicy`, `libcoreclr` and the JIT compiler `libclrjit` from the program's folder, eight managed threads, a garbage collection. Trimmed in the fixture; the untrimmed 80 MB folder runs the same. No signal has to be delivered for this program |

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
