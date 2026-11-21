const std = @import("std");
const root = @import("root");
const pci = @import("pci.zig");
const hpet = @import("hpet.zig");
const pmm = @import("../kernel/pmm.zig");
const vmm = @import("../arch/x86_64/vmm.zig");

// 64-byte submission entry and 16-byte completion entry, as the spec defines them.
const Sqe = extern struct {
    cdw0: u32, // opcode (bits 0-7), command id (bits 16-31)
    nsid: u32,
    rsvd: u64 = 0,
    mptr: u64 = 0,
    prp1: u64, // physical address of the data page
    prp2: u64 = 0,
    cdw10: u32 = 0,
    cdw11: u32 = 0,
    cdw12: u32 = 0,
    cdw13: u32 = 0,
    cdw14: u32 = 0,
    cdw15: u32 = 0,
};
const Cqe = extern struct {
    dw0: u32,
    dw1: u32,
    sq_head: u16,
    sq_id: u16,
    cid: u16,
    status: u16, // bit 0 = phase tag, bits 1-15 = status code
};
comptime {
    std.debug.assert(@sizeOf(Sqe) == 64 and @sizeOf(Cqe) == 16);
}

const QSIZE = 64;

const Queue = struct {
    sq: [*]volatile Sqe,
    cq: [*]volatile Cqe,
    sq_phys: u64,
    cq_phys: u64,
    sq_db: *volatile u32, // doorbell: tell the controller about new commands
    cq_db: *volatile u32, // doorbell: tell the controller we consumed completions
    tail: u16 = 0,
    head: u16 = 0,
    phase: u16 = 1, // flips each time the completion queue wraps around
    cid: u16 = 0,
};

var regs: usize = 0;
var stride: usize = 4;
var admin: Queue = undefined;
var io: Queue = undefined;
var bounce: u64 = 0; // one DMA page for all transfers

pub var sector_size: u32 = 512;
pub var sector_count: u64 = 0;

// Read a 32-bit register at offset `off` from the NVMe controller's MMIO region.
fn reg32(off: usize) *volatile u32 {
    return @ptrFromInt(regs + off);
}

// Read a 64-bit register at offset `off` from the NVMe controller's MMIO region.
fn reg64(off: usize) *volatile u64 {
    return @ptrFromInt(regs + off);
}

// Allocate a page of physical memory and zero it. Returns the physical address.
fn zeroedPage() u64 {
    const p = pmm.alloc() orelse @panic("nvme: out of memory");
    @memset(pmm.physToVirt(p)[0..pmm.PAGE_SIZE], 0);
    return p;
}

// Create a submission/completion queue pair. Returns the queues, which are mapped into the HHDM.
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

// Submit a command to the queue and wait for its completion. Returns an error if the command failed or timed out.
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

// Wait for the controller to reach the desired ready state. Returns an error if the controller reports a fatal error or times out.
fn waitReady(want: bool) !void {
    const deadline = hpet.nanos() + 2_000_000_000;
    while (((reg32(0x1C).* & 1) != 0) != want) { // CSTS.RDY
        if (reg32(0x1C).* & 2 != 0) return error.ControllerFatal; // CSTS.CFS
        if (hpet.nanos() > deadline) return error.Timeout;
    }
}

// Initialize the NVMe driver. Finds the first NVMe device on the PCI bus, enables it, and sets up the admin and I/O queues. Returns an error if the device is not found or fails to initialize.
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

    root.print("nvme: {d} sectors of {d} bytes ({d} MiB)\n", .{ sector_count, sector_size, sector_count * sector_size / (1024 * 1024) });
}

// Read `count` sectors starting at `lba` into `buf`. At most one page per call.
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
