# TODO

A dependency-ordered roadmap for building a small x86-64 operating system in Zig. Establish automated tests and CI first, then improve kernel safety and build out features.

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
- [x] Test valid/invalid syscall buffers and kernel/user isolation (`/test/syscalls` checks 37 cases from ring 3; reading kernel memory, `cli` and writing own code kill only the process). Unmapped user buffers are covered by 2.1.
- [x] Test scheduler transitions, process lifecycle, waits, and cleanup (FIFO round robin, wake-before-block, exit codes, no page/heap leaks after normal and crashed processes).
- [x] Test VFS and filesystem behavior (lookup, contents, offsets and EOF on the initrd; an injected fake filesystem on the host; malformed tarfs archives and boundary conditions). Storage write tests: 4.2.

### 1.3 CI and debugging
- [x] Add GitHub Actions kernel/app builds (`.github/workflows/ci.yml`; pinned Zig, checksum-verified Limine and font).
- [x] Run host unit tests and QEMU integration tests in CI.
- [x] Run debug and optimized builds (CI matrix over Debug, ReleaseSafe and ReleaseFast; the test kernel follows `-Doptimize`).
- [x] Publish serial logs on failures (per-scenario logs in `zig-out/test/<scenario>/`, printed by `scripts/test-qemu.sh` on failure and uploaded by CI as `serial-logs-<mode>`; verified with a `simulate_failure` run).
- [x] Add QEMU/GDB debugging instructions (`docs/debugging.md`, `scripts/run-qemu.sh --gdb`, `scripts/kernel.gdb`).
- [x] Add symbolized kernel faults and backtraces (kernel `.symtab` via Limine, frame-pointer walk; tested by in-kernel tests and the `panic`/`fault` scenarios).
- [x] Add log levels, subsystem assertions, and optional allocation diagnostics (`std.log` with `-Dlog-level`, `kernel/debug/assert.zig` with `-Dassertions`, heap stats and `-Dalloc-debug`).
- [x] Track host-code coverage and explicit integration-test scenarios where practical (`zig build coverage` with kcov, uploaded by CI as `host-coverage`; QEMU scenarios `tests`, `panic`, `fault`).

**Milestone 1 done when:** A clean checkout can automatically build and run regression tests, with clear failure reporting.

---

## 2. Kernel safety and correctness

**Goal:** Broken or malicious user programs cannot corrupt or crash the kernel.

### 2.1 Safe user-memory access
- [ ] Implement `copyFromUser(dst, src, len)` and `copyToUser(dst, src, len)`; replace direct user-buffer dereferences in every syscall.
- [ ] Validate canonical user addresses and use overflow-safe range checks.
- [ ] Mark the user-copy routines so the page-fault handler can tell a fault inside them from a genuine kernel fault and resume at an error path (moved from 2.2; the next item needs it).
- [ ] Handle faults inside user-copy routines by returning an error, not panicking.
- [ ] Handle unmapped, partially mapped, read-only, and page-crossing buffers.
- [ ] Enable SMEP when CPU-supported.
- [ ] Enable SMAP when CPU-supported, using `stac`/`clac` only in controlled user-access sections.
- [ ] Test null pointers, kernel pointers, overflow, invalid pages, and boundary crossings.
- [ ] Test that SMEP and SMAP are really on: the kernel faults when it executes or touches user memory outside a user-access section (QEMU runs with `-cpu max`, which has both).

**Done when:** Every syscall rejects invalid user addresses without crashing the kernel.

### 2.2 Exception handling
- [ ] Allocate an independent double-fault emergency stack.
- [ ] Configure the TSS IST entry and double-fault IDT gate.
- [ ] Consider a separate NMI IST stack.
- [x] Distinguish faults in user mode from kernel faults (`cs & 3` in `interruptHandler`). Recoverable faults during user copies: 2.1.
- [x] Terminate the offending process for ordinary unrecoverable user faults (exit code 255; tested by `/test/kernel_read`, `/test/privileged` and `/test/write_text`).
- [x] Print vector, error code, RIP, RSP, and CR2 (for page faults) in kernel fault diagnostics (checked by the `fault` scenario).
- [ ] Print the same details for user faults; the message currently shows only the fault name and RIP.
- [ ] Test deliberate user faults, kernel faults, and double-fault diagnostics.

**Done when:** User faults terminate only their process, and emergency faults produce useful diagnostics where possible.

### 2.3 Guarded kernel stacks
- [ ] Introduce a dedicated virtual-memory-backed kernel-stack allocator.
- [ ] Map stack pages with an unmapped guard page underneath.
- [ ] Migrate kernel-thread stacks away from ordinary heap allocations.
- [ ] Update context switches, TSS.RSP0, and syscall stack selection accordingly.
- [ ] Release mapped stack pages and reserved virtual ranges on thread cleanup.
- [ ] Verify stack overflow triggers a page fault rather than heap corruption.

### 2.4 Harden ELF loading
- [ ] Validate ELF class, endianness, machine type, type, version, and header sizes.
- [x] Validate program-header offset, count, entry size, and full table bounds.
- [x] Use overflow-safe arithmetic for file offsets, address ranges, and segment sizes.
- [ ] Validate segment alignment and enforce user-only mapping ranges.
- [ ] Reject overlapping or conflicting load segments unless intentionally supported.
- [ ] Prevent mapping page zero and reserved user regions.
- [ ] Verify the entry point is inside an executable loaded segment.
- [ ] Enforce readable/writable/executable permissions and avoid unintended writable-executable pages.
- [x] Roll back every allocated page and table on loading failure.
- [x] Add malformed and truncated ELF tests.
- [ ] Split ELF header/segment validation from page mapping so it runs in host tests, and fuzz it there.

### 2.5 Syscall and context-switch correctness
- [ ] Audit `syscall` entry and exit assembly for register preservation and ABI stack alignment.
- [ ] Validate return RIP/RSP and avoid unsafe `sysretq` for noncanonical or invalid return states.
- [ ] Verify interrupt masking and preemption across syscall entry, blocking, and return.
- [ ] Verify stack and address-space switches during timer interrupts and syscalls.
- [ ] Define errno-style syscall error codes and return them from every syscall instead of the single `ERR` value; mirror them in `app/lib.zig`. Do this before milestone 3 adds syscalls.
- [ ] Document the userspace syscall ABI, argument registers, clobbers, error codes, and return conventions.
- [ ] Test from ring 3 that syscalls preserve callee-saved registers and RFLAGS, keep the stack aligned, and survive preemption mid-syscall.
- [ ] Test that each failure case in `/test/syscalls` returns its specific error code.

### 2.6 Memory-management correctness
- [ ] Reject invalid, misaligned, and double page frees in the physical allocator.
- [ ] Verify free-page counts and bitmap consistency under stress.
- [ ] Make page mapping report errors rather than silently replacing mappings.
- [ ] Implement page unmapping and appropriate local TLB invalidation.
- [ ] Handle page-table allocation failure without a partially corrupted mapping.
- [ ] Free all user mappings and page tables on process teardown.
- [ ] Test memory exhaustion, mapping conflicts, repeated allocation/free, and failed allocations.
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
Moved up from 5.1: pipes, blocking I/O, sleep and interrupt-driven drivers in milestones 3 and 4 need these long before SMP does.
- [ ] Add interrupt-aware spinlocks with interrupt-state restoration (on one CPU they only mask interrupts; 5.1 makes them SMP-safe).
- [ ] Add wait queues and replace the single-`waiter` pointers (keyboard, process wait) with them.
- [ ] Add mutexes for code that may block while holding a lock.
- [ ] Add kernel timers: a timeout queue driven by the timer tick, for sleep, driver timeouts and later TCP.
- [ ] Test several waiters on one queue, wake-before-block, timer ordering and expiry, and mutex hand-off under preemption.

**Milestone 2 done when:** Malformed binaries, invalid pointers, expected user faults, and resource exhaustion do not take down the OS or leak resources.

---

## 3. Useful userspace and shell

**Goal:** Run practical programs with arguments, files, and predictable process behavior.

### 3.1 Process startup
- [ ] Define the initial userspace stack/ABI layout.
- [ ] Pass `argc`, `argv`, and `envp` to spawned programs.
- [ ] Update user startup code to read arguments/environment.
- [ ] Parse command lines with arguments and basic quoting.
- [ ] Test empty, long, invalid, and multi-argument commands.

### 3.2 VFS and directories
- [ ] Distinguish regular files from directories in VFS nodes.
- [ ] Add directory lookup and `readdir` operations.
- [ ] Add `stat`-like metadata queries.
- [ ] Normalize paths and handle `.` and `..`.
- [ ] Add mount-point traversal so multiple filesystems can coexist.
- [ ] Add create/write/truncate/unlink/mkdir operations to the VFS interface.
- [ ] Add a small in-memory filesystem (ramfs) mounted at `/tmp`, so redirection (3.4) has somewhere to write and the write API is proven before FAT32 (4.5).
- [ ] Define consistent VFS error codes that map onto the syscall error codes (2.5).
- [ ] Test directory lookup, `readdir`, `stat`, `.`/`..` normalization, mount traversal and error codes (host tests with fake filesystems, plus initrd tests in QEMU).
- [ ] Test ramfs create, write, read-back, truncate, unlink and out-of-memory on the host and from ring 3.
- [ ] Run the tarfs parser in host tests and fuzz it with malformed archives.

### 3.3 Descriptors and I/O
- [ ] Reserve FDs 0/1/2 for stdin/stdout/stderr.
- [ ] Route console I/O through descriptor-backed devices.
- [ ] Add serial input (receive interrupt) as a second console input source; the scripted shell tests in 3.4 depend on it.
- [ ] Add a terminal layer between the input drivers and FD 0: line editing, echo, backspace, and Ctrl+C/Ctrl+D handling.
- [ ] Support generic open/read/write/close plus `seek` where applicable.
- [ ] Define file-offset, ownership, and descriptor inheritance rules.
- [ ] Add descriptor duplication and pipes.
- [ ] Add a `poll`-style syscall to wait on several descriptors at once (needed by network servers in 6.3 and the compositor in 8.3).
- [ ] Test EOF, partial I/O, invalid descriptors, and cleanup.
- [ ] Test terminal line editing and `poll` (ready, blocking, and timeout cases) with input injected over serial.

### 3.4 Commands and shell features
- [ ] Implement `echo`, `cat`, `ls`, `pwd`, `cd`, and `clear`.
- [ ] Support absolute and relative paths and working directories.
- [ ] Display meaningful command errors and exit statuses.
- [ ] Implement basic input/output redirection once descriptors are ready.
- [ ] Implement pipelines once pipes are available.
- [ ] Add `mkdir` and removal commands after writable filesystems exist.
- [ ] Test commands, paths, redirection and pipelines with scripted shell sessions in QEMU (input via serial, output checked in the log).

### 3.5 User memory and process control
- [ ] Define user virtual-memory regions.
- [ ] Implement anonymous mapping/unmapping and resource reclamation.
- [ ] Expose `brk` or `mmap` and add a small userspace allocator.
- [ ] Assign stable PIDs and track parent-child relationships.
- [ ] Define generalized process waiting and exit-code handling.
- [ ] Support Ctrl+C termination of foreground jobs.
- [ ] Add monotonic timekeeping and a sleep syscall.
- [ ] Read wall-clock time from the RTC and expose it to userspace (FAT32 timestamps in 4.5 and libc in 7 need it).
- [ ] Start an `init` process that launches the shell, restarts it when it exits, and adopts orphans (2.7).
- [ ] Implement a basic `ps` command.
- [ ] Test map/unmap and out-of-memory from ring 3, PID and parent tracking, waiting on exited children, sleep accuracy, Ctrl+C termination, wall-clock time, and the shell being restarted after `exit`.

**Milestone 3 done when:** Commands such as `ls /bin`, `cat /etc/motd`, and `echo hello` work, and programs accept arguments.

---

## 4. Persistent storage and FAT32

**Goal:** Read and write files that survive a reboot.

### 4.1 Block-device layer
- [ ] Define a generic block-device interface for read/write/capacity/block size.
- [ ] Add device registration and consistent I/O error reporting.
- [ ] Validate LBA ranges, buffer sizes, and alignment.
- [ ] Add a small block cache with explicit flush (FAT32 writes in 4.5 rely on it for flush ordering).
- [ ] Test the block layer on the host against a fake in-memory device: bounds, sizes, alignment, error propagation, and cache hits, eviction and flush.

### 4.2 NVMe
- [ ] Implement NVMe write operations.
- [ ] Support multi-page transfers with PRP lists or another valid DMA mechanism.
- [ ] Add PCI MSI/MSI-X support and switch NVMe from polling to interrupt-driven completion (legacy PCI interrupt routing would need an ACPI AML interpreter; the network driver in 6.1 reuses this).
- [ ] Validate namespace geometry and bounds.
- [ ] Handle command errors, timeouts, and controller failures.
- [ ] Audit DMA allocation, synchronization, and queue handling.
- [ ] Test repeated and boundary-crossing reads/writes using disposable images, including write-then-read-back and persistence across a reboot (storage write tests, moved from 1.2).

### 4.3 Partition discovery
- [ ] Parse GPT headers and partition entries.
- [ ] Verify GPT checksums and bounds.
- [ ] Expose partitions as block devices.
- [ ] Test corrupted and empty partition tables.

### 4.4 FAT32 read support
- [ ] Validate FAT32 BPB/boot-sector fields.
- [ ] Read FAT entries and traverse cluster chains.
- [ ] Enumerate directories and open nested paths.
- [ ] Read multi-cluster files.
- [ ] Support 8.3 names, then long filename entries.
- [ ] Detect invalid clusters, loops, and malformed metadata.
- [ ] Mount FAT32 through the VFS.
- [ ] Test reads against generated fixture images (4.6), including corrupted boot sectors, cluster loops and bad directory entries.

### 4.5 FAT32 write support
- [ ] Allocate/free clusters safely.
- [ ] Create files and directories.
- [ ] Write, extend, truncate, and delete files.
- [ ] Update directory entries and filesystem metadata.
- [ ] Add flush ordering and document crash-consistency limits.
- [ ] Test filesystem integrity from both MyOS and Linux after writes.

### 4.6 Reproducible disk fixtures
- [ ] Generate disposable GPT/FAT32 disk images with scripts.
- [ ] Populate fixtures using Linux `mkfs.fat`/`mcopy` tools.
- [ ] Check MyOS writes by remounting/inspecting the image from Linux.
- [ ] Run read/write regressions in CI, never against real user disks.

**Milestone 4 done when:** A FAT32 volume can be mounted and files persist correctly across reboot.

---

## 5. SMP and synchronization

**Goal:** Safely use multiple CPU cores.

### 5.1 Synchronization
The primitives themselves come from 2.8; this section makes them and their users safe on several CPUs.
- [ ] Make the 2.8 spinlocks real locks (atomic acquire, not just interrupt masking).
- [ ] Audit existing `cli`/`sti` critical sections and replace every one that assumes a single CPU.
- [ ] Make mutexes and wait queues safe against wakeups from another CPU.
- [ ] Define lock-ordering rules and test contention.

### 5.2 Per-CPU state
- [ ] Introduce per-CPU data structures.
- [ ] Move current-thread, scheduler, syscall-stack, and interrupt state to per-CPU storage.
- [ ] Configure GS-based CPU-local addressing and correct `swapgs` transitions.
- [ ] Initialize separate GDT/TSS and guarded stacks for each CPU.
- [ ] Test per-CPU state and `swapgs` transitions (syscalls, interrupts from ring 0 and ring 3) with one and several CPUs.

### 5.3 Bring up application processors
- [ ] Request SMP information through Limine.
- [ ] Start APs and initialize CPU-local structures.
- [ ] Configure local APIC/timer and interrupts per CPU.
- [ ] Print and test online CPU counts.

### 5.4 SMP scheduling and memory
- [ ] Protect shared scheduler state.
- [ ] Choose per-CPU queues or a documented global-queue scheduling model.
- [ ] Support cross-CPU wakeups and inter-processor interrupts.
- [ ] Add CPU affinity/load balancing if needed.
- [ ] Synchronize PMM, heap, page tables, and drivers.
- [ ] Implement cross-CPU TLB shootdowns.
- [ ] Stress-test simultaneous allocations, processes, interrupts, and I/O.

**Milestone 5 done when:** Multiple cores safely execute user threads and syscalls concurrently.

---

## 6. Networking

**Goal:** Communicate with other machines over IP.

### 6.1 Network hardware
- [ ] Define a generic network-device interface.
- [ ] Choose the first network device: virtio-net is simpler than e1000e and its virtio groundwork is reusable for virtio-blk and virtio-gpu; e1000e matches real hardware.
- [ ] Implement the driver with TX/RX rings, using MSI/MSI-X interrupts (4.2).
- [ ] Handle RX interrupts and link state.
- [ ] Send/receive Ethernet frames in QEMU networking tests.

### 6.2 Network protocols
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

### 6.3 Sockets and programs
- [ ] Define socket create/bind/listen/accept/connect/send/receive/close syscalls.
- [ ] Implement `ping` and a small TCP client.
- [ ] Implement a minimal HTTP client or server.
- [ ] Add network integration tests with a host-side peer.

**Milestone 6 done when:** MyOS can ping a peer and establish a TCP connection.

---

## 7. C compatibility and libc

**Goal:** Execute small statically linked C applications.

### 7.1 Define the ABI
- [ ] Extend the syscall ABI document from 2.5 with everything the libc port relies on.
- [ ] Enable SSE (CR0/CR4), save and restore FPU/SSE state per thread on context switch, and build user programs with SSE; today kernel and user code are soft-float and compiled C code will not run.
- [ ] Define userspace startup, initial stack, arguments, environment, and TLS.
- [ ] Implement missing memory, file, time, and process syscalls needed by the selected libc.
- [ ] Add ABI conformance tests, including floating-point registers surviving preemption between two processes.

### 7.2 Port libc and utilities
- [ ] Select a small libc (e.g. musl) and implement an OS-specific syscall adapter.
- [ ] Support memory allocation and standard file/console I/O.
- [ ] Support basic time and process functions.
- [ ] Implement required thread-local-storage initialization.
- [ ] Compile and run statically linked C hello-world.
- [ ] Port a few small command-line utilities.
- [ ] Consider dynamic linking later; do not require it for initial success.
- [ ] Run the C programs and utilities as QEMU tests and check their output.

**Milestone 7 done when:** A statically linked C program runs without the custom Zig userspace runtime.

---

## 8. Graphical environment

**Goal:** Display multiple interactive windows and run a graphical terminal.

### 8.1 Graphics
- [ ] Expose framebuffer information through a safe userspace API.
- [ ] Implement pixel, rectangle, image, and text rendering.
- [ ] Add back-buffering and a display update mechanism.
- [ ] Implement a basic software renderer.
- [ ] Test rendering on the host against reference images.

### 8.2 Input
- [ ] Expose generic keyboard and pointer events to userspace.
- [ ] Add mouse support (PS/2 or USB).
- [ ] Track pointer coordinates and button states.
- [ ] Implement focus and event routing.
- [ ] Test event delivery and focus with injected input events.

### 8.3 Window system
- [ ] Implement a basic userspace compositor/window manager.
- [ ] Create/destroy windows and draw decorations.
- [ ] Support movement, resizing, overlap, and focus.
- [ ] Add shared memory mappings between processes (moved from 9; window buffers need them).
- [ ] Add IPC for graphical clients, with the compositor waiting on input and clients through `poll` (3.3).
- [ ] Build a graphical terminal and minimal desktop/launcher.
- [ ] Add a simple editor or file viewer.
- [ ] Test window management and graphical IPC with scripted clients, checking framebuffer output.

**Milestone 8 done when:** Multiple user applications can display and interact through windows.

---

## 9. Long-term / optional

### Hardware and platform
- [ ] USB xHCI and USB HID devices.
- [ ] Additional storage/network devices.
- [ ] ACPI power management, shutdown, and reboot.
- [ ] Run the QEMU test scenarios under UEFI (OVMF) as well; CI currently boots them with legacy BIOS only.
- [ ] CPU feature discovery and more QEMU/real-hardware testing.

### Advanced processes and memory
- [ ] Copy-on-write, demand paging, and file-backed mappings.
- [ ] `fork`/`exec` semantics if desired.
- [ ] Multiple threads per process.
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
