//! Host tests for the filesystem in memory (`src/kernel/fs/ramfs.zig`),
//! with blocks from the host's allocator, which also finds what is leaked.

const std = @import("std");
const ramfs = @import("ramfs");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectError = testing.expectError;

/// Blocks from the testing allocator, counted, with an end to them.
const TestBlocks = struct {
    var live: usize = 0;
    var left: usize = std.math.maxInt(usize);

    pub fn alloc() ?*[ramfs.BLOCK]u8 {
        if (left == 0) return null;
        left -= 1;
        live += 1;
        return testing.allocator.create([ramfs.BLOCK]u8) catch null;
    }

    pub fn free(block: *[ramfs.BLOCK]u8) void {
        live -= 1;
        testing.allocator.destroy(block);
    }
};

const Fs = ramfs.RamFs(TestBlocks);

fn newFs() Fs {
    TestBlocks.live = 0;
    TestBlocks.left = std.math.maxInt(usize);
    return .{ .gpa = testing.allocator, .blocks_max = 1024 };
}

fn readAll(fs: *Fs, path: []const u8, buf: []u8) ![]const u8 {
    const f = try fs.open(path);
    defer fs.release(f);
    return buf[0..fs.read(f, 0, buf)];
}

fn put(fs: *Fs, path: []const u8, text: []const u8) !void {
    const f = try fs.create(path);
    defer fs.release(f);
    try expectEqual(text.len, try fs.write(f, 0, text));
}

fn names(fs: *Fs, dir: []const u8, out: []u8) []const u8 {
    var cookie: u64 = 0;
    var len: usize = 0;
    var name_buf: [64]u8 = undefined;
    while (fs.next(dir, &cookie, &name_buf)) |e| {
        if (len != 0) {
            out[len] = ' ';
            len += 1;
        }
        @memcpy(out[len..][0..e.name.len], e.name);
        len += e.name.len;
        if (e.kind == .directory) {
            out[len] = '/';
            len += 1;
        }
    }
    return out[0..len];
}

test "ramfs: files are made, written, read back and removed" {
    var fs = newFs();
    defer fs.deinit();
    var buf: [64]u8 = undefined;

    try put(&fs, "/note", "hello");
    try testing.expectEqualStrings("hello", try readAll(&fs, "/note", &buf));
    try expectEqual(ramfs.Info{ .kind = .file, .size = 5 }, fs.info("/note").?);
    try expectEqual(.directory, fs.info("/").?.kind);
    try expectEqual(null, fs.info("/nothing"));

    // In the middle, and past the end: the gap is zeroes.
    const f = try fs.open("/note");
    try expectEqual(2, try fs.write(f, 1, "EY"));
    try expectEqual(3, try fs.write(f, 8, "end"));
    fs.release(f);
    try testing.expectEqualStrings("hEYlo\x00\x00\x00end", try readAll(&fs, "/note", &buf));
    // Reads: from an offset, short at the end, nothing beyond it.
    const g = try fs.open("/note");
    defer fs.release(g);
    try expectEqual(3, fs.read(g, 8, &buf));
    try expectEqual(1, fs.read(g, 10, &buf));
    try expectEqual(0, fs.read(g, 11, &buf));
    try expectEqual(0, fs.read(g, 5000, &buf));

    try expectError(error.Exists, fs.create("/note"));
    try expectError(error.NotFound, fs.open("/nothing"));
    try expectError(error.NotFound, fs.create("/no/such/dir/file"));
    try expectError(error.NotDirectory, fs.create("/note/inside"));
    try expectError(error.IsDirectory, fs.open("/"));
    try fs.unlink("/note");
    try expectError(error.NotFound, fs.unlink("/note"));
    try expectEqual(null, fs.info("/note"));
    // Empty again, it holds no memory at all (the handle is still open).
    try expectEqual(0, fs.entries.capacity);
}

test "ramfs: a large file takes blocks only where it was written" {
    var fs = newFs();
    defer fs.deinit();
    const f = try fs.create("/sparse");
    defer fs.release(f);
    try expectEqual(1, try fs.write(f, 10 * 1024 * 1024, "x")); // 10 MiB in
    try expectEqual(10 * 1024 * 1024 + 1, f.size);
    try expectEqual(1, TestBlocks.live);
    var buf: [8]u8 = undefined;
    try expectEqual(8, fs.read(f, 5 * 1024 * 1024, &buf));
    try expect(std.mem.allEqual(u8, &buf, 0));
    // Across a block boundary.
    var data: [3 * ramfs.BLOCK]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 7);
    try expectEqual(data.len, try fs.write(f, ramfs.BLOCK - 100, &data));
    var back: [3 * ramfs.BLOCK]u8 = undefined;
    try expectEqual(back.len, fs.read(f, ramfs.BLOCK - 100, &back));
    try testing.expectEqualSlices(u8, &data, &back);
    try expectEqual(1 + 4, TestBlocks.live);

    // Cut short: the blocks beyond go, and the cut-off part of the last
    // one does not come back when the file grows again.
    try fs.truncate(f, ramfs.BLOCK + 10);
    try expectEqual(2, TestBlocks.live);
    try fs.truncate(f, 3 * ramfs.BLOCK);
    try expectEqual(8, fs.read(f, ramfs.BLOCK + 10, &buf));
    try expect(std.mem.allEqual(u8, &buf, 0));
    try expectEqual(back[109], blk: { // the byte just before the cut is as it was
        _ = fs.read(f, ramfs.BLOCK + 9, buf[0..1]);
        break :blk buf[0];
    });
    try fs.truncate(f, 0);
    try expectEqual(0, TestBlocks.live);
    try expectError(error.TooLarge, fs.truncate(f, Fs.MAX_FILE + 1));
    try expectError(error.TooLarge, fs.write(f, Fs.MAX_FILE, "x"));
    try expectError(error.TooLarge, fs.write(f, std.math.maxInt(u64), "xy"));
}

test "ramfs: a removed file lives while it is open" {
    var fs = newFs();
    defer fs.deinit();
    try put(&fs, "/temp", "still here");
    const f = try fs.open("/temp");
    try fs.unlink("/temp");
    try expectEqual(null, fs.info("/temp"));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("still here", buf[0..fs.read(f, 0, &buf)]);
    try expectEqual(4, try fs.write(f, 6, "gone")); // and can still be written
    try put(&fs, "/temp", "another"); // the name is free for another file
    try expectEqual(2, TestBlocks.live);
    fs.release(f);
    try expectEqual(1, TestBlocks.live);
    try testing.expectEqualStrings("another", try readAll(&fs, "/temp", &buf));
}

test "ramfs: directories" {
    var fs = newFs();
    defer fs.deinit();
    var out: [128]u8 = undefined;
    try fs.mkdir("/a");
    try fs.mkdir("/a/b");
    try put(&fs, "/a/b/file", "1");
    try put(&fs, "/a/other", "2");
    try put(&fs, "/top", "3");
    try testing.expectEqualStrings("a/ top", names(&fs, "/", &out));
    try testing.expectEqualStrings("b/ other", names(&fs, "/a", &out));
    try testing.expectEqualStrings("file", names(&fs, "/a/b", &out));
    try testing.expectEqualStrings("", names(&fs, "/nothing", &out));

    try expectError(error.Exists, fs.mkdir("/a"));
    try expectError(error.Exists, fs.mkdir("/top"));
    try expectError(error.Exists, fs.mkdir("/"));
    try expectError(error.NotFound, fs.mkdir("/x/y"));
    try expectError(error.NotDirectory, fs.mkdir("/top/dir"));
    try expectError(error.IsDirectory, fs.open("/a"));
    try expectError(error.IsDirectory, fs.unlink("/a"));
    try expectError(error.NotDirectory, fs.rmdir("/top"));
    try expectError(error.NotEmpty, fs.rmdir("/a"));
    try expectError(error.NotEmpty, fs.rmdir("/a/b"));
    try expectError(error.Invalid, fs.rmdir("/"));
    try fs.unlink("/a/b/file");
    try fs.rmdir("/a/b");
    try testing.expectEqualStrings("other", names(&fs, "/a", &out));
    // A name that is the start of another is not its parent.
    try fs.mkdir("/ab");
    try testing.expectEqualStrings("other", names(&fs, "/a", &out));
}

test "ramfs: rename" {
    var fs = newFs();
    defer fs.deinit();
    var out: [128]u8 = undefined;
    var buf: [16]u8 = undefined;
    try put(&fs, "/one", "1");
    try put(&fs, "/two", "2");
    try fs.mkdir("/dir");
    try put(&fs, "/dir/inside", "in");
    try fs.mkdir("/dir/sub");
    try put(&fs, "/dir/sub/deep", "deep");

    try fs.rename("/one", "/uno");
    try testing.expectEqualStrings("1", try readAll(&fs, "/uno", &buf));
    try expectEqual(null, fs.info("/one"));
    try fs.rename("/uno", "/uno"); // onto itself: nothing
    // Onto another file: that one is replaced, and its memory freed.
    try fs.rename("/uno", "/two");
    try testing.expectEqualStrings("1", try readAll(&fs, "/two", &buf));
    try expectEqual(3, TestBlocks.live);
    // A directory takes everything inside along.
    try fs.rename("/dir", "/moved");
    try testing.expectEqualStrings("inside sub/", names(&fs, "/moved", &out));
    try testing.expectEqualStrings("deep", try readAll(&fs, "/moved/sub/deep", &buf));
    try expectEqual(null, fs.info("/dir/inside"));
    // Into another directory.
    try fs.mkdir("/box");
    try fs.rename("/two", "/box/two");
    try testing.expectEqualStrings("two", names(&fs, "/box", &out));

    try expectError(error.NotFound, fs.rename("/nothing", "/x"));
    try expectError(error.NotFound, fs.rename("/moved", "/no/where"));
    try expectError(error.Invalid, fs.rename("/moved", "/moved/sub/again")); // into itself
    try expectError(error.Invalid, fs.rename("/", "/x"));
    try expectError(error.Invalid, fs.rename("/moved", "/"));
    try expectError(error.NotDirectory, fs.rename("/moved", "/box/two")); // a directory onto a file
    try expectError(error.IsDirectory, fs.rename("/box/two", "/moved")); // a file onto a directory
    try expectError(error.NotEmpty, fs.rename("/moved", "/box")); // onto a directory that holds something
    try fs.unlink("/box/two");
    try fs.rename("/moved", "/box"); // onto an empty one: replaced
    try testing.expectEqualStrings("inside sub/", names(&fs, "/box", &out));
}

test "ramfs: full, and out of memory at every step" {
    // The filesystem's own limit.
    var fs = newFs();
    fs.blocks_max = 3;
    const f = try fs.create("/big");
    var data: [5 * ramfs.BLOCK]u8 = @splat('d');
    try expectEqual(3 * ramfs.BLOCK, try fs.write(f, 0, &data)); // as much as there is room for
    try expectEqual(3 * ramfs.BLOCK, f.size);
    try expectError(error.NoSpace, fs.write(f, f.size, "x"));
    try expectEqual(1, try fs.write(f, 100, "y")); // inside what it has: fine
    try fs.truncate(f, ramfs.BLOCK);
    try expectEqual(1, try fs.write(f, 2 * ramfs.BLOCK, "z")); // room again
    fs.release(f);
    fs.deinit();
    try expectEqual(0, TestBlocks.live);

    // No memory for the bookkeeping: every operation fails cleanly at
    // whichever allocation is refused, and nothing is leaked (the testing
    // allocator checks) or half done.
    var fail_at: usize = 0;
    while (fail_at < 40) : (fail_at += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_at });
        var small: Fs = .{ .gpa = failing.allocator(), .blocks_max = 16 };
        TestBlocks.live = 0;
        TestBlocks.left = std.math.maxInt(usize);
        const ok = scenario(&small);
        small.deinit();
        try expectEqual(0, TestBlocks.live);
        if (ok) break; // every allocation of the scenario has been refused once
    } else return error.ScenarioNeverCompleted;
}

/// A bit of everything; true if it all went through.
fn scenario(fs: *Fs) bool {
    fs.mkdir("/d") catch return false;
    const f = fs.create("/d/f") catch return false;
    defer fs.release(f);
    _ = fs.write(f, 0, "contents") catch return false;
    _ = fs.write(f, 20 * ramfs.BLOCK, "far") catch return false;
    fs.mkdir("/d/sub") catch return false;
    const before = fs.entries.items.len;
    fs.rename("/d", "/e") catch {
        // Nothing moved: the old names are all there, the new ones are not.
        std.debug.assert(fs.entries.items.len == before);
        std.debug.assert(fs.info("/d/f") != null and fs.info("/e") == null);
        return false;
    };
    std.debug.assert(fs.info("/e/f") != null and fs.info("/d") == null);
    return true;
}
