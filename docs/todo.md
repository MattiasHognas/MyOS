# TODO

A dependency-ordered roadmap for building a small x86-64 operating system in Zig. Establish automated tests and CI first, then improve kernel safety and build out features.

## Primary goal

**Run an unmodified .NET executable safely and fast, on several cores, on top of a minimal kernel core.** That is milestone 9, and it is the first point at which the project counts as having reached its goal.

- **What counts:** a .NET Native AOT program built on Linux for linux-musl, statically linked. The JIT-based runtime (`dotnet app.dll`) is a later step (9.3).
- **One ABI:** MyOS's native syscall ABI is Linux's x86-64 ABI (decided 2026-11-23, see 2.5). There is no translation layer and no libc to port: MyOS's own programs and foreign binaries make the same calls. 64-bit only.
- **On the critical path:** 2 (safety, plus per-CPU state and FPU/SSE state), 3 (SMP), 4 (first foreign program), 5 (user memory), 6 (files, descriptors, time; as far as the runtime needs them), 7 (threads and futexes), 8 (signals) and 9 (.NET, measured).
- **Not required for the goal:** 11 (persistent storage; programs can ship in the initrd) and 12 (networking; only needed for network programs).
- **After the goal:** 10 (graphical environment) is planned and will be done; it just does not gate the primary goal.
- **Minimal core:** when a feature is only needed off the critical path, prefer leaving it out or keeping it in user space over growing the kernel.
- **Order:** SMP comes before the feature work, so everything after it is written and tested on several cores; a foreign hello-world comes right after, so Linux compatibility is tested from then on rather than discovered at the end.

## Current foundation

Already implemented: Limine BIOS/UEFI boot, serial/framebuffer console, GDT/IDT/TSS, physical and virtual memory management, kernel heap, APIC timer, preemptive threading, ring 3, syscalls, ELF64 loading, basic processes, read-only tarfs/VFS, PCI, basic NVMe reads, PS/2 keyboard, and a userspace shell.

## 1. Tests, debugging, and CI

**Goal:** Establish the test harness, CI and baseline test suites for the existing kernel before changing critical code. From milestone 2 on, every section lists its own test items: a feature is done when its tests are (see `docs/testing.md` for where tests go).

### 1.1 Test infrastructure
- [x] Separate hardware-independent code for host-side Zig unit tests.
- [x] Add a kernel test build mode and in-kernel test runner.
- [x] Add a reliable test success/failure exit mechanism for QEMU.
- [x] Write a script to build, boot QEMU, capture serial output, assert results, and enforce timeouts.
- [x] Save relevant logs and failure diagnostics.

### 1.2 Baseline test suites
Tests for the kernel as it existed at milestone 1. Tests for unfinished functionality live with that functionality (noted below).
- [x] Test physical memory allocation and basic accounting.
- [x] Test kernel heap allocation and memory read/write.
- [x] Test virtual memory mapping and permissions (address-space create/destroy, map and translate, user/writable/NX bits from ELF segment flags). Unmapping and exhaustion tests: 2.6.
- [x] Test ELF parsing, failed loading, and rollback (valid image contents and `.bss`, 14 malformed/truncated images, no leaked pages, spawn rollback after partial loads).
- [x] Test valid/invalid syscall buffers and kernel/user isolation (`/test/syscalls` checks 39 cases from ring 3; reading kernel memory, `cli` and writing own code kill only the process). Unmapped user buffers: `/test/user_pointers` (2.1).
- [x] Test scheduler transitions, process lifecycle, waits, and cleanup (FIFO round robin, wake-before-block, exit codes, no page/heap leaks after normal and crashed processes).
- [x] Test VFS and filesystem behavior (lookup, contents, offsets and EOF on the initrd; an injected fake filesystem on the host; malformed tarfs archives and boundary conditions). Storage write tests: 11.2.

### 1.3 CI and debugging
- [x] Add GitHub Actions kernel/app builds (`.github/workflows/ci.yml`; pinned Zig, checksum-verified Limine and font).
- [x] Run host unit tests and QEMU integration tests in CI.
- [x] Run debug and optimized builds (CI matrix over Debug, ReleaseSafe and ReleaseFast; the test kernel follows `-Doptimize`).
- [x] Publish serial logs on failures (per-scenario logs in `zig-out/test/<scenario>/`, printed by `scripts/test-qemu.sh` on failure and uploaded by CI as `serial-logs-<mode>`; verified with a `simulate_failure` run).
- [x] Add QEMU/GDB debugging instructions (`docs/debugging.md`, `scripts/run-qemu.sh --gdb`, `scripts/kernel.gdb`).
- [x] Add VS Code kernel debugging under QEMU (`.vscode/launch.json` "MyOS: Debug kernel (QEMU)" and "MyOS: Debug kernel + user programs (QEMU)" with CodeLLDB over QEMU's GDB server, including user programs, which keep debug info in Debug builds and are linked at distinct addresses; `docs/debugging.md`).
- [x] Add symbolized kernel faults and backtraces (kernel `.symtab` via Limine, frame-pointer walk; tested by in-kernel tests and the `panic`/`fault` scenarios).
- [x] Add log levels, subsystem assertions, and optional allocation diagnostics (`std.log` with `-Dlog-level`, `kernel/debug/assert.zig` with `-Dassertions`, heap stats and `-Dalloc-debug`).
- [x] Release automatically: every push to `main` that passes all build-and-test jobs is tagged `v<major>.<minor>.<patch>` and published as a GitHub release with the bootable ISO, the kernel ELF and checksums (`release` job in `ci.yml`, `scripts/build.sh --release`, `scripts/next-version.sh` with its own test script; the boot banner shows the version and the `tests` scenario checks it). The patch number is automatic (`0.0.x`); to bump the minor or major number, edit the `VERSION` file.
- [x] Track host-code coverage and explicit integration-test scenarios where practical (`zig build coverage` with kcov, uploaded by CI as `host-coverage`; QEMU scenarios `tests`, `panic`, `fault`).

**Milestone 1 done when:** A clean checkout can automatically build and run regression tests, with clear failure reporting.

---

## 2. Kernel safety and correctness

**Goal:** Broken or malicious user programs cannot corrupt or crash the kernel.

### 2.1 Safe user-memory access
- [x] Implement `copyFromUser(dst, src)` and `copyToUser(dst, src)` (`src/kernel/uaccess.zig`; the length is the kernel slice's); replace direct user-buffer dereferences in every syscall (`write`, `open`, `run` and `read` copy through kernel buffers; `userSlice` is gone).
- [x] Validate canonical user addresses and use overflow-safe range checks (`src/kernel/user_range.zig`, host-tested).
- [x] Mark the user-copy routines so the page-fault handler can tell a fault inside them from a genuine kernel fault and resume at an error path (`user_copy_start`/`user_copy_end`/`user_copy_fault` labels in `src/arch/x86_64/usercopy.zig`, `fixup` called from `interruptHandler`).
- [x] Handle faults inside user-copy routines by returning an error, not panicking (`error.Fault`; the syscall returns `ERR`).
- [x] Handle unmapped, partially mapped, read-only, and page-crossing buffers (CR0.WP is set so ring 0 writes to read-only user pages fault too).
- [x] Enable SMEP when CPU-supported.
- [x] Enable SMAP when CPU-supported, using `stac`/`clac` only in controlled user-access sections (only around the copy instruction in `user_copy`; interrupt entry runs `clac` and `syscall` entry masks AC).
- [x] Test null pointers, kernel pointers, overflow, invalid pages, and boundary crossings (host tests for the range check, in-kernel "user copy routines" test, `/test/user_pointers` with 27 checks from ring 3).
- [x] Test that SMEP and SMAP are really on: the kernel faults when it executes or touches user memory outside a user-access section (QEMU scenarios `smap` and `smep`, plus an in-kernel check of CR0/CR4; QEMU runs with `-cpu max`, which has both).
- [x] Test that RFLAGS.AC cannot leak into the kernel: an interrupt taken with AC set runs its handler with AC clear, and the `syscall` flag mask clears AC (in-kernel test; found in the review before 2.2).

**Done when:** Every syscall rejects invalid user addresses without crashing the kernel.

### 2.2 Exception handling
- [x] Allocate an independent double-fault emergency stack (16 KiB in `.bss`, `gdt.zig`).
- [x] Configure the TSS IST entry and double-fault IDT gate (IST 1; in-kernel test "double-fault and NMI emergency stacks").
- [x] Consider a separate NMI IST stack (done, IST 2: an NMI can hit the first instructions of `syscall` entry, which still run on the user's stack).
- [x] Distinguish faults in user mode from kernel faults (`cs & 3` in `interruptHandler`; faults during user copies are recovered, see 2.1). NMIs, double faults and machine checks are kernel faults even when they interrupt ring 3.
- [x] Terminate the offending process for ordinary unrecoverable user faults (exit code 255; tested by `/test/kernel_read`, `/test/privileged` and `/test/write_text`).
- [x] Print vector, error code, RIP, RSP, and CR2 (for page faults) in kernel fault diagnostics (checked by the `fault` scenario).
- [x] Print the same details for user faults, with the thread and program name (checked from the serial log of the `tests` scenario).
- [x] Test deliberate user faults, kernel faults, and double-fault diagnostics (`/test/div_zero` and `/test/invalid_opcode` besides the isolation programs; scenarios `fault` and `double_fault`).
- [x] A fault with an unusable kernel stack no longer ends in a triple fault: the `double_fault` scenario gets a report with RIP, RSP, CR2, the thread's stack bounds and a backtrace.
  - A real stack overflow is caught since 2.3: it hits the guard page, and this stack reports it.

**Done when:** User faults terminate only their process, and emergency faults produce useful diagnostics where possible.

### 2.3 Guarded kernel stacks
- [x] Introduce a dedicated virtual-memory-backed kernel-stack allocator (`kernel/kstack.zig`: slots in their own region at `0xFFFF_C000_0000_0000`, up to 4096 stacks).
- [x] Map stack pages with an unmapped guard page underneath (16 KiB of writable, non-executable pages per stack, the same as Linux on x86-64).
- [x] Migrate kernel-thread stacks away from ordinary heap allocations (`thread.spawn`; the boot thread also leaves the bootloader's stack for a guarded one early in `kmain`).
- [x] Update context switches, TSS.RSP0, and syscall stack selection accordingly (they take the stack top from `Thread.stack`, which now comes from `kstack`; the boot thread has one too).
- [x] Release mapped stack pages and reserved virtual ranges on thread cleanup (`kstack.free` from `reap`, using the new `vmm.unmap`; in-kernel tests check pages and slots balance).
- [x] Verify stack overflow triggers a page fault rather than heap corruption (QEMU scenario `stack_overflow`: the fault on the guard page arrives as a double fault on the emergency stack and is reported as a kernel stack overflow).
- [x] The guard is a single page, so a stack frame larger than 4 KiB could step over it into the neighbouring stack. No kernel function may have one: `scripts/check-frames.sh` (`zig build check-frames`, part of `zig build test` and CI in all three build modes) fails on a frame over 4088 bytes and warns over 2 KiB, the same limit Linux warns at. The largest frame is about 1 KiB.
  - Panic messages are formatted in a 256-byte buffer (`kernel/debug/panic.zig`) instead of the standard library's 4 KiB one.
  - Not covered: a function reached only through a pointer stored in a data table, and assembly that moves RSP by a computed amount. Stack probes (`stack_check`) are the fallback if a function ever needs a larger frame.
- [x] Kernel stacks stay at 16 KiB, the same as Linux (decided; not larger, and going smaller is not a goal). The high-water mark of every stack is measured in Debug builds and in the test kernel (`-Dstack-usage`): the kernel warns when a thread used more than 12 KiB, and the `tests` scenario reports the peak (`MYOS_STACK_PEAK`) and fails above that level. The suite peaks at about 5 KiB in Debug and under 4 KiB in release builds.

**Done when:** A kernel stack overflow is caught and reported instead of corrupting memory, and no stack pages or slots leak when threads exit.

### 2.4 Harden ELF loading
- [ ] Validate ELF class, endianness, machine type, type, version, and header sizes.
- [x] Validate program-header offset, count, entry size, and full table bounds.
- [x] Use overflow-safe arithmetic for file offsets, address ranges, and segment sizes.
- [ ] Validate segment alignment and enforce user-only mapping ranges.
- [ ] Reject overlapping or conflicting load segments unless intentionally supported.
  - Today a second segment (or the user stack) mapped over an existing page silently replaces it and the old page is never freed: a permanent leak a crafted ELF can repeat.
- [ ] Prevent mapping page zero and reserved user regions.
  - [x] The last user page is never mapped (`vmm.USER_MAP_END`; see the `sysretq` item in 2.5).
- [ ] Cap segment sizes (`memsz`) against a per-process memory limit, so one ELF cannot ask for all physical memory.
- [ ] Verify the entry point is inside an executable loaded segment.
- [ ] Enforce readable/writable/executable permissions and avoid unintended writable-executable pages (a JIT later needs pages that go from writable to executable with `mprotect`, never both at once; see 9.3).
- [x] Roll back every allocated page and table on loading failure.
- [x] Add malformed and truncated ELF tests.
- [ ] Split ELF header/segment validation from page mapping so it runs in host tests, and fuzz it there.

### 2.5 Syscall and context-switch correctness
- [x] Decide whether the syscall numbers, error values and struct layouts follow Linux. Decided (2026-11-23): the native ABI is Linux's x86-64 syscall ABI, for MyOS's own programs too; no translation layer. Only the 64-bit `syscall` interface (no `int 0x80`, no x32).
- [ ] Move the existing syscalls to Linux's numbers and argument registers (`rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9`): `read` 0, `write` 1, `open` 2, `close` 3. Keep the ones with no Linux equivalent (`getchar`, `run`) on private numbers far above Linux's range until 6 replaces them.
- [ ] Return Linux's negative errno values from every syscall instead of the single `ERR` value; mirror them in `app/lib.zig`.
- [ ] Introduce the per-CPU structure reached through GS, with `swapgs` on every entry from and exit to ring 3, while there is still one CPU (moved from the SMP milestone, so the entry assembly is audited once, in its final shape).
- [ ] Enable SSE (CR0/CR4) and save and restore the extended CPU state per thread on context switch: XSAVE with the area sized from CPUID, AVX enabled where supported, FXSAVE as the fallback. Build user programs with SSE; the kernel stays soft-float. Today user code is soft-float too, and no foreign binary runs without SSE2.
- [ ] Audit `syscall` entry and exit assembly for register preservation and ABI stack alignment.
- [ ] Validate return RIP/RSP and avoid unsafe `sysretq` for noncanonical or invalid return states.
  - [x] Close the known case: a `syscall` instruction at the very end of user space returns to a non-canonical address, and `sysretq` then faults in ring 0 on the user's stack pointer (Intel). The ELF loader now refuses to map the last user page or put the entry point there (tested with segments at, across and just below it).
  - [ ] Still to do: check the saved return address in the exit path itself (needed once `mmap` or signals can put code or return addresses anywhere), and fall back to `iretq` when it is not safe.
- [ ] Verify interrupt masking and preemption across syscall entry, blocking, and return.
- [ ] Verify stack and address-space switches during timer interrupts and syscalls.
- [ ] Document the userspace syscall ABI, argument registers, clobbers, error codes, and return conventions (where it is Linux's, say so and list only what MyOS implements).
- [ ] Test from ring 3 that syscalls preserve callee-saved registers and RFLAGS, keep the stack aligned, and survive preemption mid-syscall.
- [ ] Test that each failure case in `/test/syscalls` returns its specific error code.
- [ ] Test that floating-point, SSE and AVX registers survive preemption between two processes, and that a new thread starts with clean extended state (nothing leaks from the previous owner).
- [ ] Fuzz the syscall interface from ring 3 (random numbers and arguments, fixed seed in CI): the kernel must survive and leak nothing.
- [x] Clear all general-purpose registers on the first entry to user mode, so no kernel value leaks to the program (`context.enterUser`; tested from ring 3 by `/test/entry_regs`).

### 2.6 Memory-management correctness
- [ ] Reject invalid, misaligned, and double page frees in the physical allocator.
- [ ] Verify free-page counts and bitmap consistency under stress.
  - [x] Make `pmm.alloc`/`pmm.free` safe against preemption (interrupts off around the bitmap update); before, two preemptible threads could be handed the same page.
  - [x] Stress test with two preempted kernel threads allocating and freeing concurrently. It checks for shared pages and the free count, but the race window is a few instructions wide: it passed even with the locking removed, so it does not prove the lock. A deterministic test needs a hook that forces a switch inside `alloc`.
- [ ] Make page mapping report errors rather than silently replacing mappings.
- [ ] Implement page unmapping and appropriate local TLB invalidation.
- [ ] Handle page-table allocation failure without a partially corrupted mapping.
  - Today `vmm.allocTable` panics, so a user program can take the kernel down by exhausting memory, for example by running itself recursively (each `run` keeps its parent alive).
- [ ] Free all user mappings and page tables on process teardown.
- [ ] Test memory exhaustion, mapping conflicts, repeated allocation/free, and failed allocations.
- [ ] Test from ring 3 that a program spawning itself recursively until memory runs out gets an error from `run` and the kernel survives with no leak.
- [ ] Add per-process resource limits (memory, descendants, open files) so one program cannot starve the rest.
- [ ] Test unmapping: the translation disappears, freed pages and empty page tables return to the PMM, and a stale TLB entry is never used (moved from 1.2).
- [ ] Test mapping exhaustion: `map` reports out-of-memory when page tables can't be allocated and leaves existing mappings intact (moved from 1.2).

### 2.7 Process and scheduler lifecycle
- [ ] Define ownership rules for processes, threads, stacks, page tables, and open files.
- [ ] Document the current single-thread-per-process assumption explicitly.
- [ ] Review ready/running/blocked/dead transitions and prevent duplicate queue insertion.
- [ ] Make block/wake semantics race-safe, including wake-before-block.
- [ ] Handle children that exit before the parent begins waiting.
- [ ] Handle parents that exit before their children (reparent or auto-reap the orphans).
- [ ] Reap each exited thread/process exactly once.
- [ ] Close open descriptors and free all resources on process exit and failed spawn.
- [ ] Stress-test repeated spawn/exit, wait, wakeup, orphaning, and failure paths.

### 2.8 Synchronization and timers
Pipes, blocking I/O, sleep and interrupt-driven drivers need these, and SMP (milestone 3) builds directly on them.
- [ ] Add interrupt-aware spinlocks with interrupt-state restoration, as real atomic locks from the start (on one CPU the atomic never contends, and milestone 3 needs no rewrite).
- [ ] Add wait queues and replace the single-`waiter` pointers (keyboard, process wait) with them.
- [ ] Add mutexes for code that may block while holding a lock.
- [ ] Add kernel timers: a timeout queue driven by the timer tick, for sleep, driver timeouts and later TCP.
- [ ] Test several waiters on one queue, wake-before-block, timer ordering and expiry, and mutex hand-off under preemption.

### 2.9 Further hardening
From the code review before 2.2. None of these fix a known hole; they shrink what a future bug can do. Do them after 2.2 to 2.8, in roughly this order. The random-number generator, stack protectors and page zeroing are wanted before the primary goal; page-table isolation and address randomization can wait until after it.
- [x] Enable UMIP when CPU-supported, so ring 3 cannot read kernel table addresses with `sgdt`/`sidt` (`usercopy.init`; tested by `/test/umip`).
- [ ] Add a kernel random-number generator: a CSPRNG seeded from RDSEED/RDRAND where present, plus timing jitter. Stack-protector canaries, address randomization, `AT_RANDOM` (4.1) and `getrandom` (6.4) all draw from it.
- [ ] Build the kernel with stack protectors and test that a smashed kernel stack is detected.
- [ ] Add a speculation barrier after the user range check in the user-copy path, and audit other user-controlled indexes (syscall number, file descriptor) for Spectre v1.
- [ ] Decide on kernel page-table isolation: detect CPUs that need it (Meltdown) and either implement it or refuse to run untrusted code on them.
- [ ] Randomize the kernel's load address and the user stack and program base (KASLR/ASLR); needs the PIE loading of 4.1 for programs.
- [ ] Poison freed heap memory and freed pages in debug builds to catch use-after-free.
- [ ] Zero pages when they are freed or before they reach another process, as a rule in one place instead of at each call site.

**Milestone 2 done when:** Malformed binaries, invalid pointers, expected user faults, and resource exhaustion do not take down the OS or leak resources.

---

## 3. SMP

**Goal:** Safely use multiple CPU cores.

Moved up (it was milestone 5): bringing up SMP while the kernel is small is far cheaper than retrofitting it onto pipes, a terminal, `mmap`, futexes and signals written for one CPU. Everything after this milestone is written and tested on several cores.

### 3.1 Synchronization
The primitives come from 2.8 and are already real locks; this section makes their users safe on several CPUs.
- [ ] Decide and document the kernel's preemption and locking model: whether kernel code can be preempted, which locks disable interrupts, and what may be held across a block.
- [ ] Audit existing `cli`/`sti` critical sections and replace every one that assumes a single CPU.
- [ ] Make mutexes and wait queues safe against wakeups from another CPU.
- [ ] Define lock-ordering rules and test contention.

### 3.2 Per-CPU state
The per-CPU structure and the `swapgs` transitions come from 2.5.
- [ ] Move current-thread, scheduler, syscall-stack, and interrupt state to per-CPU storage.
- [ ] Initialize separate GDT/TSS, emergency (IST) stacks and guarded stacks for each CPU.
- [ ] Test per-CPU state and `swapgs` transitions (syscalls, interrupts from ring 0 and ring 3) with one and several CPUs.

### 3.3 Bring up application processors
- [ ] Request SMP information through Limine.
- [ ] Start APs and initialize CPU-local structures.
- [ ] Apply the per-CPU control-register settings on every AP: SMEP, SMAP, UMIP, CR0.WP, the `syscall` MSRs and the extended-state setup from 2.5.
- [ ] Configure local APIC/timer and interrupts per CPU.
- [ ] Print and test online CPU counts.

### 3.4 SMP scheduling and memory
- [ ] Protect shared scheduler state.
- [ ] Choose per-CPU queues or a documented global-queue scheduling model.
- [ ] Support cross-CPU wakeups and inter-processor interrupts.
- [ ] Add CPU affinity/load balancing if needed.
- [ ] Synchronize PMM, heap, page tables, and drivers.
- [ ] Implement cross-CPU TLB shootdowns.
- [ ] Stress-test simultaneous allocations, processes, interrupts, and I/O.
- [ ] Run the QEMU test scenarios with several CPUs (`-smp 4`) in CI from here on, next to the single-CPU run.
- [ ] Add a test run under KVM where the machine supports it: QEMU's emulation hides races and timing bugs that real parallel execution shows.

**Milestone 3 done when:** Multiple cores safely execute user threads and syscalls concurrently, and CI runs the test suite on several CPUs.

---

## 4. First foreign program

**Goal:** Run an unmodified, statically linked musl C program built on Linux.

This is the smallest end-to-end slice of Linux compatibility. It comes early on purpose: from here on, new kernel features are checked against real foreign binaries instead of only against MyOS's own programs.

### 4.1 Process startup
- [ ] Build the initial user stack the way Linux does: `argc`, `argv`, `envp`, then the auxiliary vector (`AT_PHDR`, `AT_PHNUM`, `AT_PHENT`, `AT_ENTRY`, `AT_BASE`, `AT_PAGESZ`, `AT_RANDOM`, ...). `AT_RANDOM` needs the random-number generator from 2.9.
- [ ] Pass arguments and environment to spawned programs.
- [ ] Update the Zig user startup code to read arguments/environment.
- [ ] Parse command lines with arguments and basic quoting.
- [ ] Load position-independent executables (`ET_DYN`) at a chosen load bias.
- [ ] Give each thread its own FS base: `arch_prctl(ARCH_SET_FS)`, saved and restored on context switch; enable FSGSBASE when the CPU has it.
  - The kernel does not set up the TLS block from `PT_TLS`: on Linux the C library does that itself, from the program headers it finds through `AT_PHDR`.
- [ ] Extend the syscall ABI document from 2.5 with the startup stack, the auxiliary vector and TLS.
- [ ] Test empty, long, invalid, and multi-argument commands, and check the stack layout from ring 3.

### 4.2 Minimal syscall set
- [ ] Return `-ENOSYS` for unknown syscalls and add a syscall trace option that logs them, to see what a program still needs.
- [ ] Record what the target programs really ask for: run the fixture binaries (musl hello, a Go hello, the .NET Native AOT hello and a GC workload) under `strace -f` on Linux and keep the list of syscalls and files in `docs/`. Use it to order the work in milestones 5 to 9.
- [ ] Add the calls a static musl hello-world makes: `writev`, `exit_group`, `set_tid_address`, `brk`, a minimal anonymous `mmap` (milestone 5 replaces it), and `ioctl` answering `-ENOTTY`.

### 4.3 Fixtures
- [ ] Keep prebuilt fixture binaries (with the commands that built them) and run them as QEMU tests, checking their output.
- [ ] Run a static and a static-PIE musl hello-world built on Linux, with arguments and environment.
- [ ] Test malformed `ET_DYN` images and an unknown syscall number from ring 3.

**Milestone 4 done when:** An unmodified static musl hello-world built on Linux prints its arguments on MyOS, as a CI test on several CPUs.

---

## 5. User memory

**Goal:** Give processes the virtual memory model runtimes expect: reserve large ranges, commit them piece by piece, change permissions, and fail safely when memory runs out.

Designed once, demand-paged from the start, instead of an eager `mmap` first and demand paging later.

- [ ] Define user virtual-memory regions: a per-process set of regions with their permissions and backing, which the page-fault handler consults.
- [ ] Add demand paging and overcommit for anonymous memory: garbage collectors reserve huge virtual ranges and commit them piece by piece.
- [ ] Implement `mmap`: anonymous mappings, `MAP_FIXED`, `MAP_NORESERVE`, `PROT_NONE` reservations, and private file-backed mappings (needed by the dynamic loader in 9.3).
- [ ] Implement `mprotect`, `munmap` of partial ranges, `madvise(MADV_DONTNEED)` and `brk`, with resource reclamation.
- [ ] Give processes a large, guarded user stack that grows on demand (the fixed 16 KiB stack is far too small for runtimes).
- [ ] Shoot down TLB entries on the other CPUs on `munmap` and `mprotect` (3.4).
- [ ] Define the out-of-memory policy: when a page fault cannot be given a page, the process is killed and the kernel carries on; tie it to the per-process limits of 2.6.
- [ ] Add a small userspace allocator for the Zig programs on top of `mmap`.
- [ ] Test reserve-then-commit of a multi-gigabyte range, permission changes, partial unmaps, faults on `PROT_NONE` pages, stack growth up to its limit, the out-of-memory kill, and page faults on several CPUs at once in one address space (once threads exist, 7).

**Milestone 5 done when:** A program can reserve a multi-gigabyte range and commit it piece by piece, and a program that exhausts memory is the only casualty.

---

## 6. Files, descriptors, and shell

**Goal:** Run practical programs with files, pipes, a terminal and predictable process behavior.

Every syscall added here takes Linux's number, signature and struct layout (`stat`, `timespec`, `iovec`, `dirent64`, `pollfd`, ...) from the start.

### 6.1 VFS and directories
- [ ] Distinguish regular files from directories in VFS nodes.
- [ ] Add directory lookup and `readdir` operations (`getdents64`).
- [ ] Add `stat`-like metadata queries (`fstat`/`newfstatat`).
- [ ] Normalize paths and handle `.` and `..`.
- [ ] Add mount-point traversal so multiple filesystems can coexist.
- [ ] Add create/write/truncate/unlink/mkdir operations to the VFS interface.
- [ ] Add a small in-memory filesystem (ramfs) mounted at `/tmp`, so redirection (6.3) has somewhere to write and the write API is proven before FAT32 (11.5).
- [ ] Define consistent VFS error codes that map onto the syscall error codes (2.5).
- [ ] Test directory lookup, `readdir`, `stat`, `.`/`..` normalization, mount traversal and error codes (host tests with fake filesystems, plus initrd tests in QEMU).
- [ ] Test ramfs create, write, read-back, truncate, unlink and out-of-memory on the host and from ring 3.
- [ ] Run the tarfs parser in host tests and fuzz it with malformed archives.

### 6.2 Descriptors and I/O
- [ ] Reserve FDs 0/1/2 for stdin/stdout/stderr.
- [ ] Route console I/O through descriptor-backed devices.
- [ ] Add serial input (receive interrupt) as a second console input source; the scripted shell tests in 6.3 depend on it.
- [ ] Add a terminal layer between the input drivers and FD 0: line editing, echo, backspace, and Ctrl+C/Ctrl+D handling. Keep it small; anything richer belongs in user space.
- [ ] Support generic open/read/write/close plus `seek` where applicable (`openat`, `lseek`).
- [ ] Define file-offset, ownership, and descriptor inheritance rules.
- [ ] Add descriptor duplication and pipes (`dup`/`dup3`, `pipe2`).
- [ ] Add `poll` to wait on several descriptors at once (needed by network servers in 12.3 and the compositor in 10.3).
- [ ] Add the file syscalls runtimes expect: `fcntl`, a terminal subset of `ioctl`, `readlink`, `readv`, `pread`/`pwrite`.
- [ ] Add `epoll` and `eventfd` on top of `poll`.
- [ ] Provide the pseudo-files programs open at startup: `/dev/null`, `/dev/urandom`, `/proc/self/exe`, `/proc/self/maps`, `/proc/cpuinfo` or their minimal equivalents (the list from 4.2 says which).
- [ ] Test EOF, partial I/O, invalid descriptors, and cleanup.
- [ ] Test terminal line editing and `poll` (ready, blocking, and timeout cases) with input injected over serial.

### 6.3 Commands and shell features
- [ ] Implement `echo`, `cat`, `ls`, `pwd`, `cd`, and `clear`.
- [ ] Support absolute and relative paths and working directories.
- [ ] Display meaningful command errors and exit statuses.
- [ ] Implement basic input/output redirection once descriptors are ready.
- [ ] Implement pipelines once pipes are available.
- [ ] Add `mkdir` and removal commands after writable filesystems exist.
- [ ] Build MyOS's own Zig programs for Zig's `x86_64-linux` target and use the standard library (`std.fs`, allocators, later `std.Thread`) instead of the hand-written wrappers in `app/lib.zig`, once the kernel implements the syscalls the standard library's startup and I/O paths make (the syscall trace from 4.2 shows what is missing). Until then `app/lib.zig` keeps its own wrappers, on Linux's numbers.
- [ ] Build a few small C utilities with a stock Linux musl toolchain and run them (this replaces the libc port of the former milestone 7).
- [ ] Test commands, paths, redirection and pipelines with scripted shell sessions in QEMU (input via serial, output checked in the log).

### 6.4 Process control and time
- [ ] Decide how programs are started, and replace the private `run` syscall: either `clone(CLONE_VM|CLONE_VFORK)` plus `execve` (what musl's `posix_spawn` uses; no `fork` or copy-on-write needed), or one private spawn syscall kept outside Linux's numbers.
- [ ] Assign stable PIDs and track parent-child relationships.
- [ ] Define generalized process waiting and exit-code handling (`wait4`).
- [ ] Support Ctrl+C termination of foreground jobs.
- [ ] Add monotonic timekeeping and a sleep syscall (`clock_gettime`, `nanosleep`), on a calibrated TSC clock where the TSC is invariant and HPET otherwise: runtimes read the clock constantly.
- [ ] Read wall-clock time from the RTC and expose it to userspace (FAT32 timestamps in 11.5 need it).
- [ ] Add `getrandom`, `uname`, `getpid`/`gettid`, `sched_getaffinity`, `sched_yield`, `prlimit`/`getrlimit`.
- [ ] Start an `init` process that launches the shell, restarts it when it exits, and adopts orphans (2.7).
- [ ] Implement a basic `ps` command.
- [ ] Test PID and parent tracking, waiting on exited children, sleep accuracy, Ctrl+C termination, wall-clock time, and the shell being restarted after `exit`.
- [ ] Test each syscall from ring 3 against Linux's documented results and error codes, including the struct layouts.

**Milestone 6 done when:** Commands such as `ls /bin`, `cat /etc/motd`, and `echo hello` work, alone and in pipelines, from MyOS's own programs and from C programs built on Linux.

---

## 7. Threads and futexes

**Goal:** Run multi-threaded programs, with the threads of one process on different cores.

- [ ] Support multiple threads per process, with shared address space and descriptor table; revisit the single-thread assumptions documented in 2.7.
- [ ] Implement `clone` for threads (`CLONE_VM`, `CLONE_THREAD`, `CLONE_SETTLS`, `CLONE_PARENT_SETTID`, `CLONE_CHILD_CLEARTID`) and `exit` versus `exit_group`.
- [ ] Implement `futex` wait and wake with timeouts (timers from 2.8), including the wake on thread exit that `pthread_join` relies on.
- [ ] Wake futex waiters across CPUs, and keep TLB shootdowns (5) correct when threads of one process run on several cores.
- [ ] Test thread creation and join, TLS isolation between threads, futex wake-before-wait and timeouts, and many threads under preemption on several CPUs.
- [ ] Run a statically linked multi-threaded C program (pthreads, musl) built on Linux as a fixture.

**Milestone 7 done when:** An unmodified multi-threaded program built on Linux runs with its threads spread over several cores.

---

## 8. Signals

**Goal:** Deliver signals the way Linux does, so runtimes can handle their own faults and stop their own threads.

- [ ] Implement `rt_sigaction`, `rt_sigprocmask`, `sigaltstack` and `rt_sigreturn`, delivering signals on the return to user mode.
- [ ] Turn user faults into `SIGSEGV`, `SIGBUS`, `SIGFPE` and `SIGILL` with `siginfo` and a register context (including the extended state from 2.5), instead of always killing the process (2.2); runtimes use this for null checks and stack probes.
- [ ] Implement `kill`/`tgkill` and default actions; deliver Ctrl+C (6.4) as `SIGINT`.
- [ ] Interrupt blocking syscalls with `EINTR` or restart them.
- [ ] Check the saved return address and flags that `rt_sigreturn` restores (the remaining `sysretq` item in 2.5): a handler can put anything there.
- [ ] Test handlers that return, handlers that modify the saved context, nested and masked signals, the alternate stack, and signals sent to another thread on another CPU.
- [ ] Run a statically linked Go or Rust program (threads, futexes and signals in earnest).

**Milestone 8 done when:** A statically linked Go program built on Linux runs unmodified.

---

## 9. .NET, fast and multicore

**Goal:** Run an unmodified .NET Native AOT program, on several cores, with measured performance. This is the primary goal.

### 9.1 .NET Native AOT
- [ ] Implement what the list from 4.2 shows the .NET runtime still needs. Expected, to be confirmed by the trace: `/proc` and cgroup files for CPU and memory limits, `membarrier`, and thread suspension through signals.
- [ ] Run a .NET Native AOT hello-world (built for linux-musl, statically linked, invariant globalization).
- [ ] Run one that allocates enough to exercise the GC, then a multi-threaded one.
- [ ] Add them to the fixture binaries (4.3) and run them as QEMU tests on several CPUs.

### 9.2 Fast and multicore
"Fast" is part of the goal, so it is measured rather than assumed.
- [ ] Run foreign multi-threaded programs on all CPUs: threads of one process on different cores, cross-CPU futex wakeups and TLB shootdowns on `munmap`/`mprotect`.
- [ ] Add a benchmark suite run in QEMU with KVM and on real hardware: syscall round trip, context switch, page fault, thread create/join, futex ping-pong, and `mmap`/`munmap` churn.
- [ ] Benchmark a multi-threaded .NET workload (allocation-heavy and CPU-bound) for throughput and scaling from 1 to N cores, and compare with the same binary on Linux on the same machine.
- [ ] Profile and remove the hot spots the benchmarks show (the profiling items in 13 move up when this starts); candidates are per-CPU run queues, lock contention in the PMM and VMM, PCID to avoid TLB flushes, 2 MiB pages for large anonymous mappings, and a vDSO so `clock_gettime` needs no syscall.
- [ ] Known slow paths from the code review before 2.2, to measure first and fix where the benchmarks say so:
  - `read`/`write` bounce every 256 bytes through a kernel stack buffer, and `write` goes through the formatter as well.
  - Spawning a program copies the whole file to the heap and then into pages, although the initrd is already in memory (Debug builds: about 1.1 MiB per spawn, debug info included).
  - `print` keeps interrupts off while it writes to the polled serial port: about 22 ms for 256 bytes at 115200 baud, more than two timer ticks.
  - The kernel heap is first-fit over an address-sorted list with interrupts off; allocation and free are linear in the number of free chunks.
  - The page allocator scans its bitmap one bit at a time, now with interrupts off.
  - Every process switch reloads CR3 without PCID and flushes the TLB.
- [ ] Keep the safety features on in the benchmarked configuration (SMEP/SMAP, guard pages, user-copy checks), and record results per commit so regressions are visible.

### 9.3 Dynamic linking and the JIT runtime
Does not gate the milestone: the goal is met by a statically linked Native AOT binary.
- [ ] Load the ELF interpreter named by `PT_INTERP`, so dynamically linked programs run with musl's unmodified loader and shared libraries on disk.
- [ ] Run a dynamically linked hello-world built on Linux; test malformed `PT_INTERP` headers.
- [ ] Run the JIT-based .NET runtime (`dotnet app.dll`): it needs dynamic linking, file-backed mappings, many files on disk, and memory that changes from writable to executable (see the permission item in 2.4).

**Milestone 9 done when:** An unmodified .NET Native AOT program runs on MyOS without being rebuilt for it, uses several cores, cannot crash or corrupt the kernel, and its measured performance is recorded against Linux on the same hardware.

---

## 10. Graphical environment

**Goal:** Display multiple interactive windows and run a graphical terminal.

### 10.1 Graphics
- [ ] Expose framebuffer information through a safe userspace API.
- [ ] Implement pixel, rectangle, image, and text rendering.
- [ ] Add back-buffering and a display update mechanism.
- [ ] Implement a basic software renderer.
- [ ] Test rendering on the host against reference images.

### 10.2 Input
- [ ] Expose generic keyboard and pointer events to userspace.
- [ ] Add mouse support (PS/2 or USB).
- [ ] Track pointer coordinates and button states.
- [ ] Implement focus and event routing.
- [ ] Test event delivery and focus with injected input events.

### 10.3 Window system
- [ ] Implement a basic userspace compositor/window manager.
- [ ] Create/destroy windows and draw decorations.
- [ ] Support movement, resizing, overlap, and focus.
- [ ] Add shared memory mappings between processes (window buffers need them).
- [ ] Add IPC for graphical clients, with the compositor waiting on input and clients through `poll` (6.2).
- [ ] Build a graphical terminal and minimal desktop/launcher.
- [ ] Add a simple editor or file viewer.
- [ ] Test window management and graphical IPC with scripted clients, checking framebuffer output.

**Milestone 10 done when:** Multiple user applications can display and interact through windows.

---

## 11. Persistent storage and FAT32

**Goal:** Read and write files that survive a reboot.

Off the critical path (programs can ship in the initrd). It does not depend on milestone 10 and can be taken any time after milestone 6.

### 11.1 Block-device layer
- [ ] Define a generic block-device interface for read/write/capacity/block size.
- [ ] Add device registration and consistent I/O error reporting.
- [ ] Validate LBA ranges, buffer sizes, and alignment.
- [ ] Add a small block cache with explicit flush (FAT32 writes in 11.5 rely on it for flush ordering).
- [ ] Test the block layer on the host against a fake in-memory device: bounds, sizes, alignment, error propagation, and cache hits, eviction and flush.

### 11.2 NVMe
- [ ] Implement NVMe write operations.
- [ ] Support multi-page transfers with PRP lists or another valid DMA mechanism.
- [ ] Add PCI MSI/MSI-X support and switch NVMe from polling to interrupt-driven completion (legacy PCI interrupt routing would need an ACPI AML interpreter; the network driver in 12.1 reuses this).
- [ ] Validate namespace geometry and bounds.
- [ ] Handle command errors, timeouts, and controller failures.
- [ ] Audit DMA allocation, synchronization, and queue handling.
- [ ] Test repeated and boundary-crossing reads/writes using disposable images, including write-then-read-back and persistence across a reboot (storage write tests, moved from 1.2).

### 11.3 Partition discovery
- [ ] Parse GPT headers and partition entries.
- [ ] Verify GPT checksums and bounds.
- [ ] Expose partitions as block devices.
- [ ] Test corrupted and empty partition tables.

### 11.4 FAT32 read support
- [ ] Validate FAT32 BPB/boot-sector fields.
- [ ] Read FAT entries and traverse cluster chains.
- [ ] Enumerate directories and open nested paths.
- [ ] Read multi-cluster files.
- [ ] Support 8.3 names, then long filename entries.
- [ ] Detect invalid clusters, loops, and malformed metadata.
- [ ] Mount FAT32 through the VFS.
- [ ] Test reads against generated fixture images (11.6), including corrupted boot sectors, cluster loops and bad directory entries.

### 11.5 FAT32 write support
- [ ] Allocate/free clusters safely.
- [ ] Create files and directories.
- [ ] Write, extend, truncate, and delete files.
- [ ] Update directory entries and filesystem metadata.
- [ ] Add flush ordering and document crash-consistency limits.
- [ ] Test filesystem integrity from both MyOS and Linux after writes.

### 11.6 Reproducible disk fixtures
- [ ] Generate disposable GPT/FAT32 disk images with scripts.
- [ ] Populate fixtures using Linux `mkfs.fat`/`mcopy` tools.
- [ ] Check MyOS writes by remounting/inspecting the image from Linux.
- [ ] Run read/write regressions in CI, never against real user disks.

**Milestone 11 done when:** A FAT32 volume can be mounted and files persist correctly across reboot.

---

## 12. Networking

**Goal:** Communicate with other machines over IP.

Off the critical path (only network programs need it). It can be taken any time after milestone 6.

### 12.1 Network hardware
- [ ] Define a generic network-device interface.
- [ ] Choose the first network device: virtio-net is simpler than e1000e and its virtio groundwork is reusable for virtio-blk and virtio-gpu; e1000e matches real hardware.
- [ ] Implement the driver with TX/RX rings, using MSI/MSI-X interrupts (11.2).
- [ ] Handle RX interrupts and link state.
- [ ] Send/receive Ethernet frames in QEMU networking tests.

### 12.2 Network protocols
- [ ] Implement Ethernet frame parsing and ARP.
- [ ] Implement IPv4 packets, validation, and checksums.
- [ ] Add static IP/netmask/gateway configuration (QEMU user networking: 10.0.2.15/24, gateway 10.0.2.2).
- [ ] Add a DHCP client.
- [ ] Implement ICMP echo (ping).
- [ ] Implement UDP.
- [ ] Implement TCP handshake, data exchange, close, retransmission, and timeouts.
- [ ] Implement packet buffers and basic flow control.
- [ ] Add DNS resolution.
- [ ] Test protocol parsing, checksums and state machines on the host with recorded and malformed packets.

### 12.3 Sockets and programs
- [ ] Define socket create/bind/listen/accept/connect/send/receive/close syscalls (Linux's numbers and layouts).
- [ ] Implement `ping` and a small TCP client.
- [ ] Implement a minimal HTTP client or server.
- [ ] Add network integration tests with a host-side peer.

**Milestone 12 done when:** MyOS can ping a peer and establish a TCP connection.

---

## 13. Long-term / optional

### Hardware and platform
- [ ] USB xHCI and USB HID devices.
- [ ] Additional storage/network devices.
- [ ] ACPI power management, shutdown, and reboot.
- [ ] Run the QEMU test scenarios under UEFI (OVMF) as well; CI currently boots them with legacy BIOS only.
- [ ] CPU feature discovery and more QEMU/real-hardware testing.

### Advanced processes and memory
- [ ] Copy-on-write and shared file-backed mappings (demand paging and private file mappings: 5).
- [ ] `fork`/`exec` semantics if desired. A static busybox would then supply the standard utilities and a broad compatibility test.
- [ ] User/group permissions.

### Performance and observability
- [ ] CPU and memory usage statistics.
- [ ] Scheduler tracing and kernel profiling.
- [ ] Asynchronous I/O and a larger, smarter filesystem cache.

---

## Development rules

- Establish **milestone 1 (tests and CI)** first; after that, every section carries its own test items and is not done until they are.
- Deliver small, independently testable changes.
- Add regression tests alongside every subsystem or critical fix.
- Keep x86-64-specific implementation separate from architecture-neutral interfaces.
- Prefer explicit errors over panics for recoverable failures.
- Never trust pointers, addresses, lengths, or executable contents from userspace.
- Use disposable QEMU disk images for storage development.
- Update documentation when APIs or invariants change.
- Check off a milestone only when its **Done when** condition is demonstrated.
