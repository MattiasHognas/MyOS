//! Host tests for the physical allocator's bookkeeping
//! (`src/kernel/page_bitmap.zig`), including a randomized run against a
//! simple model.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const page_bitmap = @import("page_bitmap");
const PageBitmap = page_bitmap.PageBitmap;

/// A bitmap over `total` pages with its own storage.
fn Fixture(comptime total: usize) type {
    return struct {
        used: [PageBitmap.bytesFor(total)]u8 = undefined,
        managed: [PageBitmap.bytesFor(total)]u8 = undefined,

        fn init(self: *@This()) PageBitmap {
            return PageBitmap.init(&self.used, &self.managed, total);
        }
    };
}

test "a new bitmap has nothing to hand out" {
    var f: Fixture(64) = .{};
    var bm = f.init();
    try expectEqual(@as(usize, 0), bm.free_count);
    try expectEqual(@as(?usize, null), bm.alloc());
    try expect(bm.consistent());
    try expectError(error.NotManaged, bm.free(3));
}

test "bytesFor rounds up" {
    try expectEqual(@as(usize, 0), PageBitmap.bytesFor(0));
    try expectEqual(@as(usize, 1), PageBitmap.bytesFor(1));
    try expectEqual(@as(usize, 1), PageBitmap.bytesFor(8));
    try expectEqual(@as(usize, 2), PageBitmap.bytesFor(9));
}

test "regions become free pages, and only they are handed out" {
    var f: Fixture(64) = .{};
    var bm = f.init();
    bm.addRegion(10, 5);
    bm.addRegion(40, 3);
    try expectEqual(@as(usize, 8), bm.free_count);
    var seen: [64]bool = @splat(false);
    for (0..8) |_| {
        const page = bm.alloc().?;
        try expect((page >= 10 and page < 15) or (page >= 40 and page < 43));
        try expect(!seen[page]); // never the same page twice
        seen[page] = true;
    }
    try expectEqual(@as(?usize, null), bm.alloc());
    try expectEqual(@as(usize, 0), bm.free_count);
    try expect(bm.consistent());
}

test "a region is clipped to the bitmap and overlapping regions count once" {
    var f: Fixture(20) = .{};
    var bm = f.init();
    bm.addRegion(16, 100); // runs past the end
    try expectEqual(@as(usize, 4), bm.free_count);
    bm.addRegion(14, 4); // overlaps the first
    try expectEqual(@as(usize, 6), bm.free_count);
    bm.addRegion(500, 3); // entirely outside
    try expectEqual(@as(usize, 6), bm.free_count);
    try expect(bm.consistent());
}

test "free returns exactly the page, once" {
    var f: Fixture(32) = .{};
    var bm = f.init();
    bm.addRegion(0, 32);
    const a = bm.alloc().?;
    const b = bm.alloc().?;
    try expect(a != b);
    try expectEqual(@as(usize, 30), bm.free_count);
    try bm.free(a);
    try expectEqual(@as(usize, 31), bm.free_count);
    try expect(bm.isFree(a) and bm.isAllocated(b));
    try expectError(error.NotAllocated, bm.free(a)); // double free
    try expectEqual(@as(usize, 31), bm.free_count);
    try bm.free(b);
    try expectError(error.NotAllocated, bm.free(b));
    try expectEqual(@as(usize, 32), bm.free_count);
    try expect(bm.consistent());
}

test "a page that was never allocated cannot be freed" {
    var f: Fixture(32) = .{};
    var bm = f.init();
    bm.addRegion(0, 32);
    try expectError(error.NotAllocated, bm.free(7));
    try expectEqual(@as(usize, 32), bm.free_count);
}

test "pages outside the bitmap or outside managed memory cannot be freed" {
    var f: Fixture(32) = .{};
    var bm = f.init();
    bm.addRegion(8, 8);
    try expectError(error.OutOfRange, bm.free(32));
    try expectError(error.OutOfRange, bm.free(std.math.maxInt(usize)));
    try expectError(error.NotManaged, bm.free(0)); // a hole in the memory map
    try expectError(error.NotManaged, bm.free(31));
    try expectEqual(@as(usize, 8), bm.free_count);
    try expect(bm.consistent());
    // ...so a stray free can never make such a page allocatable.
    for (0..8) |_| {
        const page = bm.alloc().?;
        try expect(page >= 8 and page < 16);
    }
    try expectEqual(@as(?usize, null), bm.alloc());
}

test "a reserved page is never handed out and never freed" {
    var f: Fixture(16) = .{};
    var bm = f.init();
    bm.addRegion(0, 16);
    bm.reserve(0);
    bm.reserve(5);
    bm.reserve(5); // twice changes nothing
    bm.reserve(99); // outside: ignored
    try expectEqual(@as(usize, 14), bm.free_count);
    for (0..14) |_| {
        const page = bm.alloc().?;
        try expect(page != 0 and page != 5);
    }
    try expectEqual(@as(?usize, null), bm.alloc());
    try expectError(error.NotManaged, bm.free(0));
    try expectError(error.NotManaged, bm.free(5));
    try expect(!bm.isAllocated(5) and !bm.isFree(5));
    try expect(bm.consistent());
}

test "a freed page is found again when everything else is taken" {
    var f: Fixture(200) = .{};
    var bm = f.init();
    bm.addRegion(0, 200);
    for (0..200) |_| _ = bm.alloc().?;
    try expectEqual(@as(?usize, null), bm.alloc());
    for ([_]usize{ 0, 7, 8, 63, 64, 199, 100 }) |page| {
        try bm.free(page);
        try expectEqual(@as(?usize, page), bm.alloc()); // wherever the search hint is
        try expectEqual(@as(?usize, null), bm.alloc());
    }
}

test "a bitmap whose size is not a multiple of 8 never hands out the padding" {
    var f: Fixture(13) = .{};
    var bm = f.init();
    bm.addRegion(0, 13);
    for (0..13) |_| try expect(bm.alloc().? < 13);
    try expectEqual(@as(?usize, null), bm.alloc());
    try expectError(error.OutOfRange, bm.free(13));
    try expectError(error.OutOfRange, bm.free(15));
}

test "consistent notices a count that does not match the bitmap" {
    var f: Fixture(32) = .{};
    var bm = f.init();
    bm.addRegion(0, 32);
    _ = bm.alloc();
    try expect(bm.consistent());
    bm.free_count += 1;
    try expect(!bm.consistent());
    bm.free_count -= 1;
    // A page marked free that the allocator does not own.
    var g: Fixture(32) = .{};
    var holes = g.init();
    holes.addRegion(0, 8);
    try expect(holes.consistent());
    holes.used[2] &= ~@as(u8, 1); // page 16: unmanaged, now "free"
    try expect(!holes.consistent());
}

test "random allocations and frees agree with a model" {
    const total = 1000;
    var f: Fixture(total) = .{};
    var bm = f.init();
    // Managed memory with holes, like a real memory map.
    bm.addRegion(1, 159);
    bm.addRegion(256, 500);
    bm.addRegion(900, 100);
    bm.reserve(300);
    bm.reserve(301);

    const State = enum { unmanaged, free, allocated };
    var model: [total]State = @splat(.unmanaged);
    for (0..total) |page| {
        const in_region = (page >= 1 and page < 160) or (page >= 256 and page < 756) or page >= 900;
        if (in_region and page != 300 and page != 301) model[page] = .free;
    }
    var free_model: usize = 757;
    try expectEqual(free_model, bm.free_count);

    var prng = std.Random.DefaultPrng.init(0x504D_4D5F_4249_5453); // fixed seed
    const random = prng.random();
    for (0..200_000) |step| {
        switch (random.uintLessThan(u8, 10)) {
            0...4 => { // allocate (more often when a phase wants memory used up)
                if (bm.alloc()) |page| {
                    try expectEqual(State.free, model[page]);
                    model[page] = .allocated;
                    free_model -= 1;
                } else try expectEqual(@as(usize, 0), free_model);
            },
            5...8 => { // free a random page, whatever its state
                const page = random.uintLessThan(usize, total + 20);
                const result = bm.free(page);
                if (page >= total) {
                    try expectError(error.OutOfRange, result);
                } else switch (model[page]) {
                    .unmanaged => try expectError(error.NotManaged, result),
                    .free => try expectError(error.NotAllocated, result),
                    .allocated => {
                        try result;
                        model[page] = .free;
                        free_model += 1;
                    },
                }
            },
            else => { // free a run of pages, to make room in bulk
                const first = random.uintLessThan(usize, total);
                for (first..@min(total, first + 30)) |page| {
                    if (model[page] != .allocated) continue;
                    try bm.free(page);
                    model[page] = .free;
                    free_model += 1;
                }
            },
        }
        try expectEqual(free_model, bm.free_count);
        if (step % 5000 == 0) {
            try expect(bm.consistent());
            for (0..total) |page| {
                try expectEqual(model[page] == .allocated, bm.isAllocated(page));
                try expectEqual(model[page] == .free, bm.isFree(page));
            }
        }
    }
    try expect(bm.consistent());
    try expectEqual(free_model, bm.countFree());
}
