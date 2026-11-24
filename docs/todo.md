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

Already implemented: Limine BIOS/UEFI boot, serial/framebuffer console, GDT/IDT/TSS, physical and virtual memory management, kernel heap, APIC timer, preemptive threading, ring 3, syscalls (Linux's x86-64 ABI), SSE/AVX state per thread, ELF64 loading, basic processes, read-only tarfs/VFS, PCI, basic NVMe reads, PS/2 keyboard, and a userspace shell.

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
- [x] Validate ELF class, endianness, machine type, type, version, and header sizes (`kernel/elf_image.zig`: both version fields, `e_ehsize` and `e_phentsize` must be exact; only `ET_EXEC` until position-independent executables are loaded in 4.1).
- [x] Validate program-header offset, count, entry size, and full table bounds (1 to 64 program headers).
- [x] Use overflow-safe arithmetic for file offsets, address ranges, and segment sizes.
- [x] Validate segment alignment and enforce user-only mapping ranges.
  - The alignment must be zero or a power of two, and the address and file offset must agree modulo the alignment and modulo the page size, as on Linux.
  - A segment no longer has to start on a page boundary: the loader places its data at the right offset in the page and zeroes the rest. Linux toolchains produce such segments.
- [x] Reject overlapping or conflicting load segments: two segments may not share a page (`error.Overlap`), since a page has one set of permissions.
  - This closes the leak where a second segment (or the user stack) mapped over an existing page replaced it without freeing the old page. `vmm.map` itself still replaces silently (2.6).
- [x] Prevent mapping page zero and reserved user regions (`process.image_limits`).
  - [x] The last user page is never mapped (`vmm.USER_MAP_END`; see the `sysretq` item in 2.5).
  - The first 64 KiB are never mapped (`IMAGE_MIN`, the same as Linux's `mmap_min_addr`).
  - The 8 MiB below the top of the user stack are reserved for the stack (`STACK_RESERVE`, Linux's default stack limit; 16 KiB of it is mapped today), and a program may not be loaded there or above.
- [x] Cap segment sizes (`memsz`) so one ELF cannot ask for all physical memory.
  - The segments of one program may take 256 MiB together (`process.MAX_IMAGE_BYTES`), a stand-in until there are per-process limits (2.6).
  - The loader refuses an image that needs more pages than are free, with some left over for page tables, before it allocates anything.
  - Not covered: memory that runs out for another reason while page tables are being allocated still panics (`vmm.allocTable`, 2.6).
- [x] Verify the entry point is inside an executable loaded segment (`error.BadEntry`).
- [x] Enforce readable/writable/executable permissions and avoid unintended writable-executable pages (a JIT later needs pages that go from writable to executable with `mprotect`, never both at once; see 9.3).
  - A segment that is both writable and executable is refused (`error.WritableExecutable`), and so is one with no permissions at all.
  - x86-64 pages are always readable, so write-only and execute-only segments are readable too.
- [x] Refuse dynamically linked executables (`PT_INTERP`) with `error.Unsupported` instead of starting them without their interpreter (until 9.3).
- [x] Roll back every allocated page and table on loading failure.
- [x] Add malformed and truncated ELF tests.
- [x] Split ELF header/segment validation from page mapping so it runs in host tests, and fuzz it there.
  - `kernel/elf_image.zig` validates the whole image before anything is mapped and has no kernel dependencies; `kernel/elf.zig` only maps. It keeps no segment table, so loading adds nothing to the kernel stack peak.
  - `tests/host/elf_image_test.zig` checks each rule and its error, and runs 200 000 mutated and random images through the validator with a fixed seed, checking every accepted image against the rules. It is a mutation loop in an ordinary test, so it runs in `zig build test-host` and CI; coverage-guided fuzzing (`zig build test --fuzz`) is not set up.
  - In-kernel tests ("ELF ..." in `tests/kernel/main.zig`) check the loader itself: contents and zeroing of unaligned segments, permissions, 33 rejected images with no leaked pages, and refusal before allocation when memory is short.

**Done when:** A crafted ELF file is refused before anything is allocated, so it cannot map memory outside the range programs may use, overlap its own segments or leak pages; every rule is covered by a host test.

### 2.5 Syscall and context-switch correctness
The ABI a program sees is described in `docs/syscalls.md`.
- [x] Decide whether the syscall numbers, error values and struct layouts follow Linux. Decided (2026-11-23): the native ABI is Linux's x86-64 syscall ABI, for MyOS's own programs too; no translation layer. Only the 64-bit `syscall` interface (no `int 0x80`, no x32).
- [x] Move the existing syscalls to Linux's numbers and argument registers (`rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9`): `read` 0, `write` 1, `open` 2, `close` 3, and also `sched_yield` 24, `exit` 60 and `gettid` 186. `getchar` and `run` have no Linux equivalent and sit at `0x4D5900` and `0x4D5901` until 6 replaces them.
  - The numbers, error values and flags are in `src/abi/linux.zig`, which the kernel and `app/lib.zig` both import, so there is nothing to keep in sync by hand. A host test compares them with Zig's own table of Linux's values.
  - The calls take Linux's arguments too: `write` takes a descriptor (1 and 2 are the console), paths are NUL-terminated (`uaccess.copyStringFromUser`), `open` takes flags and returns descriptors from 3 up, and an exit status is 8 bits.
  - Not done here, on purpose: reading descriptor 0 (still `myos_getchar`) and descriptors that can be inherited or duplicated. Both are 6.
- [x] Return Linux's negative errno values from every syscall instead of the single `ERR` value; mirror them in `app/lib.zig` (shared, see above).
  - `read` and `write` return a short count when the buffer turns bad partway, as Linux does, instead of failing after a partial transfer.
- [x] Introduce the per-CPU structure reached through GS, with `swapgs` on every entry from and exit to ring 3, while there is still one CPU (moved from the SMP milestone, so the entry assembly is audited once, in its final shape).
  - `src/arch/x86_64/percpu.zig` holds the kernel stack for `syscall` and the scratch slot for the user's stack pointer, which were globals. Scheduler state moves there in 3.2.
  - NMIs, double faults, machine checks and debug exceptions can interrupt ring 0 code that has the user's GS base (the first instruction of `syscall_entry`, the last before `sysretq`/`iretq`), so they decide by the GS base MSR instead of the saved CS (`isr_paranoid` in `idt.zig`).
  - Debug exceptions also get their own emergency stack (IST 3): one at the first instruction of `syscall_entry` would otherwise run in ring 0 on the user's stack pointer (the "MOV SS" attack, CVE-2018-8897). Nothing can cause one there today, since programs cannot set debug registers and TF is masked on entry, but `ptrace` or hardware breakpoints would. Tested by raising the exception in ring 0 with the user's GS base loaded, and from ring 3 by single-stepping into a syscall (`/test/single_step`).
  - A breakpoint exception (`int3`) stays on the ordinary path: it can only come from an instruction in the kernel's own code, never from the entry assembly.
- [x] Enable SSE (CR0/CR4) and save and restore the extended CPU state per thread on context switch: XSAVE with the area sized from CPUID, AVX enabled where supported, FXSAVE as the fallback. Build user programs with SSE; the kernel stays soft-float.
  - `src/arch/x86_64/fpu.zig`. The state is switched eagerly, and only between user threads: the kernel never touches these registers, so syscalls, interrupts and kernel threads cost nothing. A user thread's save area is 832 bytes with AVX (512 with FXSAVE), allocated with the thread.
  - AVX-512 and AMX stay disabled in XCR0. Enabling AVX-512 is a size and speed question for 9.2.
  - Not done: the faster save instructions (XSAVEOPT, XSAVES/compacted format). Measure first (9.2).
- [x] Audit `syscall` entry and exit assembly for register preservation and ABI stack alignment. The audit is written down at the top of `src/arch/x86_64/syscall.zig`. What it changed:
  - The frame now ends in a complete `iretq` frame (12 words, so the stack is 16-byte aligned at the call; checked at compile time and by an assertion on every syscall).
  - SFMASK now also clears NT and IOPL on entry. A program can set NT, and an `iretq` in ring 0 with NT set faults.
  - No register carries a kernel value out: the argument registers are restored, RCX and R11 hold the return address and flags, the rest are callee-saved.
- [x] Validate return RIP/RSP and avoid unsafe `sysretq` for noncanonical or invalid return states.
  - [x] Close the known case: a `syscall` instruction at the very end of user space returns to a non-canonical address, and `sysretq` then faults in ring 0 on the user's stack pointer (Intel). The ELF loader now refuses to map the last user page or put the entry point there (tested with segments at, across and just below it).
  - [x] Check the saved state in the exit path itself, on every syscall (`src/arch/x86_64/sysret.zig`, host-tested): `sysretq` for ordinary returns, `iretq` when RF or TF is set, and the process is killed when neither can return (return address outside user space, or selectors that are not ring 3's). The flags are sanitized first, so a return can never turn interrupts off or raise IOPL.
  - RSP needs no check: both instructions load any value, and a bad one faults in ring 3.
  - The kernel counts the returns it makes with `iretq` (`syscall.iret_returns`), and the tests check that exactly the returns that need it take that path.
- [x] Verify interrupt masking and preemption across syscall entry, blocking, and return. Interrupts are off from the `syscall` instruction until the handler runs on the kernel stack, on during the call, and off again from before the registers are restored. Checked at every syscall of the test programs, including ones that block and switch threads (`helpers.installProbes`).
- [x] Verify stack and address-space switches during timer interrupts and syscalls: at every timer interrupt and syscall, the frame is where it should be on the running thread's kernel stack, and CR3, the TSS stack and the per-CPU syscall stack are that thread's. Checked by the same probes, including timer interrupts that arrive inside a syscall.
- [x] Document the userspace syscall ABI, argument registers, clobbers, error codes, and return conventions (`docs/syscalls.md`: says where it is Linux's and lists only what MyOS implements and where it differs).
- [x] Test from ring 3 that syscalls preserve callee-saved registers and RFLAGS, keep the stack aligned, and survive preemption mid-syscall (`/test/syscall_abi`, `/test/preempt`; `tests/user/checked.zig` checks every register around a syscall, with all combinations of the arithmetic and direction flags and with misaligned stack pointers).
- [x] Test that each failure case in `/test/syscalls` returns its specific error code (65 checks there, 35 in `/test/user_pointers`).
- [x] Test that floating-point, SSE and AVX registers survive preemption between two processes, and that a new thread starts with clean extended state (`/test/fpu` run as a pair, `/test/fpu_clean`). The whole suite also runs on a CPU without XSAVE (`tests_fxsave` scenario), which tests the FXSAVE path.
- [x] Fuzz the syscall interface from ring 3 (random numbers and arguments, fixed seed in CI): the kernel must survive and leak nothing (`/test/fuzz`, 20 000 calls).
  - It finds argument-handling bugs in the calls that exist; it is a fixed sequence, not coverage-guided. Add each new syscall's number to it.
- [x] Clear all general-purpose registers on the first entry to user mode, so no kernel value leaks to the program (`context.enterUser`; tested from ring 3 by `/test/entry_regs`).

### 2.6 Memory-management correctness
- [x] Reject invalid, misaligned, and double page frees in the physical allocator.
  - `pmm.tryFree` returns `Misaligned`, `OutOfRange`, `NotManaged` or `NotAllocated` and changes nothing; `pmm.free` panics on any of them, in every build mode (the alignment and range checks used to be assertions, which `-Dassertions=false` removed).
  - New: a second bitmap records which pages the allocator owns. Before, freeing an address in a hole of the memory map (device or firmware memory) or one of the bitmap's own pages succeeded, and the page was handed out later.
- [x] Verify free-page counts and bitmap consistency under stress.
  - [x] Make `pmm.alloc`/`pmm.free` safe against preemption (interrupts off around the bitmap update); before, two preemptible threads could be handed the same page.
  - [x] Stress test with two preempted kernel threads allocating and freeing concurrently. It checks for shared pages and the free count, but the race window is a few instructions wide: it passed even with the locking removed, so it does not prove the lock.
  - [x] Prove the lock: a hook in the test kernel (`pmm.critical_hook`) holds each of two preemptible threads inside the critical section of `alloc` and `free` for 70 ms, longer than a time slice. With the lock the other thread cannot run in that time; with the lock removed from either function, the timer switches to it and it enters too, and the test fails every time.
  - [x] The bookkeeping is its own module without kernel dependencies (`src/kernel/page_bitmap.zig`), tested on the host: 200 000 random allocations and frees (valid and invalid) against a model, with the count checked after every step.
  - [x] `pmm.consistent()` recounts the bitmap and compares it with `free_pages`; the in-kernel tests call it after the stress test and after every exhaustion test.
- [x] Make page mapping report errors rather than silently replacing mappings: `vmm.map` returns `error.AlreadyMapped` for an address that is mapped by a page of either size. To change a mapping, unmap first.
  - This also fixed mapping a 4 KiB page inside a 2 MiB page, which treated the large page's memory as a page table.
- [x] Implement page unmapping and appropriate local TLB invalidation. `vmm.unmap` existed (with `invlpg`); it now also frees page tables that became empty, except the ones every address space shares for kernel addresses.
- [x] Handle page-table allocation failure without a partially corrupted mapping: `vmm.map` returns `error.OutOfMemory` and frees the tables it had added, so a failed call changes nothing. `createAddressSpace` returns the error too.
  - The kernel no longer panics when memory runs out after boot: the ELF loader, the user and kernel stacks and the heap pass the error on, and free the page they were about to map.
  - Still a panic, on purpose: running out during boot (`vmm.init`, `mapMmio`, the NVMe driver's buffer), where there is nothing to fall back to.
- [x] Free all user mappings and page tables on process teardown (`vmm.destroyAddressSpace`, which did this already; now tested for an address space with pages in several parts of the address range, and by every "nothing lost" check below).
- [x] Test memory exhaustion, mapping conflicts, repeated allocation/free, and failed allocations.
  - With every page taken, and with one or two pages short of the page tables a mapping needs, `map` fails and changes nothing; address spaces, kernel stacks, heap blocks, threads and processes cannot be created and leave nothing behind.
  - The test kernel can make the allocator fail after N more allocations (`pmm.fail_after`; compiled out of the normal kernel). Starting a process is repeated with N = 0, 1, 2, ... until it succeeds, so every single allocation in it has failed once (about 60 in a Debug build), each time with nothing lost. The same for kernel stacks across page-table boundaries and for heap growth.
- [x] Test from ring 3 that a program spawning itself recursively until memory runs out gets an error from `run` and the kernel survives with no leak (`/test/recurse`, with all but 4 MiB of memory taken first so the chain is dozens of processes, not thousands).
- [x] Add per-process resource limits (memory, descendants, open files) so one program cannot starve the rest (`process.Limits`, inherited by child processes).
  - Memory: every page of physical memory the process takes: its program, its stack, the page tables of its address space and its thread's kernel stack. A program that does not fit is not started (`ENOMEM`). The limit is 256 MiB by default. The test compares the charge with what really left the allocator, and checks the limit is exact (that many pages are enough, one less is not).
  - Processes cannot ask for more memory yet, so the limit is checked once, at start. Charging later requests is a task in 5.
  - Descendants: processes alive below a process, 1024 by default. Starting one more fails with `EAGAIN`.
  - Open files: 16 descriptors by default, which is also the size of the table (`EMFILE`).
  - What this does and does not give: one program and everything it starts are bounded, and the kernel survives memory running out. The default limits add up to far more than the machine has, so a program can still use up memory and make other programs' requests fail (as on Linux by default). Reading and lowering limits, and a default that follows the machine's memory, are tasks in 6.4; dividing memory between unrelated programs needs accounting per user or group, which is not planned yet.
  - Not counted: small kernel allocations a process causes (its `Process` and `Thread` structures, the saved x87/SSE/AVX state, open-file records).
  - The descendant count follows `parent` pointers, which are valid because a parent waits for its child. 2.7 (parents that exit first) must keep them valid.
- [x] Test unmapping: the translation disappears, freed pages and empty page tables return to the PMM, and a stale TLB entry is never used (moved from 1.2). The TLB test reads a user page through its mapping, unmaps it and expects a fault, then maps another page there and expects that page's contents, 50 times over.
- [x] Test mapping exhaustion: `map` reports out-of-memory when page tables can't be allocated and leaves existing mappings intact (moved from 1.2).

### 2.7 Process and scheduler lifecycle
- [x] Define ownership rules for processes, threads, stacks, page tables, and open files. Written at the top of `src/kernel/process.zig`, with a table of what is freed when:
  - A process owns its address space, open files and name; a thread owns its kernel stack and saved CPU state.
  - The `Process` structure is reference-counted: one reference is its thread's, one belongs to whoever called `spawn`, who gives it up with `process.wait` or `process.release`.
  - Files are closed at exit; the address space and kernel stack are freed when the thread is reaped; the structure goes with the last reference.
- [x] Document the current single-thread-per-process assumption explicitly (same place: what relies on it, for milestone 7 to revisit).
- [x] Review ready/running/blocked/dead transitions and prevent duplicate queue insertion. The states and what moves a thread between them are described at the top of `src/kernel/thread.zig`.
  - `Thread.link` records which scheduler queue a thread is in; every insertion and the reaper check it, so queueing a thread twice or reaping it twice is a panic, not a corrupted list.
  - Fixed: a blocked thread with no other thread ready spun forever with interrupts off, so nothing could wake it. `block` and `exit` now idle with interrupts on until something is ready. The normal kernel never hit this (its idle thread is always ready); timers and the test kernel do.
- [x] Make block/wake semantics race-safe, including wake-before-block. `wake` leaves a permit when its target is not blocked yet, and `block` returns at once if one is there. Callers loop on their condition, because a permit can be left over; wait queues (2.8) do this and are the interface to use.
- [x] Handle children that exit before the parent begins waiting. The exit status is kept in the `Process` structure for as long as anyone holds a reference, so `wait` returns at once however late it is called. Before, the status was written into the waiting thread, which had to be blocked already.
- [x] Handle parents that exit before their children: the children are handed to the parent's own parent (or to nobody), so `Process.parent` always points at a process that has not exited and the descendant counts (2.6) stay right.
  - No syscall can cause this yet, since `myos_run` waits for its child. The kernel test builds the situation directly.
  - Not done: reparenting to an init process that collects orphans' exit statuses. Nobody can ask for an orphan's status, so nothing is kept; revisit with `fork`/`wait4` (6.4).
- [x] Reap each exited thread/process exactly once (checked by assertions on the thread's queue and state, on tearing a process down, and on the reference count; the tests compare threads created with threads reaped).
- [x] Close open descriptors and free all resources on process exit and failed spawn. Files are now closed at exit instead of when the thread is reaped, which will matter once closing has effects others see (pipes). Failed spawns are covered by the 2.6 allocation-failure sweep.
- [x] Stress-test repeated spawn/exit, wait, wakeup, orphaning, and failure paths (`helpers.lifecycleStress`: 40 rounds of processes waited for at once, late and in reverse order, never waited for, killed by a fault, starting children, cut off by a limit, and failing to start; afterwards no process, thread, stack, page or heap byte is left).

### 2.8 Synchronization and timers
Pipes, blocking I/O, sleep and interrupt-driven drivers need these, and SMP (milestone 3) builds directly on them. The code is in `src/kernel/sync/` and `src/kernel/timer.zig`.
- [x] Add interrupt-aware spinlocks with interrupt-state restoration, as real atomic locks from the start (`sync/spinlock.zig` on the atomic `sync/raw_spinlock.zig`).
  - The atomic part is tested on the host with four real threads, the only place it can meet true parallelism before milestone 3.
  - A lock that stays held absurdly long (taken twice, or never released) is a panic rather than a silent hang.
  - The physical allocator, the heap and the kernel stack allocator use them now. Still protected by turning interrupts off only, for 3.1 and 3.4: the scheduler's queues, process bookkeeping, the page tables, and the drivers.
- [x] Add wait queues and replace the single-`waiter` pointers (keyboard, process wait) with them (`sync/wait_queue.zig`: any number of waiters, woken in arrival order, one or all, with an optional timeout).
  - Several programs can now wait for a key; each key goes to the one that has waited longest.
  - On one CPU the rule "check the condition and wait with interrupts off" is enough to never lose a wake-up. With several, the check and the wait must be under a lock the waker also takes (3.1).
- [x] Add mutexes for code that may block while holding a lock (`sync/mutex.zig`). `unlock` hands the mutex to the longest waiter, which owns it before it runs, so nobody starves. Nothing in the kernel uses one yet; the first users are expected in 6 (pipes, the terminal).
- [x] Add kernel timers: a timeout queue driven by the timer tick, for sleep, driver timeouts and later TCP (`timer.zig` with the ordering in `sync/timer_queue.zig`; `sleepTicks`, `sleepMs`, and `WaitQueue.waitTimeout`).
  - Resolution is one tick (10 ms). The queue is a sorted list: fine for a handful of timers, to be replaced by a heap or a timer wheel when there are many (12, TCP).
  - No syscall uses it yet (`nanosleep`, `clock_gettime`: 6.4).
- [x] Test several waiters on one queue, wake-before-block, timer ordering and expiry, and mutex hand-off under preemption.
  - Host: the timer queue against a model (100 000 random operations), the spinlock under contention.
  - In the kernel: spinlock interrupt state and nesting; wait queue order, rechecked conditions, wake-ups with nobody waiting, timeouts, and being woken and timing out on the same tick; timers firing on their exact tick, cancellation, sleep length against the HPET; a mutex whose holder is preempted, yields and sleeps; keyboard readers.

### 2.9 Further hardening
From the code review before 2.2. None of these fix a known hole; they shrink what a future bug can do.
- [x] Enable UMIP when CPU-supported, so ring 3 cannot read kernel table addresses with `sgdt`/`sidt` (`usercopy.init`; tested by `/test/umip`).
- [x] Add a kernel random-number generator: a CSPRNG seeded from RDSEED/RDRAND where present, plus timing jitter (`src/kernel/random.zig`; the deterministic part, ChaCha with fast key erasure, is `random_core.zig` and tested on the host). Address randomization draws from it; `AT_RANDOM` (4.1) and `getrandom` (6.4) will.
  - It is reseeded from the hardware source after every megabyte of output.
  - On a CPU with neither instruction the seed rests on timer jitter alone, which is weak; boot says so in the log. Interrupt timing is not mixed in yet (`random.addEntropy` exists for it): do that with the input drivers of 6.2.
- Stack protectors: moved to 13. The compiler cannot build them for the kernel yet (see there), so they are not part of this milestone.
- [x] Add a speculation barrier after the user range check in the user-copy path, and audit other user-controlled indexes (syscall number, file descriptor) for Spectre v1 (`src/arch/x86_64/nospec.zig`).
  - `user_copy` starts with `lfence`, so it cannot begin copying before the range check on the user address is decided.
  - File descriptors index the descriptor table through `nospec.index`, which clamps without a branch.
  - The syscall number is not an index: the dispatcher is a `switch` over scattered numbers, compiled to comparisons. Check again if it becomes a table.
  - Not done: the other Spectre variants (branch target injection and later ones) and their mitigations (retpolines, IBRS/IBPB, STIBP). See 13.
- [x] Decide on kernel page-table isolation: detect CPUs that need it (Meltdown) and either implement it or refuse to run untrusted code on them. Decided: not implemented. The kernel checks the CPU at boot (`src/arch/x86_64/meltdown.zig`, rule tested on the host) and refuses to boot on an affected one, since any program could read all memory there; `-Dallow-meltdown` turns that into a warning. Processors made since about 2019, and all AMD ones, are not affected.
- [x] Randomize the kernel's load address and the user stack (KASLR/ASLR).
  - The kernel is a position-independent executable, and `kaslr: yes` in `limine.conf` has the bootloader load it at a random address in the top 2 GiB. Backtraces take the offset into account and print it. `MYOS_KASLR=no scripts/build.sh` turns it off for debuggers.
  - Each process's stack ends at a random page in a 16 GiB range, and its initial stack pointer is at a random 16-byte step within the last half page.
  - Moved to 4.1: the program's own load address, which needs position-independent programs.
  - Not randomized: the kernel's direct map of physical memory, its heap, its stacks and the device window, which are at fixed addresses (`randomise_hhdm_base: no`, because a random direct map could land on the fixed regions). See 13.
- [x] Poison freed heap memory and freed pages in debug builds to catch use-after-free (`-Dpoison`, on in Debug builds and the test kernel).
  - A freed heap block is filled with 0xDD and checked when it is handed out again: a write after free is a panic naming the address, the byte and its offset (the `use_after_free` scenario).
  - A freed page is filled with 0xDF. Pages are not checked on reuse, so a write to a freed page is not noticed; a read gives poison, which as a pointer is not a valid address.
- [x] Set up coverage-guided fuzzing next to the fixed-seed runs, for the host-tested parsers: `zig build fuzz-host --fuzz` (`docs/testing.md`), today for the ELF validator and the ELF symbol table, 3 million cases each without a finding. The fixed-seed runs stay in CI; these run on demand.
  - Moved to 13: a syscall fuzzer steered by kernel coverage, which needs coverage instrumentation in the kernel.
- [x] Zero pages before they reach another process, as a rule in one place instead of at each call site: `pmm.allocZeroed` is the only source of pages for user address spaces and page tables. Tested from ring 3 (`/test/zero_pages`) after filling all free memory with a pattern.
  - Kernel stacks and heap pages are not zeroed: only the kernel sees them.

### 2.10 Review follow-ups
From the code review of 2026-11-23 (`docs/research.md`). None fixed a known hole: the first group makes the kernel faster for a few lines each, the second shrinks what a future bug can do. They are part of milestone 2 and came before milestone 3, while there is one CPU and the changes are small.

Speed:
- [x] Take the idle thread out of the round-robin queue. There is no idle thread any more: the boot thread blocks for good once the system is up (`thread.retire`), and when nothing is ready the CPU halts inside `block` or `exit` of whichever thread ran last. Before, the idle thread got a turn like any thread and halted until the next interrupt while others waited, which cost a CPU-bound program about a sixth of the CPU.
  - The check for "nothing to run" and the halt happen with interrupts off (`sti; hlt`), so a wake-up cannot arrive just before the halt and wait for the next tick. `idleOnce` asserts the ready queue is empty.
  - Tested in the kernel ("no idling while a thread is ready"): with a retired thread and this one blocked, a CPU-bound thread runs for 200 ms without one switch or halt, and finishes within two ticks of that; with nothing ready, the CPU does halt. With the old idle loop in place of `retire` the test fails. The normal kernel was also booted to the shell prompt under QEMU, with and without KVM.
- [x] Mark kernel mappings global (page-table bit 8, CR4.PGE), so loading CR3 keeps the kernel's TLB entries. `vmm.map` sets the bit on every kernel address and on no user address, whatever the caller passes. `vmm.init` turns CR4.PGE off around its first CR3 load, so nothing of the bootloader's page tables stays in the TLB.
  - Tested: CR4.PGE is on; code, constants, data, heap, a kernel stack and the direct map have the bit, in the kernel's tables and seen from another address space; a user page has not. A second TLB test maps, reads, unmaps and remaps a kernel address 50 times, with CR3 loads in between, and never sees the old page.
- [x] A kernel thread keeps the address space that is loaded instead of switching to `kernel_root` (`switchToNext` in `src/kernel/thread.zig`): every address space maps the kernel half. `vmm` now records which root is loaded (`loadedRoot`), and `process.teardown` switches to the kernel's own tables before it destroys one that is still loaded (`vmm.unloadRoot`); destroying the loaded one is an assertion failure.
  - Tested: a kernel thread and a process take turns for over 100 round trips at the cost of exactly two CR3 loads (into the process, and away from it at teardown); CR3 holds the process's root while the kernel thread runs, and the kernel's after teardown, with no page lost. With either change undone the test fails.
- [x] Scan the page allocator's bitmap a 64-bit word at a time with `@ctz` (`src/kernel/page_bitmap.zig`); the bitmaps are whole words now. Host tests: the only free page at the first and last bit of every word and as the last page, for search hints before, at and after it; a search that starts mid-word and wraps; and the existing run against the model.
- [x] Replace the `lfence` at the start of `user_copy` with branch-free clamping of the user address (`user_copy_from` and `user_copy_to` in `src/arch/x86_64/usercopy.zig`): an address outside user space becomes 0, which is never mapped, so the copy fails whatever the CPU predicted. Only the start is clamped: the copy runs upwards and meets the unmapped gap above user space before any kernel address.
  - Tested in the kernel, by calling the copy routines without the range check: reading from kernel data, the direct map and the first addresses past user space fails and brings nothing back; writing to kernel data fails and changes nothing. With the clamp removed the test fails. (Not a host test, as planned first: the clamp is in the assembly routine, and this tests the routine itself.)

Hardening:
- [x] Make the relocated constants read-only once the kernel runs: `.data.rel.ro`, `.dynamic` and `.got` have their own page-aligned part of `linker.ld` and are mapped without `WRITABLE` in `vmm.init`. They hold tables of function pointers, the heap allocator's among them.
  - Tested: the `relro` scenario writes to that table and gets a page fault; an in-kernel test checks the page-table entries.
- [x] Map the kernel's text, read-only data and relocated constants read-only in the direct map of physical memory as well (`mapDirect` in `vmm.zig`): the 2 MiB pages around the image are 4 KiB pages there, so the rest stays writable.
  - Tested: the `text_alias` scenario writes to kernel code through its direct-map address and gets a page fault; an in-kernel test checks the entries at both ends of the read-only range and walks every kernel mapping to see that none is writable and executable.
- [x] Give machine checks their own emergency stack (IST 4), like double faults, NMIs and debug exceptions. The emergency-stack test covers all four: gates, separate aligned stacks, and the CPU really switching to each.
- [x] Call the syscall dispatcher directly in the normal kernel; the replaceable handler pointer (`arch.syscall.setHandler`) exists in the test kernel only. The handler for returns to an invalid state is called directly in both.
  - Tested by `zig build check-dispatch` (`scripts/check-dispatch.sh`, part of `zig build test` and CI in every build mode): the pointer's symbol must be in the test kernel and not in the normal one.

Found on the way: the "kernel runs at a randomized address" test overflowed, and panicked, when the bootloader placed the kernel in the top 64 MiB (about 3 boots in 100). Fixed in `tests/kernel/helpers.zig`.

**Milestone 2 done when:** Malformed binaries, invalid pointers, expected user faults, and resource exhaustion do not take down the OS or leak resources. Reached: 2.1 to 2.10 are done.

---

## 3. SMP

**Goal:** Safely use multiple CPU cores.

Moved up (it was milestone 5): bringing up SMP while the kernel is small is far cheaper than retrofitting it onto pipes, a terminal, `mmap`, futexes and signals written for one CPU. Everything after this milestone is written and tested on several cores.

### 3.1 Synchronization
The primitives come from 2.8 and are already real locks; this section makes their users safe on several CPUs. It is done on one CPU: what needs a second CPU to be tested is listed under 3.4.
- [x] Decide and document the kernel's preemption and locking model: whether kernel code can be preempted, which locks disable interrupts, and what may be held across a block.
  - In `docs/locking.md` (locks and what each protects, the lock order, the sleep and wake pattern, per-CPU state, TLB rules), describing the code. The model checks have run.
- [x] Audit existing `cli`/`sti` critical sections and replace every one that assumes a single CPU:
  - the scheduler's ready queue, zombie list and thread states: the scheduler lock (`thread.zig`);
  - the process tree, descendant counts, reference counts and exit status: the process-tree lock (`process.zig`). A new process's thread is created before the lock is taken (`thread.create`, `start`, `destroy`), so nothing is allocated under it;
  - the page tables of `kernel_root`: each region (heap, kernel stacks, device window) has its own lock and its own top-level slot, whose tables exist from boot, so no two regions share a page table. The device window got its lock (`vmm.zig`);
  - the keyboard buffer, modifier state and readers: one lock, and `keyboard.read` does the waiting (`ps2_keyboard.zig`). The console and the serial port: the console lock (`main.zig`); a CPU reporting a panic or a kernel fault prints without waiting for it.
  - What is left with interrupts off only is state that belongs to the CPU (the running thread, the time slice, the loaded address space), which moves to per-CPU storage in 3.2.
- [x] Hold the scheduler lock across the context switch and release it in the thread that is switched to (a new thread's first code included), so a thread that has marked itself blocked cannot be woken and run by another CPU while its own CPU is still on its stack (`docs/locking.md`).
  - An exited thread goes on the zombie list on the far side of the switch too, so no CPU can free a stack another one is still on.
  - A blocked thread whose CPU idles on its stack (there is no idle thread) is woken in place (`Thread.on_cpu`), never through the ready queue. Added to the model, with the failure that follows without it.
- [x] Make timer callbacks safe against the thread that armed them returning: `timer.WakeTimer` has the two flags ("fired" before the wake, "finished" last) and `finish`, which cancels the timer or waits for a callback that has started. `sleepTicks` and `waitTimeout` use it.
- [x] Wake a thread before releasing the lock of the condition it waited for: `WaitQueue.wakeOne` and `wakeAll` are called with that lock held, and assert that a lock is.
- [x] Make mutexes and wait queues safe against wakeups from another CPU: `WaitQueue.wait` takes the condition's lock, which the waker takes too, and releases it only once the thread is on the queue. A wait queue has no lock of its own any more. `Mutex` has an internal spinlock; `process.wait` waits under the process-tree lock.
- [x] Define lock-ordering rules: every `SpinLock` has a rank (`sync/lock_order.zig`), each CPU records the locks it holds, and taking one out of order, blocking, yielding or exiting with one held, or releasing one that is not the innermost panics at once, in every build with assertions.
  - Tests: the bookkeeping on the host (every pair of ranks); in the kernel, that the record follows the locks through waits, switches and interrupts; two QEMU scenarios that break the rules on purpose (`lock_order`, `sleep_with_lock`) and must panic.
- [x] Model-check the blocking protocols before relying on them with several CPUs (the Converos approach, `docs/research.md`): sleep and wake with the permit, the context switch out of a blocking thread, wait queues with timeouts, and the mutex hand-off.
  - The checker is `tools/modelcheck`, about 200 lines of Zig that try a model's steps in every order; no outside tool (TLA+ was the first idea and needs Java). The models are in `tests/models/`, each naming the code it describes. `zig build check-models` runs them; it is part of `zig build test` and CI.
  - Every rule can be switched off in its model, and a test expects the failure that follows (a lost wake-up, a thread on two CPUs, a thread that is never run again, a thread woken after it has gone, two owners of a mutex): 4 models that must hold and 9 that must fail.
  - It showed one thing the design had wrong: the waker must wake a thread before it releases the condition's lock, not after, or a waiter with a timeout can be gone by then. `docs/locking.md` says so now.
  - Limits: a model is not the code, so the conversions above still need tests on several CPUs (3.4). The checker has no fairness; "eventually" is checked as "nothing gets stuck and finishing stays possible".
- [x] Go through the syscalls that exist with the scalable commutativity rule (`docs/research.md`) and write down, in the locking document, which pairs must not contend on several CPUs and which cannot avoid it (`open` must return the lowest free descriptor). Calls that commute and still contend today do so on the heap lock, the scheduler lock and the process-tree lock; the first two have items in 3.4.

### 3.2 Per-CPU state
The per-CPU structure and the `swapgs` transitions come from 2.5.
- [ ] Move current-thread, scheduler, syscall-stack, and interrupt state to per-CPU storage.
- [ ] Initialize separate GDT/TSS, emergency (IST) stacks and guarded stacks for each CPU.
- [ ] Add a speculation barrier (`lfence`) after the conditional `swapgs` in `isr_common`, on both branches, once kernel code reads through GS: the CPU can guess the branch wrong and run on with the wrong GS base (CVE-2019-1125). Check the details against Linux's entry code first; the note in `docs/research.md` was written from memory.
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
  - A CPU that halted with nothing to run must be interrupted when another CPU makes a thread ready or wakes the thread it idles in (`thread.wake`, `idleOnce`); until then it notices at its next timer tick.
  - A CPU that reports a panic or a kernel fault stops the others first, so the report comes out whole (`root.seizeConsole`).
- [ ] Add CPU affinity/load balancing if needed.
- [ ] Synchronize PMM, heap, page tables, and drivers.
- [ ] Implement cross-CPU TLB shootdowns.
  - `vmm.unmap` frees page tables that became empty, and hands the page back to its caller, before it flushes. With several CPUs the order must be: clear the entries, flush on every CPU that has the address space loaded, and only then free tables and pages. Otherwise another CPU can walk a freed table.
- [ ] Decide the page allocator for several CPUs: per-CPU caches of free pages in front of the bitmap, or a lock-free design on bitmaps such as LLFree (`docs/research.md`), which also hands out 2 MiB frames cheaply (9.2).
- [ ] Give the kernel heap size classes with a per-CPU cache of free objects, replacing the first-fit list under one lock (`docs/research.md`: magazines, snmalloc).
- [ ] Preempt on wake-up, or otherwise bound how long a woken thread waits: today it goes to the tail of the queue and waits for the running thread's slice to end, up to 50 ms. Futex-heavy programs depend on it (7).
- [ ] Stress-test simultaneous allocations, processes, interrupts, and I/O.
  - From 3.1, the cases one CPU cannot produce: a timer that fires on another CPU exactly as the waiter is woken (`WakeTimer.finish` then has to wait for the callback); a wake-up from another CPU between a waiter's check and its sleep; a thread woken while its CPU is still switching away from it; real contention on the scheduler, process-tree and console locks.
  - The in-kernel tests keep their own shared state safe with interrupts off in many places, which is only enough on one CPU: give them locks (as the wait-queue, mutex and timer tests have) before running them on several.
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
- [ ] Choose that load bias at random for each process (moved from 2.9, which randomized the stack and the kernel), with `process.SpawnOptions.randomize` turning it off as it does for the stack. Fixed-address executables (`ET_EXEC`) cannot be moved. Test that two runs of a PIE get different bases.
- [ ] Give each thread its own FS base: `arch_prctl(ARCH_SET_FS)`, saved and restored on context switch; enable FSGSBASE when the CPU has it.
  - Before FSGSBASE is enabled, change `isr_paranoid` (`src/arch/x86_64/idt.zig`): it takes a GS base with the top bit set to be the kernel's, and with `wrgsbase` a program can load such a value, so an NMI or debug exception would run on the user's GS base. Save the GS base on entry, load this CPU's own unconditionally, and restore the saved one on exit, as Linux does. Test from ring 3: set a kernel-looking GS base, single-step into a syscall, and expect the kernel to survive.
  - `arch_prctl(ARCH_SET_GS)` and `ARCH_SET_FS` must refuse addresses outside user space.
  - The kernel does not set up the TLS block from `PT_TLS`: on Linux the C library does that itself, from the program headers it finds through `AT_PHDR`.
- [ ] Extend the syscall ABI document from 2.5 with the startup stack, the auxiliary vector and TLS.
- [ ] Test empty, long, invalid, and multi-argument commands, and check the stack layout from ring 3.

### 4.2 Minimal syscall set
- [ ] Return `-ENOSYS` for unknown syscalls and add a syscall trace option that logs them, to see what a program still needs.
- [ ] Record what the target programs really ask for: run the fixture binaries (musl hello, a Go hello, the .NET Native AOT hello and a GC workload) under `strace -f` on Linux and keep the list of syscalls and files in `docs/`. Use it to order the work in milestones 5 to 9.
  - Run them under Loupe as well (`docs/research.md`): it finds which of those calls must really work, which may return `ENOSYS` and which may pretend to succeed. That, not the bare list, is the work order.
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

- [ ] Before designing the next item, read the two opposite answers to it in `docs/research.md` and write down which way MyOS goes and why: page tables as the only record, with metadata per page (CortenMM), or a region structure built for concurrency (the interval skiplist). Many threads of one process fault and change mappings at once under a garbage collector, so the choice decides how 7 and 9.2 scale.
- [ ] Define user virtual-memory regions: a per-process set of regions with their permissions and backing, which the page-fault handler consults.
- [ ] Add demand paging and overcommit for anonymous memory: garbage collectors reserve huge virtual ranges and commit them piece by piece.
- [ ] Implement `mmap`: anonymous mappings, `MAP_FIXED`, `MAP_NORESERVE`, `PROT_NONE` reservations, and private file-backed mappings (needed by the dynamic loader in 9.3).
- [ ] Implement `mprotect`, `munmap` of partial ranges, `madvise(MADV_DONTNEED)` and `brk`, with resource reclamation.
- [ ] Charge every page a process gets after it has started against its memory limit (`process.Limits.max_pages`, 2.6): pages given on demand to `mmap`, `brk` and stack growth, and the page tables they need; give the charge back on `munmap`. Today the limit is only checked when the program is loaded, because nothing else can allocate. A request over the limit fails with `ENOMEM`; a page fault over it follows the out-of-memory policy below. Test that the charge always equals what left the allocator, as the 2.6 test does at start.
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
- [ ] Raise the longest path from 255 bytes to Linux's 4095 (`PATH_MAX` 4096). Paths are copied to a buffer on the 16 KiB kernel stack today (2.5), which is why the limit is low; the buffer has to move to the heap first. Relative paths and a current directory belong here too.
- [ ] Add mount-point traversal so multiple filesystems can coexist.
- [ ] Add create/write/truncate/unlink/mkdir operations to the VFS interface.
- [ ] Add a small in-memory filesystem (ramfs) mounted at `/tmp`, so redirection (6.3) has somewhere to write and the write API is proven before FAT32 (11.5).
- [ ] Define consistent VFS error codes that map onto the syscall error codes (2.5).
- [ ] Test directory lookup, `readdir`, `stat`, `.`/`..` normalization, mount traversal and error codes (host tests with fake filesystems, plus initrd tests in QEMU).
- [ ] Test ramfs create, write, read-back, truncate, unlink and out-of-memory on the host and from ring 3.
- [ ] Run the tarfs parser in host tests and fuzz it with malformed archives.

### 6.2 Descriptors and I/O
- [ ] Reserve FDs 0/1/2 for stdin/stdout/stderr.
  - [x] The numbers are reserved since 2.5: `open` returns descriptors from 3 up, and `write` to 1 and 2 reaches the console.
  - [ ] Still to do: they are not real descriptors. They cannot be closed, redirected or inherited, and `write` handles them as a special case.
- [ ] Make `read` on descriptor 0 return keyboard input and remove the private `myos_getchar` syscall (`0x4D5900`). Today `read(0, ...)` returns `EBADF` and the shell reads keys with `myos_getchar`. Do it together with the terminal layer below, so blocking, line editing, echo and end of file are designed once; move `app/sh.zig` to `read` and update `docs/syscalls.md`.
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
- [ ] Add monotonic timekeeping and a sleep syscall (`clock_gettime`, `nanosleep`), on a calibrated TSC clock where the TSC is invariant and HPET otherwise: runtimes read the clock constantly. `nanosleep` sits on the kernel timers of 2.8, whose resolution is one tick (10 ms): decide whether that is enough or sleeps need a one-shot timer.
- [ ] Read wall-clock time from the RTC and expose it to userspace (FAT32 timestamps in 11.5 need it).
- [ ] Add `getrandom`, `uname`, `getpid`/`gettid`, `sched_getaffinity`, `sched_yield`, `prlimit`/`getrlimit`.
  - `prlimit64` reads and lowers the limits of 2.6: `RLIMIT_AS` or `RLIMIT_DATA` for memory, `RLIMIT_NOFILE` for descriptors, `RLIMIT_NPROC` for processes (MyOS counts descendants, Linux counts per user: decide how to present that). A process may lower its limits and never raise them above what it was given.
  - Make the default memory limit follow the machine: a share of physical memory instead of a fixed 256 MiB, so one program cannot take everything on a small machine and is not held back on a large one.
- [ ] Start an `init` process that launches the shell, restarts it when it exits, and adopts orphans (2.7).
- [ ] Implement a basic `ps` command.
- [ ] Test PID and parent tracking, waiting on exited children, sleep accuracy, Ctrl+C termination, wall-clock time, and the shell being restarted after `exit`.
- [ ] Test from ring 3 that a parent can exit before its child and the child is adopted. 2.7 handles this in the kernel, but no syscall could cause it then, so it is only tested from inside the kernel.
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
  - The page allocator scans its whole bitmap for a free page, with interrupts off (a word at a time since 2.10; a free list or per-CPU caches would not scan at all: 3.4).
  - Every switch between two processes reloads CR3 without PCID and flushes the user TLB entries (kernel entries are global and kernel threads do not reload it since 2.10).
  - Every switch between user threads saves and restores the whole x87/SSE/AVX state with plain XSAVE (2.5). XSAVEOPT or XSAVES would skip what has not changed.
  - AVX-512 is disabled (2.5). Decide whether to enable it: the .NET runtime uses it where it can, at the cost of a save area of about 2.5 KiB per thread.
  - `vmm.unmap` scans whole page tables (512 entries per level) to see whether they became empty (2.6); a count per table would avoid it.
  - Timers are a sorted list, linear to arm (2.8).
  - The kernel heap never gives pages back to the page allocator: memory it grew by for one large allocation stays with it.
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
- [ ] Replace the sorted list behind kernel timers (2.8) with a heap or a timer wheel before TCP arms several timers per connection.
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
- [ ] Divide memory between unrelated programs: accounting per user or per group of processes, with a share each cannot exceed. The limits of 2.6 bound one program and what it starts; they do not stop it from using up memory other programs need.
- [ ] Build the kernel with stack protectors and test that a smashed kernel stack is detected (moved from 2.9).
  - What it is: the compiler puts a secret value (a canary) between each function's local variables and its return address, and checks it before the function returns. A buffer overflow that reaches the return address has overwritten the canary first, so the kernel panics instead of jumping where the overflow says.
  - Waiting for Zig: version 0.17 refuses the option (`stack_protector` in `build.zig`, `-fstack-protector`) for a target without a C library, with "enabling stack protection requires libc", and it has no C library for a freestanding target such as the kernel. Zig has to allow stack protection without libc, or we need another way to pass the option to its LLVM backend. Try again whenever the Zig version is raised.
  - What is ready: the canary would come from `src/kernel/random.zig`, and the compiler's runtime already provides `__stack_chk_guard` and `__stack_chk_fail`, so it should be the build option, setting the canary early in boot, and one crash scenario in `scripts/test-qemu.sh`.
  - Until then: the guard page below each kernel stack (2.3) catches a stack that grows too far, but not an overflow that overwrites a return address inside the stack.
- [ ] Fuzz the syscall interface with a fuzzer steered by kernel coverage (the fixed-sequence fuzzer of 2.5 stays in CI). Needs coverage instrumentation in the kernel and a way to get it out to the fuzzer.
- [ ] Mitigate the Spectre variants beyond bounds-check bypass (2.9): branch target injection (retpolines or IBRS, IBPB on process switch, STIBP), return stack underflow, and the newer ones, decided per CPU from its capability bits as for Meltdown.
  - First step, cheap: turn on enhanced IBRS (Intel) or AutoIBRS (AMD) at boot where the CPU has it. Check the details first; the note in `docs/research.md` was written from memory.
- [ ] Enable LASS (linear address space separation) where the CPU has it: one CR4 bit that makes ring 3 accesses to kernel addresses fault before the page walk, which closes timing probes of the kernel's layout that KASLR alone does not. It reuses the `stac`/`clac` section of `user_copy` (`docs/research.md`). Needs a CPU model in QEMU that has it to test.
- [ ] Add a FRED entry path next to the IDT and `syscall` one, once QEMU can emulate FRED in CI: it replaces `swapgs`, the emergency stacks and `sysretq` with entry and return that cannot be caught half-done (`docs/research.md`).
- [ ] Randomize the kernel's fixed regions as well as its image (2.9): the direct map of physical memory, the heap, the kernel stacks and the device window. They are at fixed addresses today, so a leaked pointer into one of them is as good as before KASLR.
- [ ] Decide whether to implement kernel page-table isolation after all, so that CPUs affected by Meltdown can run untrusted programs (2.9 refuses to boot on them).
- [ ] Charge a process for the kernel memory it causes beyond its pages: its process and thread structures, saved x87/SSE/AVX state, open-file records, and later pipe buffers and socket buffers.

### Other ABIs
The native ABI is Linux's and there is one of it (see the primary goal). These are things to look into, not plans.
- [ ] A second syscall ABI in the kernel: each process carries an ABI tag and the dispatcher (`src/kernel/syscall.zig`) picks the table from it, with the numbers in a sibling of `src/abi/linux.zig`. The entry path (`src/arch/x86_64/syscall.zig`) is already independent of the ABI. FreeBSD's Linux emulation and WSL1 work this way.
- [ ] Windows programs: Windows's stable interface is its DLLs (`ntdll`, `kernel32`), not its syscall numbers, which change between builds. So this is a PE loader plus user-space implementations of those DLLs on top of the native ABI (what Wine does), not a syscall table. Not needed for .NET, which runs as a linux-musl build.

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
