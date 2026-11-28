//! The regions of a user address space: what is mapped where, and how.
//!
//! A region is a range of whole pages with one set of permissions:
//! a program segment, the stack, the `brk` heap, an `mmap`. A page inside a
//! region may or may not have memory yet: anonymous memory is given on
//! first touch (`process.zig` handles the page fault and asks `find`). A
//! page outside every region is not the program's, and touching it is a
//! fault.
//!
//! This is the record of *intent*; the page tables hold what has actually
//! been given. Keeping both is the simple one of two designs
//! (`docs/research.md`): the regions say what a fault at an address means
//! without looking at page tables, and reserving a gigabyte costs one
//! entry here and no page table at all. The cost is one lock per address
//! space around both, which is fine while a process has one thread and is
//! the first thing to look at when many threads of one process fault at
//! once (milestone 7).
//!
//! The regions are kept sorted by address in one array, never overlapping.
//! Neighbours that are alike are merged, so that a program that maps
//! memory piece by piece (every allocator does) does not grow the array
//! without bound.
//!
//! No kernel dependencies: tested on the host against a page-by-page model.

const std = @import("std");

pub const PAGE_SIZE: u64 = 4096;

/// What a program may do with the pages of a region. No bit set is a
/// reservation: address space that is taken, and faults when touched.
pub const Prot = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    exec: bool = false,
    _pad: u5 = 0,

    pub const none: Prot = .{};
    pub const rw: Prot = .{ .read = true, .write = true };

    pub fn eql(a: Prot, b: Prot) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }

    /// True if any access is allowed.
    pub fn any(p: Prot) bool {
        return p.read or p.write or p.exec;
    }
};

/// What a region is, for the rules that differ and for listings.
pub const Kind = enum(u8) {
    /// A segment of the program file: its pages were filled when it was loaded.
    image,
    /// The stack.
    stack,
    /// The `brk` heap.
    heap,
    /// An anonymous `mmap`.
    anon,
    /// A private mapping of a file: a page is filled from the file when
    /// it is first touched, and is the program's own from then on.
    file,
    /// The kernel's page with the clock for the vDSO (`[vvar]`), and the
    /// vDSO itself (`[vdso]`): pages shared by every process, mapped on
    /// first touch and never the process's own (`kernel/vdso.zig`).
    vvar,
    vdso,
    /// A shared mapping of a memory object (`MAP_SHARED`, `memfd.zig`):
    /// its pages are the object's own, the same for every mapping of it.
    shared,
};

/// Where a file-backed region reads its pages from.
pub const Backing = struct {
    /// The file, in whatever terms the owner of the regions uses (the
    /// kernel keeps a `vfs.Node` here). Copied with the region.
    file: [3]u64 = .{ 0, 0, 0 },
    /// Offset in the file of the region's first byte. Page aligned.
    offset: u64 = 0,
    /// The region holds what `file` names (a memory object), through
    /// `hold`: one hold for each region, taken as it is made or cut in
    /// two and given up as it goes.
    counted: bool = false,
    /// For `hold`: a shared mapping that may be made writable.
    may_write: bool = false,
};

/// What takes and gives up a counted region's hold on its backing
/// (`Backing.counted`), set by the kernel (`memfd.zig`); none in the host
/// tests.
pub var hold: ?*const fn (backing: Backing, take: bool) void = null;

fn holdOf(r: Region, take: bool) void {
    if (!r.backing.counted) return;
    if (hold) |f| f(r.backing, take);
}

pub const Region = struct {
    /// First address, page aligned.
    start: u64,
    /// First address past the end, page aligned.
    end: u64,
    prot: Prot,
    kind: Kind,
    /// For `kind == .file`.
    backing: Backing = .{},

    /// The file offset of the page at `addr`, which is in this region.
    /// Whether the region has a file offset: a file's or an object's.
    pub fn hasOffset(r: Region) bool {
        return r.kind == .file or r.kind == .shared;
    }

    pub fn fileOffset(r: Region, addr: u64) u64 {
        return r.backing.offset + (addr - r.start);
    }

    pub fn pages(r: Region) u64 {
        return (r.end - r.start) / PAGE_SIZE;
    }

    fn mergeable(a: Region, b: Region) bool {
        // Only anonymous memory: the others are known by their extent.
        return a.end == b.start and a.kind == .anon and b.kind == .anon and a.prot.eql(b.prot);
    }
};

pub const Error = error{
    OutOfMemory,
    /// The range is not page aligned, empty, or wraps around.
    BadRange,
    /// Part of the range is already in a region.
    Overlap,
    /// Part of the range is in no region.
    NotMapped,
    /// More regions than an address space may have.
    TooManyRegions,
};

/// Most regions one address space may have (Linux's default is 65530).
pub const MAX_REGIONS = 65530;

pub const Regions = struct {
    list: std.ArrayListUnmanaged(Region) = .empty,

    pub fn deinit(self: *Regions, gpa: std.mem.Allocator) void {
        for (self.list.items) |r| holdOf(r, false);
        self.list.deinit(gpa);
        self.* = .{};
    }

    /// Take a hold for every counted region: for a copy of another
    /// address space's list (`fork`), which holds them as well.
    pub fn holdAll(self: *const Regions) void {
        for (self.list.items) |r| holdOf(r, true);
    }

    /// The regions, in order of address.
    pub fn items(self: *const Regions) []const Region {
        return self.list.items;
    }

    fn checkRange(start: u64, len: u64) Error!u64 {
        if (len == 0 or start % PAGE_SIZE != 0 or len % PAGE_SIZE != 0) return error.BadRange;
        return std.math.add(u64, start, len) catch error.BadRange;
    }

    /// Index of the first region that ends after `addr`.
    fn lowerBound(self: *const Regions, addr: u64) usize {
        var lo: usize = 0;
        var hi: usize = self.list.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.list.items[mid].end <= addr) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// The region `addr` is in, or null.
    pub fn find(self: *const Regions, addr: u64) ?Region {
        const i = self.lowerBound(addr);
        if (i == self.list.items.len) return null;
        const r = self.list.items[i];
        return if (r.start <= addr) r else null;
    }

    /// True if no page of `[start, start + len)` is in a region.
    pub fn isFree(self: *const Regions, start: u64, len: u64) bool {
        const end = checkRange(start, len) catch return false;
        const i = self.lowerBound(start);
        return i == self.list.items.len or self.list.items[i].start >= end;
    }

    /// True if every page of `[start, start + len)` is in a region.
    pub fn isCovered(self: *const Regions, start: u64, len: u64) bool {
        const end = checkRange(start, len) catch return false;
        var at = start;
        var i = self.lowerBound(start);
        while (at < end) : (i += 1) {
            if (i == self.list.items.len) return false;
            const r = self.list.items[i];
            if (r.start > at) return false;
            at = r.end;
        }
        return true;
    }

    /// The highest address in `[low, high)` at which `len` bytes are free,
    /// or null if there is no such place. Top down, as Linux places
    /// mappings: the low addresses stay free for the `brk` heap to grow.
    pub fn findFree(self: *const Regions, len: u64, low: u64, high: u64) ?u64 {
        if (len == 0 or len % PAGE_SIZE != 0 or low % PAGE_SIZE != 0 or high % PAGE_SIZE != 0) return null;
        var top = high; // the free space being looked at ends here
        var i = self.lowerBound(high -| 1);
        if (i < self.list.items.len and self.list.items[i].start < high) {
            top = self.list.items[i].start; // `high` is inside a region
        }
        while (true) {
            const floor = if (i == 0) low else @max(low, self.list.items[i - 1].end);
            if (top >= floor and top - floor >= len) return top - len;
            if (i == 0) return null;
            i -= 1;
            top = self.list.items[i].start;
            if (top <= low) return null;
        }
    }

    /// Add the region `[start, start + len)`, which must be free.
    /// Make room for `n` more regions, so that the next changes that add at
    /// most that many cannot fail for want of memory (or of the limit).
    pub fn reserve(self: *Regions, gpa: std.mem.Allocator, n: usize) Error!void {
        if (self.list.items.len + n > MAX_REGIONS) return error.TooManyRegions;
        self.list.ensureUnusedCapacity(gpa, n) catch return error.OutOfMemory;
    }

    pub fn add(self: *Regions, gpa: std.mem.Allocator, start: u64, len: u64, prot: Prot, kind: Kind) Error!void {
        return self.addBacked(gpa, start, len, prot, kind, .{});
    }

    /// `add` for a region of a file (`kind` `.file`), with where its
    /// pages come from.
    pub fn addBacked(self: *Regions, gpa: std.mem.Allocator, start: u64, len: u64, prot: Prot, kind: Kind, backing: Backing) Error!void {
        const end = try checkRange(start, len);
        if (!self.isFree(start, len)) return error.Overlap;
        const new: Region = .{ .start = start, .end = end, .prot = prot, .kind = kind, .backing = backing };
        const i = self.lowerBound(start);
        const list = self.list.items;
        const joins_before = i > 0 and list[i - 1].mergeable(new);
        const joins_after = i < list.len and new.mergeable(list[i]);
        if (joins_before and joins_after) {
            list[i - 1].end = list[i].end;
            _ = self.list.orderedRemove(i);
        } else if (joins_before) {
            list[i - 1].end = end;
        } else if (joins_after) {
            list[i].start = start;
        } else {
            if (list.len >= MAX_REGIONS) return error.TooManyRegions;
            self.list.insert(gpa, i, new) catch return error.OutOfMemory;
            holdOf(new, true); // (a counted region never merges)
        }
    }

    /// Make sure a region starts or ends at `addr`, by cutting the region
    /// it is inside of in two. Does nothing if no region spans it.
    fn splitAt(self: *Regions, gpa: std.mem.Allocator, addr: u64) Error!void {
        const i = self.lowerBound(addr);
        if (i == self.list.items.len) return;
        const r = self.list.items[i];
        if (r.start >= addr) return;
        if (self.list.items.len >= MAX_REGIONS) return error.TooManyRegions;
        var upper = r;
        upper.start = addr;
        if (r.hasOffset()) upper.backing.offset = r.fileOffset(addr);
        self.list.insert(gpa, i + 1, upper) catch return error.OutOfMemory;
        self.list.items[i].end = addr;
        holdOf(upper, true); // two regions now, each holding
    }

    /// Remove `[start, start + len)` from whatever regions it is in; parts
    /// of it that are in no region are skipped. A region it only partly
    /// covers is shortened or cut in two. On error nothing has changed
    /// that a program could see (a region may have been cut in two).
    pub fn remove(self: *Regions, gpa: std.mem.Allocator, start: u64, len: u64) Error!void {
        const end = try checkRange(start, len);
        try self.splitAt(gpa, start);
        try self.splitAt(gpa, end);
        const first = self.lowerBound(start);
        var last = first;
        while (last < self.list.items.len and self.list.items[last].start < end) last += 1;
        for (self.list.items[first..last]) |r| holdOf(r, false);
        self.list.replaceRangeAssumeCapacity(first, last - first, &.{});
    }

    /// Give `[start, start + len)` the permissions `prot`. All of it must
    /// be in regions (`error.NotMapped` otherwise, and nothing changes).
    pub fn protect(self: *Regions, gpa: std.mem.Allocator, start: u64, len: u64, prot: Prot) Error!void {
        const end = try checkRange(start, len);
        if (!self.isCovered(start, len)) return error.NotMapped;
        try self.splitAt(gpa, start);
        try self.splitAt(gpa, end);
        var i = self.lowerBound(start);
        const first = i;
        while (i < self.list.items.len and self.list.items[i].start < end) : (i += 1) {
            self.list.items[i].prot = prot;
        }
        self.mergeAround(first -| 1, i);
    }

    /// Merge neighbours that have become alike, among the regions with
    /// index `from` up to and including `to`.
    fn mergeAround(self: *Regions, from: usize, to: usize) void {
        var i = from;
        var limit = @min(to, self.list.items.len -| 1);
        while (i < limit) {
            if (self.list.items[i].mergeable(self.list.items[i + 1])) {
                self.list.items[i].end = self.list.items[i + 1].end;
                _ = self.list.orderedRemove(i + 1);
                limit -= 1;
            } else i += 1;
        }
    }

    /// Total pages in regions that allow any access: what the program could
    /// come to use.
    pub fn accessiblePages(self: *const Regions) u64 {
        var n: u64 = 0;
        for (self.list.items) |r| {
            if (r.prot.any()) n += r.pages();
        }
        return n;
    }
};
