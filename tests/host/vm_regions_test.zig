//! Host tests for the regions of a user address space
//! (`src/kernel/vm_regions.zig`), against a model that keeps one entry per
//! page.

const std = @import("std");
const vm = @import("vm_regions");
const Regions = vm.Regions;
const Prot = vm.Prot;
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectError = testing.expectError;

const P = vm.PAGE_SIZE;
const gpa = testing.allocator;

const ro: Prot = .{ .read = true };
const rx: Prot = .{ .read = true, .exec = true };

fn expectRegions(r: *const Regions, want: []const [2]u64) !void {
    try expectEqual(want.len, r.items().len);
    for (want, r.items()) |w, got| {
        try expectEqual(w[0] * P, got.start);
        try expectEqual(w[1] * P, got.end);
    }
}

test "add keeps the regions sorted and refuses overlaps" {
    var r: Regions = .{};
    defer r.deinit(gpa);
    try r.add(gpa, 10 * P, 2 * P, Prot.rw, .image);
    try r.add(gpa, 2 * P, 3 * P, ro, .image);
    try r.add(gpa, 20 * P, P, Prot.rw, .stack);
    try expectRegions(&r, &.{ .{ 2, 5 }, .{ 10, 12 }, .{ 20, 21 } });
    try expectError(error.Overlap, r.add(gpa, 4 * P, 2 * P, ro, .anon)); // tail of the first
    try expectError(error.Overlap, r.add(gpa, 9 * P, 2 * P, ro, .anon)); // head of the second
    try expectError(error.Overlap, r.add(gpa, P, 30 * P, ro, .anon)); // around all
    try expectError(error.Overlap, r.add(gpa, 10 * P, P, ro, .anon));
    try r.add(gpa, 5 * P, 5 * P, ro, .anon); // exactly the gap
    try expectRegions(&r, &.{ .{ 2, 5 }, .{ 5, 10 }, .{ 10, 12 }, .{ 20, 21 } });
}

test "ranges must be whole pages, not empty and not wrap" {
    var r: Regions = .{};
    defer r.deinit(gpa);
    try expectError(error.BadRange, r.add(gpa, 100, P, ro, .anon));
    try expectError(error.BadRange, r.add(gpa, P, 100, ro, .anon));
    try expectError(error.BadRange, r.add(gpa, P, 0, ro, .anon));
    try expectError(error.BadRange, r.add(gpa, ~@as(u64, 0) - P + 1, 2 * P, ro, .anon));
    try expectError(error.BadRange, r.remove(gpa, P, 0));
    try expectError(error.BadRange, r.protect(gpa, 3, P, ro));
    try expectEqual(0, r.items().len);
}

test "find says which region an address is in" {
    var r: Regions = .{};
    defer r.deinit(gpa);
    try r.add(gpa, 4 * P, 2 * P, ro, .image);
    try r.add(gpa, 8 * P, P, Prot.rw, .heap);
    try expect(r.find(4 * P - 1) == null);
    try expectEqual(vm.Kind.image, r.find(4 * P).?.kind);
    try expectEqual(vm.Kind.image, r.find(6 * P - 1).?.kind);
    try expect(r.find(6 * P) == null);
    try expectEqual(vm.Kind.heap, r.find(8 * P + 5).?.kind);
    try expect(r.find(9 * P) == null);
    try expect(r.find(0) == null);
}

test "anonymous neighbours with the same permissions become one region" {
    var r: Regions = .{};
    defer r.deinit(gpa);
    try r.add(gpa, 10 * P, P, Prot.rw, .anon);
    try r.add(gpa, 12 * P, P, Prot.rw, .anon);
    try r.add(gpa, 11 * P, P, Prot.rw, .anon); // joins both
    try expectRegions(&r, &.{.{ 10, 13 }});
    try r.add(gpa, 13 * P, P, ro, .anon); // other permissions: stays apart
    try r.add(gpa, 9 * P, P, Prot.rw, .stack); // other kind: stays apart
    try expectRegions(&r, &.{ .{ 9, 10 }, .{ 10, 13 }, .{ 13, 14 } });
    // Making them alike merges them.
    try r.protect(gpa, 13 * P, P, Prot.rw);
    try expectRegions(&r, &.{ .{ 9, 10 }, .{ 10, 14 } });
}

test "remove shortens, splits and deletes regions, and skips holes" {
    var r: Regions = .{};
    defer r.deinit(gpa);
    try r.add(gpa, 10 * P, 10 * P, Prot.rw, .anon);
    try r.remove(gpa, 13 * P, 2 * P); // from the middle
    try expectRegions(&r, &.{ .{ 10, 13 }, .{ 15, 20 } });
    try r.remove(gpa, 10 * P, P); // from the front
    try r.remove(gpa, 19 * P, P); // from the back
    try expectRegions(&r, &.{ .{ 11, 13 }, .{ 15, 19 } });
    try r.remove(gpa, 12 * P, 4 * P); // across the hole
    try expectRegions(&r, &.{ .{ 11, 12 }, .{ 16, 19 } });
    try r.remove(gpa, 30 * P, P); // nothing there
    try r.remove(gpa, 0, 100 * P); // everything
    try expectRegions(&r, &.{});
}

test "protect needs the whole range mapped, and splits at its ends" {
    var r: Regions = .{};
    defer r.deinit(gpa);
    try r.add(gpa, 10 * P, 4 * P, Prot.rw, .anon);
    try r.add(gpa, 16 * P, 2 * P, Prot.rw, .anon);
    try expectError(error.NotMapped, r.protect(gpa, 12 * P, 6 * P, ro)); // a hole inside
    try expectError(error.NotMapped, r.protect(gpa, 9 * P, 2 * P, ro)); // starts before
    try expectError(error.NotMapped, r.protect(gpa, 17 * P, 2 * P, ro)); // ends after
    try expectRegions(&r, &.{ .{ 10, 14 }, .{ 16, 18 } }); // unchanged
    try r.protect(gpa, 11 * P, 2 * P, Prot.none);
    try expectRegions(&r, &.{ .{ 10, 11 }, .{ 11, 13 }, .{ 13, 14 }, .{ 16, 18 } });
    try expect(!r.find(11 * P).?.prot.any());
    try expect(r.find(13 * P).?.prot.write);
    try r.protect(gpa, 11 * P, 2 * P, Prot.rw); // back: one region again
    try expectRegions(&r, &.{ .{ 10, 14 }, .{ 16, 18 } });
}

test "findFree places top down, in the highest gap that fits" {
    var r: Regions = .{};
    defer r.deinit(gpa);
    const low = 16 * P;
    const high = 100 * P;
    try expectEqual(96 * P, r.findFree(4 * P, low, high).?); // empty: at the top
    try r.add(gpa, 96 * P, 4 * P, Prot.rw, .anon);
    try expectEqual(94 * P, r.findFree(2 * P, low, high).?); // just below it
    try r.add(gpa, 80 * P, 10 * P, Prot.rw, .stack);
    try expectEqual(90 * P, r.findFree(6 * P, low, high).?); // the gap of 6 between them
    try expectEqual(73 * P, r.findFree(7 * P, low, high).?); // too big for it: below
    try expectEqual(16 * P, r.findFree(64 * P, low, high).?); // exactly what is left
    try expect(r.findFree(65 * P, low, high) == null);
    // Regions outside the window do not matter; one straddling its top does.
    try r.add(gpa, 2 * P, P, Prot.rw, .image);
    try r.add(gpa, 200 * P, P, Prot.rw, .anon);
    try expectEqual(16 * P, r.findFree(64 * P, low, high).?);
    try expectEqual(78 * P, r.findFree(2 * P, low, 85 * P).?);
    try expect(r.findFree(0, low, high) == null);
    try expect(r.findFree(P + 1, low, high) == null);
}

test "isFree and isCovered" {
    var r: Regions = .{};
    defer r.deinit(gpa);
    try r.add(gpa, 10 * P, 2 * P, ro, .image);
    try r.add(gpa, 12 * P, 2 * P, Prot.rw, .image); // adjacent, another region
    try expect(r.isFree(8 * P, 2 * P) and r.isFree(14 * P, P));
    try expect(!r.isFree(9 * P, 2 * P) and !r.isFree(13 * P, 5 * P) and !r.isFree(0, 100 * P));
    try expect(r.isCovered(10 * P, 4 * P) and r.isCovered(11 * P, 2 * P));
    try expect(!r.isCovered(9 * P, 2 * P) and !r.isCovered(13 * P, 2 * P));
    try expectEqual(4, r.accessiblePages());
    try r.protect(gpa, 10 * P, 2 * P, Prot.none);
    try expectEqual(2, r.accessiblePages());
}

/// An allocator that has no memory to give, and cannot grow what it is shown.
const no_memory: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = struct {
        fn f(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
            return null;
        }
    }.f,
    .resize = struct {
        fn f(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
    }.f,
    .remap = struct {
        fn f(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
    }.f,
    .free = struct {
        fn f(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
    }.f,
} };

/// One entry per page: 0 = free, otherwise 1 + the permission bits.
const Model = struct {
    const PAGES = 96;
    page: [PAGES]u8 = @splat(0),

    fn check(m: *const Model, r: *const Regions) !void {
        // Every page agrees, and the regions are sorted, disjoint, non-empty
        // and merged as far as they can be.
        for (0..PAGES) |i| {
            const got: u8 = if (r.find(i * P)) |reg| 1 + @as(u8, @bitCast(reg.prot)) else 0;
            try expectEqual(m.page[i], got);
        }
        var prev_end: u64 = 0;
        for (r.items(), 0..) |reg, i| {
            try expect(reg.start < reg.end and reg.start >= prev_end);
            try expect(reg.start % P == 0 and reg.end % P == 0);
            if (i > 0) {
                const before = r.items()[i - 1];
                try expect(!(before.end == reg.start and before.prot.eql(reg.prot))); // would have merged
            }
            prev_end = reg.end;
        }
    }
};

test "random maps, unmaps and permission changes agree with a page-by-page model" {
    var prng = std.Random.DefaultPrng.init(0x5EED_0001);
    const rand = prng.random();
    var r: Regions = .{};
    defer r.deinit(gpa);
    var m: Model = .{};
    const prots = [_]Prot{ Prot.none, ro, Prot.rw, rx };

    for (0..20_000) |_| {
        const start = rand.uintLessThan(usize, Model.PAGES);
        const len = 1 + rand.uintLessThan(usize, @min(12, Model.PAGES - start));
        const prot = prots[rand.uintLessThan(usize, prots.len)];
        switch (rand.uintLessThan(u8, 4)) {
            0 => { // map where it is free
                const free = std.mem.allEqual(u8, m.page[start..][0..len], 0);
                const result = r.add(gpa, start * P, len * P, prot, .anon);
                if (free) {
                    try result;
                    @memset(m.page[start..][0..len], 1 + @as(u8, @bitCast(prot)));
                } else try expectError(error.Overlap, result);
            },
            1 => { // unmap
                try r.remove(gpa, start * P, len * P);
                @memset(m.page[start..][0..len], 0);
            },
            2 => { // change permissions
                const covered = std.mem.indexOfScalar(u8, m.page[start..][0..len], 0) == null;
                const result = r.protect(gpa, start * P, len * P, prot);
                if (covered) {
                    try result;
                    @memset(m.page[start..][0..len], 1 + @as(u8, @bitCast(prot)));
                } else try expectError(error.NotMapped, result);
            },
            else => { // place a mapping where there is room
                if (r.findFree(len * P, 0, Model.PAGES * P)) |at| {
                    try expect(std.mem.allEqual(u8, m.page[at / P ..][0..len], 0));
                    // Top down: no free run of that length starts above it.
                    var higher = at / P + 1;
                    while (higher + len <= Model.PAGES) : (higher += 1) {
                        try expect(!std.mem.allEqual(u8, m.page[higher..][0..len], 0));
                    }
                    try r.add(gpa, at, len * P, prot, .anon);
                    @memset(m.page[at / P ..][0..len], 1 + @as(u8, @bitCast(prot)));
                } else {
                    var any: usize = 0;
                    while (any + len <= Model.PAGES) : (any += 1) {
                        try expect(!std.mem.allEqual(u8, m.page[any..][0..len], 0));
                    }
                }
            },
        }
        try m.check(&r);
    }
}

test "running out of memory for the list changes nothing a program can see" {
    var r: Regions = .{};
    defer r.deinit(gpa);
    try r.add(gpa, 10 * P, 10 * P, Prot.rw, .anon);
    // Fill the list's spare room with regions far away, so that one more
    // entry needs memory.
    var far: u64 = 1000;
    while (r.list.items.len < r.list.capacity) : (far += 2) try r.add(gpa, far * P, P, ro, .image);
    const count = r.items().len;
    const bad = no_memory;
    // Each of these needs a new entry, which cannot be had.
    try expectError(error.OutOfMemory, r.add(bad, 30 * P, P, ro, .anon));
    try expectError(error.OutOfMemory, r.remove(bad, 13 * P, P));
    try expectError(error.OutOfMemory, r.protect(bad, 13 * P, P, ro));
    try expectEqual(count, r.items().len);
    try expectEqual(10 * P, r.items()[0].start);
    try expectEqual(20 * P, r.items()[0].end);
    try expect(r.find(13 * P).?.prot.write and r.find(30 * P) == null);
}
