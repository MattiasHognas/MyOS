# Research notes

What we have read, what it says, and what it means for MyOS. Two kinds of
entries: findings from reviews of our own code, and papers or techniques from
outside. Each entry says where it applies in [the roadmap](todo.md) and what
we decided to do with it.

Rules for this file:

- An entry states what the source claims, then what it means for MyOS. Keep
  the two apart.
- Numbers are the authors' own unless the entry says we measured them.
- Mark anything written from memory, without the source open, as *unverified*.
- When an entry becomes a task, link the roadmap section. When a task is done
  or dropped, say so here.

Status words: **adopt** (there is a task for it), **read first** (read it
before designing the named milestone), **watch** (not usable yet), **not for
us** (and why).

## Code review, 2026-11-23

A read-through of all of `src/` at commit `a546b13`. Nothing was built or
measured: every finding comes from reading the code. No exploitable hole was
found in the code as it stands.

### Fix now

All done in [2.10](todo.md#210-review-follow-ups), each with a test. The table
describes the code as it was reviewed.

| Finding | Where | Why it matters |
| --- | --- | --- |
| The idle thread is in the round-robin queue. On its turn it halts until the next interrupt, even when other threads are ready. | `idle` in `src/main.zig` | With one CPU-bound program, about 10 ms halted per 60 ms: roughly a sixth of the CPU. |
| A wake-up that arrives between `yield` returning and `sti; hlt` in `idle` waits for the next tick. | `src/main.zig` | Up to 10 ms of added latency for the woken thread. |
| Kernel mappings do not set the global bit, and CR4.PGE is not set. | `src/arch/x86_64/vmm.zig` | Every CR3 load throws away the kernel's TLB entries too. |
| Kernel threads load `kernel_root`. | `switchToNext` in `src/kernel/thread.zig` | Every blocking syscall goes user, idle, user: two CR3 loads and two full TLB flushes. Every address space maps the kernel half, so a kernel thread can keep the previous one loaded. |
| The page allocator scans its bitmap a bit at a time. | `src/kernel/page_bitmap.zig` | `u64` words and `@ctz` make the scan up to 64 times faster for a few lines. |
| `user_copy` starts with `lfence`. | `src/arch/x86_64/usercopy.zig` | It serializes every copy. Linux replaced the barrier in 64-bit `copy_from_user` with branch-free masking of the address in late 2024, for speed. We already have the `cmp`/`sbb` idiom in `nospec.index`. |
| `.got` and `.data.rel.ro` stay writable after the bootloader has applied relocations. | `linker.ld`, `vmm.init` | They hold function pointers (the heap's allocator table, for one). Read-only after boot costs nothing. |
| The direct map of physical memory maps the kernel's text and read-only data writable. | `vmm.init` | A stray or attacker-controlled kernel write can change kernel code through the alias, although the image itself is mapped read-only. |
| Machine checks have no emergency stack. | `istFor` in `src/arch/x86_64/idt.zig` | One that arrives in the first instructions of `syscall_entry` runs on the user's stack pointer. It is fatal either way; with SMAP it becomes a double fault. |
| The syscall handler is called through a writable function pointer in every build. | `src/arch/x86_64/syscall.zig` | Only tests replace it. A direct call in the normal kernel removes an indirect branch per syscall and a target for an overwrite. |

### Fix before the milestone that makes it a bug

| Finding | Milestone | Detail |
| --- | --- | --- |
| `isr_paranoid` takes a GS base with the top bit set to be the kernel's. | [4.1](todo.md#41-process-startup), with FSGSBASE | Once a program can run `wrgsbase` it can load a kernel-looking value, and an NMI or debug exception would then skip `swapgs` and run on the user's GS base. Linux saves the GS base and loads the kernel's own unconditionally on these paths. |
| The conditional `swapgs` in `isr_common` can be skipped speculatively (CVE-2019-1125). | [3.2](todo.md#32-per-cpu-state) | Harmless while interrupt handlers do not read through GS. Once `current` comes from GS it needs an `lfence` on both branches. *Unverified*: written from memory. |
| `vmm.unmap` frees empty page tables and returns the page before `invlpg`. | [3.4](todo.md#34-smp-scheduling-and-memory) | With several CPUs, another CPU can still walk a freed table or use a stale entry. Tables and pages may only be freed after every CPU has flushed. |

### Design notes for later milestones

- **Scheduler (3.4).** A woken thread goes to the tail of the queue and waits
  for the running thread's slice to end: up to 50 ms. Futex-heavy programs
  such as the .NET runtime need wake-up preemption or a shorter path.
- **Extended state (9.2).** Linux saves on every switch out but restores only
  on the return to user mode, and skips the restore when the CPU still holds
  that thread's state. That, with XSAVEOPT or XSAVES, is the modern form of
  the lazy switch. *Unverified*: written from memory.
- **Framebuffer (10.1).** The framebuffer is reached through the direct map
  with ordinary caching. Write-combining (through the PAT) is the usual
  setting and much faster for drawing. *Unverified*.
- **Speculation (13).** KASLR without page-table isolation can be probed from
  ring 3 by timing (prefetch attacks). *Unverified*. See LASS below.

## Memory management

### CortenMM (SOSP 2025, best paper)

*Claims:* an operating system does not need a region tree beside its page
tables. CortenMM keeps only the page tables plus a little metadata per page,
behind a transactional interface with scalable locking. Formally verified.
1.2 to 26 times faster than Linux on real applications. Built in Asterinas, a
Linux-ABI kernel.

*For MyOS:* **read first**, before the "user virtual-memory regions" item of
[milestone 5](todo.md#5-user-memory). It is one of two opposite answers to
that item; the next entry is the other.

### Scalable Address Spaces using Concurrent Interval Skiplist (SOSP 2025)

*Claims:* keep the region structure, but make it a concurrent skiplist of
intervals that combines mapping and locking, so operations on different parts
of an address space run in parallel.

*For MyOS:* **read first**, with CortenMM. A garbage collector with many
threads faulting and calling `mprotect` and `madvise` in one address space is
exactly the load both papers target.

### LLFree (USENIX ATC 2023)

*Claims:* a lock-free page-frame allocator built on bitmaps, with per-CPU
reservations and cheap 2 MiB frames. Up to 88% less time for concurrent 4 KiB
allocations and 98% for 2 MiB than Linux's allocator. Rust and C
implementations are public.

*For MyOS:* **adopt** as the design to evaluate in
[3.4](todo.md#34-smp-scheduling-and-memory). Our allocator is already a
bitmap, so it is a step, not a rewrite.

### Per-CPU object caches: magazines, sheaves, snmalloc, mimalloc

*Claims:* the standard design for a kernel heap on several CPUs is size
classes with a per-CPU cache of free objects (Bonwick's magazines, 2001).
Linux moved its allocator to the same shape in 2025 ("sheaves"). snmalloc
returns objects freed on another CPU to their owner in lock-free batches;
mimalloc keeps separate free lists per page for local and remote frees.

*For MyOS:* **adopt** in [3.4](todo.md#34-smp-scheduling-and-memory). The
first-fit list under one lock is correct but will not scale.

### Broadcast TLB invalidation: AMD INVLPGB (Linux 6.15)

*Claims:* on AMD Zen 3 and later, one instruction flushes TLB entries on all
CPUs without interrupting them. 28% to 56% better on a flush-heavy benchmark.
Intel's equivalent (RAR) is not in Linux yet.

*For MyOS:* **watch**. The interrupt-based shootdown of 3.4 is needed
regardless; this is a fast path to add once benchmarks (9.2) show shootdowns
cost.

### Operating-system primitives for garbage collectors

*Claims:* Appel and Li (1991) list what a collector wants from the kernel:
user-level fault handling, changing protection in batches, and asking which
pages were written. Azul's C4 collector wanted remapping without a TLB flush
per page. Linux has since added moving pages without copying
(`userfaultfd` move), and there is work on fault handlers that run in the
kernel (eBPF), 2.8 to 6.7 times faster than `userfaultfd`.

*For MyOS:* **not for us** for now. .NET's collector uses software write
barriers and plain `mmap`, `mprotect` and `madvise`. These matter only if we
add private extensions for a modified runtime.

### What the .NET collector does need

- It reserves about 256 GB of address space at start. Reservations
  (`PROT_NONE`, no commit) with overcommit are a hard requirement of
  milestone 5.
- It calls `membarrier` to implement `FlushProcessWriteBuffers`, which thread
  suspension relies on (9.1).

### Copier: asynchronous copy as an OS service (SOSP 2025)

*Claims:* data is rarely used the moment it is copied, so the kernel can copy
in the background and overlap the copy with the program's own work.

*For MyOS:* **watch**. Our copies still bounce through 256-byte buffers
(9.2); fix that first.

## Concurrency and scaling

### Converos (USENIX ATC 2025)

*Claims:* model checking of a kernel's concurrency code from PlusCal
specifications, with the specification kept in step with the code. 20 bugs
(data races, deadlocks, livelocks, panics) in 12 modules of a Linux-ABI
kernel, for four person-months of work.

*For MyOS:* **adopt**. Done in [3.1](todo.md#31-synchronization), with our
own checker in place of PlusCal and TLC (`tools/modelcheck`, a few hundred
lines of Zig, no outside tool): sleep and wake, timeouts and the mutex are
modelled in `tests/models/`, each with variants that must fail. It found one
mistake in the design before any code was written (wake before releasing the
condition's lock). What we do not have from the paper: checking that the
model and the code still agree; that is by hand.

### The scalable commutativity rule (sv6, SOSP 2013)

*Claims:* whenever two operations commute (their order cannot be observed), an
implementation exists in which they do not contend. So an interface decides
how well its implementation can scale.

*For MyOS:* **adopt** as a design check in 3.1. Our interface is Linux's and
fixed, so the rule tells us which calls cannot scale whatever we do (`open`
must return the lowest free descriptor) and which must (two threads faulting
on different pages).

### FlexGuard (SOSP 2025)

*Claims:* a user-space lock that asks the scheduler whether the lock's holder
was preempted, and switches from spinning to blocking when it was.

*For MyOS:* **not for us**. Kernel spinlocks run with interrupts off; the
problem is the runtime's own locks, and unmodified .NET would not use it.

## Kernel entry and scheduling

### Intel FRED

*Claims:* a new event-delivery mechanism that replaces the IDT, `swapgs`, the
interrupt stack table and `sysretq` with one entry point per privilege level
and an atomic return. It removes the class of hazards that 2.5 audits by
hand. In Panther Lake processors; on by default in Linux 7.1.

*For MyOS:* **watch**. We could not confirm QEMU emulates it without KVM, so
CI could not test a FRED entry path.

### User interrupts: Skyloft (SOSP 2024), xUI (ASPLOS 2025, best paper)

*Claims:* interrupts delivered straight to ring 3 give preemption at
microsecond granularity and safepoints without signals. A study at NSDI 2025
found limited benefit unless the whole runtime is designed around them.

*For MyOS:* **not for us**. Unmodified .NET suspends threads with signals
(milestone 8).

## Security

### Linear Address Space Separation (LASS)

*Claims:* a CR4 bit on recent Intel processors that makes any access from
ring 3 to a kernel-half address fault before the page walk starts, and makes
the kernel fault on user addresses unless RFLAGS.AC is set, as SMAP does. In
Linux 6.19, mostly off by default; corner cases fixed for 7.1. The maintainers
call it a generic defence against side channels on kernel addresses.

*For MyOS:* **adopt** in [13](todo.md#13-long-term--optional). We already keep
user access inside one `stac`/`clac` section, and we have no vsyscall page or
firmware runtime calls, which are what made it hard for Linux.

### Branch target injection: enhanced IBRS and AutoIBRS

*Claims:* on processors that have them, one MSR bit set at boot keeps
branch predictions trained in ring 3 from steering ring 0, at close to no
cost. *Unverified*: written from memory.

*For MyOS:* **adopt** as the first step of the Spectre item in 13, decided
from capability bits like the Meltdown check.

### Pointer masking instead of `lfence` in user copies

*Claims:* Linux's 64-bit `copy_from_user` clamps the user address without a
branch instead of executing `lfence`, because the barrier was slow. An
objection about AMD processors was raised on the list and rejected by the
author; the pattern was already in `get_user`.

*For MyOS:* **adopt**. Done in 2.10: the copy routines clamp the address to 0
when it is outside user space.

## Compatibility

### Loupe (ASPLOS 2024)

*Claims:* a tool that runs a program and finds which system calls it really
needs, which can return `ENOSYS`, and which can pretend to succeed. More than
half the calls Redis makes can be stubbed or faked. Half of the applications
OSv supports need 37 calls. Tool and database are public.

*For MyOS:* **adopt** in [4.2](todo.md#42-minimal-syscall-set). It gives a
better work order than a plain `strace` list, which only says what is called.

### "A fork() in the road" (HotOS 2019)

*Claims:* `fork` is a poor primitive: it is slow, does not compose with
threads, and forces overcommit and copy-on-write on the kernel.

*For MyOS:* supports choosing spawn or `vfork` plus `execve` in
[6.4](todo.md#64-process-control-and-time). μFork (SOSP 2025) shows what
`fork` costs a kernel that was not built around it.

### Asterinas (USENIX ATC 2025)

*Claims:* a Linux-ABI kernel in Rust in which all unsafe code sits in a small
framework: 14% of the code base, against 44% to 66% in comparable kernels.

*For MyOS:* Zig has no safe and unsafe split, but the discipline carries over:
keep raw pointers and assembly in `arch/` and a few audited modules. No task.

## Testing and verification

### Verified kernels: Atmosphere, TickTock, the Verus page table (2024 to 2025)

*Claims:* kernels and page-table code verified with Verus, at about 7.5 lines
of proof per line of code.

*For MyOS:* **not for us**. The tools are for Rust. Converos, above, is the
part that transfers.

### Fuzzing without system-call descriptions: FuzzNG (NDSS 2023)

*Claims:* reaches the coverage of syzkaller on ten Linux components with
configurations under 2% of the size of its hand-written grammars.

*For MyOS:* **read first** for the coverage-guided syscall fuzzer in 13.
Because our ABI is Linux's, syzkaller's own descriptions apply to us too.

### Biscuit (OSDI 2018)

*Claims:* a POSIX kernel in Go is 5% to 15% slower than C on identical
syscall, page-fault and context-switch paths.

*For MyOS:* a method to copy for the comparison with Linux in 9.2: the same
paths, measured one by one.

## Not looked at

- EuroSys 2026: the list of accepted papers could not be loaded.
- Only abstracts and summaries were read, not full papers.

## Sources

Code review and Linux practice:

- [x86/uaccess: Avoid barrier_nospec() in copy_from_user()](https://lists.ozlabs.org/pipermail/linuxppc-dev/2024-October/277350.html)
- [LWN: LASS merged for 6.19](https://lwn.net/Articles/1048869/), [pull request](https://lkml.iu.edu/2512.0/01584.html), [Phoronix: LASS for 7.1](https://www.phoronix.com/news/Intel-LASS-Linux-7.1)
- [AMD broadcast TLB invalidation](https://lkml.rescloud.iu.edu/2502.3/04729.html), [LWN](https://lwn.net/Articles/1008298/)
- [Phoronix: FRED on by default in Linux 7.1](https://phoronix.com/news/linux-7.1-enabled-intel-fred)
- [LWN: SLUB sheaves](https://lwn.net/Articles/1010667)
- [LWN: userfaultfd move](https://lwn.net/Articles/952319/)
- [Custom page fault handling with eBPF, LPC 2026](https://lpc.events/event/20/contributions/2434/)
- [dotnet/coreclr #20949: membarrier](https://www.github.com/dotnet/coreclr/pull/20949), [dotnet/runtime #85556: 256 GB reservation](https://github.com/dotnet/runtime/issues/85556)

Papers:

- [CortenMM, SOSP 2025](https://zhou-diyu.github.io/files/cortenmm-sosp25.pdf)
- [Scalable Address Spaces using Concurrent Interval Skiplist, SOSP 2025](https://travis1829.github.io/assets/pdf/interval-vm.pdf)
- [LLFree, USENIX ATC 2023](https://usenix.org/conference/atc23/presentation/wrenger), [code](https://github.com/luhsra/llfree-rs)
- [snmalloc](https://www.microsoft.com/en-us/research/uploads/prod/2020/04/snmalloc.pdf), [mimalloc](https://www.microsoft.com/en-us/research/publication/mimalloc-free-list-sharding-in-action)
- [Appel and Li, Virtual Memory Primitives for User Programs, 1991](https://www.cs.princeton.edu/~appel/papers/vmpup.pdf)
- [Copier, SOSP 2025](https://ipads.se.sjtu.edu.cn/_media/pub/sosp25-copier-preprint.pdf)
- [Converos, USENIX ATC 2025](https://www.usenix.org/conference/atc25/presentation/tang)
- [A Revised and Verified Proof of the Scalable Commutativity Rule](https://arxiv.org/pdf/1809.09550)
- [FlexGuard, SOSP 2025](https://github.com/vlaforet/flexguard)
- [Skyloft, SOSP 2024](https://madsys.cs.tsinghua.edu.cn/publication/skyloft-a-general-high-efficient-scheduling-framework-in-user-space/), [xUI, ASPLOS 2025](https://mktrm.github.io/files/xui-asplos25.pdf), [limits of user interrupts, NSDI 2025](https://www.usenix.org/conference/nsdi25/presentation/guo)
- [Loupe, ASPLOS 2024](https://arxiv.org/pdf/2309.15996), [code](https://github.com/unikraft/loupe)
- [A fork() in the road, HotOS 2019](https://www.bu.edu/rhcollab/files/2019/04/fork-in-the-road.pdf), [μFork, SOSP 2025](https://arxiv.org/pdf/2509.09439)
- [Asterinas, USENIX ATC 2025](https://arxiv.org/pdf/2506.03876)
- [Atmosphere, SOSP 2025](https://mars-research.github.io/doc/2025-sosp-atmo.pdf)
- [FuzzNG, NDSS 2023](https://research.redhat.com/?p=243910)
- [Biscuit, OSDI 2018](https://www.usenix.org/conference/osdi18/presentation/cutler)

Lists searched: [SOSP 2025](https://sigops.org/s/conferences/sosp/2025/accepted.html), [OSDI 2025](https://www.usenix.org/conference/osdi25/technical-sessions), [USENIX ATC 2025](https://www.usenix.org/conference/atc25/technical-sessions), ASPLOS 2026, HotOS 2025.
