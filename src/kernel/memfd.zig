//! Memory objects: the memory behind `memfd_create` and shared mappings.
//!
//! An object is pages of memory with a size, read and written like a file
//! through its descriptor and mapped into programs with `mmap`. A shared
//! mapping (`MAP_SHARED`) maps the object's own pages: what one mapping or
//! the descriptor writes, every other mapping sees, in this process and in
//! others (a child made by `fork` shares the mapping). That is what the
//! .NET JIT does with its code: written through one mapping, run through
//! another that cannot be written, so no page is both (W^X). A private
//! mapping (`MAP_PRIVATE`) gets a copy of a page when it first touches it.
//! `mmap` of `MAP_SHARED | MAP_ANONYMOUS` makes an object of its own,
//! which only the mapping (and its copies in children) hold.
//!
//! ## Who holds what
//!
//! The object is held by every open file on it (its node: `retain`,
//! `release`) and by every region of a mapping of it (`vm_regions` calls
//! `hold` as regions are made, cut and removed). It goes with the last
//! holder. Its pages each have one owner for the object and one for every
//! page-table entry that maps it (`pmm.share`, `pmm.release`), so a page
//! goes when neither the object nor any mapping has it any more.
//!
//! ## Seals
//!
//! An object made with `MFD_ALLOW_SEALING` can be sealed (`fcntl`
//! `F_ADD_SEALS`): against shrinking, growing, writing (refused while a
//! writable shared mapping exists; mappings that may write are counted),
//! future writing, and against more seals. One made without starts with
//! the seal against more seals, as on Linux.
//!
//! ## Not as on Linux
//!
//! Shrinking an object gives up its pages past the new end, but a page a
//! mapping has already mapped stays mapped there (Linux takes it out of
//! every mapping). Programs that shrink what they have mapped seal
//! against it, or do not touch past the end.
//!
//! ## Locking
//!
//! An object's lock (rank `memory_object`) covers its size, seals and
//! pages. A page fault takes it under the address-space lock; reads and
//! writes through the descriptor take it alone. Pages and the page list's
//! memory are allocated under it.

const std = @import("std");

const heap = @import("heap.zig");
const pmm = @import("pmm.zig");
const vfs = @import("vfs.zig");
const SpinLock = @import("sync/spinlock.zig").SpinLock;

const PAGE = pmm.PAGE_SIZE;

pub const SEAL = struct {
    pub const SEAL: u32 = 0x1;
    pub const SHRINK: u32 = 0x2;
    pub const GROW: u32 = 0x4;
    pub const WRITE: u32 = 0x8;
    pub const FUTURE_WRITE: u32 = 0x10;
    pub const ALL: u32 = 0x1F;
};

/// The largest an object may be: 1 TiB, far beyond memory (pages exist
/// only where written).
pub const MAX_SIZE: u64 = 1 << 40;

pub const Object = struct {
    lock: SpinLock = .{ .rank = .memory_object },
    /// Holders: open files and regions of mappings. Changed atomically.
    refs: std.atomic.Value(u32) = .init(1),
    size: u64 = 0,
    /// The page at each index, 0 where there is none (it reads as zeroes).
    pages: std.ArrayListUnmanaged(u64) = .empty,
    seals: u32 = SEAL.SEAL,
    /// Regions of shared mappings that may write (`F_SEAL_WRITE` waits
    /// for none).
    writable_maps: u32 = 0,
    /// For `/proc/self/maps`: "memfd:" and the name it was given.
    name: [64]u8 = @splat(0),
    name_len: u8 = 0,
};

pub const CreateError = error{OutOfMemory};

/// A new empty object named `name` (cut to what fits), sealable or not.
pub fn create(label: []const u8, sealable: bool) CreateError!*Object {
    const o = try heap.allocator.create(Object);
    o.* = .{ .seals = if (sealable) 0 else SEAL.SEAL };
    const prefix = "memfd:";
    const n = @min(label.len, o.name.len - prefix.len);
    @memcpy(o.name[0..prefix.len], prefix);
    @memcpy(o.name[prefix.len..][0..n], label[0..n]);
    o.name_len = @intCast(prefix.len + n);
    return o;
}

/// An object of `size` bytes for `MAP_SHARED | MAP_ANONYMOUS`, held by
/// the caller once (the mapping's region takes its own hold).
pub fn createAnonymous(size: u64) CreateError!*Object {
    const o = try create("", false);
    o.size = size;
    o.name_len = 0;
    return o;
}

pub fn retain(o: *Object) void {
    _ = o.refs.fetchAdd(1, .monotonic);
}

/// Give up a hold; the object, and its own claim on each page, go with
/// the last one. No lock may be held but the caller's address-space lock.
pub fn release(o: *Object) void {
    if (o.refs.fetchSub(1, .acq_rel) != 1) return;
    for (o.pages.items) |page| {
        if (page != 0) pmm.release(page);
    }
    o.pages.deinit(heap.allocator);
    heap.allocator.destroy(o);
}

pub fn name(o: *const Object) []const u8 {
    return o.name[0..o.name_len];
}

// --- The node a descriptor on the object has.

pub const ops = vfs.Ops{
    .read = nodeRead,
    .write = nodeWrite,
    .truncate = nodeTruncate,
    .size = nodeSize,
    .retain = nodeRetain,
    .release = nodeRelease,
};

/// The node for `o`; the caller's hold becomes the node's.
pub fn node(o: *Object) vfs.Node {
    return .{ .size = 0, .ctx = @intFromPtr(o), .ops = &ops };
}

/// The object behind `n`, if it is one.
pub fn fromNode(n: *const vfs.Node) ?*Object {
    return if (n.ops == &ops) @ptrFromInt(n.ctx) else null;
}

fn of(n: *const vfs.Node) *Object {
    return @ptrFromInt(n.ctx);
}

fn nodeRetain(n: *const vfs.Node) void {
    retain(of(n));
}

fn nodeRelease(n: *const vfs.Node) void {
    release(of(n));
}

fn nodeSize(n: *const vfs.Node) u64 {
    const o = of(n);
    const held = o.lock.acquire();
    defer o.lock.release(held);
    return o.size;
}

fn nodeRead(n: *const vfs.Node, offset: u64, buf: []u8) usize {
    const o = of(n);
    const held = o.lock.acquire();
    defer o.lock.release(held);
    if (offset >= o.size) return 0;
    const len = @min(buf.len, o.size - offset);
    var done: usize = 0;
    while (done < len) {
        const at = offset + done;
        const in_page = at % PAGE;
        const n_here = @min(len - done, PAGE - in_page);
        const index: usize = @intCast(at / PAGE);
        const page = if (index < o.pages.items.len) o.pages.items[index] else 0;
        if (page == 0) @memset(buf[done..][0..n_here], 0) else @memcpy(buf[done..][0..n_here], pmm.physToVirt(page)[in_page..][0..n_here]);
        done += n_here;
    }
    return len;
}

fn nodeWrite(n: *const vfs.Node, offset: u64, data: []const u8) vfs.Error!usize {
    const o = of(n);
    const held = o.lock.acquire();
    defer o.lock.release(held);
    if (o.seals & (SEAL.WRITE | SEAL.FUTURE_WRITE) != 0) return error.NotPermitted;
    const end = std.math.add(u64, offset, data.len) catch return error.TooLarge;
    if (end > MAX_SIZE) return error.TooLarge;
    if (end > o.size and o.seals & SEAL.GROW != 0) return error.NotPermitted;
    var done: usize = 0;
    while (done < data.len) {
        const at = offset + done;
        const in_page = at % PAGE;
        const n_here = @min(data.len - done, PAGE - in_page);
        const page = pageAtLocked(o, @intCast(at / PAGE)) orelse break;
        @memcpy(pmm.physToVirt(page)[in_page..][0..n_here], data[done..][0..n_here]);
        done += n_here;
    }
    if (done == 0 and data.len != 0) return error.NoSpace;
    o.size = @max(o.size, offset + done);
    return done;
}

fn nodeTruncate(n: *const vfs.Node, size: u64) vfs.Error!void {
    const o = of(n);
    const held = o.lock.acquire();
    defer o.lock.release(held);
    if (size > MAX_SIZE) return error.TooLarge;
    if (size < o.size and o.seals & SEAL.SHRINK != 0) return error.NotPermitted;
    if (size > o.size and o.seals & SEAL.GROW != 0) return error.NotPermitted;
    // The pages wholly past the new end go; the part of the last page
    // past it reads as zeroes again.
    const keep: usize = @intCast((size + PAGE - 1) / PAGE);
    if (keep < o.pages.items.len) {
        for (o.pages.items[keep..]) |page| {
            if (page != 0) pmm.release(page);
        }
        o.pages.shrinkRetainingCapacity(keep);
    }
    if (size % PAGE != 0 and size < o.size) {
        const index: usize = @intCast(size / PAGE);
        if (index < o.pages.items.len and o.pages.items[index] != 0) {
            @memset(pmm.physToVirt(o.pages.items[index])[size % PAGE ..PAGE], 0);
        }
    }
    o.size = size;
}

/// The object's page at `index`, made (zeroed) if there is none. Null if
/// memory ran out. The lock must be held.
fn pageAtLocked(o: *Object, index: usize) ?u64 {
    if (index >= o.pages.items.len) {
        const old = o.pages.items.len;
        o.pages.resize(heap.allocator, index + 1) catch return null;
        @memset(o.pages.items[old..], 0);
    }
    if (o.pages.items[index] == 0) o.pages.items[index] = pmm.allocZeroed() orelse return null;
    return o.pages.items[index];
}

// --- Mappings.

pub const FaultError = error{
    /// Past the end of the object (Linux: `SIGBUS`).
    PastEnd,
    OutOfMemory,
};

/// The page at byte `offset` for a shared mapping to map, with one more
/// owner taken for the mapping's page-table entry. Under the caller's
/// address-space lock.
pub fn pageForMapping(o: *Object, offset: u64) FaultError!u64 {
    const held = o.lock.acquire();
    defer o.lock.release(held);
    if (offset >= std.mem.alignForward(u64, o.size, PAGE)) return error.PastEnd;
    const page = pageAtLocked(o, @intCast(offset / PAGE)) orelse return error.OutOfMemory;
    if (!pmm.share(page)) return error.OutOfMemory; // as many owners as can be counted
    return page;
}

/// Whether a shared mapping that may write can be made: not with a seal
/// against writing.
pub fn mayMapWritable(o: *Object) bool {
    const held = o.lock.acquire();
    defer o.lock.release(held);
    return o.seals & (SEAL.WRITE | SEAL.FUTURE_WRITE) == 0;
}

/// A region of a mapping of `o` comes (`take`) or goes: one hold, and for
/// a shared one that may write, one in the count `F_SEAL_WRITE` looks at.
pub fn holdRegion(o: *Object, take: bool, may_write: bool) void {
    if (take) {
        retain(o);
        if (may_write) {
            const held = o.lock.acquire();
            defer o.lock.release(held);
            o.writable_maps += 1;
        }
    } else {
        if (may_write) {
            const held = o.lock.acquire();
            defer o.lock.release(held);
            o.writable_maps -= 1;
        }
        release(o);
    }
}

// --- Seals.

pub const SealError = error{ NotPermitted, Busy, Invalid };

/// `F_ADD_SEALS`.
pub fn addSeals(o: *Object, seals: u32) SealError!void {
    if (seals & ~SEAL.ALL != 0) return error.Invalid;
    const held = o.lock.acquire();
    defer o.lock.release(held);
    if (o.seals & SEAL.SEAL != 0) return error.NotPermitted;
    if (seals & SEAL.WRITE != 0 and o.writable_maps != 0) return error.Busy;
    o.seals |= seals;
}

/// `F_GET_SEALS`.
pub fn getSeals(o: *Object) u32 {
    const held = o.lock.acquire();
    defer o.lock.release(held);
    return o.seals;
}
