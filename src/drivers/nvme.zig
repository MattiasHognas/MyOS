//! Minimal polling NVMe driver.
//!
//! Sets up one admin queue pair and one I/O queue pair, identifies namespace 1
//! and reads sectors from it. Commands are submitted one at a time and
//! completed by polling (no interrupts). All transfers go through a single
//! page-sized DMA bounce buffer.

const std = @import("std");

const vmm = @import("../arch/x86_64/vmm.zig");
const pmm = @import("../kernel/pmm.zig");
const hpet = @import("hpet.zig");
const pci = @import("pci.zig");

const log = std.log.scoped(.nvme);

/// 64-byte submission queue entry, as defined by the NVMe specification.
const Sqe = extern struct {
    /// Opcode (bits 0-7) and command ID (bits 16-31).
    cdw0: u32,
    nsid: u32,
    rsvd: u64 = 0,
    mptr: u64 = 0,
    /// Physical address of the data page.
    prp1: u64,
    prp2: u64 = 0,
    cdw10: u32 = 0,
    cdw11: u32 = 0,
    cdw12: u32 = 0,
    cdw13: u32 = 0,
    cdw14: u32 = 0,
    cdw15: u32 = 0,
};
/// 16-byte completion queue entry, as defined by the NVMe specification.
const Cqe = extern struct {
    dw0: u32,
    dw1: u32,
    sq_head: u16,
    sq_id: u16,
    cid: u16,
    /// Bit 0 = phase tag, bits 1-15 = status code.
    status: u16,
};
comptime {
    std.debug.assert(@sizeOf(Sqe) == 64 and @sizeOf(Cqe) == 16);
}

/// Number of entries in every submission and completion queue.
const QSIZE = 64;

/// A submission/completion queue pair and the driver's position in it.
const Queue = struct {
    sq: [*]volatile Sqe,
    cq: [*]volatile Cqe,
    sq_phys: u64,
    cq_phys: u64,
    /// Doorbell: tell the controller about new commands.
    sq_db: *volatile u32,
    /// Doorbell: tell the controller we consumed completions.
    cq_db: *volatile u32,
    tail: u16 = 0,
    head: u16 = 0,
    /// Expected phase tag; flips each time the completion queue wraps around.
    phase: u16 = 1,
    /// Next command ID.
    cid: u16 = 0,
};

var regs: usize = 0;
var stride: usize = 4;
var admin: Queue = undefined;
var io: Queue = undefined;
var bounce: u64 = 0; // one DMA page for all transfers

/// Logical block size of namespace 1, in bytes. Valid after `init`.
pub var sector_size: u32 = 512;
/// Number of logical blocks in namespace 1. Valid after `init`.
pub var sector_count: u64 = 0;

/// Return a pointer to the 32-bit controller register at byte offset `off`.
fn reg32(off: usize) *volatile u32 {
    return @ptrFromInt(regs + off);
}

/// Return a pointer to the 64-bit controller register at byte offset `off`.
fn reg64(off: usize) *volatile u64 {
    return @ptrFromInt(regs + off);
}

/// Allocate a zeroed physical page and return its physical address.
/// Panics if physical memory is exhausted.
fn zeroedPage() u64 {
    const p = pmm.alloc() orelse @panic("nvme: out of memory");
    @memset(pmm.physToVirt(p)[0..pmm.PAGE_SIZE], 0);
    return p;
}

/// Allocate memory for queue pair `qid` (0 = admin) and locate its doorbells.
/// The controller is not told about the queues; that is up to the caller.
fn makeQueue(qid: usize) Queue {
    const sq = zeroedPage();
    const cq = zeroedPage();
    return .{
        .sq = @ptrCast(@alignCast(pmm.physToVirt(sq))),
        .cq = @ptrCast(@alignCast(pmm.physToVirt(cq))),
        .sq_phys = sq,
        .cq_phys = cq,
        .sq_db = @ptrFromInt(regs + 0x1000 + (2 * qid) * stride),
        .cq_db = @ptrFromInt(regs + 0x1000 + (2 * qid + 1) * stride),
    };
}

/// Submit `cmd_in` on queue `q` and poll until it completes.
///
/// Assigns the command ID, rings the submission doorbell, waits up to one
/// second for the matching completion and acknowledges it. Returns
/// `error.Timeout` if no completion arrives, or `error.CommandFailed` if the
/// controller reports a non-zero status.
fn submit(q: *Queue, cmd_in: Sqe) !void {
    var cmd = cmd_in;
    cmd.cdw0 |= @as(u32, q.cid) << 16;
    q.cid +%= 1;

    q.sq[q.tail] = cmd;
    q.tail = (q.tail + 1) % QSIZE;
    q.sq_db.* = q.tail; // ring the doorbell

    // A new completion has arrived when its phase bit matches what we expect.
    const deadline = hpet.nanos() + 1_000_000_000;
    while ((q.cq[q.head].status & 1) != q.phase) {
        if (hpet.nanos() > deadline) return error.Timeout;
        std.atomic.spinLoopHint();
    }
    const status = q.cq[q.head].status >> 1;
    q.head = (q.head + 1) % QSIZE;
    if (q.head == 0) q.phase ^= 1;
    q.cq_db.* = q.head;

    if (status != 0) return error.CommandFailed;
}

/// Wait up to two seconds for CSTS.RDY to equal `want`. Returns
/// `error.ControllerFatal` if the controller reports a fatal status, or
/// `error.Timeout`.
fn waitReady(want: bool) !void {
    const deadline = hpet.nanos() + 2_000_000_000;
    while (((reg32(0x1C).* & 1) != 0) != want) { // CSTS.RDY
        if (reg32(0x1C).* & 2 != 0) return error.ControllerFatal; // CSTS.CFS
        if (hpet.nanos() > deadline) return error.Timeout;
    }
}

/// Initialize the NVMe controller `dev` (found by the caller with `pci.find`).
///
/// Enables bus mastering, maps the registers, resets the controller, sets up
/// the admin queues, identifies namespace 1 (filling in `sector_count` and
/// `sector_size`) and creates I/O queue pair 1. Requires `hpet.init`.
pub fn init(dev: pci.Device) !void {
    pci.enableBusMaster(dev);
    regs = vmm.mapMmio(pci.bar(dev, 0), 0x4000);

    const cap = reg64(0x00).*;
    stride = @as(usize, 4) << @intCast((cap >> 32) & 0xF); // CAP.DSTRD
    if ((cap & 0xFFFF) + 1 < QSIZE) return error.QueueTooSmall; // CAP.MQES

    // Reset, then set up the admin queues while the controller is disabled.
    reg32(0x14).* = 0; // CC.EN = 0
    try waitReady(false);
    admin = makeQueue(0);
    reg32(0x24).* = ((QSIZE - 1) << 16) | (QSIZE - 1); // AQA: queue sizes
    reg64(0x28).* = admin.sq_phys; // ASQ
    reg64(0x30).* = admin.cq_phys; // ACQ
    reg32(0x14).* = 1 | (6 << 16) | (4 << 20); // enable; 64-byte SQ / 16-byte CQ entries
    try waitReady(true);

    bounce = zeroedPage();

    // Identify namespace 1: size and sector size.
    try submit(&admin, .{ .cdw0 = 0x06, .nsid = 1, .prp1 = bounce, .cdw10 = 0 });
    const id = pmm.physToVirt(bounce);
    sector_count = std.mem.readInt(u64, id[0..8], .little);
    const fmt = id[26] & 0xF; // FLBAS: which LBA format is in use
    const lbaf = std.mem.readInt(u32, id[128 + @as(usize, fmt) * 4 ..][0..4], .little);
    sector_size = @as(u32, 1) << @intCast((lbaf >> 16) & 0xFF);

    // I/O queue pair 1: completion queue first, then the submission queue that uses it.
    io = makeQueue(1);
    try submit(&admin, .{ .cdw0 = 0x05, .nsid = 0, .prp1 = io.cq_phys, .cdw10 = ((QSIZE - 1) << 16) | 1, .cdw11 = 1 });
    try submit(&admin, .{ .cdw0 = 0x01, .nsid = 0, .prp1 = io.sq_phys, .cdw10 = ((QSIZE - 1) << 16) | 1, .cdw11 = (1 << 16) | 1 });

    log.info("{d} sectors of {d} bytes ({d} MiB)", .{ sector_count, sector_size, sector_count * sector_size / (1024 * 1024) });
}

/// Read `count` sectors starting at `lba` from namespace 1 into `buf`.
///
/// At most one page (4 KiB) can be read per call. Returns `error.BadRequest`
/// if `count` is 0, the transfer is larger than a page or `buf` is too small,
/// or any error from the command itself.
pub fn read(lba: u64, count: u32, buf: []u8) !void {
    const bytes = count * sector_size;
    if (count == 0 or bytes > pmm.PAGE_SIZE or buf.len < bytes) return error.BadRequest;
    try submit(&io, .{
        .cdw0 = 0x02, // read
        .nsid = 1,
        .prp1 = bounce,
        .cdw10 = @truncate(lba),
        .cdw11 = @truncate(lba >> 32),
        .cdw12 = count - 1, // zero-based
    });
    @memcpy(buf[0..bytes], pmm.physToVirt(bounce)[0..bytes]);
}
