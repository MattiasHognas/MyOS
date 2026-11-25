//! Kernel-side helpers for the in-kernel tests.
//!
//! These reach into the running kernel through `@import("root")`, so they use
//! the kernel's own module instances (and their global state) rather than
//! second copies. Each helper does one measurable thing and reports the
//! result; the test cases in `main.zig` decide what is expected.

const std = @import("std");
const kernel_root = @import("root");
const cpu = kernel_root.arch.x86_64.cpu;
const vmm = kernel_root.arch.x86_64.vmm;
const usercopy = kernel_root.arch.x86_64.usercopy;
const idt = kernel_root.arch.x86_64.idt;
const gdt = kernel_root.arch.x86_64.gdt;
const uaccess = kernel_root.kernel.uaccess;
const nvme = kernel_root.drivers.nvme;
const elf = kernel_root.kernel.elf;
const heap = kernel_root.kernel.heap;
const kstack = kernel_root.kernel.kstack;
const pmm = kernel_root.kernel.pmm;
const process = kernel_root.kernel.process;
const thread = kernel_root.kernel.thread;
const vfs = kernel_root.kernel.vfs;
const tarfs = kernel_root.kernel.fs.tarfs;
const backtrace = kernel_root.kernel.debug.backtrace;
const percpu = kernel_root.arch.x86_64.percpu;
const fpu = kernel_root.arch.x86_64.fpu;
const apic = kernel_root.arch.x86_64.apic;
const arch_syscall = kernel_root.arch.x86_64.syscall;
const abi = kernel_root.abi;
const hpet = kernel_root.drivers.hpet;
const keyboard = kernel_root.drivers.ps2_keyboard;
const timer = kernel_root.kernel.timer;
const SpinLock = kernel_root.kernel.sync.spinlock.SpinLock;
const WaitQueue = kernel_root.kernel.sync.wait_queue.WaitQueue;
const Mutex = kernel_root.kernel.sync.mutex.Mutex;
const random = kernel_root.kernel.random;
const nospec = kernel_root.arch.x86_64.nospec;
const meltdown = kernel_root.arch.x86_64.meltdown;
/// Where program images may be loaded and how large they may be.
pub const image_limits = process.image_limits;
/// Whether the helpers below start processes with a randomized layout.
/// Off for the tests that need two runs of a program to use exactly the
/// same memory.
pub var randomize_layout = true;

/// The limits a process gets by default.
pub const Limits = process.Limits;
/// Bytes in a kernel stack, and the usage above which the run should fail.
pub const STACK_SIZE = kstack.STACK_SIZE;
pub const STACK_WARN_BYTES = kstack.WARN_BYTES;

/// Result of loading an ELF image for inspection (see `elfProbe`).
pub const ElfProbe = struct {
    /// Entry point returned by the loader.
    entry: u64,
    /// Leaf page-table entry mapping the probed address, or 0 if unmapped.
    pte: u64,
};

/// Return the number of free physical pages.
pub fn freePages() usize {
    return pmm.free_pages;
}

/// Return true if a file exists at `path`.
pub fn hasFile(path: []const u8) bool {
    return vfs.lookup(path) != null;
}

/// Return the size of the file at `path`, or null if it doesn't exist.
pub fn fileSize(path: []const u8) ?u64 {
    const node = vfs.lookup(path) orelse return null;
    return node.size;
}

/// Read from the file at `path` starting at `offset` into
/// `buf`. Returns the number of bytes read, or null if the file doesn't exist.
pub fn readFileAt(
    path: []const u8,
    offset: u64,
    buf: []u8,
) ?usize {
    const node = vfs.lookup(path) orelse return null;
    return vfs.read(&node, offset, buf);
}

/// Write a pattern to both ends of physical page `page` through
/// The HHDM and return true if it reads back correctly.
pub fn pageRw(page: u64) bool {
    const memory =
        pmm.physToVirt(page)[0..pmm.PAGE_SIZE];

    memory[0] = 0xA5;
    memory[pmm.PAGE_SIZE - 1] = 0x5A;

    return memory[0] == 0xA5 and
        memory[pmm.PAGE_SIZE - 1] == 0x5A;
}

/// Allocate 257 bytes from the kernel heap, fill and verify
/// Them, then free them. Returns false on allocation failure or mismatch.
pub fn heapRoundtrip() bool {
    const memory = heap.allocator.alloc(
        u8,
        257,
    ) catch return false;

    defer heap.allocator.free(memory);

    @memset(memory, 0xBC);

    for (memory) |byte| {
        if (byte != 0xBC) return false;
    }

    return true;
}

/// Create and destroy an address space and return true if
/// Exactly one page was used and all pages were given back.
pub fn addressSpaceRoundtrip() bool {
    const before = pmm.free_pages;
    const address_space =
        vmm.createAddressSpace() catch return false;

    if (pmm.free_pages + 1 != before) {
        vmm.destroyAddressSpace(address_space);
        return false;
    }

    vmm.destroyAddressSpace(address_space);

    return pmm.free_pages == before;
}

/// Load the ELF `image` into a fresh address space, then report
/// Its entry point and the leaf page-table entry mapping `addr`, and copy the
/// Bytes at `addr` (up to the end of that page) into `out`. Returns null if
/// Loading fails. The address space is always destroyed again.
pub fn elfProbe(image: []const u8, addr: u64, out: []u8) ?ElfProbe {
    const root = vmm.createAddressSpace() catch return null;
    defer vmm.destroyAddressSpace(root);
    const entry = (elf.load(root, image, process.image_limits, null) catch return null).entry;
    const pte = vmm.leafEntry(root, addr) orelse 0;
    if (vmm.translate(root, addr)) |phys| {
        const n = @min(out.len, pmm.PAGE_SIZE - (addr % pmm.PAGE_SIZE));
        @memcpy(out[0..n], pmm.physToVirt(phys)[0..n]);
    }
    return .{ .entry = entry, .pte = pte };
}

/// Load the ELF `image` into a fresh address space, destroy it again and
/// return the loader's error, or null if the image loaded.
pub fn elfLoadError(image: []const u8) ?elf.Error {
    const root = vmm.createAddressSpace() catch return error.OutOfMemory;
    defer vmm.destroyAddressSpace(root);
    _ = elf.load(root, image, process.image_limits, null) catch |e| return e;
    return null;
}

/// `elfProbe` on the file at `path`.
pub fn elfProbePath(path: []const u8, addr: u64, out: []u8) ?ElfProbe {
    const node = vfs.lookup(path) orelse return null;
    const image = heap.allocator.alloc(u8, node.size) catch return null;
    defer heap.allocator.free(image);
    if (vfs.read(&node, 0, image) != node.size) return null;
    return elfProbe(image, addr, out);
}

/// Return true if `process.spawn` rejects `image` and leaves
/// Physical memory and the heap exactly as they were (full rollback).
pub fn spawnFailsCleanly(image: []const u8) bool {
    const pages = pmm.free_pages;
    const in_use = heap.stats().bytes_in_use;
    const p = process.spawn("bad", image, .{}) catch
        return pmm.free_pages == pages and heap.stats().bytes_in_use == in_use;
    _ = process.wait(p); // it started; the test fails
    return false;
}

/// Run the program at `path` as a child process of the current
/// Thread and wait for it. Returns its exit code (255 if it was killed by a
/// Fault), or null if it could not be started.
pub fn runProgram(path: []const u8) ?u64 {
    return runProgramLimited(path, .{});
}

/// `runProgram` with `limits` on the new process (and, by inheritance, on
/// everything it starts).
pub fn runProgramLimited(path: []const u8, limits: Limits) ?u64 {
    const p = process.spawnPath(path, .{ .limits = limits, .randomize = randomize_layout }) catch return null;
    return waitUntilGone(p);
}

/// Run the program at `path` with the arguments `argv` and the environment
/// `envp`, and wait for it. Returns its exit status, or null if it could
/// not be started.
pub fn runProgramArgs(path: []const u8, argv: []const []const u8, envp: []const []const u8) ?u64 {
    const p = process.spawnPath(path, .{ .argv = argv, .envp = envp, .randomize = randomize_layout }) catch return null;
    return waitUntilGone(p);
}

/// `runProgramArgs` with `limits` on the new process.
pub fn runProgramLimitedArgs(path: []const u8, argv: []const []const u8, limits: Limits) ?u64 {
    const p = process.spawnPath(path, .{ .argv = argv, .limits = limits, .randomize = randomize_layout }) catch return null;
    return waitUntilGone(p);
}

/// True if starting a program with more argument bytes, or more
/// arguments, than fit on its stack is refused as such.
pub fn argumentsTooLong() bool {
    const long = heap.allocator.alloc(u8, abi.ARG_MAX) catch return false;
    defer heap.allocator.free(long);
    @memset(long, 'x');
    const many = heap.allocator.alloc([]const u8, abi.ARG_COUNT_MAX + 1) catch return false;
    defer heap.allocator.free(many);
    @memset(many, "y");
    for ([_][]const []const u8{ &.{ "p", long }, many }) |argv| {
        if (process.spawnPath("/bin/hello", .{ .argv = argv })) |p| {
            _ = waitUntilGone(p);
            return false;
        } else |e| {
            if (e != error.ArgumentsTooLong) return false;
        }
    }
    return true;
}

/// Wait for `p` like `process.wait`, giving up the caller's reference, and
/// then until its thread has been freed as well. A process's memory is back
/// when `wait` returns; its thread and kernel stack follow when the CPU
/// that ran it has left that stack, which on another CPU is a moment
/// later. Tests that compare memory before and after wait for that too.
pub fn waitUntilGone(p: *process.Process) u64 {
    process.retain(p); // to look at it after `wait` has given up one reference
    const code = process.wait(p);
    // The thread holds one reference until it is freed; then ours is the last.
    var tries: usize = 0;
    while (@atomicLoad(u32, &p.refs, .monotonic) != 1 and tries < 100_000) : (tries += 1) thread.yield();
    process.release(p);
    return code;
}

/// Try to start the program at `path` with `limits` and return the error
/// that stopped it. Null means it started (and now runs on its own, with
/// nobody waiting for it).
pub fn spawnError(path: []const u8, limits: Limits) ?anyerror {
    const p = process.spawnPath(path, .{ .limits = limits, .randomize = randomize_layout }) catch |e| return e;
    process.release(p);
    return null;
}

/// Size of an emergency stack, and the most any of them has been used.
pub const IST_STACK_SIZE = gdt.IST_STACK_SIZE;
pub fn istPeak() ?usize {
    return gdt.istPeak();
}

/// Nanoseconds since boot, by the HPET.
pub fn nanos() u64 {
    return hpet.nanos();
}

/// Bytes currently allocated from the kernel heap.
pub fn heapInUse() usize {
    return heap.stats().bytes_in_use;
}

// State shared by the scheduler test's worker threads.
var sched_log: [8]u8 = undefined;
var sched_len: usize = 0;
var sched_done: usize = 0;

/// Scheduler test worker: append `tag` to the log three times, yielding after
/// Each, then report completion. Interrupts stay off so only the explicit
/// Yields switch threads, which makes the interleaving deterministic.
fn schedWorker(tag: u8) void {
    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    for (0..3) |_| {
        if (sched_len < sched_log.len) sched_log[sched_len] = tag;
        sched_len += 1;
        thread.yield();
    }
    signalDone(&sched_done, &done_queue);
}

/// First scheduler test worker.
fn schedWorkerA() void {
    schedWorker('A');
}

/// Second scheduler test worker.
fn schedWorkerB() void {
    schedWorker('B');
}

/// Run two kernel threads that yield to each other and check
/// That they alternate in FIFO order, that the waiting thread is woken when
/// Both are done, and that their stacks and thread structs are freed.
pub fn schedulerRoundRobin() bool {
    const in_use = heap.stats().bytes_in_use;
    const stacks = kstack.inUse();
    const pages = pmm.free_pages;
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    sched_len = 0;
    sched_done = 0;
    const a = thread.spawn(schedWorkerA, null) catch return false;
    const b = thread.spawn(schedWorkerB, null) catch return false;
    if (b.id <= a.id or a.state != .ready) return false;
    waitForDone(&sched_done, 2, &done_queue);
    return sched_len == 6 and
        std.mem.eql(u8, sched_log[0..6], "ABABAB") and
        heap.stats().bytes_in_use == in_use and // both threads reaped,
        kstack.inUse() == stacks and pmm.free_pages == pages; // with their stacks
}

/// A wake that arrives before `block` must make `block`
/// Return immediately (otherwise this test hangs and times out).
pub fn wakeBeforeBlock() bool {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const me = thread.current();
    thread.wake(me);
    if (!me.wake_pending or me.state != .running) return false;
    thread.block();
    return !me.wake_pending and me.state == .running;
}

/// Mount the tar archive `image`, read the file at `path` from
/// `offset` into `buf`, then remount the initrd. Returns the bytes read, or
/// Null if the file is not found.
pub fn tarfsRead(image: []const u8, path: []const u8, offset: u64, buf: []u8) ?usize {
    const fs = tarfs.init(image);
    defer _ = tarfs.init(kernel_root.initrd_image);
    const node = fs.lookup(fs.ctx, path) orelse return null;
    return vfs.read(&node, offset, buf);
}

/// Read the sector at `lba` from the NVMe disk into `buf`.
/// Returns the sector's bytes, or null if there is no working NVMe disk or
/// The read fails.
pub fn nvmeRead(lba: u64, buf: []u8) ?[]u8 {
    if (!kernel_root.nvme_ready) return null;
    nvme.read(lba, 1, buf) catch return null;
    return buf[0..nvme.sector_size];
}

/// Return the name of the function containing code address
/// `addr`, or null if it can't be symbolized.
pub fn symbolize(addr: u64) ?[]const u8 {
    const sym = backtrace.symbolize(addr) orelse return null;
    return sym.name;
}

/// Store the return addresses of the caller's frame chain in
/// `out`, innermost first (the first one points into the caller).
pub noinline fn captureBacktrace(out: []u64) usize {
    return backtrace.capture(@frameAddress(), out);
}

/// In a fresh address space, map one user page, check that
/// `vmm.translate` finds it (including an offset into the page) and that
/// Neighbouring pages are unmapped, then destroy the address space and check
/// That no physical pages leaked.
pub fn vmmMapTranslate() bool {
    const before = pmm.free_pages;
    const root = vmm.createAddressSpace() catch return false;
    const virt: u64 = 0x40_0000;
    const phys = pmm.alloc() orelse {
        vmm.destroyAddressSpace(root);
        return false;
    };
    vmm.map(root, virt, phys, vmm.USER | vmm.WRITABLE, false) catch return false;
    const ok = vmm.translate(root, virt) == phys and
        vmm.translate(root, virt + 0x123) == phys + 0x123 and
        vmm.translate(root, virt + pmm.PAGE_SIZE) == null and
        vmm.translate(root, virt - pmm.PAGE_SIZE) == null and
        vmm.translate(root, 0x7FFF_0000_0000) == null;
    vmm.destroyAddressSpace(root); // frees the mapped page and its tables too
    return ok and pmm.free_pages == before;
}

/// Check that the heap usage counters track an allocation,
/// A shrink and a free, and return to their starting value.
pub fn heapStats() bool {
    const s0 = heap.stats();
    const mem = heap.allocator.alloc(u8, 100) catch return false;
    const s1 = heap.stats();
    const shrunk = heap.allocator.resize(mem, 20);
    const s2 = heap.stats();
    heap.allocator.free(mem[0..20]);
    const s3 = heap.stats();
    return s1.allocs == s0.allocs + 1 and
        s1.bytes_in_use == s0.bytes_in_use + 112 and // 100 rounded up to 16
        s1.peak_bytes >= s1.bytes_in_use and
        shrunk and s2.bytes_in_use == s0.bytes_in_use + 32 and
        s3.frees == s0.frees + 1 and
        s3.bytes_in_use == s0.bytes_in_use and
        s3.bytes_mapped >= s3.bytes_in_use;
}

/// Address of the user page mapped by `enterUserPageSpace`.
pub const USER_PAGE: u64 = 0x40_0000;

/// Allocate a zeroed page and map it at `virt` in `root` with `flags`.
/// Returns its physical address, or null if memory ran out.
fn mapUserPage(root: u64, virt: u64, flags: u64) ?u64 {
    const phys = pmm.alloc() orelse return null;
    @memset(pmm.physToVirt(phys)[0..pmm.PAGE_SIZE], 0);
    vmm.map(root, virt, phys, flags, false) catch {
        pmm.free(phys);
        return null;
    };
    return phys;
}

/// True if copying `len` bytes from user address `addr` fails with a fault.
fn readFaults(addr: u64, len: usize) bool {
    var buf: [32]u8 = undefined;
    return uaccess.copyFromUser(buf[0..len], addr) == error.Fault;
}

/// True if copying `len` bytes to user address `addr` fails with a fault.
fn writeFaults(addr: u64, len: usize) bool {
    const buf: [32]u8 = @splat(0xEE);
    return uaccess.copyToUser(addr, buf[0..len]) == error.Fault;
}

/// Exercise `copyFromUser`/`copyToUser` against a private address space with
/// two writable pages at 0x400000, a hole at 0x402000 and a read-only page
/// at 0x403000. Returns 0 if everything behaves, otherwise the number of the
/// first failing check.
pub fn userCopyChecks() u32 {
    const flags = cpu.saveAndDisableInterrupts(); // no thread switch while the root is swapped
    defer cpu.restoreInterrupts(flags);
    const pages_before = pmm.free_pages;
    const root = vmm.createAddressSpace() catch return 99;
    const rw = vmm.USER | vmm.WRITABLE | vmm.NX;
    const p0 = mapUserPage(root, 0x40_0000, rw);
    const p1 = mapUserPage(root, 0x40_1000, rw);
    const ro = mapUserPage(root, 0x40_3000, vmm.USER | vmm.NX);
    vmm.loadRoot(root);
    const failed = userCopyChecksIn(p0, p1, ro);
    vmm.loadRoot(vmm.kernel_root);
    vmm.destroyAddressSpace(root);
    if (failed != 0) return failed;
    return if (pmm.free_pages == pages_before) 0 else 100;
}

/// The checks of `userCopyChecks`, run with its address space loaded.
/// `p0`, `p1` and `ro` are the physical pages behind 0x400000, 0x401000 and 0x403000.
fn userCopyChecksIn(p0: ?u64, p1: ?u64, ro: ?u64) u32 {
    const first = pmm.physToVirt(p0 orelse return 1);
    const second = pmm.physToVirt(p1 orelse return 1);
    const readonly = pmm.physToVirt(ro orelse return 1);
    const end = kernel_root.kernel.user_range.USER_END;
    var buf: [16]u8 = undefined;

    // A buffer crossing a page boundary is written and read back whole.
    const msg = "0123456789abcdef";
    uaccess.copyToUser(0x40_0FF8, msg) catch return 2;
    if (!std.mem.eql(u8, first[0xFF8..0x1000], msg[0..8])) return 3;
    if (!std.mem.eql(u8, second[0..8], msg[8..])) return 4;
    uaccess.copyFromUser(&buf, 0x40_0FF8) catch return 5;
    if (!std.mem.eql(u8, &buf, msg)) return 6;

    // Unmapped page, null, and never-mapped parts of user space.
    if (!readFaults(0x40_2000, 8) or !writeFaults(0x40_2000, 8)) return 7;
    if (!readFaults(0, 8) or !writeFaults(0, 8)) return 8;
    if (!readFaults(0x7000_0000_0000, 8)) return 9;

    // Partly mapped: starts in the second page, runs into the hole. The
    // bytes before the hole were written, as documented.
    if (!readFaults(0x40_1FF8, 16) or !writeFaults(0x40_1FF8, 16)) return 10;
    if (second[0xFFF] != 0xEE) return 11;
    // The last mapped bytes on their own are fine.
    uaccess.copyFromUser(buf[0..8], 0x40_1FF8) catch return 12;

    // Read-only page: readable, not writable, contents untouched.
    readonly[0] = 0x77;
    uaccess.copyFromUser(buf[0..1], 0x40_3000) catch return 13;
    if (buf[0] != 0x77) return 14;
    if (!writeFaults(0x40_3000, 8) or readonly[0] != 0x77) return 15;
    // Starting in the read-only page and running off its end fails as well.
    if (!writeFaults(0x40_3FF8, 16)) return 16;

    // Kernel pointers, the end of user space, and address + length overflow
    // are rejected before any memory is touched.
    if (!readFaults(@intFromPtr(&buf), 8) or !writeFaults(@intFromPtr(&buf), 8)) return 17;
    if (!readFaults(0xFFFF_8000_0000_0000, 8) or !readFaults(end, 1)) return 18;
    if (!readFaults(end - 4, 8) or !writeFaults(end - 4, 8)) return 19;
    if (!readFaults(std.math.maxInt(u64) - 3, 8) or !writeFaults(std.math.maxInt(u64) - 3, 8)) return 20;
    if (!readFaults(0x8000_0000_0000 + 0x1000, 8)) return 21; // non-canonical

    // Empty copies succeed without touching memory, even at unmapped addresses.
    uaccess.copyFromUser(buf[0..0], 0x40_2000) catch return 22;
    uaccess.copyToUser(end, buf[0..0]) catch return 23;

    // The user-access window is closed again after successful and failed copies.
    if (cpu.readFlags() & (1 << 18) != 0) return 24; // RFLAGS.AC
    return 0;
}

/// True if write protection in ring 0, UMIP, SMEP and SMAP are all switched
/// on, both in the kernel's bookkeeping and in the control registers.
pub fn userProtectionOn() bool {
    const cr4 = cpu.readCr4();
    return usercopy.umip_enabled and usercopy.smep_enabled and usercopy.smapEnabled() and
        cr4 & (1 << 11) != 0 and cr4 & (1 << 20) != 0 and cr4 & (1 << 21) != 0 and
        cpu.readCr0() & (1 << 16) != 0;
}

const RFLAGS_AC: u64 = 1 << 18;
/// A vector no device uses, for `acClearedOnKernelEntry`.
const AC_TEST_VECTOR = 0xF0;
var ac_seen_in_handler: ?bool = null;

/// Interrupt handler for `acClearedOnKernelEntry`: record RFLAGS.AC.
fn acProbe(_: *idt.Frame) void {
    ac_seen_in_handler = cpu.readFlags() & RFLAGS_AC != 0;
}

/// Check that SMAP's user-access override (RFLAGS.AC) cannot leak into the
/// kernel: an interrupt taken while AC is set runs its handler with AC clear
/// and gives the interrupted code its AC back, and the `syscall` flag mask
/// clears AC on entry. Returns 0, or the number of the first failing check.
pub fn acClearedOnKernelEntry() u32 {
    if (!usercopy.smapEnabled()) return 1; // `stac` would be an invalid opcode
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    ac_seen_in_handler = null;
    idt.register(AC_TEST_VECTOR, acProbe);
    asm volatile (
        \\ .byte 0x0f, 0x01, 0xcb   # stac
        \\ int $0xF0
    );
    const ac_after = cpu.readFlags() & RFLAGS_AC != 0;
    asm volatile (".byte 0x0f, 0x01, 0xca"); // clac
    const seen = ac_seen_in_handler orelse return 2; // the handler never ran
    if (seen) return 3; // the handler ran with user access allowed
    if (!ac_after) return 4; // the interrupted code lost its AC
    if (cpu.readFlags() & RFLAGS_AC != 0) return 5;
    if (cpu.rdmsr(0xC0000084) & RFLAGS_AC == 0) return 6; // SFMASK must clear AC on syscall
    return 0;
}

/// A vector no device uses, for `emergencyStacks`.
const IST_TEST_VECTOR = 0xF1;
var ist_probe_frame: u64 = 0;

/// Interrupt handler for `emergencyStacks`: record where the CPU pushed the
/// interrupt frame, which tells which stack the handler runs on.
fn istProbe(f: *idt.Frame) void {
    ist_probe_frame = @intFromPtr(f);
}

/// True if `addr` lies in the emergency stack with IST index `index`.
fn onIstStack(index: u3, addr: u64) bool {
    const stack = gdt.istStack(index);
    const low = @intFromPtr(stack.ptr);
    return addr >= low and addr < low + stack.len;
}

/// Raise `IST_TEST_VECTOR` with its gate set to IST index `ist` and return
/// the address of the frame its handler saw (0 if the handler never ran).
fn istProbeFrame(ist: u3) u64 {
    ist_probe_frame = 0;
    idt.setGateIst(IST_TEST_VECTOR, ist);
    asm volatile ("int $0xF1");
    idt.setGateIst(IST_TEST_VECTOR, 0);
    return ist_probe_frame;
}

/// Check the emergency stacks: the double-fault, NMI, debug and
/// machine-check gates name their own IST entries, the TSS points those at
/// the ends of four separate, 16-byte aligned stacks, no other exception
/// uses an IST stack, and the CPU really switches to each such stack (and
/// back) when a gate asks for it. Returns 0, or the number of the first
/// failing check.
pub fn emergencyStacks() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);

    // Vector and the IST index its gate must name.
    const gates = [_]struct { vector: u8, ist: u3 }{
        .{ .vector = 8, .ist = gdt.IST_DOUBLE_FAULT },
        .{ .vector = 2, .ist = gdt.IST_NMI },
        .{ .vector = 1, .ist = gdt.IST_DEBUG },
        .{ .vector = 18, .ist = gdt.IST_MACHINE_CHECK },
    };
    for (gates) |g| {
        if (idt.gateIst(g.vector) != g.ist) return 1;
    }
    vectors: for (0..256) |vec| {
        for (gates) |g| {
            if (g.vector == vec) continue :vectors;
        }
        if (idt.gateIst(@intCast(vec)) != 0) return 2;
    }

    // Each index has a stack of its own; the TSS points at its aligned end.
    for (gdt.IST_INDEXES, 0..) |index, n| {
        const stack = gdt.istStack(index);
        const low = @intFromPtr(stack.ptr);
        if (gdt.istTop(index) != low + stack.len or gdt.istTop(index) % 16 != 0) return 3;
        for (gdt.IST_INDEXES[n + 1 ..]) |other_index| {
            const other = gdt.istStack(other_index);
            const other_low = @intFromPtr(other.ptr);
            if (low < other_low + other.len and other_low < low + stack.len) return 4; // they overlap
        }
    }
    used: for (1..8) |index| {
        for (gdt.IST_INDEXES) |in_use| {
            if (in_use == index) continue :used;
        }
        if (gdt.istTop(@intCast(index)) != 0) return 5;
    }

    idt.register(IST_TEST_VECTOR, istProbe);
    const plain = istProbeFrame(0);
    if (plain == 0) return 6; // the handler never ran
    for (gdt.IST_INDEXES) |index| {
        if (onIstStack(index, plain)) return 7;
        if (!onIstStack(index, istProbeFrame(index))) return 10 + @as(u32, index);
    }
    // Back on the thread's own stack: a local is not on an emergency stack.
    var here: u8 = 0;
    const here_addr = @intFromPtr(&here);
    here = 1;
    for (gdt.IST_INDEXES) |index| {
        if (onIstStack(index, here_addr)) return 8;
    }
    return 0;
}

/// True if `addr` is mapped in the kernel's page tables.
fn kernelMapped(addr: u64) bool {
    return vmm.translate(vmm.kernel_root, addr) != null;
}

/// Check the kernel stack allocator: a stack is `STACK_SIZE` bytes of
/// writable, non-executable pages with an unmapped guard page right below
/// it; two stacks never touch; freeing unmaps the pages, returns them to the
/// PMM and releases the slot for reuse; and the current thread (the boot
/// thread included) runs on such a stack. Returns 0, or the number of the
/// first failing check.
pub fn kernelStacks() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);

    // The page tables of the first slots exist by now, so pages balance exactly.
    const pages = pmm.free_pages;
    const in_use = kstack.inUse();

    const a = kstack.alloc() orelse return 1;
    const b = kstack.alloc() orelse return 2;
    const a_low = @intFromPtr(a.ptr);
    const b_low = @intFromPtr(b.ptr);
    if (a.len != kstack.STACK_SIZE or a_low % pmm.PAGE_SIZE != 0) return 3;
    if (!kstack.owns(a) or !kstack.owns(b)) return 4;
    if (kstack.inUse() != in_use + 2) return 5;
    if (pmm.free_pages != pages - 2 * kstack.STACK_PAGES) return 6;

    // Guard pages: unmapped below each stack, and recognized as guards.
    if (kernelMapped(a_low - 1) or kernelMapped(b_low - 1)) return 7;
    if (!kstack.isGuard(a_low - 1) or !kstack.isGuard(a_low - pmm.PAGE_SIZE)) return 8;
    if (kstack.isGuard(a_low) or kstack.isGuard(a_low + a.len - 1)) return 9;
    if (kstack.isGuard(@intFromPtr(&kernelStacks)) or kstack.isGuard(0)) return 10;
    // The stacks do not overlap and a guard page lies between them.
    const lower = @min(a_low, b_low);
    const upper = @max(a_low, b_low);
    if (upper < lower + kstack.STACK_SIZE + pmm.PAGE_SIZE) return 11;

    // Every page is mapped writable and not executable, to distinct frames.
    var frames: [kstack.STACK_PAGES]u64 = undefined;
    for (0..kstack.STACK_PAGES) |i| {
        const virt = a_low + i * pmm.PAGE_SIZE;
        const e = vmm.leafEntry(vmm.kernel_root, virt) orelse return 12;
        if (e & vmm.WRITABLE == 0 or e & vmm.NX == 0 or e & vmm.USER != 0) return 13;
        frames[i] = vmm.translate(vmm.kernel_root, virt).?;
        for (frames[0..i]) |other| if (other == frames[i]) return 14;
    }
    @memset(a, 0xA5); // the whole stack is usable
    @memset(b, 0x5A);
    if (a[0] != 0xA5 or a[a.len - 1] != 0xA5 or b[0] != 0x5A) return 15;

    // Freeing unmaps everything and gives pages and slot back.
    kstack.free(a);
    if (kernelMapped(a_low) or kernelMapped(a_low + a.len - 1)) return 16;
    if (kstack.inUse() != in_use + 1 or pmm.free_pages != pages - kstack.STACK_PAGES) return 17;
    const again = kstack.alloc() orelse return 18;
    if (@intFromPtr(again.ptr) != a_low) return 19; // the slot is reused
    again[0] = 1; // and its new pages are reachable (no stale TLB entry)
    kstack.free(again);
    kstack.free(b);
    if (kstack.inUse() != in_use or pmm.free_pages != pages) return 20;

    // This thread runs on a kernel stack from the allocator.
    const mine = thread.current().stack orelse return 21;
    if (!kstack.owns(mine)) return 22;
    var here: u8 = 0;
    const here_addr = @intFromPtr(&here);
    here = 1;
    if (here_addr < @intFromPtr(mine.ptr) or here_addr >= @intFromPtr(mine.ptr) + mine.len) return 23;
    return 0;
}

/// Use at least `bytes` of stack, write to all of it and return the lowest
/// address written. The buffer's address escapes, so the optimizer has to
/// keep it on the stack.
noinline fn touchStack(comptime bytes: usize) usize {
    var pad: [bytes]u8 = undefined;
    @memset(&pad, 0xEE);
    std.mem.doNotOptimizeAway(&pad);
    return @intFromPtr(&pad);
}

// State of the stack usage test's worker thread.
var usage_needed: ?usize = null;
var usage_measured: ?usize = null;
var usage_done: usize = 0;

/// Stack usage test worker: write to 1 KiB of stack and compare the measured
/// usage with how deep that write really was. Nothing is assumed about how
/// much of the stack was used before: a timer interrupt may already have run
/// on it before this function turned interrupts off.
fn stackUsageWorker() void {
    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    const mine = thread.current().stack.?;
    const lowest = touchStack(1024);
    usage_needed = @intFromPtr(mine.ptr) + mine.len - lowest;
    usage_measured = kstack.used(mine);
    signalDone(&usage_done, &done_queue);
}

/// Check the stack high-water mark: a fresh stack counts as unused, writing
/// to it is measured from the top, a thread's usage covers the deepest
/// address it wrote to, exited threads are recorded when reaped, and nothing in this test
/// run has come close to filling its stack. Returns 0, or the number of the
/// first failing check.
pub fn stackUsage() u32 {
    if (!kstack.track_usage) return 1; // the test kernel always measures
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);

    // A fresh stack is unused; usage is the distance from the top to the lowest write.
    const s = kstack.alloc() orelse return 2;
    if (kstack.used(s) != 0) return 3;
    s[s.len - 8] = 0;
    if (kstack.used(s) != 8) return 4;
    s[s.len - 1000] = 0;
    if (kstack.used(s) != 1000) return 5;
    s[0] = 0;
    if (kstack.used(s) != kstack.STACK_SIZE) return 6;
    kstack.free(s);
    const again = kstack.alloc() orelse return 7; // a reused slot starts clean
    if (kstack.used(again) != 0) return 8;
    kstack.free(again);

    // A thread's usage is at least as deep as the lowest address it wrote to.
    usage_needed = null;
    usage_measured = null;
    usage_done = 0;
    _ = thread.spawn(stackUsageWorker, null) catch return 9;
    waitForDone(&usage_done, 1, &done_queue);
    const needed = usage_needed orelse return 10;
    const measured = usage_measured orelse return 11;
    if (needed < 1024 or measured < needed or measured > kstack.STACK_SIZE) return 12;
    // The worker has exited and was reaped when this thread was switched
    // back to, which recorded its usage.
    thread.yield();
    if (kstack.peak() < measured) return 13;

    // This thread's own usage is plausible and can be recorded.
    const mine = thread.recordStackUsage() orelse return 14;
    if (mine == 0 or mine > kstack.STACK_SIZE) return 15;
    if (kstack.peak() < mine) return 16;
    return 0;
}

/// Record the current (boot) thread's stack usage and return the largest
/// usage any thread has had in this run, for the end-of-run report.
pub fn stackPeak() usize {
    _ = thread.recordStackUsage();
    return kstack.peak();
}

/// Recurse without end, using some stack in every call. `noinline` and the
/// volatile buffer keep the optimizer from turning it into a loop.
noinline fn recurseForever(depth: usize) usize {
    var pad: [128]u8 = undefined;
    const p: *volatile [128]u8 = &pad;
    p[depth % pad.len] = @truncate(depth);
    return recurseForever(depth + 1) + p[0];
}

/// Thread body for the `stack_overflow` scenario.
fn stackOverflowThread() void {
    _ = cpu.saveAndDisableInterrupts();
    _ = recurseForever(0);
}

/// For the `stack_overflow` scenario: overflow the kernel stack of a thread
/// with unbounded recursion. Returns only if the thread could not be started.
pub fn overflowStackInThread() void {
    _ = thread.spawn(stackOverflowThread, null) catch return;
    for (0..100) |_| thread.yield();
}

/// Thread body for the `double_fault` scenario: point RSP at unmapped kernel
/// memory and push. The page fault cannot be delivered on that stack, so the
/// CPU raises a double fault. This is what a kernel stack overflow into a
/// guard page looks like.
fn doubleFaultThread() void {
    _ = cpu.saveAndDisableInterrupts();
    asm volatile (
        \\ movabs $0xFFFFB00000001000, %%rsp
        \\ push %%rax
    );
}

/// For the `double_fault` scenario: run `doubleFaultThread` in a kernel
/// thread of its own, so the report can compare RSP with a thread stack.
/// Returns only if the thread could not be started or survived.
pub fn doubleFaultInThread() void {
    _ = thread.spawn(doubleFaultThread, null) catch return;
    for (0..100) |_| thread.yield();
}

// State shared by the PMM stress workers.
var pmm_stress_done: usize = 0;
var pmm_stress_errors: usize = 0;
var pmm_stress_next_tag: u64 = 1;

/// PMM stress worker: with interrupts on (so the timer preempts it), keep
/// allocating a batch of pages, stamping each with this worker's tag, and
/// checking that every stamp is still there before freeing the batch. A page
/// handed to both workers shows up as a foreign stamp or a duplicate.
fn pmmStressWorker() void {
    const tag = blk: {
        const held = test_lock.acquire();
        defer test_lock.release(held);
        pmm_stress_next_tag += 1;
        break :blk pmm_stress_next_tag - 1;
    };

    var pages: [32]u64 = undefined;
    var errors: usize = 0;
    for (0..1500) |round| {
        var n: usize = 0;
        while (n < pages.len) : (n += 1) {
            const p = pmm.alloc() orelse break;
            for (pages[0..n]) |other| {
                if (other == p) errors += 1;
            }
            const word: *volatile u64 = @ptrCast(@alignCast(pmm.physToVirt(p)));
            word.* = (tag << 32) | round;
            pages[n] = p;
        }
        for (pages[0..n]) |p| {
            const word: *volatile u64 = @ptrCast(@alignCast(pmm.physToVirt(p)));
            if (word.* != (tag << 32) | round) errors += 1;
            pmm.free(p);
        }
    }

    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    {
        const held = test_lock.acquire();
        defer test_lock.release(held);
        pmm_stress_errors += errors;
    }
    signalDone(&pmm_stress_done, &done_queue);
}

/// Run two preemptible kernel threads that allocate and free pages at the
/// same time. Returns true if no page was ever handed out twice and the free
/// count is back where it started.
pub fn pmmConcurrentStress() bool {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const before = pmm.free_pages;
    pmm_stress_done = 0;
    pmm_stress_errors = 0;
    _ = thread.spawn(pmmStressWorker, null) catch return false;
    _ = thread.spawn(pmmStressWorker, null) catch return false;
    waitForDone(&pmm_stress_done, 2, &done_queue);
    return pmm_stress_errors == 0 and pmm.free_pages == before and pmm.consistent();
}

/// For the `smap` and `smep` scenarios: switch to a new address space with
/// one user-accessible, writable, executable page at `USER_PAGE` that holds a
/// single `ret` instruction. Interrupts stay off so the scheduler keeps this
/// address space loaded. Returns false if memory ran out.
pub fn enterUserPageSpace() bool {
    _ = cpu.saveAndDisableInterrupts();
    const root = vmm.createAddressSpace() catch return false;
    const phys = mapUserPage(root, USER_PAGE, vmm.USER | vmm.WRITABLE) orelse return false;
    pmm.physToVirt(phys)[0] = 0xC3; // ret
    vmm.loadRoot(root);
    return true;
}

// ---------------------------------------------------------------------------
// Syscall and context-switch correctness (roadmap 2.5)

// State shared by `runPair` and its two runner threads.
var pair_path: []const u8 = "";
var pair_codes: [2]?u64 = .{ null, null };
var pair_done: usize = 0;

/// Runner thread `index`: run the program and report its exit status.
fn pairRunner(index: usize) void {
    const code = runProgram(pair_path);
    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    pair_codes[index] = code;
    signalDone(&pair_done, &done_queue);
}

fn pairRunnerA() void {
    pairRunner(0);
}

fn pairRunnerB() void {
    pairRunner(1);
}

/// Run two copies of the program at `path` at the same time, each started
/// by a kernel thread of its own, and wait for both. Returns true if both
/// exited with status 0.
pub fn runPair(path: []const u8) bool {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    pair_path = path;
    pair_codes = .{ null, null };
    pair_done = 0;
    _ = thread.spawn(pairRunnerA, null) catch return false;
    _ = thread.spawn(pairRunnerB, null) catch return false;
    waitForDone(&pair_done, 2, &done_queue);
    return pair_codes[0] == 0 and pair_codes[1] == 0;
}

const RFLAGS_IF: u64 = 1 << 9;
const RFLAGS_DF: u64 = 1 << 10;

/// Test-only syscall numbers handled by `syscallProbe`; must match
/// `tests/user/bad_return.zig`.
const SYS_VIA_IRET = abi.Sys.PRIVATE_BASE + 0x100;
const SYS_BAD_FLAGS = abi.Sys.PRIVATE_BASE + 0x101;
const SYS_BAD_STATE = abi.Sys.PRIVATE_BASE + 0x102;

/// What `SYS_BAD_STATE` does to the saved state.
pub const BadState = enum {
    /// Return address in the non-canonical hole.
    noncanonical_rip,
    /// Return address in kernel memory.
    kernel_rip,
    /// Kernel code selector: a return to ring 0.
    kernel_cs,
    /// Kernel stack selector.
    kernel_ss,
};

/// What the probes saw. Cleared by `installProbes`.
pub const Probes = struct {
    /// Syscalls that went through `syscallProbe`.
    syscalls: usize = 0,
    /// Timer interrupts that arrived in ring 3.
    user_ticks: usize = 0,
    /// Timer interrupts that arrived in ring 0 on a process's thread: in
    /// the middle of a syscall.
    syscall_ticks: usize = 0,
    /// `SYS_VIA_IRET` calls, each of which must return through `iretq`.
    via_iret: usize = 0,
    /// Number of the first invariant that did not hold; 0 if all did.
    violation: u32 = 0,
};

pub var probes: Probes = .{};
var bad_state: BadState = .noncanonical_rip;
var real_syscall_handler: ?arch_syscall.Handler = null;
var real_tick_handler: ?idt.Handler = null;

/// Record the first violated invariant.
fn violated(number: u32) void {
    if (probes.violation == 0) probes.violation = number;
}

/// Invariants that hold whenever the kernel runs on behalf of a process:
/// the GS base is the per-CPU area (and the user's value is parked), the
/// process's address space is loaded, and both ways into the kernel from
/// ring 3 lead to the top of this thread's kernel stack.
fn checkKernelState(base: u32) void {
    const t = thread.current();
    const p = t.process orelse return violated(base + 1);
    const stack = t.stack orelse return violated(base + 2);
    const top = @intFromPtr(stack.ptr) + stack.len;
    const gs = cpu.rdmsr(percpu.MSR_GS_BASE);
    if (gs != @intFromPtr(percpu.current()) or gs >> 63 == 0) violated(base + 3);
    if (cpu.rdmsr(percpu.MSR_KERNEL_GS_BASE) != 0) violated(base + 4);
    if (percpu.current().kernel_rsp != top) violated(base + 5);
    if (gdt.kernelStack() != top) violated(base + 6);
    if (cpu.readCr3() & ~@as(u64, 0xFFF) != p.root) violated(base + 7);
    const rsp = @frameAddress();
    if (rsp < @intFromPtr(stack.ptr) or rsp >= top) violated(base + 8);
}

/// Syscall handler installed by `installProbes`: check the state every
/// syscall starts and ends in, serve the test-only numbers, and pass
/// everything else to the real handler.
fn syscallProbe(f: *arch_syscall.Frame) void {
    probes.syscalls += 1;
    const t = thread.current();
    const flags = cpu.readFlags();
    // Interrupts are on while a syscall runs; the flags a program could
    // have set to confuse the kernel are off.
    if (flags & RFLAGS_IF == 0) violated(1);
    if (flags & (RFLAGS_AC | RFLAGS_DF) != 0) violated(2);
    // The frame is the first thing on this thread's kernel stack, aligned.
    if (t.stack) |stack| {
        if (@intFromPtr(f) + @sizeOf(arch_syscall.Frame) != @intFromPtr(stack.ptr) + stack.len) violated(3);
    }
    if (@intFromPtr(f) % 16 != 0) violated(4);
    // The saved state is a ring 3 state with interrupts on.
    if (f.cs != gdt.USER_CODE or f.ss != gdt.USER_DATA) violated(5);
    if (f.rflags & RFLAGS_IF == 0 or f.rip >= vmm.USER_END) violated(6);
    checkKernelState(10);

    switch (f.rax) {
        SYS_VIA_IRET => {
            probes.via_iret += 1;
            f.rax = 0x1234;
            f.rflags |= 1 << 16; // RF: sysretq cannot restore it
        },
        SYS_BAD_FLAGS => {
            f.rax = 0x1234;
            f.rflags = (f.rflags & ~RFLAGS_IF) | 0x3000 | 0x4000; // IOPL 3, NT, interrupts off
        },
        SYS_BAD_STATE => switch (bad_state) {
            .noncanonical_rip => f.rip = 0x0000_8000_0000_0000,
            .kernel_rip => f.rip = @intFromPtr(&syscallProbe),
            .kernel_cs => f.cs = gdt.KERNEL_CODE,
            .kernel_ss => f.ss = gdt.KERNEL_DATA,
        },
        else => {
            real_syscall_handler.?(f);
            // Whatever the syscall did (block, switch threads, fail), it
            // comes back with interrupts on and the same kernel state.
            if (cpu.readFlags() & RFLAGS_IF == 0) violated(20);
            checkKernelState(30);
        },
    }
}

/// Timer handler installed by `installProbes`: check where the interrupt
/// frame is and which address space is loaded, then run the real handler
/// (which may switch threads).
fn tickProbe(f: *idt.Frame) void {
    const t = thread.current();
    if (cpu.readFlags() & RFLAGS_IF != 0) violated(40); // interrupt gates mask interrupts
    if (f.cs & 3 == 3) {
        probes.user_ticks += 1;
        // From ring 3 the CPU switched to the top of the thread's kernel stack.
        if (t.stack) |stack| {
            if (@intFromPtr(f) + @sizeOf(idt.Frame) != @intFromPtr(stack.ptr) + stack.len) violated(41);
        }
        if (f.rflags & RFLAGS_IF == 0) violated(42);
        checkKernelState(50);
    } else if (t.process != null) {
        probes.syscall_ticks += 1;
        // From ring 0 there is no stack switch: the frame is on the stack
        // the syscall was using, and the kernel state is already set up.
        if (t.stack) |stack| {
            const at = @intFromPtr(f);
            if (at < @intFromPtr(stack.ptr) or at >= @intFromPtr(stack.ptr) + stack.len) violated(43);
        }
        checkKernelState(60);
    }
    real_tick_handler.?(f);
}

/// Route syscalls and timer interrupts through the probes, with `state` as
/// what `SYS_BAD_STATE` does, and clear `probes`.
pub fn installProbes(state: BadState) void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    probes = .{};
    bad_state = state;
    if (real_syscall_handler == null) real_syscall_handler = arch_syscall.setHandler(syscallProbe);
    if (real_tick_handler == null) {
        real_tick_handler = idt.registered(apic.TIMER_VECTOR);
        idt.register(apic.TIMER_VECTOR, tickProbe);
    }
}

/// Put the real syscall and timer handlers back.
pub fn removeProbes() void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    if (real_syscall_handler) |h| _ = arch_syscall.setHandler(h);
    if (real_tick_handler) |h| idt.register(apic.TIMER_VECTOR, h);
    real_syscall_handler = null;
    real_tick_handler = null;
}

/// Check the GS bases as seen from a kernel thread: the active one is this
/// CPU's per-CPU area (whose first field points at itself), the parked one
/// is the user's (0). Returns 0, or the number of the first failing check.
pub fn gsBases() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const gs = cpu.rdmsr(percpu.MSR_GS_BASE);
    if (gs >> 63 == 0) return 1; // not a kernel address
    if (gs != @intFromPtr(percpu.current())) return 2;
    if (percpu.current().self != percpu.current()) return 3;
    if (cpu.rdmsr(percpu.MSR_KERNEL_GS_BASE) != 0) return 4;
    const t = thread.current();
    const stack = t.stack orelse return 5;
    if (percpu.current().kernel_rsp != @intFromPtr(stack.ptr) + stack.len) return 6;
    return 0;
}

/// Check how extended CPU state is set up: the control-register bits, the
/// mechanism (`want_xsave` says which one this CPU should get) and the save
/// area. Returns 0, or the number of the first failing check.
pub fn extendedStateSetup(want_xsave: bool) u32 {
    const cr0 = cpu.readCr0();
    const cr4 = cpu.readCr4();
    if (cr0 & (1 << 2) != 0 or cr0 & (1 << 3) != 0) return 1; // EM, TS: would trap SSE
    if (cr0 & (1 << 1) == 0 or cr0 & (1 << 5) == 0) return 2; // MP, NE
    if (cr4 & (1 << 9) == 0 or cr4 & (1 << 10) == 0) return 3; // OSFXSR, OSXMMEXCPT
    const leaf1 = cpu.cpuid(1, 0);
    const cpu_xsave = leaf1.ecx & (1 << 26) != 0;
    if (cpu_xsave != want_xsave) return 4; // QEMU was not started as the scenario expects
    if ((fpu.currentMode() == .xsave) != want_xsave) return 5;
    if ((cr4 & (1 << 18) != 0) != want_xsave) return 6; // OSXSAVE
    if (want_xsave) {
        const cpu_avx = leaf1.ecx & (1 << 28) != 0;
        if (fpu.avxEnabled() != cpu_avx) return 7;
        if (fpu.enabledFeatures() != @as(u64, if (cpu_avx) 7 else 3)) return 8;
        if (fpu.areaSize() != cpu.cpuid(0xD, 0).ebx) return 9;
        if (cpu_avx and fpu.areaSize() != 832) return 10;
    } else {
        if (fpu.avxEnabled() or fpu.areaSize() != 512) return 11;
    }
    if (fpu.areaSize() > fpu.MAX_AREA_SIZE) return 12;
    // Kernel threads carry no saved state.
    if (thread.current().fpuArea() != null) return 13;
    return 0;
}

/// The syscalls that returned through `iretq` since boot.
pub fn iretReturns() usize {
    return arch_syscall.iret_returns;
}

// What `debugProbe` saw.
var debug_probe_runs: usize = 0;
var debug_probe_gs: u64 = 0;
var debug_probe_frame: u64 = 0;

/// Debug-exception handler for `debugTrapEntry`: record the GS base the
/// handler runs with and where the CPU pushed the frame.
fn debugProbe(f: *idt.Frame) void {
    debug_probe_runs += 1;
    debug_probe_gs = cpu.rdmsr(percpu.MSR_GS_BASE);
    debug_probe_frame = @intFromPtr(f);
}

/// Raise a debug exception in ring 0 and return the GS base seen right
/// after it returns. With `user_gs` the exception is raised while the
/// user's GS base is loaded, as at the first instruction of `syscall_entry`.
fn raiseDebug(user_gs: bool) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    if (user_gs) {
        asm volatile (
            \\ swapgs
            \\ int $1
            \\ mov $0xC0000101, %%ecx
            \\ rdmsr
            \\ swapgs
            : [lo] "={eax}" (lo),
              [hi] "={edx}" (hi),
            :
            : .{ .rcx = true, .memory = true });
    } else {
        asm volatile (
            \\ int $1
            \\ mov $0xC0000101, %%ecx
            \\ rdmsr
            : [lo] "={eax}" (lo),
              [hi] "={edx}" (hi),
            :
            : .{ .rcx = true, .memory = true });
    }
    return @as(u64, hi) << 32 | lo;
}

/// Check the entry path of debug exceptions (shared with NMIs, double
/// faults and machine checks, which cannot be raised and returned from): the
/// handler runs on the debug emergency stack with the kernel's GS base
/// whichever base was loaded when the exception hit, and the interrupted
/// code gets its own base back. Returns 0, or the number of the first
/// failing check.
pub fn debugTrapEntry() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const kernel_gs = @intFromPtr(percpu.current());
    const before = idt.registered(1);
    idt.register(1, debugProbe);
    defer idt.setHandler(1, before);
    debug_probe_runs = 0;

    // With the kernel's GS base: nothing to switch.
    if (raiseDebug(false) != kernel_gs) return 1;
    if (debug_probe_runs != 1) return 2;
    if (debug_probe_gs != kernel_gs) return 3;
    if (!onIstStack(gdt.IST_DEBUG, debug_probe_frame)) return 4;

    // With the user's GS base, in ring 0: the saved CS says "kernel", and
    // only the GS base itself shows that it must be switched.
    const after = raiseDebug(true);
    if (debug_probe_runs != 2) return 5;
    if (debug_probe_gs != kernel_gs) return 6; // the handler ran with the user's base
    if (after != 0) return 7; // the interrupted code did not get the user's base back
    if (!onIstStack(gdt.IST_DEBUG, debug_probe_frame)) return 8;
    if (cpu.rdmsr(percpu.MSR_GS_BASE) != kernel_gs or cpu.rdmsr(percpu.MSR_KERNEL_GS_BASE) != 0) return 9;
    return 0;
}

// ---------------------------------------------------------------------------
// Memory-management correctness (roadmap 2.6)

/// Check that the physical allocator refuses every free that is not of an
/// allocated page, and that a refusal changes nothing. Returns 0, or the
/// number of the first failing check.
pub fn pmmRejectsBadFrees() u32 {
    const before = pmm.free_pages;
    const page = pmm.alloc() orelse return 1;

    // Not the start of a page.
    if (pmm.tryFree(page + 1) != error.Misaligned) return 2;
    if (pmm.tryFree(page + 0x800) != error.Misaligned) return 3;
    if (pmm.tryFree(page + pmm.PAGE_SIZE - 1) != error.Misaligned) return 4;
    // Beyond the memory the machine has.
    const beyond = @as(u64, pmm.totalPages()) * pmm.PAGE_SIZE;
    if (pmm.tryFree(beyond) != error.OutOfRange) return 5;
    if (pmm.tryFree(0x0000_7FFF_FFFF_F000) != error.OutOfRange) return 6;
    if (pmm.tryFree(0xFFFF_FFFF_FFFF_F000) != error.OutOfRange) return 7;
    // Memory the allocator never hands out: page 0 and the legacy video
    // hole, which is device memory on every PC.
    if (pmm.tryFree(0) != error.NotManaged) return 8;
    if (pmm.tryFree(0xA_0000) != error.NotManaged) return 9;
    if (pmm.isAllocated(0) or pmm.isAllocated(0xA_0000)) return 10;
    // All of that left the page allocated and the count alone.
    if (!pmm.isAllocated(page) or pmm.free_pages != before - 1) return 11;

    // The real free works once...
    pmm.tryFree(page) catch return 12;
    if (pmm.isAllocated(page) or pmm.free_pages != before) return 13;
    // ...and only once.
    if (pmm.tryFree(page) != error.NotAllocated) return 14;
    if (pmm.free_pages != before) return 15;
    // A page that was never handed out is not allocated either: the next
    // allocation returns the lowest free page at or after the hint, so the
    // page just freed comes back, and it is usable.
    const again = pmm.alloc() orelse return 16;
    pmm.free(again);
    if (pmm.free_pages != before or !pmm.consistent()) return 17;
    return 0;
}

// Pages taken by `drainMemory`, chained through their first word.
var drained_head: u64 = 0;
var drained_count: usize = 0;

/// Allocate physical pages until only `leave` are free, and keep them until
/// `releaseDrained`. Returns the number of free pages afterwards.
pub fn drainMemory(leave: usize) usize {
    while (pmm.free_pages > leave) {
        const page = pmm.alloc() orelse break;
        const link: *u64 = @ptrCast(@alignCast(pmm.physToVirt(page)));
        link.* = drained_head;
        drained_head = page;
        drained_count += 1;
    }
    return pmm.free_pages;
}

/// Give `count` of the drained pages back (all of them if there are fewer).
pub fn releaseSome(count: usize) void {
    var n: usize = 0;
    while (n < count and drained_head != 0) : (n += 1) {
        const page = drained_head;
        const link: *u64 = @ptrCast(@alignCast(pmm.physToVirt(page)));
        drained_head = link.*;
        drained_count -= 1;
        pmm.free(page);
    }
}

/// Give every drained page back.
pub fn releaseDrained() void {
    releaseSome(drained_count);
}

/// Everything the kernel holds on to, in one comparable value: memory that
/// is neither free nor part of the heap's pool, heap bytes in use, and
/// kernel stacks. The heap keeps pages it has grown by, so free pages alone
/// go down the first time something large is allocated.
pub const Footprint = struct {
    pages: usize,
    heap_bytes: usize,
    stacks: usize,

    pub fn eql(a: Footprint, b: Footprint) bool {
        return a.pages == b.pages and a.heap_bytes == b.heap_bytes and a.stacks == b.stacks;
    }
};

pub fn footprint() Footprint {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const h = heap.stats();
    return .{
        // Free pages, plus what the heap holds and the page tables the
        // kernel has added to map its own memory: the heap grows on demand
        // and keeps what it got, tables included, so neither is a leak.
        .pages = pmm.free_pages + h.bytes_mapped / pmm.PAGE_SIZE + vmm.kernelTablePages(),
        .heap_bytes = h.bytes_in_use,
        .stacks = kstack.inUse(),
    };
}

const VM_A: u64 = 0x40_0000;
/// 2 MiB above `VM_A`: another page table under the same page directory.
const VM_B: u64 = VM_A + 0x20_0000;
/// In another PML4 slot: nothing shared with `VM_A` below the root.
const VM_FAR: u64 = 0x7000_0000_0000;
/// A kernel address nothing uses, in a PML4 slot of its own.
const VM_KERNEL: u64 = 0xFFFF_B800_0000_0000;
const USER_RW = vmm.USER | vmm.WRITABLE | vmm.NX;

/// Check that `map` refuses to replace a mapping, of either page size, and
/// leaves the existing one and the free-page count alone. Returns 0, or
/// the number of the first failing check.
pub fn vmmMapConflicts() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const start = pmm.free_pages;
    const root = vmm.createAddressSpace() catch return 1;
    const p1 = pmm.alloc() orelse return 2;
    const p2 = pmm.alloc() orelse return 3;

    vmm.map(root, VM_A, p1, USER_RW, false) catch return 4;
    const pte = vmm.leafEntry(root, VM_A) orelse return 5;
    const mapped = pmm.free_pages;
    // A second mapping of the same address, with other flags or not.
    if (vmm.map(root, VM_A, p2, USER_RW, false) != error.AlreadyMapped) return 6;
    if (vmm.map(root, VM_A, p2, vmm.USER, false) != error.AlreadyMapped) return 7;
    if (vmm.map(root, VM_A, p1, USER_RW, false) != error.AlreadyMapped) return 8;
    if (vmm.leafEntry(root, VM_A) != pte or vmm.translate(root, VM_A) != p1) return 9;
    if (pmm.free_pages != mapped) return 10;
    // A 2 MiB page where a table of 4 KiB pages already is.
    if (vmm.map(root, VM_A, 0x20_0000, USER_RW, true) != error.AlreadyMapped) return 11;
    if (vmm.translate(root, VM_A) != p1 or pmm.free_pages != mapped) return 12;
    // A 4 KiB page inside a 2 MiB page: the direct map of physical memory.
    const hhdm_page = @intFromPtr(pmm.physToVirt(0x20_0000));
    const hhdm_before = vmm.leafEntry(vmm.kernel_root, hhdm_page);
    if (vmm.map(vmm.kernel_root, hhdm_page, p2, vmm.WRITABLE | vmm.NX, false) != error.AlreadyMapped) return 13;
    if (vmm.leafEntry(vmm.kernel_root, hhdm_page) != hhdm_before or pmm.free_pages != mapped) return 14;
    // The neighbouring page is free to map.
    vmm.map(root, VM_A + pmm.PAGE_SIZE, p2, USER_RW, false) catch return 15;
    if (vmm.translate(root, VM_A + pmm.PAGE_SIZE) != p2 or vmm.translate(root, VM_A) != p1) return 16;

    vmm.destroyAddressSpace(root); // frees p1 and p2 with the tables
    return if (pmm.free_pages == start and pmm.consistent()) 0 else 17;
}

/// Check `unmap`: the translation goes away, the page comes back to the
/// caller, page tables that became empty are freed (and only those), and
/// the shared kernel tables stay. Returns 0, or the number of the first
/// failing check.
pub fn vmmUnmap() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const start = pmm.free_pages;
    const root = vmm.createAddressSpace() catch return 1;
    const p1 = pmm.alloc() orelse return 2;
    const p2 = pmm.alloc() orelse return 3;
    const empty = pmm.free_pages; // an address space with nothing mapped

    // One page: three tables appear, and all three go again.
    if (vmm.unmap(root, VM_A) != null) return 4; // nothing there yet
    vmm.map(root, VM_A, p1, USER_RW, false) catch return 5;
    if (pmm.free_pages != empty - 3) return 6; // PDPT, PD, PT
    if (vmm.unmap(root, VM_A) != p1) return 7;
    if (vmm.translate(root, VM_A) != null or vmm.leafEntry(root, VM_A) != null) return 8;
    if (pmm.free_pages != empty) return 9;
    if (vmm.unmap(root, VM_A) != null) return 10; // a second unmap finds nothing
    if (!pmm.isAllocated(p1)) return 11; // the page itself is the caller's to free

    // Two pages in one page table: the table stays until both are gone.
    vmm.map(root, VM_A, p1, USER_RW, false) catch return 12;
    vmm.map(root, VM_A + pmm.PAGE_SIZE, p2, USER_RW, false) catch return 13;
    if (pmm.free_pages != empty - 3) return 14;
    if (vmm.unmap(root, VM_A) != p1 or pmm.free_pages != empty - 3) return 15;
    if (vmm.translate(root, VM_A + pmm.PAGE_SIZE) != p2) return 16;
    if (vmm.unmap(root, VM_A + pmm.PAGE_SIZE) != p2 or pmm.free_pages != empty) return 17;

    // Two page tables under one page directory: only the empty one goes.
    vmm.map(root, VM_A, p1, USER_RW, false) catch return 18;
    vmm.map(root, VM_B, p2, USER_RW, false) catch return 19;
    if (pmm.free_pages != empty - 4) return 20; // PDPT, PD, two PTs
    if (vmm.unmap(root, VM_A) != p1 or pmm.free_pages != empty - 3) return 21;
    if (vmm.translate(root, VM_B) != p2) return 22;
    if (vmm.unmap(root, VM_B) != p2 or pmm.free_pages != empty) return 23;

    // Kernel addresses: the table the PML4 points at is shared by every
    // address space and must stay; the ones below it go.
    const kernel_free = pmm.free_pages;
    vmm.map(vmm.kernel_root, VM_KERNEL, p1, vmm.WRITABLE | vmm.NX, false) catch return 24;
    if (pmm.free_pages != kernel_free - 2) return 25; // PD and PT only
    if (vmm.translate(root, VM_KERNEL) != p1) return 26; // visible in every address space
    if (vmm.unmap(vmm.kernel_root, VM_KERNEL) != p1 or pmm.free_pages != kernel_free) return 27;
    if (vmm.translate(root, VM_KERNEL) != null) return 28;
    vmm.map(vmm.kernel_root, VM_KERNEL, p1, vmm.WRITABLE | vmm.NX, false) catch return 29; // still usable
    if (vmm.unmap(vmm.kernel_root, VM_KERNEL) != p1 or pmm.free_pages != kernel_free) return 30;

    // Many rounds leave nothing behind.
    for (0..2000) |round| {
        const a = VM_A + (round % 7) * pmm.PAGE_SIZE;
        vmm.map(root, a, p1, USER_RW, false) catch return 31;
        vmm.map(root, VM_FAR, p2, USER_RW, false) catch return 32;
        if (vmm.unmap(root, a) != p1 or vmm.unmap(root, VM_FAR) != p2) return 33;
    }
    if (pmm.free_pages != empty) return 34;

    // Tearing down an address space frees pages and tables in every part of it.
    vmm.map(root, VM_A, p1, USER_RW, false) catch return 35;
    vmm.map(root, VM_FAR, p2, USER_RW, false) catch return 36;
    if (pmm.free_pages != empty - 6) return 37;
    vmm.destroyAddressSpace(root);
    return if (pmm.free_pages == start and pmm.consistent()) 0 else 38;
}

/// The first byte at user address `addr`, read through the page tables
/// (and so through the TLB), or null if the read faults.
fn userByte(addr: u64) ?u8 {
    var b: [1]u8 = undefined;
    uaccess.copyFromUser(&b, addr) catch return null;
    return b[0];
}

/// Check that `unmap` flushes the TLB: after a page has been read through
/// its mapping (so the translation is cached), unmapping makes the next
/// access fault, and mapping another page there shows that page's contents,
/// never the old one's. Returns 0, or the number of the first failing check.
pub fn vmmTlbFlush() u32 {
    const flags = cpu.saveAndDisableInterrupts(); // no thread switch while the root is swapped
    defer cpu.restoreInterrupts(flags);
    const start = pmm.free_pages;
    const root = vmm.createAddressSpace() catch return 1;
    const p1 = pmm.alloc() orelse return 2;
    const p2 = pmm.alloc() orelse return 3;
    pmm.physToVirt(p1)[0] = 0x11;
    pmm.physToVirt(p2)[0] = 0x22;
    vmm.loadRoot(root);
    defer vmm.loadRoot(vmm.kernel_root);

    var failed: u32 = 0;
    for (0..50) |_| {
        vmm.map(root, VM_A, p1, USER_RW, false) catch return 4;
        if (userByte(VM_A) != 0x11) failed = 5; // now cached in the TLB
        if (vmm.unmap(root, VM_A) != p1) failed = 6;
        if (userByte(VM_A) != null) failed = 7; // a stale entry would still read 0x11
        vmm.map(root, VM_A, p2, USER_RW, false) catch return 8;
        if (userByte(VM_A) != 0x22) failed = 9; // a stale entry would read 0x11
        // A write goes to the new page too.
        uaccess.copyToUser(VM_A, &.{0x33}) catch {
            failed = 10;
        };
        if (pmm.physToVirt(p2)[0] != 0x33 or pmm.physToVirt(p1)[0] != 0x11) failed = 11;
        pmm.physToVirt(p2)[0] = 0x22;
        if (vmm.unmap(root, VM_A) != p2) failed = 12;
        if (userByte(VM_A) != null) failed = 13;
        if (failed != 0) break;
    }
    vmm.loadRoot(vmm.kernel_root);
    pmm.free(p1);
    pmm.free(p2);
    vmm.destroyAddressSpace(root);
    if (failed != 0) return failed;
    return if (pmm.free_pages == start) 0 else 14;
}

/// Entry for the thread `memoryExhaustion` must not be able to start.
fn neverRuns() void {}

/// Check that running out of physical memory is an error everywhere and
/// corrupts nothing: with no page left, and with too few for the page
/// tables a mapping needs, `map` fails and leaves the address space as it
/// was; address spaces, kernel stacks, heap blocks, threads and processes
/// cannot be created and leave nothing behind. Returns 0, or the number of
/// the first failing check.
pub fn memoryExhaustion() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const before = footprint();
    const root = vmm.createAddressSpace() catch return 1;
    const p1 = pmm.alloc() orelse return 2;
    const p2 = pmm.alloc() orelse return 3;
    vmm.map(root, VM_A, p1, USER_RW, false) catch return 4;
    const pte = vmm.leafEntry(root, VM_A);

    var failed: u32 = 0;
    check: {
        if (drainMemory(0) != 0 or pmm.alloc() != null) {
            failed = 5;
            break :check;
        }
        // Next to an existing mapping only one table is missing; with no
        // page free that fails as well.
        if (vmm.map(root, VM_B, p2, USER_RW, false) != error.OutOfMemory) failed = 11;
        // A mapping that needs three new tables, with 0, 1 and 2 pages
        // free: never enough, and nothing may be left half-built.
        for (0..3) |have| {
            if (pmm.free_pages != have) failed = 6;
            if (vmm.map(root, VM_FAR, p2, USER_RW, false) != error.OutOfMemory) failed = 7;
            if (pmm.free_pages != have) failed = 8; // tables it had added were freed again
            if (vmm.leafEntry(root, VM_FAR) != null) failed = 9;
            if (vmm.leafEntry(root, VM_A) != pte) failed = 10; // the old mapping is intact
            if (pmm.free_pages != have) failed = 12;
            releaseSome(1);
        }
        // With 3 pages the same mapping works, and uses exactly those.
        vmm.map(root, VM_FAR, p2, USER_RW, false) catch {
            failed = 13;
            break :check;
        };
        if (pmm.free_pages != 0 or vmm.translate(root, VM_FAR) != p2) failed = 14;
        if (vmm.unmap(root, VM_FAR) != p2 or pmm.free_pages != 3) failed = 15;

        // Everything else that allocates fails cleanly with nothing free.
        if (drainMemory(0) != 0) failed = 16;
        const stacks = kstack.inUse();
        const in_use = heap.stats().bytes_in_use;
        if (vmm.createAddressSpace()) |r| {
            vmm.destroyAddressSpace(r);
            failed = 17;
        } else |_| {}
        if (kstack.alloc() != null) failed = 18;
        if (heap.allocator.alloc(u8, 64 * 1024 * 1024)) |block| {
            heap.allocator.free(block);
            failed = 19;
        } else |_| {}
        if (thread.spawn(neverRuns, null)) |_| {
            failed = 20;
        } else |_| {}
        if (process.spawnPath("/bin/hello", .{})) |p| {
            process.release(p);
            failed = 21;
        } else |e| {
            if (e != error.OutOfMemory) failed = 22;
        }
        if (kstack.inUse() != stacks or heap.stats().bytes_in_use != in_use) failed = 23;
        if (pmm.free_pages != 0) failed = 24;
        // One stack's worth short of a kernel stack: the pages it did get go back.
        releaseSome(kstack.STACK_PAGES - 1);
        if (kstack.alloc() != null or pmm.free_pages != kstack.STACK_PAGES - 1) failed = 25;
        if (vmm.leafEntry(root, VM_A) != pte) failed = 26;
    }
    releaseDrained();
    pmm.free(p2);
    vmm.destroyAddressSpace(root);
    if (failed != 0) return failed;
    if (!pmm.consistent()) return 27;
    return if (footprint().eql(before)) 0 else 28;
}

/// Start `/bin/hello` again and again, each time letting one more page
/// allocation succeed before the allocator starts failing, until a start
/// succeeds. Every failed start must report out-of-memory and leave nothing
/// behind, whichever allocation it was that failed: a page table, a page of
/// the program, the user stack, the kernel stack, heap growth. Returns 0,
/// or the number of the first failing check; `failures.*` is the number of
/// allocation points that were made to fail.
pub fn spawnAllocationFailures(failures: *usize) u32 {
    failures.* = 0;
    // Stands in for a parent process, to see what is counted against it.
    var parent: process.Process = .{ .root = 0, .entry = 0, .name = "test parent" };
    var n: usize = 0;
    while (n < 2000) : (n += 1) {
        const flags = cpu.saveAndDisableInterrupts();
        const before = footprint();
        pmm.fail_after = n;
        const result = process.spawnPath("/bin/hello", .{ .parent = &parent });
        pmm.fail_after = null;
        if (result) |p| {
            const counted = parent.descendants;
            const code = process.wait(p); // it started: let it run and finish
            cpu.restoreInterrupts(flags);
            if (code != 0) return 1;
            if (counted != 1 or parent.descendants != 0) return 6; // alive, then gone
            return if (failures.* > 10) 0 else 2; // too few: the sweep tested nothing
        } else |e| {
            const after = footprint();
            cpu.restoreInterrupts(flags);
            if (e != error.OutOfMemory) return 3;
            if (!after.eql(before)) return 4;
            if (parent.descendants != 0) return 7; // a process that never started is not counted
            failures.* += 1;
        }
    }
    return 5; // it never succeeded
}

/// Allocate enough kernel stacks to need new page tables on the way, and
/// before each one make every allocation inside `kstack.alloc` fail in
/// turn: a failed attempt must give back the pages it had taken. Returns 0,
/// or the number of the first failing check.
pub fn kstackAllocationFailures() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const before = footprint();
    const count = 220; // 5 pages per slot: at least two page-table boundaries
    const stacks = heap.allocator.alloc(?[]u8, count) catch return 1;
    @memset(stacks, null);

    var failed: u32 = 0;
    var needed_table = false;
    for (stacks) |*slot| {
        var n: usize = 0;
        while (n < 8) : (n += 1) {
            const pages = pmm.free_pages;
            const in_use = kstack.inUse();
            pmm.fail_after = n;
            const stack = kstack.alloc();
            pmm.fail_after = null;
            if (stack) |s| {
                if (n > kstack.STACK_PAGES) needed_table = true;
                slot.* = s;
                break;
            }
            if (pmm.free_pages != pages or kstack.inUse() != in_use) failed = 2;
        }
        if (slot.* == null) failed = 3;
        if (failed != 0) break;
    }
    for (stacks) |slot| {
        if (slot) |s| kstack.free(s);
    }
    heap.allocator.free(stacks); // before the footprint is compared
    if (failed != 0) return failed;
    if (!needed_table) return 4; // no attempt had to allocate a page table
    return if (footprint().eql(before) and pmm.consistent()) 0 else 5;
}

/// Make the heap grow one page at a time across a page-table boundary, with
/// the allocation of that page table failing: the page the heap had taken
/// for the spot must go back to the PMM. Each attempt asks for far more
/// than can be had while only one page allocation is allowed, so the heap
/// keeps the single page it could map and the request fails. 600 attempts
/// cover more than the 512 pages of one page table. Returns 0, or the
/// number of the first failing check.
pub fn heapGrowthFailures() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const before = footprint();
    var stuck: usize = 0; // attempts that could not grow at all: a table was needed
    for (0..600) |_| {
        const mapped = heap.stats().bytes_mapped;
        pmm.fail_after = 1;
        const block = heap.allocator.alloc(u8, 512 * 1024 * 1024);
        pmm.fail_after = null;
        if (block) |b| {
            heap.allocator.free(b);
            return 1;
        } else |_| {}
        if (heap.stats().bytes_mapped == mapped) stuck += 1;
    }
    if (stuck == 0) return 2; // never reached a page-table boundary
    // The heap kept what it mapped; nothing else is gone.
    return if (footprint().eql(before) and pmm.consistent()) 0 else 3;
}

// State of `pmmLockHolds` and its hook.
var lock_workers: [2]usize = .{ 0, 0 }; // thread IDs the hook acts on
var lock_inside: usize = 0;
var lock_entries: usize = 0;
var lock_overlaps: usize = 0;
var lock_irq_on: usize = 0;
var lock_errors: usize = 0;
var lock_done: usize = 0;

/// Longer than a time slice (50 ms), so a thread that could be preempted
/// while it waits is preempted.
const LOCK_HOLD_NS = 70 * 1000 * 1000;

/// `pmm.critical_hook` for `pmmLockHolds`: stay inside the allocator's
/// critical section for longer than a time slice, and notice if another
/// thread is in there at the same time.
fn lockHook() void {
    const id = thread.id();
    if (id != lock_workers[0] and id != lock_workers[1]) return;
    lock_entries += 1;
    if (cpu.readFlags() & RFLAGS_IF != 0) lock_irq_on += 1;
    lock_inside += 1;
    if (lock_inside != 1) lock_overlaps += 1;
    const until = hpet.nanos() + LOCK_HOLD_NS;
    while (hpet.nanos() < until) {}
    if (lock_inside != 1) lock_overlaps += 1;
    lock_inside -= 1;
}

/// Worker for `pmmLockHolds`: allocate and free with interrupts on, so the
/// timer can preempt it anywhere the allocator lets it.
var lock_go: std.atomic.Value(bool) = .init(false);

fn lockWorker() void {
    while (!lock_go.load(.acquire)) thread.yield(); // until the hook knows this thread
    for (0..2) |_| {
        if (pmm.alloc()) |page| pmm.free(page) else lock_errors += 1;
    }
    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    signalDone(&lock_done, &done_queue);
}

/// Prove that the physical allocator's critical sections exclude other
/// threads. Two preemptible threads allocate and free while a hook holds
/// each of them inside the critical section for longer than a time slice.
/// With the lock (interrupts off) the other thread cannot run in that time;
/// without it the timer switches to the other thread, which enters the
/// critical section too. Returns 0, or the number of the first failing check.
pub fn pmmLockHolds() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const before = pmm.free_pages;
    lock_inside = 0;
    lock_entries = 0;
    lock_overlaps = 0;
    lock_irq_on = 0;
    lock_errors = 0;
    lock_done = 0;
    const a = thread.spawn(lockWorker, null) catch return 1;
    const b = thread.spawn(lockWorker, null) catch return 1;
    lock_workers = .{ a.id, b.id };
    pmm.critical_hook = lockHook;
    lock_go.store(true, .release);
    waitForDone(&lock_done, 2, &done_queue);
    lock_go.store(false, .release);
    pmm.critical_hook = null;
    lock_workers = .{ 0, 0 };

    if (lock_errors != 0) return 2;
    if (lock_entries < 8) return 3; // two threads, two allocations and two frees each
    if (lock_overlaps != 0) return 4; // two threads inside at once
    if (lock_irq_on != 0) return 5; // inside the critical section with interrupts on
    return if (pmm.free_pages == before and pmm.consistent()) 0 else 6;
}

/// Start the program at `path`, compare the pages the kernel charged to
/// the new process with the pages that actually left the allocator (its
/// program, stack, page tables and kernel stack), and wait for it. Returns
/// the charged number, or null if the two differ or it could not start.
pub fn chargedPages(path: []const u8) ?u64 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const before = footprint();
    const p = process.spawnPath(path, .{ .randomize = randomize_layout }) catch return null;
    const taken = before.pages - footprint().pages; // it has not run yet
    const charged = p.pages;
    _ = process.wait(p); // until it exits; `p` is gone after this
    if (charged != taken) return null;
    return charged;
}

// ---------------------------------------------------------------------------
// Synchronization and timers (roadmap 2.8)

/// True if interrupts are enabled.
fn interruptsOn() bool {
    return cpu.readFlags() & RFLAGS_IF != 0;
}

// State of the spinlock contention test.
var spin_lock: SpinLock = .{};
var spin_counter: u64 = 0;
var spin_done: usize = 0;
var spin_waiter: WaitQueue = .{};

/// The lock of the conditions the tests wait for: their counters of
/// finished threads, and the wait queues that go with them.
var test_lock: SpinLock = .{};
/// Where a test's main thread waits for its workers (`waitForDone`), for
/// the tests that have no queue of their own.
var done_queue: WaitQueue = .{};

/// Count one more in `counter` and wake everyone on `queue`, under `test_lock`.
fn signalDone(counter: *usize, queue: *WaitQueue) void {
    const held = test_lock.acquire();
    defer test_lock.release(held);
    counter.* += 1;
    _ = queue.wakeAll();
}

/// Sleep on `queue` until `counter` has reached `n`, and then until the
/// threads that counted have gone (`quiesce`). The other side is `signalDone`.
fn waitForDone(counter: *const usize, n: usize, queue: *WaitQueue) void {
    {
        const held = test_lock.acquire();
        defer test_lock.release(held);
        while (counter.* < n) queue.wait(&test_lock);
    }
    quiesce();
}

/// Threads that exist: created and not yet freed.
fn threadsAlive() usize {
    return thread.spawnedCount() - thread.reapedCount();
}

/// What `threadsAlive` was when the running test case began.
var alive_at_start: usize = 0;

/// Note the threads that exist now as the ones that are not this test's.
/// The test runner calls it before each case.
pub fn beginCase() void {
    alive_at_start = threadsAlive();
}

/// Let other threads run until every thread this test case started has
/// been freed, with its stack and (for a process) what was left of the
/// process. A thread that has finished its work is not gone yet: it still
/// has to exit, its CPU has to leave its stack, and some CPU has to free
/// it at its next thread switch. On one CPU all of that has happened by
/// the time the thread that waited for it runs again; with several it
/// takes a moment longer, and a test that compares memory before and
/// after has to wait for it. Gives up after about half a second, for the
/// test that leaves a thread behind on purpose.
pub fn quiesce() void {
    for (0..5000) |_| {
        if (threadsAlive() <= alive_at_start) return;
        thread.yield();
    }
    for (0..50) |_| {
        if (threadsAlive() <= alive_at_start) return;
        timer.sleepTicks(1);
    }
}

/// Let other threads run until `count` returns `n`. False if it never happens.
fn untilCount(comptime count: fn () usize, n: usize) bool {
    for (0..10_000) |_| {
        if (count() == n) return true;
        thread.yield();
    }
    return false;
}
const SPIN_ROUNDS = 20_000;

/// Add to a shared counter with a read, a pause and a write: an update is
/// lost if another thread gets in between, which only the lock prevents.
fn spinWorker() void {
    for (0..SPIN_ROUNDS) |_| {
        const held = spin_lock.acquire();
        const seen = spin_counter;
        for (0..20) |_| std.atomic.spinLoopHint();
        spin_counter = seen + 1;
        spin_lock.release(held);
    }
    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    signalDone(&spin_done, &spin_waiter);
}

/// Check spinlocks: taking one turns interrupts off and releasing restores
/// what was there, also when locks nest; a held lock cannot be taken again;
/// and preemptible threads never lose an update made under one. Must be
/// called with interrupts on. Returns 0, or the number of the first failing check.
pub fn spinlockChecks() u32 {
    if (!interruptsOn()) return 1;
    var a: SpinLock = .{};
    var b: SpinLock = .{ .rank = .timer }; // taken inside `a`, so it ranks after it

    const held_a = a.acquire();
    if (interruptsOn() or !a.isHeld()) return 2;
    const held_b = b.acquire();
    if (interruptsOn()) return 3;
    b.release(held_b);
    if (interruptsOn()) return 4; // still inside `a`: must stay off
    if (b.isHeld() or !a.isHeld()) return 5;
    // A held lock cannot be taken, and asking does not disturb anything.
    if (a.tryAcquire() != null) return 6;
    if (interruptsOn() or !a.isHeld()) return 7;
    a.release(held_a);
    if (!interruptsOn() or a.isHeld()) return 8;

    // Taken with interrupts already off: release leaves them off.
    const flags = cpu.saveAndDisableInterrupts();
    const inner = a.acquire();
    a.release(inner);
    const still_off = !interruptsOn();
    cpu.restoreInterrupts(flags);
    if (!still_off or !interruptsOn()) return 9;

    // tryAcquire on a free lock behaves like acquire.
    const tried = a.tryAcquire() orelse return 10;
    if (interruptsOn()) return 11;
    a.release(tried);
    if (!interruptsOn()) return 12;

    // Two preemptible threads, one counter.
    spin_counter = 0;
    spin_done = 0;
    _ = thread.spawn(spinWorker, null) catch return 13;
    _ = thread.spawn(spinWorker, null) catch return 13;
    waitForDone(&spin_done, 2, &spin_waiter);
    if (spin_counter != 2 * SPIN_ROUNDS) return 14;
    return 0;
}

// State of the wait queue test.
var wq: WaitQueue = .{};
/// The lock of `wq`, `wq_finished` and the conditions waited for on them.
var wq_lock: SpinLock = .{};
var wq_go: [3]bool = @splat(false);
var wq_order: [8]u8 = undefined;
var wq_order_len: usize = 0;
var wq_wakeups: [3]usize = @splat(0);
var wq_next_index: usize = 0;
var wq_finished: WaitQueue = .{};
var wq_threads: [3]?*thread.Thread = @splat(null);

/// Wait on `wq` until this waiter's flag is set, then note the order.
fn wqWaiter() void {
    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    const held = wq_lock.acquire();
    defer wq_lock.release(held);
    const index = wq_next_index;
    wq_next_index += 1;
    while (!wq_go[index]) {
        wq.wait(&wq_lock);
        wq_wakeups[index] += 1;
    }
    wq_order[wq_order_len] = @intCast(index);
    wq_order_len += 1;
    _ = wq_finished.wakeAll();
}

/// `wq.wakeOne`, `wakeAll`, `waiting` and `waitTimeout` under the queue's lock.
fn wqWakeOne() ?*thread.Thread {
    const held = wq_lock.acquire();
    defer wq_lock.release(held);
    return wq.wakeOne();
}

fn wqWakeAll() usize {
    const held = wq_lock.acquire();
    defer wq_lock.release(held);
    return wq.wakeAll();
}

fn wqWaiting() usize {
    const held = wq_lock.acquire();
    defer wq_lock.release(held);
    return wq.waiting();
}

fn wqWaitTimeout(ticks: u64) bool {
    const held = wq_lock.acquire();
    defer wq_lock.release(held);
    return wq.waitTimeout(&wq_lock, ticks);
}

/// Sleep until `n` of the waiters have finished.
fn wqUntilFinished(n: usize) void {
    const held = wq_lock.acquire();
    defer wq_lock.release(held);
    while (wq_order_len < n) wq_finished.wait(&wq_lock);
}

/// Wake `wq` from a timer, for the timeout test.
fn wqTimerWake(_: *timer.Timer) void {
    _ = wqWakeOne();
}

/// Check wait queues: several threads wait on one queue and are woken one
/// at a time in arrival order, or all at once; a waiter whose condition is
/// not true yet goes back to sleep; a wake-up with nobody waiting is not
/// remembered; a wait with a timeout ends when it is woken or when time is
/// up, whichever is first. Returns 0, or the number of the first failing check.
pub fn waitQueueChecks() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const before = footprint();
    const timers_before = timer.pending();
    wq_go = @splat(false);
    wq_wakeups = @splat(0);
    wq_order_len = 0;
    wq_next_index = 0;

    if (wqWakeOne() != null or wqWakeAll() != 0) return 1; // empty: nothing to wake
    for (&wq_threads) |*t| {
        t.* = thread.spawn(wqWaiter, null) catch return 2;
        thread.yield(); // let it reach the queue, so the order is known
    }
    if (!untilCount(wqWaiting, 3)) return 3;
    if (wq_order_len != 0) return 4;

    // A wake-up for a condition that is not true: the waiter looks and
    // sleeps again, at the back of the queue.
    if (wqWakeOne() != wq_threads[0]) return 5; // first in, first woken
    if (!untilCount(wqWaiting, 3)) return 6;
    if (wq_wakeups[0] != 1 or wq_order_len != 0) return 7;
    // The queue is now 1, 2, 0. A plain `thread.wake` is not a wake-up of
    // the queue: the thread stays on it.
    thread.wake(wq_threads[1].?);
    thread.wake(wq_threads[1].?); // twice: must not queue it twice either
    for (0..20) |_| thread.yield();
    if (wqWaiting() != 3 or wq_wakeups[1] != 0) return 8;

    // One at a time, in order.
    wq_go[1] = true;
    if (wqWakeOne() != wq_threads[1]) return 9;
    wqUntilFinished(1);
    if (wqWaiting() != 2) return 10; // the other two were left alone
    if (wq_order[0] != 1) return 11;
    // All at once: both run, in the order they waited (2, then 0).
    wq_go[2] = true;
    wq_go[0] = true;
    if (wqWakeAll() != 2) return 12;
    wqUntilFinished(3);
    if (!std.mem.eql(u8, wq_order[0..3], &.{ 1, 2, 0 })) return 13;
    if (wqWaiting() != 0) return 14;

    // A wake-up with nobody waiting is gone: the next wait really waits.
    if (wqWakeOne() != null) return 15;
    const t0 = timer.now();
    if (wqWaitTimeout(3)) return 16; // nobody wakes us: time runs out
    const waited = timer.now() - t0;
    if (waited < 3 or waited > 6) return 17;
    if (wqWaiting() != 0 or thread.current().wait_queue != null) return 18;

    // Woken before the timeout: returns true, early, and disarms its timer.
    var waker: timer.Timer = .{ .callback = wqTimerWake };
    timer.add(&waker, 2);
    const t1 = timer.now();
    if (!wqWaitTimeout(500)) return 19;
    if (timer.now() - t1 > 10) return 20;
    if (timer.pending() != timers_before) return 21;

    // Woken and out of time on the same tick: the wake-up counts. (The
    // waker was armed first, so it fires first and takes this thread off
    // the queue; then the timeout fires, before the thread has run.)
    timer.add(&waker, 3);
    if (!wqWaitTimeout(3)) return 23;
    if (timer.pending() != timers_before or wqWaiting() != 0) return 24;

    quiesce();
    return if (footprint().eql(before)) 0 else 22;
}

// State of the timer test.
var tm_order: [8]u8 = undefined;
var tm_ticks: [8]u64 = undefined;
var tm_len: usize = 0;

/// Timer callback: note which timer fired, and when.
fn tmFired(t: *timer.Timer) void {
    if (tm_len < tm_order.len) {
        tm_order[tm_len] = @intCast(t.context);
        tm_ticks[tm_len] = timer.now();
    }
    tm_len += 1;
}

var sleep_order: [2]u8 = undefined;
var sleep_len: usize = 0;
var sleep_done: WaitQueue = .{};

fn sleeper(ticks: u64, tag: u8) void {
    timer.sleepTicks(ticks);
    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    const held = test_lock.acquire();
    defer test_lock.release(held);
    sleep_order[sleep_len] = tag;
    sleep_len += 1;
    _ = sleep_done.wakeAll();
}

fn sleeperLong() void {
    sleeper(8, 'L');
}

fn sleeperShort() void {
    sleeper(2, 'S');
}

/// Check kernel timers: they fire at their tick, earliest first and in
/// arming order among equals; a cancelled timer never fires; a sleep lasts
/// at least as long as asked, by the tick counter and by the HPET, while
/// the CPU idles; and sleeping threads wake in deadline order. Returns 0,
/// or the number of the first failing check.
pub fn timerChecks() u32 {
    const before = footprint();
    const pending_before = timer.pending();
    var timers: [5]timer.Timer = undefined;
    for (&timers, 0..) |*t, i| t.* = .{ .callback = tmFired, .context = i };
    const delays = [5]u64{ 6, 2, 4, 2, 3 };
    tm_len = 0;

    const flags = cpu.saveAndDisableInterrupts();
    const start = timer.now();
    for (&timers, delays) |*t, d| timer.add(t, d);
    if (timer.pending() != pending_before + 5) return 1;
    // Timer 4 is cancelled before it is due.
    if (!timer.cancel(&timers[4]) or timer.cancel(&timers[4])) return 2;
    cpu.restoreInterrupts(flags);

    timer.sleepTicks(10); // nothing else is ready: the CPU idles meanwhile
    if (tm_len != 4) return 3; // the cancelled one never fired
    if (!std.mem.eql(u8, tm_order[0..4], &.{ 1, 3, 2, 0 })) return 4; // 2, 2 (arming order), 4, 6
    for (tm_order[0..4], tm_ticks[0..4]) |index, tick| {
        if (tick != start + delays[index]) return 5; // exactly on its tick
    }
    if (timer.cancel(&timers[0])) return 6; // it has fired: nothing to cancel
    if (timer.pending() != pending_before) return 7;

    // A sleep is never shorter than asked: by ticks and by an independent clock.
    const t0 = timer.now();
    const ns0 = hpet.nanos();
    timer.sleepTicks(5);
    const ticks = timer.now() - t0;
    const ns = hpet.nanos() - ns0;
    if (ticks < 5 or ticks > 8) return 8;
    if (ns < 5 * timer.NS_PER_TICK or ns > 20 * timer.NS_PER_TICK) return 9;
    if (timer.msToTicks(0) != 0 or timer.msToTicks(1) != 1 or timer.msToTicks(10) != 1 or timer.msToTicks(11) != 2 or timer.msToTicks(1000) != timer.HZ) return 10;

    // Two sleepers: the one with the earlier deadline wakes first, though
    // it went to sleep second.
    sleep_len = 0;
    {
        const irq = cpu.saveAndDisableInterrupts();
        defer cpu.restoreInterrupts(irq);
        _ = thread.spawn(sleeperLong, null) catch return 11;
        _ = thread.spawn(sleeperShort, null) catch return 11;
    }
    waitForDone(&sleep_len, 2, &sleep_done);
    if (!std.mem.eql(u8, &sleep_order, "SL")) return 12;
    if (timer.pending() != pending_before) return 13;
    quiesce();
    return if (footprint().eql(before)) 0 else 14;
}

// State of the mutex test.
var mx: Mutex = .{};
var mx_inside: usize = 0;
var mx_overlaps: usize = 0;
var mx_counter: u64 = 0;
var mx_done: usize = 0;
var mx_finished: WaitQueue = .{};
var mx_order: [3]usize = undefined;
var mx_order_len: usize = 0;
const MX_THREADS = 4;
const MX_ROUNDS = 40;

/// Take the mutex again and again, and do things inside that let other
/// threads run: spin (the timer preempts), yield, and sleep.
fn mxWorker() void {
    const me = thread.id();
    for (0..MX_ROUNDS) |round| {
        mx.lock();
        mx_inside += 1;
        if (mx_inside != 1 or !mx.heldByMe()) mx_overlaps += 1;
        const seen = mx_counter;
        switch ((round + me) % 4) {
            0 => thread.yield(),
            1 => timer.sleepTicks(1), // blocks while holding the mutex
            else => for (0..2000) |_| std.atomic.spinLoopHint(),
        }
        mx_counter = seen + 1;
        if (mx_inside != 1) mx_overlaps += 1;
        mx_inside -= 1;
        mx.unlock();
    }
    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    signalDone(&mx_done, &mx_finished);
}

fn mxWaiting() usize {
    return mx.waiterCount();
}

/// Wait for the mutex once and note the order it was obtained in.
fn mxQueuer() void {
    mx.lock();
    mx_order[mx_order_len] = thread.id();
    mx_order_len += 1;
    mx.unlock();
    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    signalDone(&mx_done, &mx_finished);
}

/// Check the mutex: only one thread is inside at a time, even though the
/// holder is preempted, yields and sleeps while it holds it; nothing is
/// lost; `unlock` hands the mutex to the thread that has waited longest,
/// which owns it before it runs; `tryLock` never waits. Must be called
/// with interrupts on. Returns 0, or the number of the first failing check.
pub fn mutexChecks() u32 {
    const before = footprint();
    if (!mx.tryLock()) return 1;
    if (!mx.heldByMe() or mx.tryLock()) return 2; // held: no second taker, not even its owner
    mx.unlock();
    if (mx.owner != null) return 3;

    // Exclusion under preemption, yielding and sleeping.
    mx_inside = 0;
    mx_overlaps = 0;
    mx_counter = 0;
    mx_done = 0;
    {
        const irq = cpu.saveAndDisableInterrupts();
        defer cpu.restoreInterrupts(irq);
        for (0..MX_THREADS) |_| _ = thread.spawn(mxWorker, null) catch return 4;
    }
    waitForDone(&mx_done, MX_THREADS, &mx_finished);
    if (mx_overlaps != 0) return 5;
    if (mx_counter != MX_THREADS * MX_ROUNDS) return 6;
    if (mx.owner != null or mx.waiterCount() != 0) return 7;

    // Hand-off: three threads queue up behind the holder, in a known order.
    mx.lock();
    mx_order_len = 0;
    mx_done = 0;
    var queued: [3]usize = undefined;
    const irq = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(irq);
    for (&queued, 0..) |*id, i| {
        const t = thread.spawn(mxQueuer, null) catch return 8;
        id.* = t.id;
        if (!untilCount(mxWaiting, i + 1)) return 9;
    }
    if (!mx.heldByMe()) return 10;
    mx.unlock();
    // Before anyone else has run, the first waiter already owns it.
    if (mx.owner == null or mx.owner.?.id != queued[0]) return 11;
    if (mx.tryLock()) return 12; // it is not free in between
    waitForDone(&mx_done, 3, &mx_finished);
    if (!std.mem.eql(usize, &mx_order, &queued)) return 13; // longest wait first
    if (mx.owner != null) return 14;
    quiesce();
    return if (footprint().eql(before)) 0 else 15;
}

/// Check that keyboard readers wait on a queue: three programs each wait
/// for a key and get one each, in the order they started waiting; a key
/// typed with nobody waiting is kept for the next reader. Returns 0, or
/// the number of the first failing check.
pub fn keyboardReaders() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const before = footprint();
    while (keyboard.getChar() != null) {} // start with an empty buffer
    var readers: [3]*process.Process = undefined;
    for (&readers, 0..) |*r, i| {
        r.* = process.spawnPath("/test/getchar", .{}) catch return 1;
        if (!untilCount(keyboard.waitingReaders, i + 1)) return 2;
    }
    // One key wakes one reader: the first.
    keyboard.inject('a');
    if (process.wait(readers[0]) != 'a') return 3;
    if (keyboard.waitingReaders() != 2) return 4;
    // Two keys at once: one each, in order.
    keyboard.inject('b');
    keyboard.inject('c');
    if (process.wait(readers[1]) != 'b') return 5;
    if (process.wait(readers[2]) != 'c') return 6;
    if (keyboard.waitingReaders() != 0) return 7;
    // A key with nobody waiting stays in the buffer.
    keyboard.inject('d');
    const late = process.spawnPath("/test/getchar", .{}) catch return 8;
    if (process.wait(late) != 'd') return 9;
    if (keyboard.getChar() != null) return 10;
    quiesce();
    if (!footprint().eql(before)) {
        const now = footprint();
        kernel_root.print("  keyboard readers: before {any}, after {any}\n", .{ before, now });
        return 11;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// The locking model on one CPU (roadmap 3.1)

const spinlock = kernel_root.kernel.sync.spinlock;

/// A thread for `lockingModelChecks` that is never started.
fn neverStarted() void {}

/// Timer callback for `lockingModelChecks`: the interrupt it runs in must
/// have found this CPU holding no lock.
var lm_locks_in_timer: ?usize = null;
fn lmTimerProbe(_: *timer.Timer) void {
    lm_locks_in_timer = spinlock.heldCount();
}

/// Check what the locking model promises and can be seen on one CPU: each
/// CPU knows the locks it holds; a wait hands its condition's lock back; a
/// thread switch and an interrupt happen with no lock held; a thread can be
/// created and taken back without ever running; a thread that blocks with
/// nothing else to run idles on its own stack and carries on there when it
/// is woken, without passing through the ready queue; a timer that wakes a
/// thread can be let go safely whether it fired, was cancelled or never
/// ran. Must be called with interrupts on. Returns 0, or the number of the
/// first failing check.
pub fn lockingModelChecks() u32 {
    if (!interruptsOn()) return 1;
    if (spinlock.heldCount() == null) return 2; // the test kernel always records
    const before = footprint();

    // The record follows the locks, also through tryAcquire.
    var outer: SpinLock = .{};
    var inner: SpinLock = .{ .rank = .timer };
    if (spinlock.heldCount() != 0) return 3;
    const held_outer = outer.acquire();
    if (spinlock.heldCount() != 1) return 4;
    const held_inner = inner.tryAcquire() orelse return 5;
    if (spinlock.heldCount() != 2) return 6;
    if (outer.tryAcquire() != null or spinlock.heldCount() != 2) return 7; // a failed try records nothing
    inner.release(held_inner);
    outer.release(held_outer);
    if (spinlock.heldCount() != 0 or !interruptsOn()) return 8;

    // A wait releases the condition's lock for the sleep and returns with
    // it: one lock held before and after, and the timer interrupt that ended
    // the wait saw none.
    lm_locks_in_timer = null;
    var probe: timer.Timer = .{ .callback = lmTimerProbe };
    {
        const held = wq_lock.acquire();
        defer wq_lock.release(held);
        timer.add(&probe, 1);
        if (wq.waitTimeout(&wq_lock, 3)) return 9;
        if (spinlock.heldCount() != 1 or !wq_lock.isHeld()) return 10;
    }
    if (lm_locks_in_timer != 0) return 11;
    // The kernel's own locks are all free again after sleeping and switching.
    thread.yield();
    timer.sleepTicks(1);
    if (spinlock.heldCount() != 0 or !interruptsOn()) return 12;

    // A thread that was created but never started leaves nothing behind
    // and is not counted.
    const spawned = thread.spawnedCount();
    const t = thread.create(neverStarted, null) catch return 13;
    if (t.id != 0 or t.on_cpu or t.link != .none) return 14;
    thread.destroy(t);
    if (thread.spawnedCount() != spawned or !footprint().eql(before)) return 15;

    // Blocking with nothing else ready: the CPU halts on this stack, and
    // the wake-up lets the thread carry on in place.
    {
        const irq = cpu.saveAndDisableInterrupts();
        defer cpu.restoreInterrupts(irq);
        const me = thread.current();
        if (!me.on_cpu or me.state != .running) return 16;
        const halts = thread.haltCount();
        const switches = thread.switchCount();
        var alarm = timer.WakeTimer.init(me);
        timer.add(&alarm.timer, 2);
        while (!alarm.hasFired()) thread.block();
        alarm.finish();
        if (thread.haltCount() == halts) return 17; // it idled
        if (thread.switchCount() != switches) return 18; // and was not switched away from
        if (me.state != .running or me.link != .none or !me.on_cpu or me.wake_pending) return 19;
    }

    // A wake timer can be let go when it has fired (above), when it is
    // cancelled before it fires, and the cancelled one never wakes anybody.
    {
        const pending = timer.pending();
        var alarm = timer.WakeTimer.init(thread.current());
        timer.add(&alarm.timer, 2);
        alarm.finish();
        if (timer.pending() != pending or alarm.hasFired()) return 20;
        timer.sleepTicks(4);
        if (alarm.hasFired() or thread.current().wake_pending) return 21;
    }
    return if (footprint().eql(before)) 0 else 22;
}

/// For the `lock_order` scenario: take two spinlocks against the lock
/// order. Returns only if nothing noticed.
pub fn takeLocksOutOfOrder() void {
    var first: SpinLock = .{ .rank = .timer };
    var second: SpinLock = .{ .rank = .condition };
    const held_first = first.acquire();
    const held_second = second.acquire();
    second.release(held_second);
    first.release(held_first);
}

/// For the `sleep_with_lock` scenario: sleep while holding a spinlock.
/// Returns only if nothing noticed.
pub fn sleepHoldingSpinlock() void {
    var lock: SpinLock = .{};
    const held = lock.acquire();
    timer.sleepTicks(1);
    lock.release(held);
}

// ---------------------------------------------------------------------------
// Per-CPU state and the other CPUs (roadmap 3.2, 3.3)

const smp = kernel_root.arch.x86_64.smp;

/// True if the byte ranges `a` and `b` share a byte.
fn overlap(a: []const u8, b: []const u8) bool {
    const a_low = @intFromPtr(a.ptr);
    const b_low = @intFromPtr(b.ptr);
    return a_low < b_low + b.len and b_low < a_low + a.len;
}

/// Park every CPU but this one (the boot CPU), or let them run threads
/// again. Parking returns when each of them has given up the thread it ran
/// and halted; false if one does not within a few seconds. Must be called
/// with interrupts on.
pub fn setOthersParked(parked: bool) bool {
    const n = percpu.count();
    for (1..n) |i| thread.setParked(i, parked);
    if (!parked) return true;
    for (0..500) |_| {
        var all = true;
        for (1..n) |i| {
            if (!thread.isParked(i)) all = false;
        }
        if (all) return true;
        timer.sleepTicks(1);
    }
    return false;
}

/// Check the speculation barriers at kernel entry: where the two paths of
/// the conditional `swapgs` meet, in the common and in the emergency entry
/// path, the next instruction is `lfence`, and a `swapgs` comes right
/// before it (so the barrier is on both paths, not after one of them).
/// Returns 0, or the number of the first failing check.
pub fn swapgsFences() u32 {
    const lfence = [3]u8{ 0x0f, 0xae, 0xe8 };
    const swapgs = [3]u8{ 0x0f, 0x01, 0xf8 };
    for (idt.swapgsFences(), 0..) |fence, n| {
        if (!std.mem.eql(u8, fence, &lfence)) return @intCast(1 + 2 * n);
        // The bytes before the join are the skipped path: it ends in the
        // `swapgs` (followed, in the emergency path, by a 5-byte `mov`).
        const before = @as([*]const u8, @ptrCast(fence)) - 8;
        var found = false;
        for (0..6) |at| { // by hand: `std.mem.indexOf` has a frame of 2.5 KiB in Debug builds
            if (std.mem.eql(u8, before[at..][0..3], &swapgs)) found = true;
        }
        if (!found) return @intCast(2 + 2 * n);
    }
    return 0;
}

/// Check the CPUs: `want` of them are up, which is all the machine has;
/// each has its own per-CPU structure, reachable by its number, its own
/// GDT, TSS and emergency stacks (guarded, except the boot CPU's), its own
/// kernel stack and its own thread; the control registers and `syscall`
/// MSRs every CPU must have are the same on all of them and each one's GS
/// base points at its own structure; every CPU takes timer interrupts,
/// with no lock left held; only the boot CPU runs threads, and time
/// advances once per tick however many CPUs there are. The other CPUs must
/// be parked (`setOthersParked`). Must be called with interrupts on. Returns 0, or the number of the first failing check.
pub fn cpuChecks(want: usize) u32 {
    if (!interruptsOn()) return 1;
    const n = percpu.count();
    if (n != want or smp.detectedCount() != want) return 2;

    // This CPU, as its own code sees it.
    const mine = blk: {
        const flags = cpu.saveAndDisableInterrupts();
        defer cpu.restoreInterrupts(flags);
        const c = percpu.current();
        if (c != percpu.get(0) or c.id != 0 or !c.runs_threads) return 3; // the tests run on the boot CPU
        if (c.thread != @as(?*anyopaque, thread.current())) return 4;
        if (c.apic_id != apic.id()) return 5;
        if (c.loaded_root != cpu.readCr3() & ~@as(u64, 0xFFF)) return 6;
        break :blk smp.readSetup();
    };
    if (mine.gs_base != @intFromPtr(percpu.get(0))) return 7;

    for (0..n) |i| {
        const c = percpu.get(i);
        const base: u32 = @intCast(100 * (i + 1));
        if (c.self != c or c.id != i) return base + 1;
        const tables = c.tables orelse return base + 2;
        const t: *thread.Thread = @ptrCast(@alignCast(c.thread orelse return base + 3));
        const stack = t.stack orelse return base + 4;
        // This thread runs; the other CPUs are parked, each halted in the thread it started in.
        if (!t.on_cpu or t.link != .none or t.cpu != c) return base + 5;
        if (i == 0 and t.state != .running) return base + 5;
        if (i != 0 and (c.thread != c.idle_thread or !thread.isParked(i))) return base + 5;
        // Its kernel stack is where `syscall` and interrupts from ring 3 would land.
        const top = @intFromPtr(stack.ptr) + stack.len;
        if (i != 0 and (c.kernel_rsp != top or tables.tss.rsp0 != top)) return base + 6;
        if (!kstack.owns(stack)) return base + 7;
        // Its emergency stacks: where its TSS says, and guarded on every
        // CPU that was started after memory management was up.
        for (gdt.IST_INDEXES) |index| {
            const ist = gdt.istStackOf(tables, index);
            if (tables.tss.ist[index - 1] != @intFromPtr(ist.ptr) + ist.len) return base + 8;
            if (i != 0 and (!kstack.owns(ist) or kernelMapped(@intFromPtr(ist.ptr) - 1))) return base + 9;
            if (overlap(ist, stack)) return base + 10;
        }
        // The same protections as the boot CPU, and its own GS base.
        if (!smp.sameSetup(c.setup, mine)) return base + 11;
        if (c.setup.gs_base != @intFromPtr(c) or c.setup.kernel_gs_base != 0) return base + 12;
        if (c.loaded_root != vmm.kernel_root and i != 0) return base + 13;
        if (c.runs_threads != (i == 0)) return base + 14; // parked for this test

        // Nothing is shared with another CPU.
        for (0..i) |j| {
            const o = percpu.get(j);
            if (o == c or o.apic_id == c.apic_id or o.tables == c.tables or o.thread == c.thread) return base + 15;
            const other: *thread.Thread = @ptrCast(@alignCast(o.thread.?));
            if (overlap(other.stack.?, stack)) return base + 16;
            for (gdt.IST_INDEXES) |index| {
                for (gdt.IST_INDEXES) |other_index| {
                    if (overlap(gdt.istStackOf(tables, index), gdt.istStackOf(o.tables.?, other_index))) return base + 17;
                }
            }
        }
    }

    // Every CPU takes its timer interrupt: from ring 0, through the common
    // entry path, on its own stack, with its own GS base. Time itself
    // advances once per tick, not once per CPU.
    var ticks_before: [8]u64 = undefined;
    if (n > ticks_before.len) return 8;
    for (0..n) |i| ticks_before[i] = @atomicLoad(u64, &percpu.get(i).ticks, .monotonic);
    const t0 = timer.now();
    const ns0 = hpet.nanos();
    timer.sleepTicks(10);
    const ticks = timer.now() - t0;
    const ms = (hpet.nanos() - ns0) / 1_000_000;
    if (ticks < 10 or ticks > 13) return 9;
    if (ms < 100 or ms > 100 + 10 * 5) return 10; // 10 ms a tick: nobody else advanced it
    for (0..n) |i| {
        const c = percpu.get(i);
        const took = @atomicLoad(u64, &c.ticks, .monotonic) - ticks_before[i];
        if (took < 8 or took > 15) return @intCast(20 + i);
        if (i != 0 and c.halts == 0) return @intCast(40 + i); // it idles through the scheduler
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Several CPUs at once (roadmap 3.4). These tests run with every CPU taking
// threads, so everything they share is atomic or under a lock.

const ipi = kernel_root.arch.x86_64.ipi;
const Atomic = std.atomic.Value;

/// Which CPUs the threads of a test were seen running on, as a bit mask.
var seen_cpus: Atomic(u64) = .init(0);

/// Note the CPU the calling thread is on right now.
fn noteCpu() void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    _ = seen_cpus.fetchOr(@as(u64, 1) << @intCast(percpu.current().id), .monotonic);
}

/// Number of CPUs that run threads.
fn schedulingCpus() usize {
    var n: usize = 0;
    for (0..percpu.count()) |i| {
        if (i == 0 or !thread.isParked(i)) n += 1;
    }
    return n;
}

/// Sleep until memory is back to `before` (threads that have exited are
/// freed by whichever CPU switches threads next). False if it never is.
fn untilFootprint(before: Footprint) bool {
    for (0..200) |_| {
        if (footprint().eql(before)) return true;
        timer.sleepTicks(1);
    }
    return false;
}

var par_done: usize = 0;
var par_failures: Atomic(usize) = .init(0);
var par_first_failure: Atomic(usize) = .init(0);

/// Run a mix of programs one after the other and compare their exit statuses.
fn programRunner() void {
    const programs = [_]struct { path: []const u8, want: u64 }{
        .{ .path = "/test/fpu", .want = 0 }, // every x87/SSE/AVX register, across switches
        .{ .path = "/bin/hello", .want = 0 },
        .{ .path = "/test/preempt", .want = 0 }, // long syscalls, registers checked after each
        .{ .path = "/test/open_count", .want = 13 },
        .{ .path = "/test/div_zero", .want = process.EXIT_KILLED }, // a fault kills it, wherever it runs
        .{ .path = "/test/syscall_abi", .want = 0 },
        .{ .path = "/test/zero_pages", .want = 0 }, // nothing of another process in fresh memory
    };
    for (programs, 1..) |program, n| {
        noteCpu();
        const code = runProgram(program.path);
        if (code != program.want) {
            _ = par_failures.fetchAdd(1, .monotonic);
            _ = par_first_failure.cmpxchgStrong(0, n, .monotonic, .monotonic);
        }
    }
    signalDone(&par_done, &done_queue);
}

/// Run programs on every CPU at once: six kernel threads each start and
/// wait for seven programs, so processes are created, run, preempted,
/// moved between CPUs, killed and torn down everywhere at the same time.
/// Every program must end the way it does alone, the work must really have
/// been spread over the CPUs, and afterwards no memory is missing: no
/// address space was freed while a CPU still used it, and none was leaked.
/// `first.*` is set to the number of the first program that ended wrong.
/// Must be called with interrupts on. Returns 0, or the number of the
/// first failing check.
pub fn parallelPrograms(first: *usize) u32 {
    const RUNNERS = 6;
    const live = process.liveCount();
    par_failures.store(0, .monotonic);
    par_first_failure.store(0, .monotonic);
    seen_cpus.store(0, .monotonic);
    const before = footprint();
    par_done = 0;
    for (0..RUNNERS) |_| _ = thread.spawn(programRunner, null) catch return 1;
    waitForDone(&par_done, RUNNERS, &done_queue);
    // A thread that has exited is freed, and its process with it, by
    // whichever CPU switches threads next: that may still be about to happen.
    if (!untilFootprint(before)) {
        const now = footprint();
        kernel_root.print("  parallel programs: memory before {any}, after {any}\n", .{ before, now });
        return 5;
    }
    first.* = par_first_failure.load(.monotonic);
    if (par_failures.load(.monotonic) != 0) return 2;
    // Eight threads that mostly sleep in `wait`, and their programs: with
    // more than one CPU taking threads, more than one took part.
    if (schedulingCpus() > 1 and @popCount(seen_cpus.load(.monotonic)) < 2) return 3;
    if (process.liveCount() != live) return 4;
    return if (pmm.consistent()) 0 else 6;
}

// State of the kernel stress test.
const STRESS_WORKERS = 8;
const STRESS_ROUNDS = 250;
var stress_done: usize = 0;
var stress_errors: Atomic(usize) = .init(0);
var stress_spin: SpinLock = .{};
var stress_spin_count: u64 = 0;
var stress_mutex: Mutex = .{};
var stress_mutex_count: u64 = 0;
var stress_inside: usize = 0;
var stress_lock: SpinLock = .{};
var stress_queue: WaitQueue = .{};
var stress_tokens: u64 = 0;
var stress_taken: u64 = 0;
var stress_timeouts: Atomic(u64) = .init(0);
var stress_next_tag: Atomic(u64) = .init(1);

fn stressError() void {
    _ = stress_errors.fetchAdd(1, .monotonic);
}

/// One worker of `kernelStress`: every round uses each shared part of the
/// kernel once, in a way that shows if another thread got in.
fn stressWorker() void {
    const tag = stress_next_tag.fetchAdd(1, .monotonic);
    var pages: [6]u64 = undefined;
    for (0..STRESS_ROUNDS) |round| {
        noteCpu();
        const stamp = (tag << 32) | round;

        // Page allocator: nobody else gets or scribbles on these pages.
        var n: usize = 0;
        while (n < pages.len) : (n += 1) {
            pages[n] = pmm.alloc() orelse break;
            @as(*volatile u64, @ptrCast(@alignCast(pmm.physToVirt(pages[n])))).* = stamp;
        }

        // Heap: a block keeps its contents until it is freed.
        const size = 24 + (round * 37 + tag * 101) % 700;
        const block = heap.allocator.alloc(u8, size) catch null;
        if (block) |b| @memset(b, @truncate(stamp));

        // Spinlock: a read, a pause and a write lose no update.
        {
            const held = stress_spin.acquire();
            const seen = stress_spin_count;
            std.atomic.spinLoopHint();
            stress_spin_count = seen + 1;
            stress_spin.release(held);
        }

        // Mutex: one thread inside, also while the holder is switched away from.
        stress_mutex.lock();
        stress_inside += 1;
        if (stress_inside != 1) stressError();
        const seen = stress_mutex_count;
        if (round % 16 == 0) thread.yield();
        stress_mutex_count = seen + 1;
        stress_inside -= 1;
        stress_mutex.unlock();

        // Wait queue: hand a token to whoever waits, then wait for one,
        // with a timeout that often runs out at the moment a token comes:
        // the timer fires on the boot CPU, the waker runs on any.
        {
            const held = stress_lock.acquire();
            defer stress_lock.release(held);
            stress_tokens += 1;
            _ = stress_queue.wakeOne();
            var waited = false;
            while (stress_tokens == 0 and !waited) {
                waited = true;
                if (!stress_queue.waitTimeout(&stress_lock, 1)) _ = stress_timeouts.fetchAdd(1, .monotonic);
            }
            if (stress_tokens > 0) {
                stress_tokens -= 1;
                stress_taken += 1;
            }
            if (thread.current().wait_queue != null) stressError();
        }

        // Kernel stacks: mapping one and unmapping it again reaches every
        // CPU's TLB, and a new stack is usable memory from top to bottom.
        if (round % 8 == tag % 8) {
            if (kstack.alloc()) |stack| {
                stack[0] = @truncate(stamp);
                stack[stack.len - 1] = @truncate(stamp >> 8);
                if (stack[0] != @as(u8, @truncate(stamp))) stressError();
                kstack.free(stack);
            }
        }
        if (round % 32 == tag % 32) timer.sleepTicks(1);

        if (block) |b| {
            for (b) |byte| {
                if (byte != @as(u8, @truncate(stamp))) {
                    stressError();
                    break;
                }
            }
            heap.allocator.free(b);
        }
        for (pages[0..n], 0..) |page, i| {
            if (@as(*volatile u64, @ptrCast(@alignCast(pmm.physToVirt(page)))).* != stamp) stressError();
            for (pages[0..i]) |other| {
                if (other == page) stressError();
            }
            pmm.free(page);
        }
    }
    signalDone(&stress_done, &done_queue);
}

/// Use every shared part of the kernel from all CPUs at once: eight kernel
/// threads allocate and free pages, heap blocks and kernel stacks, count
/// under a spinlock and under a mutex, pass tokens through a wait queue
/// with timeouts, sleep and yield. Afterwards nothing was handed out
/// twice or overwritten, no update was lost, every token was taken once,
/// no timer is left armed, memory is back, and (with more than one CPU
/// running threads) the kernel stacks that were freed were flushed from
/// the other CPUs' TLBs by request. Must be called with interrupts on.
/// Returns 0, or the number of the first failing check.
pub fn kernelStress() u32 {
    const before = footprint();
    const timers_before = timer.pending();
    const requests_before = ipi.requestsSent();
    stress_done = 0;
    stress_errors.store(0, .monotonic);
    stress_spin_count = 0;
    stress_mutex_count = 0;
    stress_inside = 0;
    stress_tokens = 0;
    stress_taken = 0;
    stress_timeouts.store(0, .monotonic);
    seen_cpus.store(0, .monotonic);
    for (0..STRESS_WORKERS) |_| _ = thread.spawn(stressWorker, null) catch return 1;
    waitForDone(&stress_done, STRESS_WORKERS, &done_queue);

    const total = STRESS_WORKERS * STRESS_ROUNDS;
    if (stress_errors.load(.monotonic) != 0) return 2;
    if (stress_spin_count != total) return 3;
    if (stress_mutex_count != total or stress_mutex.owner != null or stress_mutex.waiterCount() != 0) return 4;
    {
        const held = stress_lock.acquire();
        defer stress_lock.release(held);
        if (stress_taken + stress_tokens != total) return 5; // a token lost, or taken twice
        if (stress_queue.waiting() != 0) return 6;
    }
    if (timer.pending() != timers_before) return 7;
    const cpus = schedulingCpus();
    if (cpus > 1 and @popCount(seen_cpus.load(.monotonic)) < 2) return 8;
    if (percpu.count() > 1 and ipi.requestsSent() == requests_before) return 9;
    if (!pmm.consistent()) return 10;
    return if (untilFootprint(before)) 0 else 11;
}

// State of the TLB shootdown test.
const TLB_READERS = 8;
/// What the readers are to do: read the page and expect this value, or 0: keep off it.
var tlb_expect: Atomic(u64) = .init(0);
/// Per reader: the last value of `tlb_expect` it has acted on.
var tlb_acked: [TLB_READERS]Atomic(u64) = @splat(.init(0));
var tlb_stop: Atomic(bool) = .init(false);
var tlb_errors: Atomic(usize) = .init(0);
var tlb_next_reader: Atomic(usize) = .init(0);
var tlb_done: usize = 0;
/// An acknowledgement of "keep off": no value a page holds.
const TLB_OFF: u64 = ~@as(u64, 0);

/// Read the shared page whenever told to, so that this thread's CPU has it
/// in its TLB, and say so.
fn tlbReader() void {
    const me = tlb_next_reader.fetchAdd(1, .monotonic);
    const here: *volatile u64 = @ptrFromInt(SPARE_KERNEL_PAGE);
    while (!tlb_stop.load(.acquire)) {
        // Interrupts off around "look, then read": the page is only taken
        // away after this reader has said it keeps off, and it cannot be
        // switched away from in between and say so late.
        const flags = cpu.saveAndDisableInterrupts();
        const want = tlb_expect.load(.acquire);
        if (want != 0) {
            if (here.* != want) _ = tlb_errors.fetchAdd(1, .monotonic);
            _ = seen_cpus.fetchOr(@as(u64, 1) << @intCast(percpu.current().id), .monotonic);
            tlb_acked[me].store(want, .release);
        } else tlb_acked[me].store(TLB_OFF, .release);
        cpu.restoreInterrupts(flags);
        thread.yield();
    }
    signalDone(&tlb_done, &done_queue);
}

/// Let other threads run until every reader has acted on `value`.
fn tlbUntilAcked(value: u64) bool {
    for (0..100_000) |_| {
        var all = true;
        for (&tlb_acked) |*a| {
            if (a.load(.acquire) != value) all = false;
        }
        if (all) return true;
        thread.yield();
    }
    return false;
}

/// Check that removing a kernel mapping reaches every CPU. Eight threads,
/// spread over the CPUs, read one page of kernel address space until each
/// has its translation cached; then the page is unmapped, its memory
/// overwritten, and another page mapped at the same address. A CPU that
/// still used the old translation would read the old page: its old
/// contents, or what it was overwritten with. Repeated many times, with
/// the readers moving between CPUs. Must be called with interrupts on.
/// Returns 0, or the number of the first failing check.
pub fn tlbShootdown() u32 {
    const ROUNDS = 60;
    const before = footprint();
    const requests_before = ipi.requestsSent();
    const kernel_rw = vmm.WRITABLE | vmm.NX;
    tlb_expect.store(0, .monotonic);
    tlb_stop.store(false, .monotonic);
    tlb_errors.store(0, .monotonic);
    tlb_next_reader.store(0, .monotonic);
    for (&tlb_acked) |*a| a.store(0, .monotonic);
    seen_cpus.store(0, .monotonic);
    tlb_done = 0;
    for (0..TLB_READERS) |_| _ = thread.spawn(tlbReader, null) catch return 1;

    var failed: u32 = 0;
    var previous: ?u64 = null;
    for (1..ROUNDS + 1) |round| {
        const value: u64 = 0x7100_0000 + round;
        const page = pmm.alloc() orelse {
            failed = 2;
            break;
        };
        @as(*volatile u64, @ptrCast(@alignCast(pmm.physToVirt(page)))).* = value;
        vmm.map(vmm.kernel_root, SPARE_KERNEL_PAGE, page, kernel_rw, false) catch {
            pmm.free(page);
            failed = 3;
            break;
        };
        // The page before this one is free to be reused only now, when the
        // address has stopped meaning it on every CPU.
        if (previous) |old| pmm.free(old);
        previous = page;

        tlb_expect.store(value, .release);
        if (!tlbUntilAcked(value)) failed = 4; // every reader has read it: it is in their CPUs' TLBs
        tlb_expect.store(0, .release);
        if (!tlbUntilAcked(TLB_OFF)) failed = 5; // and now nobody touches the address
        if (vmm.unmap(vmm.kernel_root, SPARE_KERNEL_PAGE) != page) failed = 6;
        // What a stale translation would now read instead of the next value.
        @as(*volatile u64, @ptrCast(@alignCast(pmm.physToVirt(page)))).* = 0xDEAD_0000 + round;
        if (failed != 0) break;
    }
    tlb_stop.store(true, .release);
    waitForDone(&tlb_done, TLB_READERS, &done_queue);
    if (previous) |old| pmm.free(old);
    if (failed != 0) return failed;
    if (tlb_errors.load(.monotonic) != 0) return 7; // a reader saw a page that had been unmapped
    if (schedulingCpus() > 1 and @popCount(seen_cpus.load(.monotonic)) < 2) return 8;
    if (percpu.count() > 1 and ipi.requestsSent() < requests_before + ROUNDS) return 9;
    return if (untilFootprint(before)) 0 else 10;
}

/// Thread body for the `panic_smp` scenario: print without end.
fn chatter() void {
    while (true) kernel_root.print("chatter from thread {d}\n", .{thread.id()});
}

/// For the `panic_smp` scenario: start a thread for every CPU that prints
/// without end, and give them time to get going. Returns the number
/// started, or null if one could not be.
pub fn startChatter() ?usize {
    const n = percpu.count();
    for (0..n) |_| _ = thread.spawn(chatter, null) catch return null;
    timer.sleepTicks(5);
    return n;
}

// ---------------------------------------------------------------------------
// Process and scheduler lifecycle (roadmap 2.7)

/// Sleep until `p` has exited and its thread has been freed, so that the
/// caller's reference is the only one left. False if that takes more than
/// a few seconds.
fn untilTornDown(p: *const process.Process) bool {
    for (0..500) |_| {
        if (p.exit_code != null and p.root == 0 and @atomicLoad(u32, &p.refs, .monotonic) == 1) return true;
        timer.sleepTicks(1);
    }
    return false;
}

/// Sleep until only `count` process structures exist. False on timeout.
fn untilLive(count: usize) bool {
    for (0..500) |_| {
        if (process.liveCount() == count) return true;
        timer.sleepTicks(1);
    }
    return false;
}

var second_waiter_code: ?u64 = null;
var second_waiter_target: ?*process.Process = null;
var second_waiter_done: WaitQueue = .{};

/// Wait for the same process as the test thread does, with its own reference.
fn secondWaiter() void {
    const code = process.wait(second_waiter_target.?);
    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    const held = test_lock.acquire();
    defer test_lock.release(held);
    second_waiter_code = code;
    _ = second_waiter_done.wakeAll();
}

/// Check the lifetime of a process as seen by whoever started it: its exit
/// status is there however late it is asked for; its files are closed and
/// its memory freed when it exits, not when it is waited for; several
/// threads can wait for it; and nobody has to. Must be called with
/// interrupts on. Returns 0, or the number of the first failing check.
pub fn processWaiting() u32 {
    const before = footprint();
    const live = process.liveCount();
    const threads_alive = thread.spawnedCount() - thread.reapedCount();

    // Exited long before the wait. It opens 13 files and leaves them open.
    const early = process.spawnPath("/test/open_count", .{}) catch return 1;
    if (process.liveCount() != live + 1) return 2;
    if (!untilTornDown(early)) return 3;
    if (early.exit_code != 13) return 4;
    for (early.files) |f| {
        if (f != null) return 5; // closed at exit
    }
    // All it still holds is the structure and its name: no pages, no stack.
    const zombie = footprint();
    if (zombie.pages != before.pages or zombie.stacks != before.stacks) {
        kernel_root.print("  process wait: before {any}, with the exited process {any}\n", .{ before, zombie });
        return 6;
    }
    if (zombie.heap_bytes <= before.heap_bytes) return 7;
    if (thread.spawnedCount() - thread.reapedCount() != threads_alive) return 8; // its thread was reaped
    if (early.refs != 1 or early.parent != null) return 9;
    if (process.wait(early) != 13) return 10; // returns at once
    if (process.liveCount() != live or !footprint().eql(before)) return 11;

    // Two threads wait for one process; both get the status.
    const shared = process.spawnPath("/test/open_count", .{ .limits = .{ .max_files = 7 } }) catch return 12;
    process.retain(shared);
    second_waiter_code = null;
    second_waiter_target = shared;
    {
        const irq = cpu.saveAndDisableInterrupts();
        defer cpu.restoreInterrupts(irq);
        _ = thread.spawn(secondWaiter, null) catch return 13;
        if (process.wait(shared) != 4) return 14;
        const held = test_lock.acquire();
        defer test_lock.release(held);
        while (second_waiter_code == null) second_waiter_done.wait(&test_lock);
    }
    if (second_waiter_code != 4) return 15;
    if (!untilLive(live)) return 16;

    // Nobody waits: the reference is given up while it runs, and it is
    // freed when it ends.
    const detached = process.spawnPath("/bin/hello", .{}) catch return 17;
    process.release(detached);
    if (process.liveCount() != live + 1) return 18;
    if (!untilLive(live)) return 19;

    timer.sleepTicks(1);
    if (thread.spawnedCount() - thread.reapedCount() != threads_alive) return 20;
    return if (footprint().eql(before)) 0 else 21;
}

/// Check what happens when a parent exits before its child: the child is
/// handed to its grandparent, the counts of descendants stay right, and the
/// child still exits cleanly. A stand-in grandparent shows the counts.
/// Returns 0, or the number of the first failing check.
pub fn orphanedChild() u32 {
    const before = footprint();
    const live = process.liveCount();
    var grandparent: process.Process = .{ .root = 0, .entry = 0, .name = "test grandparent" };

    // Parent and child each wait for a key; the parent has waited longer,
    // so the first key is its, and it exits first.
    while (keyboard.getChar() != null) {}
    const parent = process.spawnPath("/test/getchar", .{ .parent = &grandparent }) catch return 1;
    if (!untilCount(keyboard.waitingReaders, 1)) return 13;
    const child = process.spawnPath("/test/getchar", .{ .parent = parent }) catch return 2;
    if (!untilCount(keyboard.waitingReaders, 2)) return 13;
    if (grandparent.descendants != 2 or parent.descendants != 1 or
        grandparent.first_child != parent or parent.first_child != child or child.parent != parent) return 3;

    keyboard.inject('p');
    if (process.wait(parent) != 'p') return 4; // `parent` is gone after this
    // The child is still running, and is now the grandparent's.
    if (child.exit_code != null) return 5; // it should have outlived its parent
    if (child.parent != &grandparent) return 6;
    if (grandparent.first_child != child or child.next_sibling != null) return 7;
    if (grandparent.descendants != 1) return 8;

    keyboard.inject('k');
    if (process.wait(child) != 'k') return 9;
    if (grandparent.descendants != 0 or grandparent.first_child != null) return 10;
    if (!untilLive(live)) return 11;
    timer.sleepTicks(1);
    return if (footprint().eql(before)) 0 else 12;
}

/// Start and end processes many times in every way there is: waited for at
/// once, waited for late, in reverse order, never waited for, killed by a
/// fault, and failing to start for several reasons. Afterwards no process,
/// thread, stack, page or heap byte is left over, and every thread that
/// was created has been reaped. `rounds` is the number of repetitions.
/// Returns 0, or the number of the first failing check.
pub fn lifecycleStress(rounds: usize) u32 {
    const before = footprint();
    const live = process.liveCount();
    const threads_alive = thread.spawnedCount() - thread.reapedCount();
    const switches = thread.switchCount();

    for (0..rounds) |round| {
        // Waited for at once.
        if (runProgram("/test/entry_regs") != 0) return 1;
        // Two at a time, collected in reverse order: the first has usually
        // exited long before it is waited for.
        const a = process.spawnPath("/test/entry_regs", .{}) catch return 2;
        const b = process.spawnPath("/test/open_count", .{}) catch return 3;
        if (process.wait(b) != 13) return 4;
        if (process.wait(a) != 0) return 5;
        // Never waited for.
        const detached = process.spawnPath("/test/entry_regs", .{}) catch return 6;
        process.release(detached);
        // A child that starts children of its own.
        if (runProgramLimited("/test/run_many", .{ .max_descendants = 1 }) != 8) return 7;
        // Starts that fail: no such file, not a program, over a limit.
        if (runProgram("/does/not/exist") != null) return 8;
        if (runProgram("/etc/motd") != null) return 9;
        if (spawnError("/bin/hello", .{ .max_pages = 6 }) == null) return 10;
        // Killed by the kernel (one in ten rounds: each prints a fault report).
        if (round % 10 == 0 and runProgram("/test/div_zero") != process.EXIT_KILLED) return 11;
        // A chain that is cut off by a limit, each parent waiting on its child.
        if (round % 5 == 0 and runProgramLimited("/test/recurse", .{ .max_descendants = 3 }) != 103) return 12;
    }

    if (!untilLive(live)) return 13; // the detached ones have finished too
    timer.sleepTicks(1);
    if (thread.spawnedCount() - thread.reapedCount() != threads_alive) return 14; // every thread reaped
    if (thread.switchCount() == switches) return 15;
    if (!pmm.consistent()) return 16;
    return if (footprint().eql(before)) 0 else 17;
}

/// Turn interrupts on for a test that needs to be preempted or to see
/// interrupt state change. The test thread otherwise runs with them off.
/// Returns what to pass to `restoreInterrupts`.
pub fn enableInterrupts() u64 {
    const flags = cpu.readFlags();
    asm volatile ("sti");
    return flags;
}

/// Put the interrupt state back as `enableInterrupts` found it.
pub fn restoreInterrupts(flags: u64) void {
    if (flags & RFLAGS_IF == 0) asm volatile ("cli");
}

// ---------------------------------------------------------------------------
// Further hardening (roadmap 2.9)

var random_buf: [64 * 1024]u8 = undefined;

/// Check the kernel's random-number generator: it is seeded (from the CPU
/// where there is one), its output does not repeat and is balanced, bounded
/// values are in bounds and cover their range, and a seed from timing alone
/// still differs between two takes. Returns 0, or the number of the first
/// failing check.
pub fn randomChecks() u32 {
    if (!random.isReady()) return 1;
    // QEMU's `max` CPU has RDRAND and RDSEED; the boot log names the source.
    const leaf1 = cpu.cpuid(1, 0);
    if (random.hardwareSeeded() != (leaf1.ecx & (1 << 30) != 0 or cpu.cpuid(7, 0).ebx & (1 << 18) != 0)) return 2;

    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    random.bytes(&a);
    random.bytes(&b);
    if (std.mem.eql(u8, &a, &b) or std.mem.allEqual(u8, &a, a[0])) return 3;

    // 524 288 bits: half of them set, give or take (standard deviation 362).
    random.bytes(&random_buf);
    var ones: usize = 0;
    var seen: [256]bool = @splat(false);
    for (&random_buf) |byte| { // by reference: a copy would be 64 KiB of stack
        ones += @popCount(byte);
        seen[byte] = true;
    }
    if (ones < 262_144 - 3000 or ones > 262_144 + 3000) return 4;
    if (!std.mem.allEqual(bool, &seen, true)) return 5;

    // Bounded values: always below the bound, and every value of a small
    // range turns up.
    if (random.below(1) != 0) return 6;
    var hit: [10]bool = @splat(false);
    for (0..2000) |_| {
        const v = random.below(10);
        if (v >= 10) return 7;
        hit[v] = true;
    }
    if (!std.mem.allEqual(bool, &hit, true)) return 8;
    for ([_]u64{ 2, 3, 1 << 22, (1 << 63) + 12345, std.math.maxInt(u64) }) |bound| {
        for (0..50) |_| {
            if (random.below(bound) >= bound) return 9;
        }
    }
    if (random.int(u64) == random.int(u64)) return 10;

    // More than a megabyte has been produced by now, so the generator has
    // gone back to the hardware at least once; it must simply keep working.
    for (0..20) |_| random.bytes(&random_buf);
    random.addEntropy("anything at all");
    random.bytes(&a);
    random.bytes(&b);
    if (std.mem.eql(u8, &a, &b)) return 11;

    // Without RDSEED and RDRAND the seed rests on timing; two takes differ.
    const t1 = random.timingOnlyOutput();
    const t2 = random.timingOnlyOutput();
    if (std.mem.eql(u8, &t1, &t2)) return 12;
    return 0;
}

/// Check that freed memory is poisoned and that memory for user programs
/// is zeroed: a freed heap block and a freed page hold the poison bytes,
/// and `allocZeroed` hands out zeroes even for a page that was just full
/// of something else. Returns 0, or the number of the first failing check.
pub fn poisonAndZero() u32 {
    if (!heap.poison or !pmm.poison) return 1; // always on in the test kernel
    const flags = cpu.saveAndDisableInterrupts(); // nothing else may allocate in between
    defer cpu.restoreInterrupts(flags);

    // Heap: after the 16 bytes the free list uses, a freed block is poison.
    const block = heap.allocator.alloc(u8, 256) catch return 2;
    @memset(block, 0x77);
    const where = block.ptr;
    heap.allocator.free(block);
    for (where[16..256]) |byte| {
        if (byte != heap.POISON) return 3;
    }
    // Taking it again finds the poison intact (no panic) and gives the same block.
    const again = heap.allocator.alloc(u8, 256) catch return 4;
    if (again.ptr != where) return 5;
    heap.allocator.free(again);

    // Pages: a freed page is poison from end to end.
    const page = pmm.alloc() orelse return 6;
    const bytes = pmm.physToVirt(page)[0..pmm.PAGE_SIZE];
    @memset(bytes, 0x77);
    pmm.free(page);
    if (!std.mem.allEqual(u8, bytes, pmm.POISON)) return 7;
    // A poisoned pointer is not a canonical address: following it faults.
    const as_pointer = std.mem.readInt(u64, bytes[0..8], .little);
    if (as_pointer >> 47 == 0 or as_pointer >> 47 == 0x1FFFF) return 8;

    // The same page again, for a user: all zero.
    const zeroed = pmm.allocZeroed() orelse return 9;
    if (zeroed != page) return 10; // the allocator starts at the lowest free page
    if (!std.mem.allEqual(u8, bytes, 0)) return 11;
    pmm.free(zeroed);
    return 0;
}

/// Fill every free page with a pattern (by taking them all and giving them
/// back), so a page that reaches a program without being cleared is noticed.
pub fn dirtyFreeMemory() void {
    _ = drainMemory(0);
    var page = drained_head;
    while (page != 0) {
        const bytes = pmm.physToVirt(page)[0..pmm.PAGE_SIZE];
        const next = std.mem.readInt(u64, bytes[0..8], .little);
        @memset(bytes[8..], 0xA5);
        page = next;
    }
    releaseDrained(); // with poisoning on, freeing fills them again; either way, not zero
}

// A value in kernel memory that the user-copy routines must never give out,
// and one they must never overwrite.
var clamp_secret: u64 = 0x5EC2_E75E_C2E7_5EC2;
var clamp_target: u64 = 0x7A26_E77A_26E7_7A26;

/// Check the speculation guards: the branch-free index clamp gives the
/// index inside the bounds and 0 outside, for every boundary; and the
/// user-copy routines clamp the user address the same way, so that even
/// called without the range check (which is what a mispredicted check
/// amounts to) they cannot read or write kernel memory: an address outside
/// user space is treated as address 0, and the copy fails. Returns 0, or the
/// number of the first failing check.
pub fn speculationGuards() u32 {
    const cases = [_]struct { i: usize, len: usize, want: usize }{
        .{ .i = 0, .len = 16, .want = 0 },
        .{ .i = 1, .len = 16, .want = 1 },
        .{ .i = 15, .len = 16, .want = 15 },
        .{ .i = 16, .len = 16, .want = 0 }, // one past the end
        .{ .i = 17, .len = 16, .want = 0 },
        .{ .i = std.math.maxInt(usize), .len = 16, .want = 0 },
        .{ .i = 1 << 63, .len = 16, .want = 0 }, // "negative"
        .{ .i = 0, .len = 0, .want = 0 },
        .{ .i = 5, .len = 0, .want = 0 },
        .{ .i = 0, .len = 1, .want = 0 },
        .{ .i = std.math.maxInt(usize) - 1, .len = std.math.maxInt(usize), .want = std.math.maxInt(usize) - 1 },
        .{ .i = std.math.maxInt(usize), .len = std.math.maxInt(usize), .want = 0 },
    };
    for (cases, 1..) |c, n| {
        // Through a volatile load, so the compiler cannot work the answer out itself.
        var i = c.i;
        var len = c.len;
        const pi: *volatile usize = &i;
        const pl: *volatile usize = &len;
        if (nospec.index(pi.*, pl.*) != c.want) return @intCast(n);
    }

    const flags = cpu.saveAndDisableInterrupts(); // one address space throughout
    defer cpu.restoreInterrupts(flags);
    const end = kernel_root.kernel.user_range.USER_END;
    var buf: u64 = 0x1111_1111_1111_1111;
    const buf_addr = @intFromPtr(&buf);
    const pbuf: *volatile u64 = &buf;
    const psecret: *volatile u64 = &clamp_secret;
    const ptarget: *volatile u64 = &clamp_target;
    const secret = psecret.*;
    const target = ptarget.*;

    // Reading from kernel addresses: readable memory, yet the copy fails
    // and brings nothing back.
    const kernel_sources = [_]u64{
        @intFromPtr(&clamp_secret), // kernel data
        @intFromPtr(pmm.physToVirt(vmm.kernel_root)), // the direct map
        end, // the first address that is not the user's
        end + 1,
        0xFFFF_8000_0000_0000,
        std.math.maxInt(u64) - 7,
    };
    for (kernel_sources, 0..) |src, n| {
        if (usercopy.copyFromUser(buf_addr, src, 8)) return 20 + @as(u32, @intCast(n));
        if (pbuf.* != 0x1111_1111_1111_1111) return 30 + @as(u32, @intCast(n));
    }
    // Writing to a kernel address: writable memory, yet nothing is written.
    if (usercopy.copyToUser(@intFromPtr(&clamp_target), buf_addr, 8)) return 40;
    if (ptarget.* != target or psecret.* != secret) return 41;
    if (usercopy.copyToUser(end, buf_addr, 8)) return 42;
    // An empty copy touches nothing, wherever it points.
    if (!usercopy.copyFromUser(buf_addr, @intFromPtr(&clamp_secret), 0)) return 43;
    if (!usercopy.copyToUser(end, buf_addr, 0)) return 44;
    // The last user address is not clamped away: it is simply not mapped.
    if (usercopy.copyFromUser(buf_addr, end - 8, 8)) return 45;
    // The user-access window is closed after every one of these.
    if (cpu.readFlags() & (1 << 18) != 0) return 46; // RFLAGS.AC
    return 0;
}

/// Check the Meltdown decision made at boot against this CPU: the kernel
/// is running, so either the CPU is not affected or the build allows it.
/// Returns 0, or the number of the first failing check.
pub fn meltdownDecision() u32 {
    const info = meltdown.thisCpu();
    if (meltdown.cpuAffected() != meltdown.affected(info)) return 1;
    // The test runs under QEMU's emulated CPU or a current host CPU;
    // neither is affected. (An affected one would not have booted.)
    if (meltdown.cpuAffected()) return 2;
    const fm = meltdown.familyModel(cpu.cpuid(1, 0).eax);
    if (fm.family != info.family or fm.model != info.model) return 3;
    return 0;
}

/// Check address randomization of user stacks: each new process gets a
/// page-aligned stack top somewhere in the 16 GiB range, a different one
/// nearly every time, and starts with a stack pointer on a 16-byte
/// boundary a varying distance below it, within the top page; with
/// randomization off, the stack is at the fixed top and the distance is
/// always the same. Returns 0, or the number of the first
/// failing check.
pub fn stackRandomization() u32 {
    const flags = cpu.saveAndDisableInterrupts(); // read each process before it runs
    defer cpu.restoreInterrupts(flags);
    var tops: [24]u64 = undefined;
    var offsets_differ = false;
    var first_offset: u64 = 0;
    for (&tops, 0..) |*top, n| {
        const p = process.spawnPath("/test/entry_regs", .{}) catch return 1;
        top.* = p.stack_top;
        const offset = p.stack_top - p.entry_rsp;
        const range = process.STACK_RANDOM_PAGES * pmm.PAGE_SIZE;
        const ok = p.stack_top % pmm.PAGE_SIZE == 0 and
            p.stack_top <= process.STACK_TOP_MAX and p.stack_top > process.STACK_TOP_MAX - range and
            p.entry_rsp % 16 == 0 and offset >= 16 and offset < pmm.PAGE_SIZE and
            vmm.translate(p.root, p.stack_top - 1) != null and vmm.translate(p.root, p.stack_top) == null;
        if (n == 0) first_offset = offset else if (offset != first_offset) offsets_differ = true;
        if (process.wait(p) != 0) return 2; // the program runs with that stack
        if (!ok) return 3;
    }
    // 24 draws from four million positions: any repeat is a broken generator.
    for (tops, 0..) |a, i| {
        for (tops[0..i]) |b| {
            if (a == b) return 4;
        }
    }
    if (!offsets_differ) return 5;
    // They are spread over the range, not bunched at one end.
    var low: u64 = std.math.maxInt(u64);
    var high: u64 = 0;
    for (tops) |t| {
        low = @min(low, t);
        high = @max(high, t);
    }
    if (high - low < 1 << 30) return 6; // 24 draws spanning under 1 GiB of 16

    var fixed_rsp: [2]u64 = undefined;
    for (&fixed_rsp) |*rsp| {
        const fixed = process.spawnPath("/test/entry_regs", .{ .randomize = false }) catch return 7;
        rsp.* = fixed.entry_rsp;
        const fixed_ok = fixed.stack_top == process.STACK_TOP_MAX and fixed.entry_rsp % 16 == 0 and fixed.entry_rsp < process.STACK_TOP_MAX;
        if (process.wait(fixed) != 0) return 8;
        if (!fixed_ok) return 9;
    }
    return if (fixed_rsp[0] == fixed_rsp[1]) 0 else 10;
}

/// How far the kernel was loaded from its link address.
pub fn kernelSlide() u64 {
    return backtrace.slide();
}

/// Check that the kernel runs correctly wherever it was loaded: the slide
/// is a whole number of pages inside the top 2 GiB, code and data are where
/// the slide says, and symbol lookup takes it into account. Returns 0, or
/// the number of the first failing check.
pub fn kernelRelocation() u32 {
    const slide = backtrace.slide();
    if (slide % pmm.PAGE_SIZE != 0) return 1;
    if (slide >= 0x8000_0000) return 2; // beyond the top 2 GiB
    const here = @intFromPtr(&kernelRelocation);
    // The image is near the top of the address space: compare distances, since
    // "base + 64 MiB" does not fit in 64 bits when the slide is large.
    if (here < backtrace.LINK_BASE + slide or here - (backtrace.LINK_BASE + slide) >= 64 * 1024 * 1024) return 3;
    // A function's own address is found under its own name.
    const sym = backtrace.symbolize(here) orelse return 4;
    if (sym.offset != 0 or !std.mem.endsWith(u8, sym.name, "kernelRelocation")) return 5;
    // Pointers stored in data (relocated by the bootloader) agree with
    // addresses computed by code (relative to the instruction pointer).
    const stored: *const volatile *const fn () u32 = &relocated_pointer;
    if (@intFromPtr(stored.*) != here) return 6;
    return 0;
}

/// A pointer in initialized data: the linker cannot know its final value,
/// so the bootloader has to fix it up when it moves the kernel.
var relocated_pointer: *const fn () u32 = &kernelRelocation;

/// For the `use_after_free` scenario: write to a heap block after freeing
/// it, then allocate again. The allocator must notice and panic.
pub noinline fn writeAfterFree() void {
    const block = heap.allocator.alloc(u8, 128) catch return;
    const stale = block.ptr;
    heap.allocator.free(block);
    stale[64] = 0x42; // the bug
    const again = heap.allocator.alloc(u8, 128) catch return;
    heap.allocator.free(again);
}

// ---------------------------------------------------------------------------
// Review follow-ups (2.10): idling, global mappings, address spaces of kernel
// threads, and what in the kernel is writable.

const PTE_PRESENT: u64 = vmm.PRESENT;

/// A kernel address nothing else maps, for `kernelTlbFlush`.
const SPARE_KERNEL_PAGE: u64 = 0xFFFF_B000_0010_0000;

var hog_done: usize = 0;
var hog_switches: usize = 0;
var hog_halts: usize = 0;
/// How long the CPU-bound thread of `idleChecks` runs: several time slices.
const HOG_NS = 200_000_000;

/// Kernel thread for `idleChecks`: use the CPU for `HOG_NS` without ever
/// blocking, and note how often it was switched away from and how often the
/// CPU was halted in that time.
fn hogWorker() void {
    const switches = thread.switchCount();
    const halts = thread.haltCount();
    const until = hpet.nanos() + HOG_NS;
    while (hpet.nanos() < until) {}
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    hog_switches = thread.switchCount() - switches;
    hog_halts = thread.haltCount() - halts;
    signalDone(&hog_done, &done_queue);
}

var retired_started = false;
var retired_returned = false;

/// Kernel thread for `idleChecks`: retire, as the boot thread does.
fn retiredWorker() void {
    retired_started = true;
    thread.retire();
    retired_returned = true; // unreachable: `retire` never returns
}

/// Check that the CPU is never left idle while a thread could run, and
/// sleeps when none can.
///
/// A thread retires for good, as the boot thread of the normal kernel does
/// once the system is up. Then, with this thread blocked, one CPU-bound
/// thread is the only thing that can run: over several time slices it must
/// never be switched away from and the CPU must never be halted (an idle
/// thread that took turns with the others would fail both). Finally, with nothing
/// ready at all, the CPU does halt. Returns 0, or the number of the first
/// failing check.
///
/// The retired thread and its stack stay for the rest of the run: that is
/// what retiring means.
pub fn idleChecks() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);

    retired_started = false;
    const retired = thread.spawn(retiredWorker, null) catch return 1;
    thread.yield(); // let it run up to its `block`
    if (!retired_started or retired.state != .blocked or retired.link != .none) return 2;
    alive_at_start += 1; // it stays: `quiesce` is not to wait for it

    hog_done = 0;
    _ = thread.spawn(hogWorker, null) catch return 3;
    const t0 = hpet.nanos();
    waitForDone(&hog_done, 1, &done_queue);
    const elapsed = hpet.nanos() - t0;
    if (hog_switches != 0) return 4; // something else was given the CPU
    if (hog_halts != 0) return 5; // the CPU slept while the thread was ready
    // It started at once and nothing delayed it: within a tick of its own run time.
    if (elapsed < HOG_NS or elapsed > HOG_NS + 2 * timer.NS_PER_TICK) return 6;
    if (retired.state != .blocked or retired_returned) return 7; // it never ran again

    // Nothing is ready now: sleeping halts the CPU instead of spinning.
    const halts = thread.haltCount();
    timer.sleepTicks(3);
    if (thread.haltCount() == halts) return 8;
    if (retired.state != .blocked or retired_returned) return 9;
    return 0;
}

/// The leaf entry that maps `addr` in the kernel's page tables, or 0.
fn kernelLeaf(addr: u64) u64 {
    return vmm.leafEntry(vmm.kernel_root, addr) orelse 0;
}

/// Check that kernel mappings are global and user mappings are not: CR4.PGE
/// is on; code, constants, data, the heap, a kernel stack and the direct
/// map all have the global bit, in the kernel's page tables and seen from
/// another address space; a user page has not, even if the caller asks for
/// it. Returns 0, or the number of the first failing check.
pub fn globalMappings() u32 {
    if (cpu.readCr4() & (1 << 7) == 0) return 1; // CR4.PGE
    const block = heap.allocator.alloc(u8, 64) catch return 2;
    defer heap.allocator.free(block);
    const stack = thread.current().stack orelse return 3;
    const page = pmm.alloc() orelse return 4;
    defer pmm.free(page);
    const kernel_addrs = [_]u64{
        @intFromPtr(&globalMappings), // code
        @intFromPtr("a string constant".ptr), // read-only data
        @intFromPtr(&hog_done), // data
        @intFromPtr(block.ptr), // heap
        @intFromPtr(stack.ptr), // kernel stack
        @intFromPtr(pmm.physToVirt(page)), // direct map
    };
    for (kernel_addrs, 0..) |addr, n| {
        const e = kernelLeaf(addr);
        if (e & PTE_PRESENT == 0 or e & vmm.GLOBAL == 0) return 10 + @as(u32, @intCast(n));
    }

    const root = vmm.createAddressSpace() catch return 5;
    defer vmm.destroyAddressSpace(root);
    for (kernel_addrs, 0..) |addr, n| {
        if (vmm.leafEntry(root, addr) != kernelLeaf(addr)) return 20 + @as(u32, @intCast(n));
    }
    const user_page = pmm.allocZeroed() orelse return 6;
    vmm.map(root, VM_A, user_page, USER_RW | vmm.GLOBAL, false) catch {
        pmm.free(user_page);
        return 7;
    };
    const user_leaf = vmm.leafEntry(root, VM_A) orelse return 8;
    if (user_leaf & vmm.GLOBAL != 0) return 9;
    return 0;
}

/// Check that `unmap` flushes a kernel address from the TLB although the
/// entry is global: after a page has been read through its mapping,
/// unmapping it and mapping another page there shows the new page, also
/// after loading another address space in between (which keeps global
/// entries). Returns 0, or the number of the first failing check.
pub fn kernelTlbFlush() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const start = pmm.free_pages;
    const p1 = pmm.alloc() orelse return 1;
    const p2 = pmm.alloc() orelse return 2;
    const root = vmm.createAddressSpace() catch return 3;
    const previous = vmm.loadedRoot();
    pmm.physToVirt(p1)[0] = 0x11;
    pmm.physToVirt(p2)[0] = 0x22;
    const here: *volatile u8 = @ptrFromInt(SPARE_KERNEL_PAGE);
    const kernel_rw = vmm.WRITABLE | vmm.NX;

    var failed: u32 = 0;
    for (0..50) |round| {
        vmm.map(vmm.kernel_root, SPARE_KERNEL_PAGE, p1, kernel_rw, false) catch return 4;
        if (kernelLeaf(SPARE_KERNEL_PAGE) & vmm.GLOBAL == 0) failed = 5;
        if (here.* != 0x11) failed = 6; // now cached in the TLB, as a global entry
        if (round % 2 == 1) vmm.loadRoot(root); // a CR3 load keeps it there
        if (here.* != 0x11) failed = 7;
        if (vmm.unmap(vmm.kernel_root, SPARE_KERNEL_PAGE) != p1) failed = 8;
        vmm.map(vmm.kernel_root, SPARE_KERNEL_PAGE, p2, kernel_rw, false) catch return 9;
        if (here.* != 0x22) failed = 10; // a stale entry would read 0x11
        here.* = 0x33; // and a write goes to the new page
        if (pmm.physToVirt(p2)[0] != 0x33 or pmm.physToVirt(p1)[0] != 0x11) failed = 11;
        pmm.physToVirt(p2)[0] = 0x22;
        if (vmm.unmap(vmm.kernel_root, SPARE_KERNEL_PAGE) != p2) failed = 12;
        if (round % 2 == 1) vmm.loadRoot(previous);
        if (failed != 0) break;
    }
    vmm.loadRoot(previous);
    vmm.destroyAddressSpace(root);
    pmm.free(p1);
    pmm.free(p2);
    if (failed != 0) return failed;
    return if (pmm.free_pages == start and kernelLeaf(SPARE_KERNEL_PAGE) == 0) 0 else 13;
}

/// Check which address space a kernel thread runs on. This thread (a kernel
/// thread) takes turns with a process for many switches: CR3 is loaded once
/// when the process first runs and never again while the two alternate,
/// because this thread keeps the process's address space loaded. When the
/// process has exited, its address space is still the loaded one; tearing
/// it down switches to the kernel's own page tables first. So the whole run
/// costs exactly two CR3 loads. Returns 0, or the number of the first
/// failing check.
pub fn kernelThreadAddressSpace() u32 {
    if (cpu.readCr3() & ~@as(u64, 0xFFF) != vmm.loadedRoot()) return 1;
    const pages = pmm.free_pages;
    const loads = vmm.rootLoads();
    const switches = thread.switchCount();
    // `/test/fpu` gives up the CPU with `sched_yield` 300 times and is preempted
    // by the timer a few times more; this thread takes every one of those turns.
    const p = process.spawnPath("/test/fpu", .{}) catch return 2;
    const root = p.root;
    var saw_process_root = false;
    while (true) {
        const flags = cpu.saveAndDisableInterrupts();
        const done = p.exit_code != null;
        // Whenever this thread runs after the process has, the process's
        // address space is what is loaded, in CR3 itself too.
        if (!done and vmm.loadedRoot() == root and cpu.readCr3() & ~@as(u64, 0xFFF) == root) saw_process_root = true;
        cpu.restoreInterrupts(flags);
        if (done) break;
        thread.yield();
    }
    const round_trips = (thread.switchCount() - switches) / 2;
    const loaded = vmm.rootLoads() - loads;
    if (process.wait(p) != 0) return 3;
    if (round_trips < 100) return 4; // too few switches to show anything
    if (!saw_process_root) return 5;
    if (loaded != 2) return 6; // into the process once, and away from it at teardown
    // The dead process's address space is gone and no longer loaded.
    if (vmm.loadedRoot() != vmm.kernel_root or cpu.readCr3() & ~@as(u64, 0xFFF) != vmm.kernel_root) return 7;
    return if (pmm.free_pages == pages) 0 else 8;
}

extern const __text_start: u8;
extern const __data_start: u8;

/// Walk the page table at `phys` (`level` 3 = PML4 ... 0 = PT) and count
/// the leaf entries that are writable and executable at once. `first` and
/// `last` select the entries of this table to look at.
fn writableExecutable(phys: u64, level: u6, first: usize, last: usize) usize {
    const entries: *const [512]u64 = @ptrCast(@alignCast(pmm.physToVirt(phys)));
    var n: usize = 0;
    for (entries[first..last]) |e| {
        if (e & PTE_PRESENT == 0) continue;
        if (level == 0 or e & vmm.HUGE != 0) {
            if (e & vmm.WRITABLE != 0 and e & vmm.NX == 0) n += 1;
        } else n += writableExecutable(e & 0x000F_FFFF_FFFF_F000, level - 1, 0, 512);
    }
    return n;
}

/// The address at which the direct map shows the physical page behind the
/// kernel address `addr`.
fn directMapAlias(addr: u64) ?u64 {
    const phys = vmm.translate(vmm.kernel_root, addr) orelse return null;
    return @intFromPtr(pmm.physToVirt(phys));
}

/// Check what in the kernel can be written: code and constants cannot, and
/// neither can the tables of addresses the bootloader relocated (the heap's
/// table of functions is one); data can and is not executable. The same
/// holds at the addresses where the direct map shows those physical pages.
/// No kernel mapping at all is writable and executable. Returns 0, or the
/// number of the first failing check.
pub fn kernelWriteProtection() u32 {
    const W = vmm.WRITABLE;
    const text = @intFromPtr(&kernelWriteProtection);
    const rodata = @intFromPtr("a string constant".ptr);
    const relocated = @intFromPtr(heap.allocator.vtable);
    const data = @intFromPtr(&hog_done);

    // Where the kernel runs.
    var e = kernelLeaf(text);
    if (e & PTE_PRESENT == 0 or e & W != 0 or e & vmm.NX != 0) return 1;
    e = kernelLeaf(rodata);
    if (e & PTE_PRESENT == 0 or e & W != 0 or e & vmm.NX == 0) return 2;
    e = kernelLeaf(relocated);
    if (e & PTE_PRESENT == 0 or e & W != 0 or e & vmm.NX == 0) return 3;
    e = kernelLeaf(data);
    if (e & PTE_PRESENT == 0 or e & W == 0 or e & vmm.NX == 0) return 4;
    // The relocated tables lie between the constants and the data.
    if (relocated < rodata or relocated >= @intFromPtr(&__data_start)) return 5;

    // The same physical pages in the direct map: never executable there,
    // and writable only where the image is.
    for ([_]u64{ text, rodata, relocated, @intFromPtr(&__text_start), @intFromPtr(&__data_start) - 1 }, 0..) |addr, n| {
        const alias = directMapAlias(addr) orelse return 10;
        if (alias == addr) return 11;
        e = kernelLeaf(alias);
        if (e & PTE_PRESENT == 0 or e & W != 0 or e & vmm.NX == 0 or e & vmm.HUGE != 0) return 20 + @as(u32, @intCast(n));
    }
    const data_alias = directMapAlias(data) orelse return 12;
    e = kernelLeaf(data_alias);
    if (e & PTE_PRESENT == 0 or e & W == 0 or e & vmm.NX == 0) return 13;
    // The first page of data follows the last read-only page directly.
    const boundary = directMapAlias(@intFromPtr(&__data_start)) orelse return 14;
    if (kernelLeaf(boundary) & W == 0) return 15;
    // Ordinary memory in the direct map is still writable, and works.
    const page = pmm.alloc() orelse return 16;
    defer pmm.free(page);
    if (kernelLeaf(@intFromPtr(pmm.physToVirt(page))) & W == 0) return 17;

    if (writableExecutable(vmm.kernel_root, 3, 256, 512) != 0) return 18;
    return 0;
}

/// For the `relro` scenario: overwrite an entry of the heap's table of
/// functions, which is what an attacker with a kernel write would do to
/// take over the next allocation. The table is read-only, so this faults.
pub noinline fn writeRelocatedTable() void {
    const table: *volatile usize = @ptrFromInt(@intFromPtr(heap.allocator.vtable));
    table.* = 0x4141_4141;
}

/// For the `text_alias` scenario: overwrite kernel code through the direct
/// map of physical memory, where it used to be writable. Faults.
pub noinline fn writeTextThroughDirectMap() void {
    const alias = directMapAlias(@intFromPtr(&writeTextThroughDirectMap)) orelse return;
    const code: *volatile u8 = @ptrFromInt(alias);
    code.* = 0xCC;
}

/// True if syscalls go through a pointer tests can replace. So in this
/// (test) kernel; the normal kernel calls the dispatcher directly, which
/// `scripts/check-dispatch.sh` checks in the kernel file itself.
pub fn syscallHandlerReplaceable() bool {
    return arch_syscall.replaceable;
}
