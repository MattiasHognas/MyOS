# Beyond Linux: design research, 2026-11-27

MyOS runs unmodified Linux programs, and its system calls are Linux's.
That decides what programs see; it does not decide what is behind it.
This document is the research session the order of work in `todo.md`
asks for after 9.1: for each area, where MyOS stands, what Linux does,
what could be done better, and a recommendation. The recommendations
marked **Decision** change the plan of a later milestone; what was
decided is at the end ([Decided](#decided-2026-11-27)). The rest are
tasks in `todo.md`.

The papers already summarized in `research.md` (CortenMM, LLFree,
Converos, FRED, LASS, Loupe, Asterinas, ...) are not repeated here.

Contents: [the ABI .NET asks for](#1-the-abi-net-asks-for) ·
[security and the process model](#2-security-and-the-process-model) ·
[I/O and networking](#3-io-and-networking) ·
[storage](#4-storage) ·
[scheduling, memory and measuring](#5-scheduling-memory-and-measuring) ·
[what this changes in the plan](#6-what-this-changes-in-the-plan)

---

## 1. The ABI .NET asks for

What MyOS knew it needed came from traces of the fixtures, and a call
made only on a path they never take was missed (`flock`, found in 9.1
when the fixture first read a file). This section is from the runtime's
sources instead (`dotnet/runtime`, branch `release/10.0`:
`src/native/libs/System.Native`, `src/coreclr/pal`, `src/coreclr/gc/unix`,
`src/native/eventpipe`), so it covers what an ordinary app can reach.

**Kernel version.** .NET 10 names no minimum kernel; its floor is glibc
2.27 (RHEL 8: kernel 4.18). The runtime does parse `uname`'s release as
`major.minor` and gates features on it: `memfd_create` from 3.17,
`copy_file_range` from 5.3. MyOS says 6.1 and so is offered all of them,
and must answer `ENOSYS` cleanly for what it lacks (it does).

**Already right, and why it mattered.**

- The thread-suspension signal is `SIGRTMIN` (34 under glibc), sent with
  `tgkill`, and the handler takes it only if `si_pid` is the process's own.
  `tgkill` reporting the sender (8, queued signals) is what makes that hold.
- The collector decides on control groups by `statfs("/sys/fs/cgroup")`
  returning `0x63677270`, then reads `memory.max`, `memory.current`,
  `memory.stat` (`inactive_file`) and `cpu.max` (9.1).
- Every `FileStream` takes `flock(LOCK_SH or LOCK_EX | LOCK_NB)`; only
  `EWOULDBLOCK` is an error (9.1).
- Conditions wait with `FUTEX_WAIT_BITSET` and an absolute monotonic time;
  `CLOCK_MONOTONIC_COARSE`, `CLOCK_BOOTTIME`, `/proc/self/maps` for the
  main stack, `membarrier`, the alternate signal stack per thread: all there.
- Not used by .NET at all: `timerfd`, `eventfd`, `signalfd`, `io_uring`,
  `pidfd`, `statx`, `close_range`. glibc may try `clone3` and `rseq` and
  takes `ENOSYS`.

**What an ordinary app can reach that MyOS lacks**, most likely first:

| Area | What | Triggered by | If missing |
|---|---|---|---|
| Processes | `waitid(P_ALL, WEXITED\|WNOHANG\|WNOWAIT)`, `getrusage`, `getpriority`/`setpriority` | `Process.Start` reaping, `Process` properties | Children not reaped; exceptions |
| Files | `utimensat`/`futimens`, `symlink`, `link`, `fcntl(F_SETLK)` record locks, `fallocate`, `posix_fadvise`, `sendfile`, `copy_file_range`, `FICLONE` | `File.Copy`, `File.SetLastWriteTime`, `FileStream.Lock`, `File.CreateSymbolicLink`, preallocation | Exceptions (fallbacks for copy and advice) |
| Watching | `inotify_init1`, `inotify_add_watch` with rename cookies and `IN_Q_OVERFLOW` | `FileSystemWatcher`; ASP.NET configuration with `reloadOnChange`, on by default in the generic host | Exception at startup of a web app |
| Memory | `memfd_create` with `MFD_ALLOW_SEALING` and `F_ADD_SEALS`; `MAP_SHARED` of it (W^X double mapping, on by default); `madvise(MADV_DODUMP/DONTDUMP/DONTFORK)` | The JIT, anonymous `MemoryMappedFile` | W^X off (silently), or exceptions |
| Shared mutexes | Robust process-shared pthread mutexes in `MAP_SHARED` files under `$TMPDIR/.dotnet/shm`: shared (not private) futexes, `set_robust_list` honored, `EOWNERDEAD` | Named `Mutex`, single-instance apps | Hangs or exceptions |
| Diagnostics | A Unix socket `$TMPDIR/dotnet-diagnostic-<pid>-...-socket` (`fchmod` on the socket before `bind`), FIFOs `clr-debug-pipe-*` (`mkfifo`), `/proc/<pid>/stat` | Every startup, unless `DOTNET_EnableDiagnostics=0` | Tolerated: diagnostics off |
| Sockets | `AF_INET`/`AF_INET6`/`AF_UNIX`, epoll with `EPOLLET\|EPOLLRDHUP`, `accept4`, non-blocking `connect` then `SO_ERROR`, `SO_REUSEADDR`/`SO_REUSEPORT`, `IPV6_V6ONLY=0`, `sendmsg`/`recvmsg` with `IP_PKTINFO`, `SO_PEERCRED`, `connect(AF_UNSPEC)` | Kestrel, `HttpClient` | Milestone 12 |
| Names | glibc `getaddrinfo`: `/etc/nsswitch.conf`, `/etc/hosts`, `/etc/resolv.conf`, `/etc/gai.conf`, `libnss_*`, UDP with `sendmmsg`; `getifaddrs` over netlink (`RTM_GETLINK`, `RTM_GETADDR`) | `Dns`, `NetworkInterface` | Milestone 12 |
| Console | `TIOCGWINSZ`, raw mode through termios (`IEXTEN`, `IXON`, `VMIN`/`VTIME`), `SIGWINCH`, `SIGCONT` re-applying termios | `Console.ReadKey`, `Console.WindowWidth` | Mostly there |
| /proc, /sys | `/proc/self/status` (`TracerPid`), `/proc/self/statm`, `/proc/<pid>/task/<tid>/comm` (thread names), `/proc/self/mounts`, `/sys/devices/system/cpu/cpu0/cache/index*/size` (gen0 size), `/sys/devices/system/node` | `Debugger.IsAttached`, thread names, `DriveInfo`, the collector | Tolerated mostly |

The environment variables that change what the runtime asks of the
kernel (`DOTNET_EnableWriteXorExecute`, `DOTNET_GCHeapHardLimit`,
`DOTNET_EnableDiagnostics`, `DOTNET_SYSTEM_IO_DISABLEFILELOCKING`,
`DOTNET_GCgen0size`, ...) are for testing each path, not for users.

**Recommendation.** A fixture that is a real app rather than a
hello-world: the generic host with configuration reload, a
`FileSystemWatcher`, `Process.Start` of a child, `File.Copy`, a named
mutex, a console in raw mode, and later Kestrel. Add the rows above to
`todo.md` where their milestone is (9.3 for files, processes, memory and
watching; 12 for sockets and names).

---

## 2. Security and the process model

**Where MyOS stands.** One user, no permissions at all: every process
can name every file, process and (later) port. Per-process limits, SMEP,
SMAP, guard pages, address randomization.

**What Linux does.** Ambient authority: anything can name anything, and
a check decides. Its confinement came one layer at a time, each working
around the one before: users and setuid, capabilities(7), seccomp,
seven kinds of namespace over a decade, Landlock. seccomp sees system call
numbers and registers but not what pointers point at, so `clone3` has
to be blocked outright and glibc's move to it broke sandboxes; user
namespaces became a steady source of privilege escalations.

**What others do.**

- **Fuchsia (Zircon):** every object is reached through a handle with a
  rights mask that can only be narrowed; there is no ambient authority. Its
  Starnix layer runs unmodified Linux programs as components that hold
  only what their manifest routed to them: the model MyOS would follow.
- **Capsicum (FreeBSD):** after `cap_enter`, a process acts only through
  the descriptors it holds, with fine-grained rights, and `openat` below
  directories it was given. A few percent of overhead.
- **Plan 9:** each process has its own namespace (mount table), composed
  by its parent with bind and mount; `/dev`, `/proc`, `/net` are servers
  mounted into it. Containers and `chroot` fall out of it.
- **OpenBSD pledge and unveil:** a program names the kinds of calls it
  will make ("stdio rpath inet") and the paths it may see; it can only
  narrow. It needs the program's cooperation (Go cannot pledge reliably).
- **WASI:** directories and sockets are opened in advance by the host and
  handed in; the C library maps paths onto them.
- **Genode:** a tree of sandboxes; a parent routes services and donates
  memory to its children.
- **Android:** an identity per app, not per person.

**What can be better, for unmodified programs.** A process gets what its
launcher gave it, and nothing else, from the start: Linux has to
retrofit this and MyOS does not.

1. **Per-process views** (Plan 9's namespace): the filesystem a process
   sees is a list of mounts its parent composed, which it inherits and
   can only narrow. The persistent filesystem of 11 and `/etc/resolv.conf`
   of 12 are mounted into views, not at one global root. One path walk
   over a per-process mount list; `chroot` and containers for free.
2. **Rights on descriptors** (Capsicum, Zircon): each entry of the
   descriptor table carries what may be done with it; `dup` and passing
   it to another process can only narrow it. Small now, since the table is
   young.
3. **Network as a grant**: binding, connecting and listening only with a
   network right the launcher gave, filtered by port and address. Denied
   calls fail with `EACCES`; nothing is killed.
4. **Profiles applied from outside** (pledge's vocabulary, applied at
   `execve` by the launcher): a short declaration of a view, rights and
   limits, with ready ones for ".NET app", "Go server", "command".
5. **Linux's own self-sandboxing calls** (Landlock, seccomp) mapped onto
   these, for programs that confine themselves.

**Users.** No users in the kernel: the identity is the profile. What
programs need is a believable picture, not enforcement: `getuid` returns
a stable number, `/etc/passwd` and `/etc/group` have an entry for it
(else glibc's `getpwuid` fails, a shell prints "I have no name!" and Go's
`os/user` errors), `HOME`, `USER` and `TMPDIR` are set, `stat` reports real
modes (the execute bit matters), and `chown` succeeds as a rootless
container's does.

**Pitfalls.** A deny-by-default view must still hold what every program
opens at startup (its own files, `/proc/self`, `/dev/null`,
`/dev/urandom`, `/etc` basics); denials must be clean errors, never a
`SIGSYS`; Go chooses fallbacks by the exact error number (`ENOSYS` is not
`EPERM`).

**Decision 1: adopt views, rights and the network grant?** Recommended:
yes, with views and rights before networking (12), the network grant
with the first socket (cheap then, costly to retrofit), profiles before
graphics, Landlock and seccomp after storage.

---

## 3. I/O and networking

**Where MyOS stands.** `poll` and `epoll` over pipes, the terminal,
eventfds and signalfds, all woken through one global readiness queue
(any change wakes every waiter, which then looks at everything it
watches: right, but it wakes too many). No network.

**Readiness or completion.** In the readiness model (epoll) the kernel
says "you can read now" and the program then reads: two calls per
operation, no buffers held by the kernel. In the completion model
(io_uring, Windows' IOCP) the program hands over the operation and the
buffer and is told when it is done: batching, and copies can be avoided.
FlexSC (OSDI 2010) measured large gains from calls that do not trap.

io_uring is also the warning: Google found about 60% of the kernel
exploits submitted to its program in 2022 used it, and turned it off on
ChromeOS, Android apps and its servers; Docker blocks it. Its operations
run in kernel worker threads that bypass the checks of the ordinary
calls, its shared memory brought complex lifetimes and use-after-free
bugs, and it grew fast.

**What can be better.** Make completion the kernel's inside: every
operation on a socket, pipe or file is a request that ends in a
callback, and a readiness change is just such an event. `epoll` and
`poll` are thin layers on top, which is what Go, .NET, nginx and libuv
call. Linux did the opposite (a synchronous core with io_uring added,
whose operations often fall back to "try, else hand to a worker"). If a
ring interface is ever offered, a few operations, no hidden workers, the
same checks.

Per-object wait lists come first: each epoll instance keeps a ready
list, each object a list of who watches it (Linux's `ep_poll_callback`),
so a packet wakes only those waiting for that socket. `EPOLLET`,
`EPOLLONESHOT`, `EPOLLEXCLUSIVE` and `EPOLLRDHUP` exactly as Linux.

**The stack.** Research dataplanes (IX, Arrakis, mTCP, Demikernel) need
special hardware or rewritten programs; not for unmodified binaries.
Google's Snap shows a network stack in its own address space is
affordable with shared-memory queues and polling. Fuchsia's netstack3 is
a user-space stack with its core separate from a POSIX "bindings" layer,
and publishes a POSIX-compatibility list. For MyOS now: in the kernel,
but written as a core with bindings, so that it can move out later.

Reuse or write: smoltcp (Rust) is clean and needs no heap but has no
SACK or timestamps and assumes one thread; lwIP (C) is mature but built
around one lock, with semantics that are not Linux's. Recommended: write
TCP in Zig with smoltcp's state machine as the reference, and test it
with packetdrill scripts from Linux's own tests and a fuzzer on received
packets. The socket semantics are the hard part, and no reused stack has
Linux's.

**Many cores.** Affinity-Accept and Fastsocket show that per-core accept
queues and per-core connection tables remove the contention that limits
Linux; `SO_REUSEPORT` (a listen queue per core) as the native model,
with a plain listener sharing them inside. Locality: the interrupt, the
protocol work and the woken thread on one core, which needs per-CPU run
queues (9.2) first.

**The device and the first test.** virtio-net over PCI (shared rings,
reusable for a virtio disk, multiqueue later) rather than e1000, whose
every register access is a VM exit. QEMU's user networking with
`hostfwd=tcp::8080-:8080` gives the guest 10.0.2.15, a gateway and a DNS
server; `curl localhost:8080` from the host works once there are
virtio-net, Ethernet, ARP, a static IPv4, TCP's passive open, and
`socket`/`bind`/`listen`/`accept4` with epoll. A packet capture
(`filter-dump`) for Wireshark.

**Decision 2: completion inside, per-core connection tables, TCP of our
own?** Recommended: yes; order in section 6.

---

## 4. Storage

**Where MyOS stands.** A read-only initrd in memory, `/tmp` in memory,
an NVMe driver that reads. Milestone 11 plans FAT32.

**FAT32 cannot be the disk.** Linux programs, .NET among them, rely on
what FAT32 does not have: an atomic `rename` over an existing file (every
"write a temporary, then rename" save, `File.Replace`), an `fsync` with a
meaning, symbolic and hard links, modes and the execute bit, files over
4 GiB, case-sensitive names. Programs would appear to work and lose data
in a crash. Linux does not use vfat as a root filesystem either.

**What others do.**

- **ZFS, btrfs, bcachefs:** never overwrite what is live; write new
  blocks, then commit by replacing one root pointer; checksums kept in the
  parent detect torn writes. Recovery is "use the last valid root". Large:
  btrfs took a decade.
- **littlefs:** the model for a small team. Copy-on-write, metadata in
  pairs of blocks written as small logs, every operation including rename
  atomic across power loss, about 6000 lines. Built for tiny flash; its
  directories do not scale, so take its commit protocol, not its
  structures.
- **EROFS, SquashFS:** compressed read-only images, mountable from a
  partition or a file.
- **OSTree, Nix, ChromeOS, Silverblue, Talos:** the system read-only and
  verified, updates written to the other of two slots and switched, the
  writable state on its own partition.
- **Crash consistency** (Pillai et al., OSDI 2014): 60 crash bugs in 11
  major programs, mostly orderings the program assumed and the filesystem
  never promised, behaving differently on ext3, ext4 and btrfs. ALICE and
  BOB explore crash states.
- **"fsyncgate" (2018):** Linux reported a failed write-back once, marked
  the pages clean, and a later `fsync` said all was well; PostgreSQL now
  stops on any `fsync` failure.

**What can be better.**

1. A write-back error sticks to the file: every later `fsync` returns
   `EIO`, through any descriptor, until the file is rewritten or truncated;
   failed pages are never quietly made clean.
2. Commits are whole: a transaction of the filesystem commits at once, so
   a `rename` is ordered after the writes to the file renamed, and "write a
   temporary, rename" is safe even when the program forgets `fsync` (what
   ext4 guesses at with `auto_da_alloc`).
3. `fsync` means on the medium: an NVMe flush (or FUA) before the commit
   block. Directory `fsync` honored and never needed.
4. The promises written down on one page, and tested by replaying every
   prefix of the block writes a QEMU run recorded.
5. One page cache, keyed by file and page, shared by `read`, `write` and
   `mmap`, written back by a thread on a timer and a dirty threshold no
   larger than Linux's; the block cache is the same cache.

**Decision 3: storage.** Recommended:

- A filesystem of MyOS's own as the disk: copy-on-write throughout,
  B-trees for directories and extents, checksums in parent pointers, two
  superblocks taking turns, commit = write the tree, flush, write the
  superblock, flush; full POSIX metadata; the sticky errors above. Its
  `mkfs` in `tools/`.
- FAT32 kept, for the EFI system partition and USB sticks only: mounted
  as a volume that says what it cannot do (`EPERM` for links and modes)
  and documented as not crash-safe.
- The system image as EROFS on two partitions (A and B), the writable
  state on the native filesystem: matches the FHS layout already decided.
- Order: partitions and block writes with flush, the page cache, the
  filesystem, the crash-replay test, FAT32, EROFS and the slots.

---

## 5. Scheduling, memory and measuring

**Where MyOS stands.** One ready queue for all CPUs, first in first
out; a 10 ms tick; one lock for all futexes; one lock per address space;
no PCID; the whole FPU state saved with plain XSAVE on every switch; no
vDSO, so every `clock_gettime` is a system call.

**What the runtimes want.**

- **.NET:** the thread pool's idle workers spin, then sleep on a futex,
  and a hill-climbing controller adds or removes threads by measured
  throughput. So futex wake-up latency and fairness to spinners are
  throughput. Suspending threads for a collection sends a signal to each
  and calls `membarrier`: fast signals and a fast `membarrier` shorten
  pauses. Server GC places its heaps by `sched_getcpu`.
- **Go:** since 1.25, `GOMAXPROCS` follows the control group's `cpu.max`
  (it reads the files 9.1 added); spinning threads call `sched_yield`;
  preemption is `SIGURG` through `tgkill`; `nanotime` is on hot paths and
  comes from the vDSO, which Go parses itself even in static programs.

**What can be better.**

- **One good scheduling policy, built in.** Per-CPU ready queues with
  stealing, wake-up on the waker's CPU when that helps, and a one-shot
  TSC-deadline timer instead of the tick (no tick when idle, a timer only
  when a slice ends). Linux's sched_ext (6.12) lets BPF programs replace
  the policy, which shows the built-in one does not suit everyone; MyOS
  can choose one for its workloads without BPF.
- **`sched_yield` defined:** if something else can run on this CPU, run
  it; otherwise return at once; never sleep, never move the caller.
- **A vDSO**: a read-only page with the clock's base, multiplier and a
  sequence count, and a small ELF image at `AT_SYSINFO_EHDR` with
  `__vdso_clock_gettime`, `__vdso_gettimeofday`, `__vdso_time`,
  `__vdso_getcpu`. Likely the largest single gain for both Go and .NET.
  glibc 2.35 and later read the CPU number from its `rseq` area: accepting
  `rseq` and keeping `cpu_id` current gives a `sched_getcpu` without a
  system call.
- **Futex buckets** with a lock each, keyed by address space and address.
- **A mask of the CPUs that run each address space**: TLB shootdowns
  only to those, a cheap `membarrier`, faster signal fan-out for
  collections and Go's preemption.
- **Large pages without compaction**: a 2 MiB page on first touch of a
  large anonymous region when one is free (LLFree makes that cheap), and
  never a background compactor (Linux's caused latency spikes for Go and
  .NET). `MADV_DONTNEED` is the path that matters (Go went back to it in
  1.16): batch its shootdowns, keep zeroed pages ready.
- **Always-on counters**, cheap enough to leave on, which Linux cannot
  say: per thread, calls made and cycles in each with a latency histogram;
  per lock class, contended acquisitions and cycles waited; time spent
  ready but not running. In `/proc`. Tracing rings per CPU, dumped on
  demand.

**Measuring fairly** (LEBench, SOSP 2019, found 75% of Linux's core
operations got slower from 3.0 to 4.20, mostly through mitigations and
features; will-it-scale; lmbench):

1. The same static programs on both kernels, on one machine; record
   Linux's version, tick rate, preemption model and configuration.
2. Linux with default mitigations and with `mitigations=off`, and MyOS's
   own mitigations listed: otherwise the system-call numbers say nothing.
3. Frequency fixed (performance governor, no turbo, limited C-states),
   SMT stated.
4. Under KVM, timer and IPI exits dominate futex and switch costs:
   pinned vCPUs, an idle host, the same clock source; bare metal where it
   can be had.
5. Warm-up, many runs, median and 99th percentile.

**Order for 9.2** (replacing the list in `todo.md`'s 9.2 where it
differs): the benchmark harness first (LEBench's operations, ping-pongs,
faults, thread churn, `mmap` churn, all as 1 to N copies, plus a .NET
thread-pool and collector workload and a Go one, on Linux and MyOS,
results as CSV); the counters; the vDSO and `rseq`; per-CPU queues with
the one-shot timer (this is also the open task of 3.4); futex buckets;
the CPU mask per address space; then XSAVEOPT or XSAVES and PCID once
the harness says what a switch costs.

---

## 6. What this changes in the plan

The order of work stays as decided: 9.2 with 3.4, 9.3, networking (12),
storage (11), then research before graphics. What changes inside it:

| Where | Change | Kind |
|---|---|---|
| 9.2 | Reordered as in section 5: harness, counters, vDSO and `rseq`, per-CPU queues and a one-shot timer, futex buckets, CPU mask per address space, then switch costs | Tasks |
| 9.3 | Gaps from section 1: `waitid`, `getrusage`, `get/setpriority`, `utimensat`/`futimens`, `symlink`, `link`, `fcntl` record locks, `fallocate`, `posix_fadvise`, `sendfile`, `copy_file_range`, `inotify`, `memfd` sealing, shared futexes and robust mutexes, `MADV_DODUMP`/`DONTDUMP`/`DONTFORK`; a real-app .NET fixture | Tasks |
| Before 12 | Per-process views; rights on descriptors; per-object wait lists for epoll | Decision 1, Decision 2 |
| 12 | Completion inside; virtio-net; TCP of MyOS's own, tested with packetdrill and fuzzing; per-core connection tables and `SO_REUSEPORT` as the model; the network grant from the first socket; Unix sockets for .NET's diagnostics; `getaddrinfo`'s files and netlink's `getifaddrs` | Decision 2 |
| 11 | A native copy-on-write filesystem with sticky errors and whole commits; the page cache; crash-replay testing; FAT32 for interchange only; EROFS system image on A/B slots | Decision 3 |
| Before 10 | Profiles applied by the launcher; Landlock and seccomp | Decision 1 |

## Decided (2026-11-27)

1. **Security by design: yes.** Per-process views, rights on
   descriptors, the network as a grant from the first socket, profiles
   applied by the launcher; no users in the kernel. Views and rights come
   before networking.
2. **I/O and networking: yes.** Completion inside, `epoll` and `poll` on
   top; per-object wait lists; virtio-net; a TCP of MyOS's own with
   smoltcp's state machine as the reference, tested with packetdrill and
   fuzzing; per-core connection tables with `SO_REUSEPORT` as the model;
   no general io_uring.
3. **Storage: a copy-on-write format of MyOS's own, with its tools, that
   MyOS does not get stuck with.** Chosen over ext4 (a journal: in-place
   overwrites not atomic without writing data twice, no data checksums, no
   cheap snapshots) and btrfs (copy-on-write and Linux's tools, but the
   largest and most complex to implement). So that another format (btrfs)
   can take its place later at the cost of one module:
   - Nothing outside the filesystem module sees inside it: the VFS, the
     page cache and the block layer are the same for any format.
   - The promises (errors that stay, `fsync` on the medium, ordered
     commits) are defined and tested at the VFS, so any format is held to
     them; the crash-replay and POSIX tests do not know the format.
   - System updates use the EROFS image on A/B partitions, not this
     format's snapshots; snapshots, if offered, go through an interface of
     MyOS's own.
   - A version and feature flags on disk from the first `mkfs`.
   - `mkfs` and `fsck` in `tools/`, the `fsck` also run against every image
     the tests leave behind.
   - FAT32 (and read-write ext4 later, perhaps) for exchanging files, not as
     the disk.

## Sources

The researchers' citations, by section.

1. dotnet/runtime `release/10.0`: `src/native/libs/System.Native/pal_io.c`, `pal_process.c`, `pal_signal.c`, `pal_networking.c`, `pal_console.c`, `pal_time.c`; `src/coreclr/pal/src/exception/signal.cpp`, `thread/thread.cpp`, `synchobj/mutex.cpp`, `init/pal.cpp`; `src/coreclr/gc/unix/gcenv.unix.cpp`, `cgroup.cpp`; `src/native/minipal/Unix/doublemapping.cpp`; `src/native/eventpipe/ds-ipc-pal-socket.c`; dotnet/core `release-notes/10.0/supported-os.md`.
2. Fuchsia rights and Starnix (fuchsia.dev/fuchsia-src/concepts/starnix); seL4 whitepaper (sel4.systems); Capsicum, USENIX Security 2010; OpenBSD pledge(2), unveil(2); Go issues 31927, 60322, 38599; Linux Landlock documentation (docs.kernel.org/userspace-api/landlock.html); LWN 738694, 673597; Plan 9 "The Use of Name Spaces" (9p.io/sys/doc/names.html); Genode Foundations; Android application sandbox (source.android.com).
3. FlexSC, OSDI 2010; Google security blog, "Learnings from kCTF VRP's 42 Linux kernel exploits" (2023); Docker seccomp profile; IX and Arrakis, OSDI 2014; mTCP, NSDI 2014; Demikernel, SOSP 2021; Snap, SOSP 2019; Fuchsia netstack3 and its POSIX_COMPATIBILITY.md; smoltcp; packetdrill; Affinity-Accept, EuroSys 2012; Fastsocket, ASPLOS 2016; MegaPipe, OSDI 2012; virtio 1.2 specification, section 5.1; QEMU networking documentation.
4. OpenZFS documentation; bcachefs architecture; F2FS and NILFS documentation; littlefs DESIGN.md; EROFS and SquashFS documentation; OSTree, Nix; ChromeOS disk format, Fedora Silverblue, Talos architecture; Pillai et al., "All File Systems Are Not Created Equal", OSDI 2014 (ALICE); Dan Luu on file consistency and fsyncgate; LWN 752063; PostgreSQL wiki, Fsync Errors.
5. EEVDF and sched_ext documentation (docs.kernel.org/scheduler); scheduler activations, SOSP 1991; dotnet/runtime PR 123921 and issue 51935; Go blog, container-aware GOMAXPROCS; vdso(7), time_namespaces(7); Go `runtime/vdso_linux_amd64.go`; Red Hat on rseq in glibc; Go issue 42894 (MADV_FREE); PAGEMAP_SCAN; Linux lock statistics documentation; LEBench (Ren et al., SOSP 2019); will-it-scale; lmbench.
