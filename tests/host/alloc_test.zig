//! Host tests for the allocator of MyOS's own programs (`app/alloc.zig`),
//! with pages from the host and a count of what is held.

const std = @import("std");
const alloc = @import("alloc");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

/// Pages from the host's allocator, counted.
const CountedPages = struct {
    var mapped: usize = 0;
    var maps: usize = 0;

    pub fn map(len: usize) ?[*]u8 {
        if (fail) return null;
        const memory = std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(4096), len) catch return null;
        mapped += len;
        maps += 1;
        return memory.ptr;
    }

    pub fn unmap(ptr: [*]u8, len: usize) void {
        // The host's allocator frees what it gave, in one piece or in
        // parts: pages are pages.
        std.heap.page_allocator.rawFree(ptr[0..len], .fromByteUnits(4096), @returnAddress());
        mapped -= len;
    }

    var fail = false;
};

const Heap = alloc.Allocator(CountedPages);

fn reset() void {
    CountedPages.mapped = 0;
    CountedPages.maps = 0;
    CountedPages.fail = false;
}

test "alloc: small blocks are reused, last freed first" {
    reset();
    var heap: Heap = .{};
    const a = heap.allocator();

    const one = try a.alloc(u8, 24);
    const two = try a.alloc(u8, 24);
    try expect(one.ptr != two.ptr);
    try expectEqual(1, CountedPages.maps); // both from one chunk
    a.free(one);
    const again = try a.alloc(u8, 30); // the same size of block: 32 bytes
    try expectEqual(one.ptr, again.ptr);
    // Ten thousand rounds take no more memory than the first.
    a.free(try a.alloc(u64, 5)); // the first: a chunk for blocks of 64
    const held = CountedPages.mapped;
    for (0..10_000) |_| {
        const x = try a.alloc(u64, 5);
        a.free(x);
    }
    try expectEqual(held, CountedPages.mapped);
    a.free(two);
    a.free(again);
}

test "alloc: blocks do not overlap and are aligned" {
    reset();
    var heap: Heap = .{};
    const a = heap.allocator();
    var prng: std.Random.DefaultPrng = .init(0x616c6c6f63);
    const random = prng.random();

    const Live = struct { memory: []u8, fill: u8 };
    var live: [200]?Live = @splat(null);
    for (0..20_000) |round| {
        const slot = &live[random.uintLessThan(usize, live.len)];
        if (slot.*) |l| {
            for (l.memory) |b| try expectEqual(l.fill, b); // nobody else wrote here
            a.free(l.memory);
            slot.* = null;
        } else {
            const len = switch (random.uintLessThan(u8, 10)) {
                0 => random.uintLessThan(usize, 20_000) + 1, // sometimes pages of its own
                else => random.uintLessThan(usize, 3000) + 1,
            };
            const memory = try a.alloc(u8, len);
            const fill: u8 = @truncate(round);
            @memset(memory, fill);
            slot.* = .{ .memory = memory, .fill = fill };
        }
    }
    for (live) |slot| if (slot) |l| a.free(l.memory);

    // Every alignment up to a page.
    inline for (.{ 1, 8, 16, 64, 256, 4096 }) |alignment| {
        const p = try a.alignedAlloc(u8, .fromByteUnits(alignment), 3);
        try expectEqual(0, @intFromPtr(p.ptr) % alignment);
        a.free(p);
    }
    try testing.expectError(error.OutOfMemory, a.alignedAlloc(u8, .fromByteUnits(8192), 3));
}

test "alloc: large blocks come from the system and go back to it" {
    reset();
    var heap: Heap = .{};
    const a = heap.allocator();
    const big = try a.alloc(u8, 100_000);
    try expectEqual(102_400, CountedPages.mapped); // rounded up to pages
    // Smaller in place: the pages past the new end go back.
    try expect(a.resize(big, 50_000));
    try expectEqual(53_248, CountedPages.mapped);
    try expect(!a.resize(big.ptr[0..50_000], 60_000)); // not larger than its pages
    try expect(a.resize(big.ptr[0..50_000], 53_000)); // but up to their end
    a.free(big.ptr[0..53_000]);
    try expectEqual(0, CountedPages.mapped);
}

test "alloc: resizing within a block, and the standard containers" {
    reset();
    var heap: Heap = .{};
    const a = heap.allocator();
    const s = try a.alloc(u8, 40); // a block of 64
    try expect(a.resize(s, 64) and a.resize(s.ptr[0..64], 33));
    try expect(!a.resize(s.ptr[0..33], 65) and !a.resize(s.ptr[0..33], 32)); // another size of block
    a.free(s.ptr[0..33]);

    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(a);
    for (0..5000) |i| try list.append(a, @intCast(i * 3));
    for (list.items, 0..) |v, i| try expectEqual(i * 3, v);
}

test "alloc: no memory is an error, not a crash" {
    reset();
    var heap: Heap = .{};
    const a = heap.allocator();
    CountedPages.fail = true;
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 10));
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 10_000));
    CountedPages.fail = false;
    const p = try a.alloc(u8, 10);
    a.free(p);
}
