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

## Order of work from here

Decided 2026-11-27, after milestone 8 and most of 6:

1. Finish 9.1.
2. Research: what MyOS could do better than Linux, given what it has and what is planned. The aim is not to build Linux again. Includes the ABI the .NET runtime needs, from its sources and documentation rather than from traces alone. Done: `design-beyond-linux.md`, with three decisions for the owner (views and rights before networking; completion inside the I/O core and a TCP of MyOS's own; a native copy-on-write filesystem, FAT32 for interchange only).
3. Finish 9.2, and the open task of 3.4 (CPU affinity and load balancing, which comes with per-CPU run queues).
4. Finish 9.3.
5. Before networking: per-process views and rights on descriptors (`design-beyond-linux.md`, decision 1), and per-object wait lists for `epoll` (decision 2). Tasks in 12.0.
6. Networking (12).
7. Persistent storage (11).
8. A second long research session before any work on graphics (10): whose programs run there (unmodified Linux programs through Wayland, MyOS's own, or both), what a terminal is (pseudo-terminals; foot, then Ghostty, as goals to weigh), and what drives the screen.

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
  - What the check cannot see is a task in 13 (Performance and observability).
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
  - This closes the leak where a second segment (or the user stack) mapped over an existing page replaced it without freeing the old page. `vmm.map` itself refuses to replace a mapping since 2.6.
- [x] Prevent mapping page zero and reserved user regions (`process.image_limits`).
  - [x] The last user page is never mapped (`vmm.USER_MAP_END`; see the `sysretq` item in 2.5).
  - The first 64 KiB are never mapped (`IMAGE_MIN`, the same as Linux's `mmap_min_addr`).
  - The 8 MiB below the top of the user stack are reserved for the stack (`STACK_RESERVE`, Linux's default stack limit; 16 KiB of it is mapped today), and a program may not be loaded there or above.
- [x] Cap segment sizes (`memsz`) so one ELF cannot ask for all physical memory.
  - The segments of one program may take 256 MiB together (`process.MAX_IMAGE_BYTES`), which is also the default memory limit of 2.6; making it follow the machine is a task in 6.4.
  - The loader refuses an image that needs more pages than are free, with some left over for page tables, before it allocates anything.
  - Memory that runs out while page tables are being allocated is an error since 2.6 (`vmm.allocTable`), not a panic.
- [x] Verify the entry point is inside an executable loaded segment (`error.BadEntry`).
- [x] Enforce readable/writable/executable permissions and avoid unintended writable-executable pages (a JIT later needs pages that go from writable to executable with `mprotect`, never both at once; see 9.3).
  - A segment that is both writable and executable is refused (`error.WritableExecutable`), and so is one with no permissions at all.
  - x86-64 pages are always readable, so write-only and execute-only segments are readable too.
- [x] Refuse dynamically linked executables (`PT_INTERP`) with `error.Unsupported` instead of starting them without their interpreter (until 9.3). Since 9.3 the interpreter is loaded.
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
  - Left for 6, on purpose: reading descriptor 0 (done with the terminal, 6.2) and descriptors that can be inherited or duplicated (duplicated: 6.2; inherited: the 6.2 task on inheritance rules and 6.4).
- [x] Return Linux's negative errno values from every syscall instead of the single `ERR` value; mirror them in `app/lib.zig` (shared, see above).
  - `read` and `write` return a short count when the buffer turns bad partway, as Linux does, instead of failing after a partial transfer.
- [x] Introduce the per-CPU structure reached through GS, with `swapgs` on every entry from and exit to ring 3, while there is still one CPU (moved from the SMP milestone, so the entry assembly is audited once, in its final shape).
  - `src/arch/x86_64/percpu.zig` holds the kernel stack for `syscall` and the scratch slot for the user's stack pointer, which were globals. Scheduler state moves there in 3.2.
  - NMIs, double faults, machine checks and debug exceptions can interrupt ring 0 code that has the user's GS base (the first instruction of `syscall_entry`, the last before `sysretq`/`iretq`), so they decide by the GS base MSR instead of the saved CS (`isr_paranoid` in `idt.zig`).
  - Debug exceptions also get their own emergency stack (IST 3): one at the first instruction of `syscall_entry` would otherwise run in ring 0 on the user's stack pointer (the "MOV SS" attack, CVE-2018-8897). Nothing can cause one there today, since programs cannot set debug registers and TF is masked on entry, but `ptrace` or hardware breakpoints would. Tested by raising the exception in ring 0 with the user's GS base loaded, and from ring 3 by single-stepping into a syscall (`/test/single_step`).
  - A breakpoint exception (`int3`) stays on the ordinary path: it can only come from an instruction in the kernel's own code, never from the entry assembly.
- [x] Enable SSE (CR0/CR4) and save and restore the extended CPU state per thread on context switch: XSAVE with the area sized from CPUID, AVX enabled where supported, FXSAVE as the fallback. Build user programs with SSE; the kernel stays soft-float.
  - `src/arch/x86_64/fpu.zig`. The state is switched eagerly, and only between user threads: the kernel never touches these registers, so syscalls, interrupts and kernel threads cost nothing. A user thread's save area is 832 bytes with AVX (512 with FXSAVE), allocated with the thread.
  - AVX-512 is enabled since 9.3, where the CPU has it; AMX stays disabled in XCR0.
  - The faster save instructions (XSAVEOPT, XSAVES/compacted format) are in the list of known slow paths in 9.2, to measure first.
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
  - At first the limit was checked once, at start; since 5 every page a process gets later is charged too.
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
  - At first no syscall could cause this (`myos_run` waited for its child); since `fork` (6.4) programs can, and orphans go to `init`.
  - Reparenting to an `init` process that collects orphans' exit statuses is the `init` task in 6.4, tested from ring 3 by the orphan task there.
- [x] Reap each exited thread/process exactly once (checked by assertions on the thread's queue and state, on tearing a process down, and on the reference count; the tests compare threads created with threads reaped).
- [x] Close open descriptors and free all resources on process exit and failed spawn. Files are now closed at exit instead of when the thread is reaped, which will matter once closing has effects others see (pipes). Failed spawns are covered by the 2.6 allocation-failure sweep.
- [x] Stress-test repeated spawn/exit, wait, wakeup, orphaning, and failure paths (`helpers.lifecycleStress`: 40 rounds of processes waited for at once, late and in reverse order, never waited for, killed by a fault, starting children, cut off by a limit, and failing to start; afterwards no process, thread, stack, page or heap byte is left).

### 2.8 Synchronization and timers
Pipes, blocking I/O, sleep and interrupt-driven drivers need these, and SMP (milestone 3) builds directly on them. The code is in `src/kernel/sync/` and `src/kernel/timer.zig`.
- [x] Add interrupt-aware spinlocks with interrupt-state restoration, as real atomic locks from the start (`sync/spinlock.zig` on the atomic `sync/raw_spinlock.zig`).
  - The atomic part is tested on the host with four real threads, the only place it can meet true parallelism before milestone 3.
  - A lock that stays held absurdly long (taken twice, or never released) is a panic rather than a silent hang.
  - The physical allocator, the heap and the kernel stack allocator used them first; the scheduler's queues, process bookkeeping and the page tables got theirs in 3.1. The one driver without a lock (NVMe) has a task in 11.2.
- [x] Add wait queues and replace the single-`waiter` pointers (keyboard, process wait) with them (`sync/wait_queue.zig`: any number of waiters, woken in arrival order, one or all, with an optional timeout).
  - Several programs can now wait for a key; each key goes to the one that has waited longest.
  - On one CPU the rule "check the condition and wait with interrupts off" is enough to never lose a wake-up. With several, the check and the wait must be under a lock the waker also takes (3.1).
- [x] Add mutexes for code that may block while holding a lock (`sync/mutex.zig`). `unlock` hands the mutex to the longest waiter, which owns it before it runs, so nobody starves. The first user is `/tmp` (6.1).
- [x] Add kernel timers: a timeout queue driven by the timer tick, for sleep, driver timeouts and later TCP (`timer.zig` with the ordering in `sync/timer_queue.zig`; `sleepTicks`, `sleepMs`, and `WaitQueue.waitTimeout`).
  - Resolution is one tick (10 ms). The queue is a sorted list: fine for a handful of timers, to be replaced by a heap or a timer wheel when there are many (12, TCP).
  - `nanosleep`, `clock_nanosleep`, `poll` and the futex timeouts use it.
- [x] Test several waiters on one queue, wake-before-block, timer ordering and expiry, and mutex hand-off under preemption.
  - Host: the timer queue against a model (100 000 random operations), the spinlock under contention.
  - In the kernel: spinlock interrupt state and nesting; wait queue order, rechecked conditions, wake-ups with nobody waiting, timeouts, and being woken and timing out on the same tick; timers firing on their exact tick, cancellation, sleep length against the HPET; a mutex whose holder is preempted, yields and sleeps; keyboard readers.

### 2.9 Further hardening
From the code review before 2.2. None of these fix a known hole; they shrink what a future bug can do.
- [x] Enable UMIP when CPU-supported, so ring 3 cannot read kernel table addresses with `sgdt`/`sidt` (`usercopy.init`; tested by `/test/umip`).
- [x] Add a kernel random-number generator: a CSPRNG seeded from RDSEED/RDRAND where present, plus timing jitter (`src/kernel/random.zig`; the deterministic part, ChaCha with fast key erasure, is `random_core.zig` and tested on the host). Address randomization draws from it; `AT_RANDOM` (4.1) and `getrandom` (6.4) will.
  - It is reseeded from the hardware source after every megabyte of output.
  - On a CPU with neither instruction the seed rests on timer jitter alone, which is weak; boot says so in the log. Mixing in interrupt timing is a task in 6.2.
- Stack protectors: moved to 13. The compiler cannot build them for the kernel yet (see there), so they are not part of this milestone.
- [x] Add a speculation barrier after the user range check in the user-copy path, and audit other user-controlled indexes (syscall number, file descriptor) for Spectre v1 (`src/arch/x86_64/nospec.zig`).
  - `user_copy` starts with `lfence`, so it cannot begin copying before the range check on the user address is decided.
  - File descriptors index the descriptor table through `nospec.index`, which clamps without a branch.
  - The syscall number is not an index: the dispatcher is a `switch` over scattered numbers, compiled to comparisons. Check again if it becomes a table.
  - The other Spectre variants (branch target injection and later ones) and their mitigations (retpolines, IBRS/IBPB, STIBP) are a task in 13.
- [x] Decide on kernel page-table isolation: detect CPUs that need it (Meltdown) and either implement it or refuse to run untrusted code on them. Decided: not implemented. The kernel checks the CPU at boot (`src/arch/x86_64/meltdown.zig`, rule tested on the host) and refuses to boot on an affected one, since any program could read all memory there; `-Dallow-meltdown` turns that into a warning. Processors made since about 2019, and all AMD ones, are not affected.
- [x] Randomize the kernel's load address and the user stack (KASLR/ASLR).
  - The kernel is a position-independent executable, and `kaslr: yes` in `limine.conf` has the bootloader load it at a random address in the top 2 GiB. Backtraces take the offset into account and print it. `MYOS_KASLR=no scripts/build.sh` turns it off for debuggers.
  - Each process's stack ends at a random page in a 16 GiB range, and its initial stack pointer is at a random 16-byte step within the last half page.
  - Done in 4.1: a position-independent program's own load address is random.
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
- [x] Move current-thread, scheduler, syscall-stack, and interrupt state to per-CPU storage: the running thread, its time slice, the halt count, the loaded address space and the count of CR3 loads are in `PerCpu`, next to the `syscall` stack pointer and the record of locks held. The running thread is read in one instruction (`%gs:24`), so preemptible code gets the right answer wherever it runs.
- [x] Initialize separate GDT/TSS, emergency (IST) stacks and guarded stacks for each CPU (`gdt.Tables`). A CPU that is started gets its four emergency stacks and its kernel stack from `kstack`, each with a guard page. The boot CPU's emergency stacks stay in `.bss`, unguarded: they are needed before there is memory management.
- [x] Add a speculation barrier (`lfence`) after the conditional `swapgs` in `isr_common` and `isr_paranoid`, where the two paths meet, so it covers both. Checked against Linux's entry code (`FENCE_SWAPGS_KERNEL_ENTRY` at the join in `error_entry` and `paranoid_entry`; nothing on the way out). Linux enables it only where SMAP does not hold during speculation or programs can set the GS base themselves; MyOS always has it.
- [x] Test per-CPU state and `swapgs` transitions (syscalls, interrupts from ring 0 and ring 3) with one and several CPUs: the existing entry and exit tests run in both the one-CPU and the four-CPU scenario, and the CPU test checks every CPU's structure, tables, stacks, GS base and timer interrupts (from ring 0).
  - Syscalls and interrupts from ring 3 on the other CPUs came with 3.4, when those CPUs began taking threads; the four-CPU runs cover them.

### 3.3 Bring up application processors
- [x] Request SMP information through Limine (the MP request; x2APIC is not asked for).
- [x] Start APs and initialize CPU-local structures (`arch/x86_64/smp.zig`): one at a time, each onto the kernel's page tables, its own GDT, TSS, GS base and kernel stack, as a thread of its own.
  - A started CPU handles its interrupts and halts in between; at first it did not take threads from the ready queue (`PerCpu.runs_threads`); that came with 3.4, once an address space must not be freed while another CPU has it loaded, and a kernel stack must not be unmapped while another CPU's TLB still maps it.
- [x] Apply the per-CPU control-register settings on every AP: SMEP, SMAP, UMIP, CR0.WP, the `syscall` MSRs and the extended-state setup from 2.5, and the Meltdown check. Each CPU reads back what it set, and the kernel panics if it differs from the boot CPU's.
- [x] Configure local APIC/timer and interrupts per CPU. Every CPU's timer runs at the rate measured on the boot CPU. Time is kept by the boot CPU alone: its tick advances the clock and runs the timers; the others' ticks drive only their own scheduling. Device interrupts all go to the boot CPU.
- [x] Print and test online CPU counts (`N of M CPUs online`; QEMU scenario `tests_smp` with four CPUs, next to the one-CPU runs, in CI).

### 3.4 SMP scheduling and memory
- [x] Let the started CPUs run threads: each takes threads from the ready queue as soon as it is up, and the context it started in retires.
  - A CPU can be parked (`thread.setParked`): it gives up its thread and halts in a thread of its own until it is unparked. The tests use it to have the machine to themselves.
- [x] Protect shared scheduler state (the scheduler lock from 3.1; what belongs to a CPU is in its `PerCpu`).
- [x] Choose per-CPU queues or a documented global-queue scheduling model: one ready queue under the scheduler lock (`docs/locking.md`). A ready thread is taken by whichever CPU is free. Per-CPU queues are for when measurements show the lock is contended.
- [x] Support cross-CPU wakeups and inter-processor interrupts (`arch/x86_64/ipi.zig`).
  - A CPU that halted with nothing to run is interrupted when another CPU makes a thread ready or wakes the thread it idles in.
  - Requests that every other CPU must carry out before the sender goes on (TLB flushes, letting go of an address space). They cannot deadlock against a CPU that has interrupts off: every loop that waits with interrupts off looks for a pending request and does it.
  - A CPU that reports a panic or a kernel fault halts the others first, with a non-maskable interrupt, so the report comes out whole (QEMU scenario `panic_smp`).
- [ ] Add CPU affinity/load balancing if needed. Not needed with one queue; comes back with per-CPU queues.
- [x] Synchronize PMM, heap, page tables, and drivers: each has its lock (3.1), and all are used from every CPU at once by the stress test below.
  - The NVMe driver, which polls and has no lock, is used by its test only; its lock is a task in 11.2.
- [x] Implement cross-CPU TLB shootdowns.
  - `vmm.unmap` clears the entries, has every CPU concerned flush, and only then frees page tables and hands back the page. A kernel stack is unmapped with one flush for all its pages (`vmm.unmapRange`).
  - An address space is taken away from every CPU that has it loaded before it is freed (`vmm.unloadRoot`).
  - A CPU whose thread has exited no longer sits on that thread's stack until something else is ready: it moves to a thread of its own, so the thread, its stack and its process are freed at once.
  - What the CI runners' CPUs (AMD Zen 4, under KVM) showed once preemption on wake-up came: a thread could move to another CPU between flushing its own TLB and asking the others, and the new CPU, skipped as the sender's, kept the old translation (fixed: one CPU throughout, also for `unloadRoot`); a CPU can fault on a kernel page another CPU has just mapped, from a translation looked up before (now retried after a local flush, as Linux's `spurious_kernel_fault` does); and, the cause of the failures, page tables that an unmap left empty were taken out of the tree and freed only after the flush, so a CPU could walk into one in between, keep the pointer, and read the page as a table once it had been handed out again. Now `unmap`, `unmapRange`, `unmapUserRange` and `map`'s roll-back take entries and tables out first, flush, and free last (`vmm.Gather`).
- [x] Decide the page allocator for several CPUs: per-CPU caches of free pages in front of the bitmap, or a lock-free design on bitmaps such as LLFree (`docs/research.md`), which also hands out 2 MiB frames cheaply (9.2).
  - Decided: per-CPU caches of free pages in front of the bitmap, as Linux's per-CPU page lists (`pmm.zig`). Each CPU keeps up to 64 pages under a lock of its own and moves 32 at a time to and from the bitmap; a third bitmap marks cached pages, so double frees are still caught. When the bitmap is empty the other CPUs' caches are emptied before an allocation fails. LLFree stays the candidate for when 2 MiB frames are needed (9.2): it is a change to the bitmap behind the caches, not to them.
- [x] Give the kernel heap size classes with a per-CPU cache of free objects, replacing the first-fit list under one lock (`docs/research.md`: magazines, snmalloc).
  - `heap.zig`: 14 size classes up to 2 KiB, cut from 32 KiB slabs aligned to their size; each CPU keeps up to 16 free blocks per class under a lock of its own and moves 8 at a time to and from the slabs. A slab whose blocks are all free goes back to the first-fit list, which stays for larger blocks. When memory runs out, every CPU's blocks are given back first. Each CPU's caches (pages and blocks) are made as it comes up. The stress test frees blocks of every class on other CPUs than they came from.
- [x] Preempt on wake-up, or otherwise bound how long a woken thread waits: with every CPU busy it goes to the tail of the queue and waits for a running thread's slice to end, up to 50 ms. Futex-heavy programs depend on it (7).
  - `thread.preemptForWoken`: when a woken thread finds no idle CPU, the CPU whose thread has used most of its slice switches at once (an interrupt, `ipi.PREEMPT_VECTOR`; on the waking CPU itself, at the next tick, which for a timer wake-up comes right after). A thread that has not run a full tick is left alone, so two threads waking each other cannot keep a third from running. Test: a thread sleeping while every CPU spins runs again within a tick of its timer (it took up to two before, and up to a slice with more threads).
- [x] Stress-test simultaneous allocations, processes, interrupts, and I/O. Three tests run with every CPU taking threads:
  - programs: six threads each run seven programs (extended state, long syscalls, a crash, fresh memory), so processes start, are preempted, move between CPUs, die and are torn down everywhere at once, and memory is back afterwards;
  - the kernel: eight threads use the page allocator, the heap, kernel stacks, a spinlock, a mutex and a wait queue with timeouts that run out as the wake-up comes (the timer fires on the boot CPU, the waker runs anywhere);
  - the TLB: threads on every CPU read a kernel page until it is in their TLBs, then it is unmapped and replaced, and nobody may see the old page.
  - I/O, of which there is none to do in parallel yet, has a stress task in 11.1.
- [x] Run the QEMU test scenarios with several CPUs (`-smp 4`) in CI from here on, next to the single-CPU run: `tests_smp` runs the whole suite on four CPUs, and `panic_smp` a crash.
  - All but seven of the in-kernel tests run with every CPU taking threads; the seven say why they cannot (`docs/testing.md`).
  - Getting there showed two things the kernel had wrong on several CPUs. A process's memory was freed only when its thread was, after its waiters had been woken, so a parent could find its last child's memory still taken: `process.exit` frees the address space first now. And two keyboard readers woken for two keys could take them in the wrong order: readers are served by number now.
- [x] Add a test run under KVM where the machine supports it: QEMU's emulation hides races and timing bugs that real parallel execution shows.
  - `scripts/test-qemu.sh` has it as scenario `tests_kvm` (four CPUs, the host's own CPU), skipped where `/dev/kvm` cannot be used or the kernel refuses the host CPU. It passes on the development machine (AMD Zen 5), also run a hundred times over.
  - The four tests that failed under KVM at first were the tests' fault: one wrote a reserved bit of the x87 control word as 0, which a real CPU reads back as 1 (three tests used that program); one needed timer interrupts to land inside syscalls and gave up after a fixed number of runs, which a fast CPU finishes between two ticks.
  - CI runs it: the hosted runners have `/dev/kvm`, and a udev rule opens it to the runner's user. It runs on whatever CPU the runner has; one the kernel refuses (Meltdown) is skipped, not failed.
- [x] Measure what the emergency stacks really use, now that every CPU has four, and size them by that. Measured builds record the deepest use (`gdt.istPeak`); the test run prints it and fails past three quarters, and every crash report says how much it took. The most seen: 4.4 KiB for a double-fault report in a Debug build, 2.8 KiB optimized, 3.5 KiB for a debug trap that ends a process. They are 8 KiB now, down from 16, each with its own guard on the CPUs started after boot.
  - [x] Linux has 4 KiB. To get there: do as Linux does and move to the thread's own stack before doing any work when the trap came from a program, and make the crash report's frames smaller (the 512-byte print buffer and the formatting under it are most of a Debug report). Done: a trap from ring 3 moves its frame to the thread's kernel stack first thing (`isr_paranoid`), a crash report moves to one crash stack (`main.onCrashStack`; only the CPU that stopped the others reports), and `print` formats through a 96-byte buffer instead of 512. The stacks are 4 KiB; the most seen is 1.4 KiB, for a double fault in a Debug build.

**Milestone 3 done when:** Multiple cores safely execute user threads and syscalls concurrently, and CI runs the test suite on several CPUs.

---

## 4. First foreign program

**Goal:** Run an unmodified, statically linked musl C program built on Linux.

This is the smallest end-to-end slice of Linux compatibility. It comes early on purpose: from here on, new kernel features are checked against real foreign binaries instead of only against MyOS's own programs.

### 4.1 Process startup
- [x] Build the initial user stack the way Linux does (`startup_stack.zig`, tested on the host by reading the block back the way a C library does): `argc`, `argv`, `envp`, then the auxiliary vector (`AT_PHDR`, `AT_PHNUM`, `AT_PHENT`, `AT_ENTRY`, `AT_BASE`, `AT_PAGESZ`, `AT_RANDOM`, ...). `AT_RANDOM` needs the random-number generator from 2.9.
- [x] Pass arguments and environment to spawned programs (`process.SpawnOptions`, and from user space at first `myos_run(path, argv, envp)`, `execve` since 6.4; at most 8 KiB and 256 strings together, `E2BIG` beyond).
- [x] Update the Zig user startup code to read arguments/environment: programs are entered as Linux programs are (`rsp` at `argc`, on a 16-byte boundary), `app/lib.zig` has the `_start` that calls `main`, and `lib.argv`, `lib.environ` and `lib.auxValue`.
- [x] Parse command lines with arguments and basic quoting (at first `app/cmdline.zig`, since 6.3 the shell's own `app/sh_words.zig`, tested on the host; the shell passes the arguments and its own environment).
- [x] Load position-independent executables (`ET_DYN`) at a chosen load bias: `elf_image.parse` accepts them and says what they span, `process.spawn` picks the base (`PIE_BASE`, where Linux starts too, plus a random page within 1 TiB unless the layout is fixed) and `elf.loadAt` adds it. Relocating is the program's own business.
- [x] Choose that load bias at random for each process (moved from 2.9, which randomized the stack and the kernel), with `process.SpawnOptions.randomize` turning it off as it does for the stack. Fixed-address executables (`ET_EXEC`) cannot be moved. Test that two runs of a PIE get different bases. Tested: four runs, four bases, one base with the layout fixed.
- [x] Give each thread its own FS base: `arch_prctl(ARCH_SET_FS)`, saved and restored on context switch; enable FSGSBASE when the CPU has it.
  - `arch_prctl` with all four codes, FS and GS base per thread, loaded when the thread gets a CPU, and refused outside user space. FSGSBASE is on where the CPU has it, and `AT_HWCAP2` says so: a program's own `wrfsbase`/`wrgsbase` are read back when its thread is switched away from, by `arch_prctl(ARCH_GET_*)` and by `clone`.
  - `isr_paranoid` no longer guesses from the GS base whose it is: from ring 0 it saves it, loads this CPU's own (kept at the top of each of the CPU's emergency stacks) and restores the saved one on exit, as Linux does; from ring 3 it moves to the thread's stack (3.4). Tests: `/test/fsgsbase` (the bases through switches, `arch_prctl` on top, a kernel-looking GS base and a single step into `syscall`, which the CPU delivers in ring 3), and the kernel's debug-trap test, which raises the exception in ring 0 with a kernel-looking user GS base.
  - `arch_prctl(ARCH_SET_GS)` and `ARCH_SET_FS` must refuse addresses outside user space.
  - The kernel does not set up the TLS block from `PT_TLS`: on Linux the C library does that itself, from the program headers it finds through `AT_PHDR`.
- [x] Extend the syscall ABI document from 2.5 with the startup stack, the auxiliary vector and TLS.
- [x] Test empty, long, invalid, and multi-argument commands, and check the stack layout from ring 3: the command-line splitter on the host (`tests/host/cmdline_test.zig`), the stack from ring 3 with an argument that has a space and one that is empty (`/test/linux_abi`), and argument lists too long or too many, which are refused with nothing started.

### 4.2 Minimal syscall set
- [x] Return `-ENOSYS` for unknown syscalls and add a syscall trace option that logs them, to see what a program still needs: `syscall.trace_unknown`, which the tests turn on around the fixtures; the test script fails if a fixture made a call the kernel does not know. `syscall.trace_all` logs every call with its arguments and its result, for finding where a program is stuck.
- [x] Record what the target programs really ask for (musl C, Rust and Go are in `docs/linux-programs.md`; the .NET program and the Loupe runs are open): run the fixture binaries (musl hello, a Go hello, the .NET Native AOT hello and a GC workload) under `strace -f` on Linux and keep the list of syscalls and files in `docs/`. Use it to order the work in milestones 5 to 9.
  - Run them under Loupe as well (`docs/research.md`): it finds which of those calls must really work, which may return `ENOSYS` and which may pretend to succeed. That, not the bare list, is the work order.
  - Done: `docs/linux-programs.md` has the calls by program and, measured with `tools/syscall-survey/survey.sh` (Loupe's method with `strace`'s fault injection, no container needed), which of them must work for each of the seven fixture kinds, from static musl to the .NET JIT runtime. Every call marked needed is implemented.
- [x] Add the calls a static musl hello-world makes: `writev`, `exit_group`, `set_tid_address`, `brk`, a minimal anonymous `mmap` (milestone 5 replaces it), and `ioctl` answering `-ENOTTY`.
  - Done: `writev`, `exit_group`, `set_tid_address`, `ioctl` and `arch_prctl`, which is all the hello-world calls, and `brk` and `mmap` with milestone 5.
- [x] Add the calls a static Rust program makes before `main` on top of those: `poll` (it checks that its standard streams are open), and `rt_sigaction`, `rt_sigprocmask` and `sigaltstack`, which record what is set and return it; nothing is delivered until milestone 8. A Rust hello-world with its standard library, linked statically against musl, runs (`tests/fixtures/src/hello.rs`).

### 4.3 Fixtures
- [x] Keep prebuilt fixture binaries (with the commands that built them) and run them as QEMU tests, checking their output: `tests/fixtures/` (`build.sh` has the commands), packaged as `/fixtures/` in the test image and `/bin/` in the normal one.
- [x] Run a static and a static-PIE musl hello-world built on Linux, with arguments and environment.
  - Both run, on one and on four CPUs: they print their arguments and environment through musl's `printf` and exit with their argument count. So does the Rust program as a static PIE, which is what `rustc` builds for musl unless told otherwise.
- [x] Test malformed `ET_DYN` images and an unknown syscall number from ring 3: host tests for the parser (span longer than the address space, bases that do not fit, overflow, the usual rules in the image's own terms; the fuzz test covers both kinds), `/test/syscalls` for unknown numbers.

**Milestone 4 done when:** An unmodified static musl hello-world built on Linux prints its arguments on MyOS, as a CI test on several CPUs.

---

## 5. User memory

**Goal:** Give processes the virtual memory model runtimes expect: reserve large ranges, commit them piece by piece, change permissions, and fail safely when memory runs out.

Designed once, demand-paged from the start, instead of an eager `mmap` first and demand paging later.

- [x] Before designing the next item, read the two opposite answers to it in `docs/research.md` and write down which way MyOS goes and why: page tables as the only record, with metadata per page (CortenMM), or a region structure built for concurrency (the interval skiplist). Many threads of one process fault and change mappings at once under a garbage collector, so the choice decides how 7 and 9.2 scale.
  - Decided: a list of regions per process next to the page tables, under one lock per address space (`vm_regions.zig`, `user_memory.zig`). The regions say what a fault means without reading page tables, and reserving a gigabyte costs one entry. One lock is right while a process has one thread; it is the thing to revisit when many threads of one process fault at once (7), and the two designs in the research notes are the candidates then.
- [x] Define user virtual-memory regions: a per-process set of regions with their permissions and backing, which the page-fault handler consults. Tested on the host against a page-by-page model.
- [x] Add demand paging and overcommit for anonymous memory: garbage collectors reserve huge virtual ranges and commit them piece by piece.
- [x] Implement `mmap`: anonymous mappings, `MAP_FIXED`, `MAP_NORESERVE`, `PROT_NONE` reservations, and private file-backed mappings (needed by the dynamic loader in 9.3).
  - Done: anonymous mappings, `MAP_FIXED`, `MAP_FIXED_NOREPLACE`, hints, `MAP_NORESERVE`, `PROT_NONE` reservations; `mremap` that shrinks and grows in place. Private file-backed mappings since 9.3. Moving a mapping with `mremap`: the next item.
- [x] `mremap` that moves a mapping (`MREMAP_MAYMOVE`, and `MREMAP_FIXED`): `user_memory.mremap`. The page-table entries move (`vmm.moveUserPage`), the charge (2.6) stays as it was apart from page tables, and running out of memory halfway puts back what had moved. A file's mapping grows and moves too, going on in the file. Tested from ring 3 (`/test/vm`): growing a mapping that has something right after it, the middle of a mapping to a chosen address, the old place free afterwards.
- [x] Implement `mprotect`, `munmap` of partial ranges, `madvise(MADV_DONTNEED)` and `brk`, with resource reclamation.
- [x] Charge every page a process gets after it has started against its memory limit (`process.Limits.max_pages`, 2.6): pages given on demand to `mmap`, `brk` and stack growth, and the page tables they need; give the charge back on `munmap`. Today the limit is only checked when the program is loaded, because nothing else can allocate. A request over the limit fails with `ENOMEM`; a page fault over it follows the out-of-memory policy below. Test that the charge always equals what left the allocator, as the 2.6 test does at start.
- [x] Give processes a large, guarded user stack that grows on demand (the fixed 16 KiB stack is far too small for runtimes). The stack's region is 8 MiB, Linux's default limit; below it 1 MiB is kept free of mappings.
- [x] Shoot down TLB entries on the other CPUs on `munmap` and `mprotect` (3.4).
- [x] Define the out-of-memory policy: when a page fault cannot be given a page, the process is killed and the kernel carries on; tie it to the per-process limits of 2.6.
- [x] Add a small userspace allocator for the Zig programs on top of `mmap`: `lib.allocator`, a `std.mem.Allocator` (`app/alloc.zig`). Blocks of up to 2048 bytes come in powers of two from free lists filled 64 KiB at a time; larger ones get pages of their own and give them back. For one thread. Host tests with random allocation and freeing; `/test/alloc` runs the standard library's list and hash map on it.
- [x] Test reserve-then-commit of a multi-gigabyte range, permission changes, partial unmaps, faults on `PROT_NONE` pages, stack growth up to its limit, the out-of-memory kill, and page faults on several CPUs at once in one address space (once threads exist, 7).
  - Done (`/test/vm`, alone and two at once): reserve 4 GiB and commit 1 MiB of it, permission changes that keep the data, partial unmaps, the kills for touching `PROT_NONE`, read-only and unmapped pages and for a stack past its limit, the kill at the memory limit, and system calls reading into memory nothing has touched. Faults on several CPUs in one address space: `/test/threads` has four threads go through the same untouched memory from both ends.

**Milestone 5 done when:** A program can reserve a multi-gigabyte range and commit it piece by piece, and a program that exhausts memory is the only casualty.

---

## 6. Files, descriptors, and shell

**Goal:** Run practical programs with files, pipes, a terminal and predictable process behavior.

Every syscall added here takes Linux's number, signature and struct layout (`stat`, `timespec`, `iovec`, `dirent64`, `pollfd`, ...) from the start.

### 6.1 VFS and directories
- [x] Distinguish regular files from directories in VFS nodes. Done by path, not by node: a filesystem says whether a path is a directory (`Fs.is_dir`) and lists it (`Fs.next`); a `Node` stays a file. The image's filesystem has no directory records to hand out, and nothing needed one.
- [x] Add directory lookup and `readdir` operations (`getdents64`). `vfs.next` with a cookie the filesystem defines; `getdents64` on a directory descriptor, with "." and ".." and the entries of `/proc` and `/dev`.
- [x] Add `stat`-like metadata queries (`fstat`/`newfstatat`). Done with 9.3: `fstat`, `newfstatat`, `stat`, `lstat`, for files, directories, pipes, the console and the entries of `/proc` and `/dev`.
- [x] Normalize paths and handle `.` and `..`. `vfs.normalize`, before anything is looked up; every path call goes through it (`Path.from` in `syscall.zig`).
- [x] Raise the longest path from 255 bytes to Linux's 4095 (`PATH_MAX` 4096). Paths are copied to a buffer on the 16 KiB kernel stack today (2.5), which is why the limit is low; the buffer has to move to the heap first. Relative paths and a current directory belong here too. Paths are copied to heap memory now (two buffers of 4096 bytes for each path call: what the program gave, and what it comes to).
- [x] Add mount-point traversal so multiple filesystems can coexist. `vfs.mount`: a path goes to the filesystem mounted at its longest matching prefix; mount points and the way to them show up in listings. Tested on the host with three filesystems; the kernel mounts only the root until the next item.
- [x] Add create/write/truncate/unlink/mkdir operations to the VFS interface. `vfs.create`, `write`, `truncate`, `unlink`, `mkdir`, `rmdir`, `rename`; files that can go away while in use are counted (`retain`, `release`).
- [x] Add a small in-memory filesystem (ramfs) mounted at `/tmp`, so redirection (6.3) has somewhere to write and the write API is proven before FAT32 (11.5). `fs/ramfs.zig` (no kernel dependencies: a table of entries by path, file contents in 4 KiB blocks that exist only where written) and `fs/tmpfs.zig` (pages for the blocks, one mutex around it: the first user of `sync/mutex.zig`). `open` with `O_CREAT`, `O_EXCL`, `O_TRUNC`, `O_APPEND`; `write`, `pwrite64`, `ftruncate`, `truncate`, `unlink`, `mkdir`, `rmdir`, `rename` and their `...at` forms.
- [x] Define consistent VFS error codes that map onto the syscall error codes (2.5). `vfs.Error`, each with its Linux number in `syscall.vfsError`.
- [x] Test directory lookup, `readdir`, `stat`, `.`/`..` normalization, mount traversal and error codes (host tests with fake filesystems, plus initrd tests in QEMU).
  - Done: host tests with fake filesystems for normalization, mounts, shadowing and listings (`tests/host/vfs_test.zig`); from ring 3 listings of the root, `/etc`, `/dev` and `/proc/self`, small buffers, rewinding, relative paths from a descriptor and from the working directory, a child inheriting it, long paths (`/test/files`). With `/tmp` mounted, mount traversal is tested from ring 3 as well (`/test/tmp`): renames between the two filesystems are refused, the mount point cannot be removed.
- [x] Test ramfs create, write, read-back, truncate, unlink and out-of-memory on the host and from ring 3. Host tests with the testing allocator (leaks are failures) and with every allocation refused in turn; `/test/tmp` from ring 3, two processes at once, ending with nothing left in the filesystem.
- [x] Run the tarfs parser in host tests and fuzz it with malformed archives.
  - The archive format is `fs/tar.zig`, with host tests for walking headers, truncated archives, names stored in two parts and listings, and a fuzz test: three thousand damaged archives, walked and listed, must end and stay inside the archive.

### 6.2 Descriptors and I/O
- [x] Reserve FDs 0/1/2 for stdin/stdout/stderr: a process starts with the three open on the console, as one open file with three descriptors (`open_file.zig`). They are closed, duplicated and replaced like any other.
  - [x] The numbers are reserved since 2.5: `open` returns descriptors from 3 up, and `write` to 1 and 2 reaches the console.
  - [x] They were not real descriptors at first (they could not be closed, redirected or inherited, and `write` handled them as a special case). They are now; inheriting them by new programs is the inheritance task below.
- [x] Make `read` on descriptor 0 return keyboard input and remove the private `myos_getchar` syscall (`0x4D5900`). Today `read(0, ...)` returns `EBADF` and the shell reads keys with `myos_getchar`. Do it together with the terminal layer below, so blocking, line editing, echo and end of file are designed once; move `app/sh.zig` to `read` and update `docs/syscalls.md`. Done: the shell reads its lines with `read(0)`; `lib.readKey` waits for one key with line editing off.
- [x] Route console I/O through descriptor-backed devices. The console is one open file behind descriptors 0, 1 and 2; reading it goes through the terminal (`tty.zig`).
- [x] Add serial input (receive interrupt) as a second console input source; the scripted shell tests in 6.3 depend on it. IRQ 4 into the terminal, like a typed key.
- [x] Add a terminal layer between the input drivers and FD 0: line editing, echo, backspace, and Ctrl+C/Ctrl+D handling. Keep it small; anything richer belongs in user space. `tty_core.zig` (the line discipline alone, host-tested, also against a model of random typing) and `tty.zig` (the lock, the readers in the order they asked, echo to the console, Ctrl+C ending the foreground program). `termios` through `ioctl`, and the size of the window.
- [x] Support generic open/read/write/close plus `seek` where applicable (`openat`, `lseek`). Done: `open`, `openat`, `read`, `pread64`, `write`, `writev`, `close`, `lseek`, over files, pipes, the console and devices.
- [x] Define file-offset, ownership, and descriptor inheritance rules. Written at the top of `open_file.zig`: the open file holds the offset and the status flags and is shared by every descriptor on it (`dup`, `fork`, `execve`); the descriptor holds `FD_CLOEXEC`. The reference count, the offset and `O_NONBLOCK` are changed atomically, since processes that share an open file have locks of their own. Tested from ring 3: a child's reads move its parent's offset (`/test/fork`).
- [x] Add descriptor duplication and pipes (`dup`/`dup2`/`dup3`, `fcntl(F_DUPFD)`, `pipe`/`pipe2`): `pipe.zig`, a page of buffer, readers and writers that wait and are woken, end of file and `EPIPE` when the other end is closed, `O_NONBLOCK`. Tested from ring 3 (`/test/pipes`), with a thread on each end and with a process that ends while a thread sleeps in a pipe.
  - `SIGPIPE` since 8. Inheriting descriptors: the task on inheritance rules above.
- [x] Add `poll` to wait on several descriptors at once (needed by network servers in 12.3 and the compositor in 10.3).
  - `poll` reports the console, files, pipes and eventfds and waits with a timeout. Pipes, the terminal and eventfds wake it when they change (`readiness.zig`).
- [x] Add the file syscalls runtimes expect: `fcntl`, a terminal subset of `ioctl`, `readlink`, `readv`, `pread`/`pwrite`.
  - `fcntl` (`F_DUPFD`, `F_GETFL`, `F_SETFL`, `F_GETFD`), `readlink`, `pread64`, `ioctl` answering `ENOTTY` for what is not a terminal. `readv` and `pwrite64` since `/tmp`. The terminal's `ioctl`s came with the terminal: `TCGETS`, `TCSETS*`, `TIOCGWINSZ`, `FIONREAD` (`docs/syscalls.md`).
- [x] Add `epoll` and `eventfd` on top of `poll`: `epoll.zig`; Go's timers sit on them. Woken by the objects it watches, with `EPOLLET` edge-triggered (task below).
- [x] Let descriptors wake their waiters (pipes, the terminal, eventfds, and sockets later): `poll` and `epoll_wait` then sleep until something happens instead of looking again every tick (10 ms of delay at worst today), and `EPOLLET` can be edge-triggered as on Linux (it is reported as level-triggered now). Watch the open file, not the descriptor number, as Linux does. Network servers (12.3) need this.
  - `readiness.zig`: one change count and one queue of pollers; a pipe, the terminal and an eventfd move it on when their state changes, and `poll`/`epoll_wait` sleep until it moves or the deadline passes. Each object also counts its own changes, which `EPOLLET` compares with the count when the file was last reported. `epoll_ctl` records the open file, and the watch ends when the number no longer stands for it. Tested in `/test/epoll`.
- [x] Mix the timing of interrupts (keys, the serial line, later disks and the network) into the random generator (`random.addEntropy` exists for it, 2.9). On a CPU without RDSEED and RDRAND the seed rests on timer jitter alone today.
  - Every hardware interrupt folds the TSC, its vector and the address it interrupted into a few words of its CPU's own state (`random.interruptTiming`, no lock); after 64 of them the CPU mixes them into the generator the next time it draws, as Linux's per-CPU fast pool does. Not counted as the hardware reseed. Tested in the kernel's random-number checks.
- [x] Provide the pseudo-files programs open at startup: `/dev/null`, `/dev/urandom`, `/proc/self/exe`, `/proc/self/maps`, `/proc/cpuinfo` or their minimal equivalents (the list from 4.2 says which).
  - `/dev/null`, `/dev/urandom`, `/proc/self/exe` and `/proc/self/maps` were there already; added `/proc/cpuinfo` (`cpuinfo.zig`: Linux's format and flag names, from `cpuid`; tested on the host) and `/sys/devices/system/cpu/online`, `possible` and `present`, which runtimes count CPUs by. Tested from ring 3 in `/test/files`. The control-group and mount files .NET and Go look for belong to 9.1.
  - Done: `/dev/null`, `/dev/urandom`, `/dev/random`, `/proc/self/exe`, `/proc/self/maps`, `/proc/self/stat`, `/proc/meminfo` (`procfs.zig`: text made when the file is opened). Open: `/proc/cpuinfo`, `/proc/stat`, `/proc/self/mountinfo` and `cgroup`, `/sys/devices/system/cpu/*`, which the .NET runtime looks for and does without.
- [x] Test EOF, partial I/O, invalid descriptors, and cleanup. Done: `/test/syscalls`, `/test/pipes` and `/test/files` from ring 3, with the kernel test checking that nothing stays allocated.
- [x] Test terminal line editing and `poll` (ready, blocking, and timeout cases) with input injected over serial.
  - Done for the terminal from ring 3 with keys put in from the kernel test (`/test/terminal`: editing, two lines at once, short reads, Ctrl+D, `FIONREAD`, `poll`, raw mode, non-blocking, Ctrl+C ending the foreground program and only that). Over the real serial line since 6.3: the `shell` scenario types a session, with backspace, Ctrl+U, Ctrl+C and Ctrl+D. `poll` and `epoll` waiting, ready and timing out: `/test/terminal` and `/test/epoll`.

### 6.3 Commands and shell features
- [x] Implement `echo`, `cat`, `ls`, `pwd`, `cd`, and `clear`. `app/bin/`: `echo`, `cat`, `ls` (`-a`, `-l`, `-F`), `pwd`, `clear` (the console understands the escape sequences it writes: `ansi_core.zig`, host-tested), with `cd`, `pwd`, `export`, `unset` and `exit` built into the shell; also `env`, `kill`, `ps`, `sleep`, `true`, `false`.
- [x] Support absolute and relative paths and working directories. Every command takes both; the shell starts in `/root` (its `HOME`), `cd` with no argument goes there, and children start where the shell is.
- [x] Display meaningful command errors and exit statuses. Messages worded as Linux tools word them (`sh: x: command not found`, `ls: cannot access ...: No such file or directory`); a program a signal ended is named with the signal; `$?`, and the prompt shows a status other than 0.
- [x] Implement basic input/output redirection once descriptors are ready. `<`, `>`, `>>`, `2>`, `2>>`, `2>&1`, for programs and built-ins.
- [x] Implement pipelines once pipes are available. Any number of stages, each a process in the pipeline's process group, which gets the terminal while it runs; and `;`, `&&`, `||`.
- [x] Add `mkdir` and removal commands after writable filesystems exist. `mkdir` (`-p`), `rmdir`, `rm` (`-r`, `-f`), in `/tmp`.
- [x] Build MyOS's own Zig programs for Zig's `x86_64-linux` target and use the standard library (`std.fs`, allocators, later `std.Thread`) instead of the hand-written wrappers in `app/lib.zig`, once the kernel implements the syscalls the standard library's startup and I/O paths make (the syscall trace from 4.2 shows what is missing). Until then `app/lib.zig` keeps its own wrappers, on Linux's numbers. `init`, the shell and the commands (`app/bin/`): Linux programs built with the standard library, which needed `statx`, `preadv` and `pwritev` from the kernel. They call the kernel by number through `std.os.linux` (`app/util.zig`) rather than the standard library's file API, whose shape changes between Zig versions. Built optimized and stripped even in Debug builds: a Debug build of one is 11 MB. `app/lib.zig` stays for `/bin/hello` and the test programs.
- [x] Build a few small C utilities with a stock Linux musl toolchain and run them (this replaces the libc port of the former milestone 7). `wc` and `head` (`app/c/`), statically linked against musl by the build, in `/usr/bin` and in pipelines with the Zig programs.
- [x] Test commands, paths, redirection and pipelines with scripted shell sessions in QEMU (input via serial, output checked in the log). Scenario `shell` (`scripts/test-qemu.sh`, `tests/shell/session.txt`): `init` and the shell as a user boots them, a session typed over the serial line and its output checked.

### 6.4 Process control and time
- [x] Decide how programs are started, and replace the private `run` syscall: either `clone(CLONE_VM|CLONE_VFORK)` plus `execve` (what musl's `posix_spawn` uses; no `fork` or copy-on-write needed), or one private spawn syscall kept outside Linux's numbers. Decided: both, as on Linux. `fork` copies the address space (eagerly for now; copy-on-write is in 13), `vfork` and `CLONE_VM` get a copy too, and `execve` replaces the program. `myos_run` is gone; `app/lib.zig`'s `run` is `fork`, `execve` and `wait4`, with a close-on-exec pipe for the error, as `posix_spawn` does it.
- [x] Assign stable PIDs and track parent-child relationships. A process's ID is its first thread's, and stays until it is collected; `getppid`; every process can be found by its ID (`kill`).
- [x] Define generalized process waiting and exit-code handling (`wait4`). `fork`, `vfork`, `clone` and `clone3` make processes (memory copied eagerly; copy-on-write is in 13); an ended child is a zombie in its parent's list until `wait4` collects it, with Linux's status encoding, the signal that ended it included; orphans go to `init` when there is one. Tested from ring 3 (`/test/fork`).
- [x] Support Ctrl+C termination of foreground jobs. A program the shell runs is the foreground while the shell waits for it (`process.giveForeground`: only from whoever has the terminal, or from nobody); Ctrl+C ends it with status 130 through `process.terminate`, which any thread can now ask of a process.
- [x] Job control: process groups and sessions (`setpgid`, `getpgid`, `setsid`, a terminal foreground group with `TIOCSPGRP`), and `SIGSTOP`, `SIGTSTP`, `SIGTTIN`, `SIGTTOU` stopping a process and `SIGCONT` continuing it (Ctrl+Z, `fg`, `bg`).
  - Done: process groups and sessions, inherited across `fork`; `setpgid`, `getpgid`, `getpgrp`, `setsid`, `getsid`; the terminal's foreground group (`TIOCSPGRP`), which Ctrl+C sends `SIGINT` to; `kill` and `wait4` by group. Tested from ring 3 (`/test/fork`).
  - Stopping and continuing: the stop signals stop the whole process when delivered (`proc.stopLocked`), its threads waiting on their way back to the program; `SIGCONT` continues it as it is sent. `wait4` with `WUNTRACED` and `WCONTINUED`, `SIGCHLD` (and `SA_NOCLDSTOP`), `T` in `/proc/<pid>/stat`. The terminal: Ctrl+Z and Ctrl+\\ send `SIGTSTP` and `SIGQUIT`; reading it from the background sends `SIGTTIN` (`EIO` if ignored), setting its group from the background `SIGTTOU`. The shell: Ctrl+Z makes a job, `jobs`, `fg`, `bg`. Tested from ring 3 (`/test/jobs`), the line discipline on the host, and the `shell` scenario.
- [x] Background jobs started with `&` in the shell, and stop signals thrown away for an orphaned process group as Linux does (`SIGTSTP`, `SIGTTIN`, `SIGTTOU` to a group no process outside it but in its session is a parent of).
  - `&` (`sh_words.zig`'s `background`): the shell prints the job and its group and goes on; before each prompt it says which jobs have ended or stopped. The kernel throws away the terminal's stop signals for an orphaned group, fails a background read with `EIO` there, and sends `SIGHUP` and `SIGCONT` to a group left orphaned with a stopped process in it (`proc.wakeOrphanedLocked`). Tested in `/test/jobs` and the `shell` scenario.
- [x] Signals between processes: `kill` to another process (and `-1`, everyone), `SIGCHLD` (or the signal `clone` names) to a parent when a child ends. Sending to a process group (`-pgid`) is part of the job-control task above; permission rules wait for users (13).
- [x] Add monotonic timekeeping and a sleep syscall (`clock_gettime`, `nanosleep`), on a calibrated TSC clock where the TSC is invariant and HPET otherwise: runtimes read the clock constantly. `nanosleep` sits on the kernel timers of 2.8, whose resolution is one tick (10 ms): decide whether that is enough or sleeps need a one-shot timer. `clock.zig`: the TSC where it is invariant, calibrated against the HPET over 50 ms and read in order (`lfence; rdtsc`, as Linux's `rdtsc_ordered`: a plain one let threads see time go back), checked against the boot CPU's on every CPU that comes up, the HPET otherwise. Decided for sleeps: timer ticks for whole ticks, so a sleep ends at most a tick late, and under 2 ms left the CPU is given to others until the deadline, so a sleep of 500 µs takes about that; a one-shot timer (or no fixed tick at all) is the later step if programs need better.
- [x] Read wall-clock time from the RTC and expose it to userspace (FAT32 timestamps in 11.5 need it). `drivers/rtc.zig` and `calendar.zig` (BCD or binary, 12- or 24-hour, the century register; tested on the host): the wall clock is the RTC's date at boot plus the monotonic time since, for `clock_gettime(CLOCK_REALTIME)`, `gettimeofday` and `time`.
- [x] Add `getrandom`, `uname`, `getpid`/`gettid`, `sched_getaffinity`, `sched_yield`, `prlimit`/`getrlimit`.
  - All of those exist, with `getrlimit` and `setrlimit` beside `prlimit64`.
  - `prlimit64` reads and lowers the limits of 2.6, each with a value and a ceiling as Linux's soft and hard limits (`proc.Limits`): `RLIMIT_DATA` for memory (decided: not `RLIMIT_AS`, which programs take to be about address space, and a runtime that reserves much would read as a limit on that), `RLIMIT_NOFILE` for descriptors, `RLIMIT_NPROC` for descendants (decided: presented as `RLIMIT_NPROC` though Linux counts per user, since MyOS has no users). The others are kept and reported as set, not enforced. A process may set a limit up to its ceiling and lower the ceiling, never raise it.
  - The default memory limit follows the machine: three quarters of physical memory for a process nothing else started (`Limits.default`), instead of a fixed 256 MiB.
  - Tested from ring 3 in `/test/fork` (inherited, lowered, the ceiling, the memory limit's kill).
- [x] Start an `init` process that launches the shell, restarts it when it exits, and adopts orphans (2.7). `app/bin/init.zig`, `/sbin/init`; the kernel marks it the process orphans go to (`process.setInit`).
- [x] Implement a basic `ps` command. From `/proc`, which now has a directory for every process (`stat`, `cmdline`, `comm`).
- [x] Test PID and parent tracking, waiting on exited children, sleep accuracy, Ctrl+C termination, wall-clock time, and the shell being restarted after `exit`. `/test/fork` (IDs, parents, `wait4`), `/test/clock` (sleeps; the wall clock, which the script compares with the host's), the kernel's clock checks (against the HPET, in step on every CPU), and the `shell` scenario (Ctrl+C, the shell started again after `exit`). The KVM scenario passes the host's invariant TSC, so the TSC path runs on real CPUs.
- [x] Test from ring 3 that a parent can exit before its child and the child is adopted. 2.7 handles this in the kernel, but no syscall could cause it then, so it is only tested from inside the kernel. `/test/fork`: a child ends before its own child, which goes to the grandparent and is collected there (in a system with `init`, to `init`).
- [x] Test each syscall from ring 3 against Linux's documented results and error codes, including the struct layouts.
  - `/test/errors`: a table of every implemented call with arguments whose result Linux's manual pages document (184 rows: a bad descriptor, a bad address, an unknown flag, a missing file, or the value of a call that works), and `pause`. It found and fixed: `ENOENT` for a path through a file (now `ENOTDIR`), `mmap` with an offset not page-aligned, `mlock` of memory not mapped, `faccessat2` and `getrandom` with unknown flags, `sched_getaffinity` of a thread that does not exist. The structs (`stat`, `statx`, `sigaction`, `stack_t`, `sysinfo`, `statfs`, `termios`, `epoll_event`, `clone_args`, ...) are checked field by field against Linux's x86-64 offsets on the host (`abi_test.zig`); the signal frame was already (`signal_frame_test.zig`).

**Milestone 6 done when:** Commands such as `ls /bin`, `cat /etc/motd`, and `echo hello` work, alone and in pipelines, from MyOS's own programs and from C programs built on Linux.

---

## 7. Threads and futexes

**Goal:** Run multi-threaded programs, with the threads of one process on different cores.

- [x] Support multiple threads per process, with shared address space and descriptor table; revisit the single-thread assumptions documented in 2.7.
  - The assumptions from 2.7, one by one: a process ends when its last thread does or when one asks (`exit_group`, a fault); the descriptor table has a lock, and an open file a reference for each call using it; the address space had its lock since 5; a blocking call blocks one thread.
- [x] Implement `clone` for threads (`CLONE_VM`, `CLONE_THREAD`, `CLONE_SETTLS`, `CLONE_PARENT_SETTID`, `CLONE_CHILD_CLEARTID`) and `exit` versus `exit_group`.
  - A new thread starts with a copy of every register of its creator, which is why the syscall entry now saves them all. `exit_group` makes every other thread come through the kernel, where it ends, and waits for them; waits a program can stay in forever (a futex, a sleep, a key, a child) end for it.
- [x] Implement `futex` wait and wake with timeouts (timers from 2.8), including the wake on thread exit that `pthread_join` relies on.
  - Also `FUTEX_WAIT_BITSET`, `FUTEX_WAKE_BITSET`, `FUTEX_REQUEUE` and `FUTEX_CMP_REQUEUE`, which musl's condition variables and timed waits use. One lock for all futexes, to split when measurements say so.
- [x] Wake futex waiters across CPUs, and keep TLB shootdowns (5) correct when threads of one process run on several cores.
- [x] Test thread creation and join, TLS isolation between threads, futex wake-before-wait and timeouts, and many threads under preemption on several CPUs.
  - `/test/threads` (raw calls) and the pthreads fixture, on one and four CPUs and under KVM; 40 boots in a row on four real cores without a failure.
- [x] Run a statically linked multi-threaded C program (pthreads, musl) built on Linux as a fixture.
  - `tests/fixtures/src/threads.c`: eight threads, a mutex, a condition variable, a barrier, thread-local storage, a timed wait, joins.

**Milestone 7 done when:** An unmodified multi-threaded program built on Linux runs with its threads spread over several cores.

---

## 8. Signals

**Goal:** Deliver signals the way Linux does, so runtimes can handle their own faults and stop their own threads.

- [x] Implement `rt_sigaction`, `rt_sigprocmask`, `sigaltstack` and `rt_sigreturn`, delivering signals on the return to user mode. `signal.zig`, with the frame laid out as Linux's (`signal_frame.zig`, tested on the host against its offsets). Also `rt_sigpending`, `rt_sigsuspend`, `pause`.
- [x] Turn user faults into `SIGSEGV`, `SIGBUS`, `SIGFPE` and `SIGILL` with `siginfo` and a register context (including the extended state from 2.5), instead of always killing the process (2.2); runtimes use this for null checks and stack probes. For a program that handles the signal; one that does not is killed as before. `int3` and `into` became usable from user mode for it.
- [x] Implement `kill`/`tgkill` and default actions; deliver Ctrl+C (6.4) as `SIGINT`. Within the calling process; signals to other processes and job control are tasks in 6.4.
- [x] Interrupt blocking syscalls with `EINTR` or restart them. `thread.interrupted` ends killable waits; `SA_RESTART` restarts the calls Linux restarts; `myos_run` waits through signals, since its child is running already.
- [x] Check the saved return address and flags that `rt_sigreturn` restores (the remaining `sysretq` item in 2.5): a handler can put anything there. Selectors forced, flags sanitized, RIP classified on the way out like any return; FP images sanitized so `XRSTOR` cannot fault.
- [x] Test handlers that return, handlers that modify the saved context, nested and masked signals, the alternate stack, and signals sent to another thread on another CPU. `/test/signals` (with another thread sending, on another CPU in the four-CPU runs), the terminal's Ctrl+C reaching a handler, and the fixtures: .NET turning null dereferences and divisions by zero into exceptions, Go recovering from a nil pointer and preempting a spinning goroutine.
- [x] Run a statically linked Go or Rust program (threads, futexes and signals in earnest).
  - Both run already, without signals: Rust since 4.2, and a Go program with goroutines on every CPU, a channel and a garbage collection since 7 (`tests/fixtures/src/hello.go`). Go sends itself signals to preempt goroutines that do not yield and carries on when they are not delivered. What this item still asks for is the same programs with signals delivered: a Go program whose goroutine spins without yielding and is preempted, and one that recovers from a nil dereference.

- [x] Queue real-time signals (`SIGRTMIN` to `SIGRTMAX`): each one sent is delivered, with its `sigqueue` value (`rt_sigqueueinfo`, `rt_tgsigqueueinfo`), instead of a second one being lost while the first is pending, as the standard signals are. Add `rt_sigtimedwait` and `signalfd` with it.
  - `signal.Queue`: what was sent with `siginfo`, per thread and per process under its signal lock; a real-time signal is queued each time (up to `RLIMIT_SIGPENDING`, 1024, else `EAGAIN`), a standard one sent by a program once, with the sender's details (`kill` now says `SI_USER` and the sender, `tgkill` `SI_TKILL`). `rt_sigqueueinfo`, `rt_tgsigqueueinfo` (`EPERM` for an `si_code` a program may not claim to another), `rt_sigtimedwait`, `signalfd` and `signalfd4` (readable to `poll` and `epoll`; a read sleeps on the readiness queue, which sending moves on). Found on the way: signals that waited for a handler to end were delivered only at the next system call, not as `rt_sigreturn` returned. Tested from ring 3 (`/test/sigqueue`); the record layout on the host.

**Milestone 8 done when:** A statically linked Go program built on Linux runs unmodified.

---

## 9. .NET, fast and multicore

**Goal:** Anyone can build a program with the ordinary .NET tools for Linux and run the result on Linux or on MyOS: the output of `dotnet publish -r linux-x64 --self-contained` runs unmodified, on several cores, with measured performance. This is the primary goal.

What is supported is what a .NET developer builds with nothing but `dotnet`:

| Build | Supported |
| --- | --- |
| `dotnet publish -r linux-x64 --self-contained` | Yes: the goal. It brings the .NET runtime with it |
| The same with `-p:PublishSingleFile=true` | Yes: the same program, packed into one file |
| The same with `-p:PublishAot=true` | Yes, and first: no JIT, so it asks less of the kernel |
| `dotnet build`, framework-dependent publish | No: it needs a .NET runtime installed on the system |

These are dynamically linked against glibc, so MyOS loads the dynamic loader, maps shared libraries from files and ships glibc's libraries in its image, as a Linux distribution does. No build step of MyOS's own is asked of the developer, and there is no MyOS target in .NET: Linux's target is MyOS's.

### 9.1 .NET Native AOT
- [x] Implement what the list from 4.2 shows the .NET runtime still needs. Expected, to be confirmed by the trace: `/proc` and cgroup files for CPU and memory limits, `membarrier`, and thread suspension through signals.
  - Done for the Native AOT runtime: `membarrier`, `mlock`, `sysinfo`, `statfs`, `get_mempolicy`, `mremap` in place, pipes and real standard descriptors. It runs without the `/proc` and cgroup files and without signals. Those files (it sizes its heap by them) are the pseudo-file task of 6.2; what the JIT runtime adds is in 9.3.
  - The control-group (v2) and mount files: `/proc/self/mountinfo` and `/proc/self/cgroup`, and `/sys/fs/cgroup` with `memory.max` (the process's memory limit), `memory.current`, `memory.stat`, `cpu.max`, `cpuset.cpus.effective`; `statfs` gives Linux's magic numbers for `/proc`, `/sys` and the cgroup root, which is how the runtime finds them. There are no control groups: the files say what the reader's own limits are. The fixture checks that the collector sizes itself by `memory.max` (it reports less memory than the machine has).
  - `flock` (`flock.zig`): advisory whole-file locks held by open files, which the runtime takes on every file it opens. Found when the fixture first read a file.
  - Signals: the runtime turns faults into exceptions, and stops threads for the collector with a real-time signal (next task).
- [x] Run a .NET Native AOT hello-world built for linux-musl, statically linked, invariant globalization (`tests/fixtures/src/dotnet-hello`): the runtime starts, eight managed threads allocate, the collector runs, on one and four CPUs, two at once, with its memory back afterwards. A stepping stone and a test fixture, not something a developer is asked to build: it shows what the runtime's core needs before dynamic linking exists. (It is linked with `zig cc`, which brings musl; the build machine has none.)
- [x] Run a .NET Native AOT hello-world built the ordinary way (`dotnet publish -r linux-x64 -p:PublishAot=true`): `tests/fixtures/` builds `dotnet-hello-aot`, position independent and dynamically linked against glibc, with managed threads and a collection, on one and four CPUs. It added `clone3` and `time` to what the kernel knows.
  - The fixture is linked against a plain glibc, not the build machine's: a distribution built for newer CPUs only marks every program linked on it as needing one (`x86-64-v4` here, which also needs AVX-512 state, saved since 9.3).
- [x] Run one that allocates enough to exercise the GC, then a multi-threaded one. The fixture does both: eight managed threads each allocate a megabyte in small arrays, then a collection is forced and counted.
- [x] Test that the .NET garbage collector stops a thread spinning in a tight loop: the runtime interrupts such a thread with a signal (it cannot wait for it to reach a safe point). A thread loops without calls or allocation while the main thread forces collections; the program must end. The fixtures' threads only allocate, so the collector never needed the signal there.
  - The fixture (`tests/fixtures/src/dotnet-hello`) starts a thread that loops on a volatile read and forces three full collections meanwhile; they finish, on one and four CPUs and under KVM, for the ahead-of-time and JIT builds.
- [x] Add them to the fixture binaries (4.3) and run them as QEMU tests on several CPUs. Four .NET fixtures: static ahead-of-time, ahead-of-time against glibc, the self-contained folder with the JIT, each on one and four CPUs and under KVM.

### 9.2 Fast and multicore
"Fast" is part of the goal, so it is measured rather than assumed.
- [x] Run foreign multi-threaded programs on all CPUs: threads of one process on different cores, cross-CPU futex wakeups and TLB shootdowns on `munmap`/`mprotect`. Done by the fixtures: pthreads in C, goroutines in Go and managed threads in .NET, each with its threads spread over four CPUs (emulated and under KVM), futex wake-ups between CPUs, and the runtimes' `munmap`/`mprotect`/`madvise` while their other threads run.
Order from the research of 2026-11-27 (`design-beyond-linux.md`, section 5): the harness, the counters, the vDSO, per-CPU queues, futex buckets, the CPU mask per address space, then switch costs.
- [x] Add a benchmark suite run in QEMU with KVM and on real hardware: syscall round trip, context switch, page fault, thread create/join, futex ping-pong, and `mmap`/`munmap` churn. LEBench's operations, each as 1 to N copies (will-it-scale's shape), static programs run unchanged on Linux and MyOS on one machine, results as CSV; Linux with and without mitigations, frequency fixed, warm-up, median and 99th percentile.
  - `tools/bench/`: `bench.zig`, one static program with no C library (also `/usr/bin/bench` on MyOS), and `run.sh`, which runs it in a Linux guest (the host's own kernel, the program as `/init`, with and without mitigations) and a MyOS guest (ReleaseSafe, scenario `bench`) under the same QEMU and KVM, and prints the medians side by side. Each benchmark: a warm-up, five runs of about 150 ms, median, fastest and slowest. Results per commit in `tools/bench/results/`; the first is `baseline-96acc89.csv`.
  - What the first run says (4 CPUs, KVM, Zen 5): a system call 1.5 times Linux's and worse with more CPUs (`getppid` takes the process-tree lock), `clock_gettime` 3.5 times (no vDSO), a page fault 13 times (Linux maps 2 MiB pages here), `mmap` and `munmap` of a page 22 times, futex and pipe round trips about twice, thread and process creation 2.2 to 2.5 times.
- [ ] Run the benchmark on real hardware too (MyOS booted on the machine, Linux on the same machine), with the CPU frequency fixed; and add a 99th percentile once runs are long enough for one.
- [x] Always-on counters, in `/proc`: per thread, the calls made with their cycles and a latency histogram; per lock class, contended acquisitions and cycles waited; time spent ready but not running. A per-CPU increment and an `rdtsc` each, cheap enough to leave on.
  - `stats.zig`: `/proc/syscalls` (per call, machine-wide rather than per thread: calls, total and average time, a histogram in powers of two), `/proc/lockstat` (per lock class: acquisitions that waited, time waited), `/proc/<pid>/schedstat` as Linux's (running, ready but waiting, slices). Each CPU counts into its own table, made when it comes up. The cost is inside the run-to-run noise of `bench`'s `getppid`. `bench` prints them at the end of a MyOS run (`run.sh` keeps them).
  - What they said on the first run: the address-space lock waited for 3.2 million times (9.5 s in all), the scheduler's lock 2.3 million (1.3 s), the process tree's 144 000 (`getppid` takes it).
- [x] A vDSO: a read-only page with the clock's base, multiplier and a sequence count, and an ELF image at `AT_SYSINFO_EHDR` with `__vdso_clock_gettime`, `__vdso_gettimeofday`, `__vdso_time` and `__vdso_getcpu` (Go parses it itself; glibc uses it for .NET). And `rseq`, accepted, with `cpu_id` kept current, which glibc reads for `sched_getcpu`.
  - `src/vdso/` (built position independent into one segment with Zig's lld: both hash tables, `LINUX_2.6` versions, an unwind table) and `kernel/vdso.zig`: the clock page and the image are physical pages every process shares, mapped on first touch below its mappings (regions `vvar` and `vdso`, page-table entries marked `vmm.SHARED`: never freed, copied or made writable), with `AT_SYSINFO_EHDR`. `clock_gettime` through it: 66 ns to 17 ns (Linux 15); .NET's thread pool, which reads the clock all the time, 92 ns to 68 ns a work item (Linux 65). Tested from ring 3 in `/test/linux_abi` (the clock against the system call's, `mprotect` refused, a forked child), and by every glibc, Go and .NET fixture, which now use it.
- [ ] `__vdso_getcpu` and `rseq` (accepted, with `cpu_id` kept current on every move to another CPU, which glibc 2.35 and later read for `sched_getcpu`), and the `getcpu` system call: .NET's server collector places its heaps by the CPU number.
- [ ] Futexes in buckets with a lock each, keyed by address space and address, instead of one lock for all.
- [ ] A mask of the CPUs that run each address space: TLB shootdowns to those only, `membarrier` to those only, signals for a collection fanned out faster.
  - Done for TLB shootdowns, without a mask: each CPU says which address space it has loaded before it loads it (`vmm.loadRoot`), and a flush of user addresses goes only to the CPUs that have it (`ipi.broadcastTo`). A CPU halted with nothing to run is not woken for one (Linux's lazy TLB): it is marked stale and flushes when it wakes (`vmm.enterLazy`, `vmm.leaveLazy`). `mmap`, touch, `munmap` of a page went from 28 µs to 0.9 µs (Linux: 1.2 µs); threads are made 1.5 times as slowly as Linux's instead of 2.2. Open: `membarrier` and signal fan-out to the CPUs of one process only.
- [x] Benchmark a multi-threaded .NET workload (allocation-heavy and CPU-bound) for throughput and scaling from 1 to N cores, and compare with the same binary on Linux on the same machine.
  - `tools/bench/dotnet`: allocation (the collector), arithmetic (scaling alone) and the thread pool (queues, wake-ups, futexes), on 1 to N threads, built ahead of time and static so both kernels run the same program; `run.sh` runs it after the rest in both guests.
  - First run (4 CPUs, KVM): arithmetic as fast as on Linux at every thread count, which says the comparison is fair; allocation 2.1 times Linux's on one thread and 4 times on four (page faults and the address space's lock: Linux scales, MyOS does not); the thread pool 1.5 to 2.3 times. Linux's numbers do not change with `mitigations=off` here.
- [ ] Profile and remove the hot spots the benchmarks show (the profiling items in 13 move up when this starts); a sampling profiler is in kernels built with `-Dbench` (`profile.zig`, `/proc/profile`; `tools/bench/run.sh --only NAME --myos-only` profiles one benchmark alone); candidates are per-CPU run queues, lock contention in the PMM and VMM, PCID to avoid TLB flushes, 2 MiB pages for large anonymous mappings, and a vDSO so `clock_gettime` needs no syscall.
- [ ] Known slow paths from the code review before 2.2, to measure first and fix where the benchmarks say so:
  - `read`/`write` bounce every 256 bytes through a kernel stack buffer, and `write` goes through the formatter as well.
  - Spawning a program copies the whole file to the heap and then into pages, although the initrd is already in memory (Debug builds: about 1.1 MiB per spawn, debug info included).
  - `print` keeps interrupts off while it writes to the polled serial port: about 22 ms for 256 bytes at 115200 baud, more than two timer ticks.
  - The kernel heap's blocks over 2 KiB, and its slabs, still come from a first-fit list, linear in the number of free chunks (3.4 put size classes in front for small blocks).
  - A heap block freed on another CPU goes to that CPU's cache, not back to the one it came from (snmalloc returns them to their owner in batches).
  - The page allocator scans its bitmap for a free page when a CPU's cache needs filling (a word at a time; 3.4 put per-CPU caches in front).
  - A CPU with nothing to run spins for up to 50 µs before it halts (`thread.pollForWork`, Linux's guest halt polling), and a waker skips the interrupt to a CPU that spins. Under KVM a wake-up of a halted CPU is two exits: pipe round trips between two processes on two CPUs went from 20 µs to 0.43 µs, futex round trips from 11.7 µs to 0.08 µs, `fork` and `wait4` from 62 µs to 38 µs (Linux 36). The Linux guest of `tools/bench` has no halt polling (`cpuidle-haltpoll` is a module it does not load), so for cross-CPU wake-ups the comparison is not yet like for like.
  - One ready queue, first in first out: with more ready threads than CPUs, a woken thread waits behind them (3.4 bounds the wait only when there are as many CPUs as threads). Per-CPU queues or priorities.
  - One lock for all futexes (7), and one lock per address space for faults and mapping changes (5): threads of one process that fault or wait at once meet on them. The research notes have the candidates for the address space.
  - Every switch between two processes reloads CR3 without PCID and flushes the user TLB entries (kernel entries are global and kernel threads do not reload it since 2.10).
  - Every switch between user threads saves and restores the whole x87/SSE/AVX state with plain XSAVE (2.5). XSAVEOPT or XSAVES would skip what has not changed.
  - AVX-512 is enabled where the CPU has it (decided by the programs, not by speed): a distribution built for x86-64-v4 marks everything linked on it as needing such a CPU, and glibc's loader refuses to start that unless the system has AVX-512's state enabled. The save area is 2432 bytes per thread on the development machine (AMD Zen 5), 832 without AVX-512.
  - `vmm.unmap` scans whole page tables (512 entries per level) to see whether they became empty (2.6); a count per table would avoid it.
  - Timers are a sorted list, linear to arm (2.8).
  - Any change to a pipe, the terminal or an eventfd wakes every thread in `poll` or `epoll_wait`, which then look at all they watch again (`readiness.zig`); per-object wake lists would wake only those watching it.
  - The kernel heap never gives pages back to the page allocator: memory it grew by for one large allocation stays with it.
- [ ] Keep the safety features on in the benchmarked configuration (SMEP/SMAP, guard pages, user-copy checks), and record results per commit so regressions are visible.

### 9.3 Dynamic linking and the JIT runtime
Gates the milestone: what the ordinary .NET tools produce is dynamically linked.
- [x] Load position-independent executables (`ET_DYN`, 4.1) and the ELF interpreter named by `PT_INTERP`, with `AT_BASE`, `AT_PHDR` and `AT_ENTRY` in the auxiliary vector, so dynamically linked programs run with the unmodified loader and shared libraries from the filesystem. The interpreter goes where `mmap` would put it, the highest free place below the stack; one that names an interpreter itself is refused, as on Linux. Tested with a C program standing in for the loader; malformed `PT_INTERP` headers on the host, missing and unusable interpreters in the kernel tests.
- [x] File-backed `mmap` (5), private, with the permissions of each segment: a page is read from the file when it is first touched and is the program's own from then on (`user_memory.zig`, regions of kind `file`). Read-only shared mappings are the same thing; writable shared ones are refused, files being read-only.
  - Open: pages of a file that nobody has written are copied per process instead of shared. Sharing them (a page cache, copy-on-write) saves the memory of one C library per process; it is in 13.
- [x] The calls a loader finds libraries with: `openat`, `fstat`, `newfstatat`, `pread64`, `readlink`, `access`/`faccessat`, `getcwd`; and `set_robust_list`, with `rseq` refused on purpose.
  - Directories exist for `stat` and `access` since the JIT runtime needed them (it resolves its own path one part at a time); opening and listing them (`getdents64`) came with 6.1.
- [x] Ship glibc's loader and libraries (`ld-linux-x86-64.so.2`, `libc.so.6`, `libm`, `libstdc++`, `libgcc_s`) in the image: `scripts/fetch-sysroot.sh` takes them from Debian 13, pinned by checksum, and `scripts/build.sh` packs them into test images. Release images carry no C library (decided 2026-11-26): the task below.
- [x] Run a dynamically linked hello-world built for Linux against glibc; test malformed `PT_INTERP` headers. (`tests/fixtures/` builds `glibc-hello-dynamic`, on one and four CPUs, two at once, memory back afterwards.)
- [x] Run C, Rust and Go programs built the way a developer builds them, with no flags (`gcc hello.c`, `cargo build --release`, `go build`): `tests/fixtures/` builds `c-hello-gcc`, `rust-hello-cargo`, `go-hello-plain`. The `gcc` one is marked x86-64-v4 by this machine's toolchain and runs where the CPU has AVX-512 (under KVM here); elsewhere it is refused as Linux refuses it.
- [x] Run the JIT-based runtime: a self-contained `dotnet publish -r linux-x64` hello-world (`dotnet-hello-app` of `tests/fixtures/build.sh`). The host program finds itself through `/proc/self/exe`, loads the runtime from its folder, and the runtime compiles and runs the program, with eight managed threads and a garbage collection, on one and four CPUs, two at once, its memory back afterwards. The untrimmed 80 MB folder runs too (tried by hand with `MYOS_INITRD_EXTRA`); the fixture is the trimmed one.
  - What it needed beyond the ahead-of-time build: directories that exist, `/proc/self/exe`, `/proc/self/maps` (glibc finds the main stack there; without it the runtime reports that it is out of memory), `stat`, more than 16 descriptors, the scheduling-policy calls and `sched_setaffinity`, `getsid`. No signal was delivered.
  - Tolerated by the runtime today, each a task: `memfd_create` with shared mappings and FIFOs in `/tmp` (below), sockets for its diagnostics (12.3), `/proc/self/mountinfo`, cgroup files and `/sys/devices/system/cpu` (6.2).
- [ ] `memfd_create` and shared mappings of it: the JIT maps its code twice, writable in one place and executable in the other, and without that uses memory that is both (W^X broken for the JIT). Shared pages between two mappings of one object; test that a write through one is seen through the other and that the executable one is never writable.
- [ ] FIFOs (`mknodat` with `S_IFIFO`, `mkfifo`) in `/tmp`: the .NET runtime makes them for its diagnostics and does without when refused. Opening one end waits for the other, as on Linux; reuse `pipe.zig`.
- [ ] What the .NET runtime's sources show an ordinary app can reach and MyOS lacks (`design-beyond-linux.md`, section 1), as far as no network is needed: `waitid` (`P_ALL`, `WNOWAIT`), `getrusage`, `getpriority`/`setpriority`, `utimensat`/`futimens`, `symlink`, `link`, `fcntl` record locks (`F_SETLK`, `F_GETLK`), `fallocate`, `posix_fadvise`, `sendfile`, `copy_file_range`, `madvise` with `MADV_DODUMP`/`DONTDUMP`/`DONTFORK`, `/proc/self/status`, `/proc/self/statm`, `/proc/<pid>/task/<tid>/comm`, `/proc/self/mounts`, `/sys/devices/system/cpu/cpu0/cache`.
- [ ] `inotify` (`inotify_init1`, `inotify_add_watch`, `inotify_rm_watch`), with rename cookies and `IN_Q_OVERFLOW`: .NET's `FileSystemWatcher`, which ASP.NET's configuration reload turns on by default.
- [ ] `memfd_create` sealing (`MFD_ALLOW_SEALING`, `F_ADD_SEALS`, `F_GET_SEALS`) for anonymous memory-mapped files, with the shared mappings of the task above.
- [ ] Shared (not private) futexes on `MAP_SHARED` memory, and robust mutexes: `set_robust_list` honored when a thread dies holding one (`EOWNERDEAD` for the next owner). .NET's named `Mutex` keeps such a mutex in a file under `$TMPDIR/.dotnet/shm`.
- [ ] A .NET fixture that is a real app rather than a hello-world: the generic host with configuration reload, a `FileSystemWatcher`, `Process.Start` of a child, `File.Copy`, a named mutex, the console in raw mode.
- [x] The same published as a single file. Runs (`-p:PublishSingleFile=true -p:PublishTrimmed=true`, one file of 15 MB). Tried by hand with `MYOS_INITRD_EXTRA`; not a fixture, since it would be 15 MB in the repository for what the folder already tests.
- [x] A way to put a published folder into the image, until there is a writable disk (11) or a network (12): `MYOS_INITRD_EXTRA=<dir> scripts/build.sh` copies the tree under `<dir>` over the image's root.
- [ ] glibc for release images, without MyOS passing it on (decided 2026-11-26): release images carry no C library, and the user fetches Debian's. First a script run on the user's machine that adds the pinned packages to a downloaded release ISO; later an install command on a running MyOS, once there is a disk that keeps files (11) and a network (12).
- Not supported: framework-dependent builds (`dotnet app.dll` with a runtime installed on the system).

**Milestone 9 done when:** The unmodified output of `dotnet publish -r linux-x64 --self-contained` runs on MyOS as it does on Linux, uses several cores, cannot crash or corrupt the kernel, and its measured performance is recorded against Linux on the same hardware.

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

## 11. Persistent storage

**Goal:** Read and write files that survive a reboot, safely.

Decided 2026-11-27 (`design-beyond-linux.md`, decision 3): the disk is a copy-on-write filesystem of MyOS's own, with its tools, built so that MyOS is not stuck with it (another format, btrfs say, can replace the one module). FAT32 is for exchanging files (the EFI system partition, USB sticks), not the disk. The system image becomes EROFS on two partitions.

Off the critical path (programs can ship in the initrd). It does not depend on milestone 10 and can be taken any time after milestone 6.

### 11.1 Block-device layer
- [ ] Define a generic block-device interface for read/write/capacity/block size.
- [ ] Add device registration and consistent I/O error reporting.
- [ ] Validate LBA ranges, buffer sizes, and alignment.
- [ ] Add a small block cache with explicit flush (the page cache of 11.4 takes it over; FAT32 writes in 11.8 rely on it for flush ordering).
- [ ] Test the block layer on the host against a fake in-memory device: bounds, sizes, alignment, error propagation, and cache hits, eviction and flush.
- [ ] Stress-test I/O from every CPU at once (several programs reading and writing files on the disk, and later sockets), as 3.4 stress-tests memory and processes.

### 11.2 NVMe
- [ ] Implement NVMe write operations.
- [ ] Give the NVMe driver a lock (or a queue per CPU): today it polls with no lock and is used by its own test only (3.4).
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

### 11.4 Page cache and the promises
- [ ] One page cache, keyed by file and page, shared by `read`, `write` and `mmap` (`MAP_SHARED` dirty pages found through the page tables); the block cache of 11.1 is this cache for block devices. Write-back by a thread, on a timer and above a dirty threshold no larger than Linux's.
- [ ] A write-back error sticks to the file: every later `fsync` or `fdatasync`, through any descriptor, returns `EIO` until the file is rewritten or truncated; failed pages are never quietly made clean (Linux's "fsyncgate"). Counted per mount too.
- [ ] `fsync` means on the medium: an NVMe flush (or FUA) before the commit. Directory `fsync` honored.
- [ ] The persistence model written down on one page (`docs/`), and tested: a recorder of the block writes a QEMU run makes, and a replay of every prefix of them, with the filesystem's `fsck` and the program's own invariants checked on each (ALICE's method), including a .NET program that saves by writing a temporary file and renaming it.

### 11.5 The native filesystem
- [ ] Design the on-disk format: copy-on-write throughout, B-trees for directories and extents, a checksum of each block kept in its parent, two superblocks taking turns, each with a generation and the root; commit = write the new tree, flush, write the superblock, flush; recovery = the newest valid superblock. A version and feature flags from the first image. Written down in `docs/`.
- [ ] Keep it replaceable: nothing outside the filesystem module sees inside it; the VFS, page cache and block layer, and the promises of 11.4, are the same for any format; system updates do not depend on its snapshots.
- [ ] `mkfs` and `fsck` in `tools/` (the `fsck` checks every image the tests leave behind).
- [ ] Implement it: files, directories, full POSIX metadata (modes, owner, nanosecond times), symbolic and hard links, `rename` atomic over an existing file and ordered after the writes before it, `fsync`, `ftruncate`, `fallocate`, `mmap`.
- [ ] Test it on the host against the format's own model, and in QEMU across reboots and with the crash replay of 11.4.
- [ ] Later, once it is right: snapshots (nearly free with copy-on-write, through an interface of MyOS's own), clones (`FICLONE`, which .NET's `File.Copy` tries first), compression.

### 11.6 System image
- [ ] Read EROFS, and boot from an EROFS image on one of two partitions (A and B), the writable state (`/var`, `/home`, `/etc`'s changes) on the native filesystem; an update writes the other partition and switches. Replaces the initrd as the system image.

### 11.7 FAT32 read support (for exchanging files)
- [ ] Validate FAT32 BPB/boot-sector fields.
- [ ] Read FAT entries and traverse cluster chains.
- [ ] Enumerate directories and open nested paths.
- [ ] Read multi-cluster files.
- [ ] Support 8.3 names, then long filename entries.
- [ ] Detect invalid clusters, loops, and malformed metadata.
- [ ] Mount FAT32 through the VFS.
- [ ] Test reads against generated fixture images (11.9), including corrupted boot sectors, cluster loops and bad directory entries.

### 11.8 FAT32 write support
- [ ] Allocate/free clusters safely.
- [ ] Create files and directories.
- [ ] Write, extend, truncate, and delete files.
- [ ] Update directory entries and filesystem metadata.
- [ ] Add flush ordering and document crash-consistency limits. Mounted as a volume that says what it cannot do: `EPERM` for links and modes, `rename` documented as not crash-safe.
- [ ] Test filesystem integrity from both MyOS and Linux after writes.

### 11.9 Reproducible disk fixtures
- [ ] Generate disposable GPT/FAT32 disk images with scripts.
- [ ] Populate fixtures using Linux `mkfs.fat`/`mcopy` tools.
- [ ] Check MyOS writes by remounting/inspecting the image from Linux.
- [ ] Run read/write regressions in CI, never against real user disks.

**Milestone 11 done when:** A .NET program's files persist across reboots on the native filesystem, and survive every crash point the replay test tries; a FAT32 volume can be read and written for exchanging files.

---

## 12. Networking

**Goal:** Communicate with other machines over IP, and host a .NET or Go HTTP API that the host can reach.

Decided 2026-11-27 (`design-beyond-linux.md`, decisions 1 and 2): completion inside the I/O core with `epoll` and `poll` on top; virtio-net; a TCP of MyOS's own (smoltcp's state machine as the reference); per-core connection tables; no general io_uring; the network as a grant from the first socket.

### 12.0 Before networking
- [ ] Per-process views: the filesystem a process sees is a list of mounts its parent composed (Plan 9's namespaces), inherited and only narrowed; one path walk over it. The persistent filesystem (11) and `/etc/resolv.conf` are mounted into views. A synthesized `/etc/passwd` and `/etc/group` with the process's identity, and `HOME`, `USER`, `TMPDIR` set by the launcher.
- [ ] Rights on descriptors: each entry of the descriptor table carries what may be done with it, and `dup` and passing it to another process only narrow it (Capsicum, Zircon). Denials are clean errors, never `SIGSYS`.
- [ ] Per-object wait lists: each object keeps who waits for it and each epoll instance a ready list (Linux's `ep_poll_callback`), replacing the one readiness queue of 6.2 (and its entry in 9.2's slow paths); `EPOLLET`, `EPOLLONESHOT`, `EPOLLEXCLUSIVE`, `EPOLLRDHUP` exact.
- [ ] The I/O core as completions: an operation on a socket, pipe or file is a request that ends in a callback, and a readiness change is one such event; `epoll` and `poll` are built on it.
- [ ] Test views (what a process can and cannot name), rights (narrowed, never widened) and the wait lists (only the watchers of an object woken) from ring 3.

### 12.1 Network hardware
- [ ] Define a generic network-device interface.
- [x] Choose the first network device: virtio-net is simpler than e1000e and its virtio groundwork is reusable for virtio-blk and virtio-gpu; e1000e matches real hardware. Decided: modern virtio-net over PCI (2026-11-27), with QEMU's user networking and `hostfwd` for tests from the host.
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
- [ ] Implement TCP handshake, data exchange, close, retransmission, and timeouts: in Zig, smoltcp's state machine as the reference; NewReno, window scaling, timestamps, a real `TIME_WAIT`, keepalive; SACK later. Tested with packetdrill scripts from Linux's tests and a fuzzer on received packets.
- [ ] Per-core connection tables and accept queues, steered by a hash of the address and port pairs; `SO_REUSEPORT` as the native model.
- [ ] Replace the sorted list behind kernel timers (2.8) with a heap or a timer wheel before TCP arms several timers per connection.
- [ ] Implement packet buffers and basic flow control.
- [ ] Add DNS resolution.
- [ ] Test protocol parsing, checksums and state machines on the host with recorded and malformed packets.

### 12.3 Sockets and programs
- [ ] Define socket create/bind/listen/accept/connect/send/receive/close syscalls (Linux's numbers and layouts).
- [ ] Unix domain sockets (`AF_UNIX`, stream and datagram): the .NET runtime opens one for its diagnostics (9.3) and many programs talk to local services through them. No network needed.
- [ ] The network as a grant: binding, connecting and listening only with a network right the launcher gave, filtered by port and address; `EACCES` otherwise.
- [ ] What servers and .NET rely on: `accept4`, non-blocking `connect` then `SO_ERROR`, `SO_REUSEADDR`/`SO_REUSEPORT`, `TCP_NODELAY`, keepalive options, `MSG_NOSIGNAL`, `sendfile`, `sendmsg`/`recvmsg` with `IP_PKTINFO`, `sendmmsg`, `SO_PEERCRED`, `connect(AF_UNSPEC)`, `IPV6_V6ONLY=0` (or `EAFNOSUPPORT` for IPv6 until it exists), `fchmod` on a socket before `bind`.
- [ ] Names and interfaces: `/etc/nsswitch.conf`, `/etc/hosts`, `/etc/resolv.conf` (written from DHCP), `/etc/gai.conf` in the image; netlink's `RTM_GETLINK` and `RTM_GETADDR` for `getifaddrs`; a loopback interface.
- [ ] Host an ASP.NET Core (Kestrel) API and a Go `net/http` server, reached with `curl` from the host through `hostfwd`.
- [ ] Implement `ping` and a small TCP client.
- [ ] Implement a minimal HTTP client or server.
- [ ] Add network integration tests with a host-side peer.

**Milestone 12 done when:** MyOS can ping a peer and establish a TCP connection, and an unmodified ASP.NET Core API running on it answers `curl` from the host.

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
- [ ] Cover what `check-frames` (2.3) cannot see: a function reached only through a pointer stored in a data table, and assembly that moves RSP by a computed amount. Or build with stack probes (`stack_check`), the fallback if a function ever needs a larger frame.

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
