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
const uaccess = kernel_root.kernel.uaccess;
const nvme = kernel_root.drivers.nvme;
const elf = kernel_root.kernel.elf;
const heap = kernel_root.kernel.heap;
const pmm = kernel_root.kernel.pmm;
const process = kernel_root.kernel.process;
const thread = kernel_root.kernel.thread;
const vfs = kernel_root.kernel.vfs;
const tarfs = kernel_root.kernel.fs.tarfs;
const backtrace = kernel_root.kernel.debug.backtrace;

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
        vmm.createAddressSpace();

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
    const root = vmm.createAddressSpace();
    defer vmm.destroyAddressSpace(root);
    const entry = elf.load(root, image) catch return null;
    const pte = vmm.leafEntry(root, addr) orelse 0;
    if (vmm.translate(root, addr)) |phys| {
        const n = @min(out.len, pmm.PAGE_SIZE - (addr % pmm.PAGE_SIZE));
        @memcpy(out[0..n], pmm.physToVirt(phys)[0..n]);
    }
    return .{ .entry = entry, .pte = pte };
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
    _ = process.spawn("bad", image, null) catch
        return pmm.free_pages == pages and heap.stats().bytes_in_use == in_use;
    return false; // it started; the test fails (the process runs on its own)
}

/// Run the program at `path` as a child process of the current
/// Thread and wait for it. Returns its exit code (255 if it was killed by a
/// Fault), or null if it could not be started.
pub fn runProgram(path: []const u8) ?u64 {
    const me = thread.current();
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    _ = process.spawnPath(path, me) catch return null;
    thread.block(); // until the child calls process.exit
    return me.wake_value;
}

/// Bytes currently allocated from the kernel heap.
pub fn heapInUse() usize {
    return heap.stats().bytes_in_use;
}

// State shared by the scheduler test's worker threads.
var sched_log: [8]u8 = undefined;
var sched_len: usize = 0;
var sched_done: usize = 0;
var sched_waiter: ?*thread.Thread = null;

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
    sched_done += 1;
    if (sched_done == 2) thread.wake(sched_waiter.?);
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
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    sched_len = 0;
    sched_done = 0;
    sched_waiter = thread.current();
    const a = thread.spawn(schedWorkerA, null) catch return false;
    const b = thread.spawn(schedWorkerB, null) catch return false;
    if (b.id <= a.id or a.state != .ready) return false;
    while (sched_done < 2) thread.block();
    return sched_len == 6 and
        std.mem.eql(u8, sched_log[0..6], "ABABAB") and
        heap.stats().bytes_in_use == in_use; // both threads reaped
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
    const root = vmm.createAddressSpace();
    const virt: u64 = 0x40_0000;
    const phys = pmm.alloc() orelse {
        vmm.destroyAddressSpace(root);
        return false;
    };
    vmm.map(root, virt, phys, vmm.USER | vmm.WRITABLE, false);
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
    vmm.map(root, virt, phys, flags, false);
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
    const root = vmm.createAddressSpace();
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

/// True if write protection in ring 0, SMEP and SMAP are all switched on,
/// both in the kernel's bookkeeping and in the control registers.
pub fn userProtectionOn() bool {
    const cr4 = cpu.readCr4();
    return usercopy.smep_enabled and usercopy.smapEnabled() and
        cr4 & (1 << 20) != 0 and cr4 & (1 << 21) != 0 and
        cpu.readCr0() & (1 << 16) != 0;
}

/// For the `smap` and `smep` scenarios: switch to a new address space with
/// one user-accessible, writable, executable page at `USER_PAGE` that holds a
/// single `ret` instruction. Interrupts stay off so the scheduler keeps this
/// address space loaded. Returns false if memory ran out.
pub fn enterUserPageSpace() bool {
    _ = cpu.saveAndDisableInterrupts();
    const root = vmm.createAddressSpace();
    const phys = mapUserPage(root, USER_PAGE, vmm.USER | vmm.WRITABLE) orelse return false;
    pmm.physToVirt(phys)[0] = 0xC3; // ret
    vmm.loadRoot(root);
    return true;
}
