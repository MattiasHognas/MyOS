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
