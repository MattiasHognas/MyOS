# TODO

A dependency-ordered roadmap for building a small x86-64 operating system in Zig. Establish automated tests and CI first, then improve kernel safety and build out features.

## Current foundation

Already implemented: Limine BIOS/UEFI boot, serial/framebuffer console, GDT/IDT/TSS, physical and virtual memory management, kernel heap, APIC timer, preemptive threading, ring 3, syscalls, ELF64 loading, basic processes, read-only tarfs/VFS, PCI, basic NVMe reads, PS/2 keyboard, and a userspace shell.

## 1. Tests, debugging, and CI (ongoing)

**Goal:** Every subsystem has automated tests; establish the test harness before changing critical kernel code, then expand it alongside every subsequent milestone.

### 1.1 Test infrastructure
- [x] Separate hardware-independent code for host-side Zig unit tests.
- [x] Add a kernel test build mode and in-kernel test runner.
- [x] Add a reliable test success/failure exit mechanism for QEMU.
- [x] Write a script to build, boot QEMU, capture serial output, assert results, and enforce timeouts.
- [x] Save relevant logs and failure diagnostics.

### 1.2 Test suites
- [x] Test physical memory allocation and basic accounting.
- [x] Test kernel heap allocation and memory read/write.
- [ ] Test virtual memory mapping, permissions, unmapping, and exhaustion.
  - [x] Test address-space creation and destruction.
  - [x] Test page mapping and translation (`vmm.translate`), including unmapped neighbours.
- [ ] Test ELF parsing, failed loading, and rollback.
  - [x] Test rejection of invalid ELF magic.
- [ ] Test valid/invalid syscall buffers and kernel/user isolation.
- [ ] Test scheduler transitions, process lifecycle, waits, and cleanup.
- [ ] Test VFS and filesystem behavior; later add storage write tests.
  - [x] Test VFS lookup, file contents, offsets, and EOF.
  - [x] Test VFS using an injected fake filesystem.
  - [ ] Test malformed filesystem data and boundary conditions.
  - [ ] Add storage write tests when NVMe writes are implemented.

### 1.3 CI and debugging
- [ ] Add GitHub Actions kernel/app builds.
  - [x] Write `.github/workflows/ci.yml` with pinned Zig, checksum-verified Limine (`scripts/install-limine.sh`) and font (`scripts/fetch-font.sh`).
  - [ ] Confirm the first green run on GitHub.
- [ ] Run host unit tests and QEMU integration tests in CI.
  - [x] Workflow runs `zig build test-host` and `zig build test-qemu`.
  - [ ] Confirm the first green run on GitHub.
- [ ] Run debug and optimized builds.
  - [x] Test kernel follows `-Doptimize`; all QEMU scenarios pass locally in Debug, ReleaseSafe and ReleaseFast.
  - [x] CI matrix over Debug, ReleaseSafe and ReleaseFast.
  - [ ] Confirm the first green run on GitHub.
- [ ] Publish serial logs on failures.
  - [x] Per-scenario logs in `zig-out/test/<scenario>/`, printed by `test-qemu.sh` when a check fails.
  - [x] CI uploads them as the `serial-logs-<mode>` artifact on failure.
  - [ ] Confirm the upload with a deliberately failing run on GitHub.
- [x] Add QEMU/GDB debugging instructions (`docs/debugging.md`, `./run-qemu.sh --gdb`, `scripts/kernel.gdb`).
- [x] Add symbolized kernel faults and backtraces (kernel `.symtab` via Limine, frame-pointer walk; tested by in-kernel tests and the `panic`/`fault` scenarios).
- [x] Add log levels, subsystem assertions, and optional allocation diagnostics (`std.log` with `-Dlog-level`, `kernel/debug/assert.zig` with `-Dassertions`, heap stats and `-Dalloc-debug`).
- [ ] Track host-code coverage and explicit integration-test scenarios where practical.
  - [x] Explicit QEMU scenarios (`tests`, `panic`, `fault`) selected via fw_cfg; documented in `docs/testing.md`.
  - [x] `zig build coverage` (kcov) and an informational CI coverage job.
  - [ ] Confirm a coverage report is produced (kcov is not installed locally; first run will be in CI).

**Milestone 1 done when:** A clean checkout can automatically build and run regression tests, with clear failure reporting.

---

## 2. Kernel safety and correctness

**Goal:** Broken or malicious user programs cannot corrupt or crash the kernel.

### 2.1 Safe user-memory access
- [ ] Implement `copyFromUser(dst, src, len)` and `copyToUser(dst, src, len)`; replace direct user-buffer dereferences in every syscall.
- [ ] Validate canonical user addresses and use overflow-safe range checks.
- [ ] Handle faults inside user-copy routines by returning an error, not panicking.
- [ ] Handle unmapped, partially mapped, read-only, and page-crossing buffers.
- [ ] Enable SMEP when CPU-supported.
- [ ] Enable SMAP when CPU-supported, using `stac`/`clac` only in controlled user-access sections.
- [ ] Test null pointers, kernel pointers, overflow, invalid pages, and boundary crossings.

**Done when:** Every syscall rejects invalid user addresses without crashing the kernel.

### 2.2 Exception handling
- [ ] Allocate an independent double-fault emergency stack.
- [ ] Configure the TSS IST entry and double-fault IDT gate.
- [ ] Consider a separate NMI IST stack.
- [ ] Distinguish faults in user mode from recoverable faults during kernel user-copy operations and genuine kernel faults.
- [ ] Terminate the offending process for ordinary unrecoverable user faults.
- [ ] Print vector, error code, RIP, RSP, and CR2 (for page faults) in fault diagnostics.
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
- [ ] Validate program-header offset, count, entry size, and full table bounds.
- [ ] Use overflow-safe arithmetic for file offsets, address ranges, and segment sizes.
- [ ] Validate segment alignment and enforce user-only mapping ranges.
- [ ] Reject overlapping or conflicting load segments unless intentionally supported.
- [ ] Prevent mapping page zero and reserved user regions.
- [ ] Verify the entry point is inside an executable loaded segment.
- [ ] Enforce readable/writable/executable permissions and avoid unintended writable-executable pages.
- [ ] Roll back every allocated page and table on loading failure.
- [ ] Add malformed and truncated ELF tests.

### 2.5 Syscall and context-switch correctness
- [ ] Audit `syscall` entry and exit assembly for register preservation and ABI stack alignment.
- [ ] Validate return RIP/RSP and avoid unsafe `sysretq` for noncanonical or invalid return states.
- [ ] Verify interrupt masking and preemption across syscall entry, blocking, and return.
- [ ] Verify stack and address-space switches during timer interrupts and syscalls.
- [ ] Document the userspace syscall ABI, argument registers, clobbers, and return conventions.

### 2.6 Memory-management correctness
- [ ] Reject invalid, misaligned, and double page frees in the physical allocator.
- [ ] Verify free-page counts and bitmap consistency under stress.
- [ ] Make page mapping report errors rather than silently replacing mappings.
- [ ] Implement page unmapping and appropriate local TLB invalidation.
- [ ] Handle page-table allocation failure without a partially corrupted mapping.
- [ ] Free all user mappings and page tables on process teardown.
- [ ] Test memory exhaustion, mapping conflicts, repeated allocation/free, and failed allocations.

### 2.7 Process and scheduler lifecycle
- [ ] Define ownership rules for processes, threads, stacks, page tables, and open files.
- [ ] Document the current single-thread-per-process assumption explicitly.
- [ ] Review ready/running/blocked/dead transitions and prevent duplicate queue insertion.
- [ ] Make block/wake semantics race-safe, including wake-before-block.
- [ ] Handle children that exit before the parent begins waiting.
- [ ] Reap each exited thread/process exactly once.
- [ ] Close open descriptors and free all resources on process exit and failed spawn.
- [ ] Stress-test repeated spawn/exit, wait, wakeup, and failure paths.

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
- [ ] Define consistent VFS error codes.

### 3.3 Descriptors and I/O
- [ ] Reserve FDs 0/1/2 for stdin/stdout/stderr.
- [ ] Route console I/O through descriptor-backed devices.
- [ ] Support generic open/read/write/close plus `seek` where applicable.
- [ ] Define file-offset, ownership, and descriptor inheritance rules.
- [ ] Add descriptor duplication and pipes.
- [ ] Test EOF, partial I/O, invalid descriptors, and cleanup.

### 3.4 Commands and shell features
- [ ] Implement `echo`, `cat`, `ls`, `pwd`, `cd`, and `clear`.
- [ ] Support absolute and relative paths and working directories.
- [ ] Display meaningful command errors and exit statuses.
- [ ] Implement basic input/output redirection once descriptors are ready.
- [ ] Implement pipelines once pipes are available.
- [ ] Add `mkdir` and removal commands after writable filesystems exist.

### 3.5 User memory and process control
- [ ] Define user virtual-memory regions.
- [ ] Implement anonymous mapping/unmapping and resource reclamation.
- [ ] Expose `brk` or `mmap` and add a small userspace allocator.
- [ ] Assign stable PIDs and track parent-child relationships.
- [ ] Define generalized process waiting and exit-code handling.
- [ ] Support Ctrl+C termination of foreground jobs.
- [ ] Add monotonic timekeeping and a sleep syscall.
- [ ] Implement a basic `ps` command.

**Milestone 3 done when:** Commands such as `ls /bin`, `cat /etc/motd`, and `echo hello` work, and programs accept arguments.

---

## 4. Persistent storage and FAT32

**Goal:** Read and write files that survive a reboot.

### 4.1 Block-device layer
- [ ] Define a generic block-device interface for read/write/capacity/block size.
- [ ] Add device registration and consistent I/O error reporting.
- [ ] Validate LBA ranges, buffer sizes, and alignment.

### 4.2 NVMe
- [ ] Implement NVMe write operations.
- [ ] Support multi-page transfers with PRP lists or another valid DMA mechanism.
- [ ] Validate namespace geometry and bounds.
- [ ] Handle command errors, timeouts, and controller failures.
- [ ] Audit DMA allocation, synchronization, and queue handling.
- [ ] Test repeated and boundary-crossing reads/writes using disposable images.

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
- [ ] Add interrupt-aware spinlocks with interrupt-state restoration.
- [ ] Audit existing `cli`/`sti` critical sections and replace unsafe pseudo-locking.
- [ ] Add mutexes and reliable wait queues.
- [ ] Define lock-ordering rules and test contention.

### 5.2 Per-CPU state
- [ ] Introduce per-CPU data structures.
- [ ] Move current-thread, scheduler, syscall-stack, and interrupt state to per-CPU storage.
- [ ] Configure GS-based CPU-local addressing and correct `swapgs` transitions.
- [ ] Initialize separate GDT/TSS and guarded stacks for each CPU.

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
- [ ] Implement an e1000e driver with TX/RX descriptor rings.
- [ ] Handle RX interrupts and link state.
- [ ] Send/receive Ethernet frames in QEMU networking tests.

### 6.2 Network protocols
- [ ] Implement Ethernet frame parsing and ARP.
- [ ] Implement IPv4 packets, validation, and checksums.
- [ ] Add static IP/netmask/gateway configuration.
- [ ] Implement ICMP echo (ping).
- [ ] Implement UDP.
- [ ] Implement TCP handshake, data exchange, close, retransmission, and timeouts.
- [ ] Implement packet buffers and basic flow control.
- [ ] Add DNS resolution.

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
- [ ] Document syscall numbers, calling convention, errors, and register clobbers.
- [ ] Define userspace startup, initial stack, arguments, environment, and TLS.
- [ ] Implement missing memory, file, time, and process syscalls needed by the selected libc.
- [ ] Add ABI conformance tests.

### 7.2 Port libc and utilities
- [ ] Select a small libc (e.g. musl) and implement an OS-specific syscall adapter.
- [ ] Support memory allocation and standard file/console I/O.
- [ ] Support basic time and process functions.
- [ ] Implement required thread-local-storage initialization.
- [ ] Compile and run statically linked C hello-world.
- [ ] Port a few small command-line utilities.
- [ ] Consider dynamic linking later; do not require it for initial success.

**Milestone 7 done when:** A statically linked C program runs without the custom Zig userspace runtime.

---

## 8. Graphical environment

**Goal:** Display multiple interactive windows and run a graphical terminal.

### 8.1 Graphics
- [ ] Expose framebuffer information through a safe userspace API.
- [ ] Implement pixel, rectangle, image, and text rendering.
- [ ] Add back-buffering and a display update mechanism.
- [ ] Implement a basic software renderer.

### 8.2 Input
- [ ] Expose generic keyboard and pointer events to userspace.
- [ ] Add mouse support (PS/2 or USB).
- [ ] Track pointer coordinates and button states.
- [ ] Implement focus and event routing.

### 8.3 Window system
- [ ] Implement a basic userspace compositor/window manager.
- [ ] Create/destroy windows and draw decorations.
- [ ] Support movement, resizing, overlap, and focus.
- [ ] Add IPC for graphical clients.
- [ ] Build a graphical terminal and minimal desktop/launcher.
- [ ] Add a simple editor or file viewer.

**Milestone 8 done when:** Multiple user applications can display and interact through windows.

---

## 9. Long-term / optional

### Hardware and platform
- [ ] USB xHCI and USB HID devices.
- [ ] Additional storage/network devices.
- [ ] ACPI power management, shutdown, and reboot.
- [ ] CPU feature discovery and more QEMU/real-hardware testing.

### Advanced processes and memory
- [ ] Copy-on-write, demand paging, and file-backed mappings.
- [ ] `fork`/`exec` semantics if desired.
- [ ] Shared memory and multiple threads per process.
- [ ] User/group permissions.

### Performance and observability
- [ ] CPU and memory usage statistics.
- [ ] Scheduler tracing and kernel profiling.
- [ ] Filesystem cache and asynchronous I/O.

---

## Development rules

- Establish **milestone 1 (tests and CI)** first, then keep expanding the test suites alongside all later milestones.
- Deliver small, independently testable changes.
- Add regression tests alongside every subsystem or critical fix.
- Keep x86-64-specific implementation separate from architecture-neutral interfaces.
- Prefer explicit errors over panics for recoverable failures.
- Never trust pointers, addresses, lengths, or executable contents from userspace.
- Use disposable QEMU disk images for storage development.
- Update documentation when APIs or invariants change.
- Check off a milestone only when its **Done when** condition is demonstrated.
