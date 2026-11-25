//! Host tests for the archive format behind the initrd
//! (`src/kernel/fs/tar.zig`): walking headers, and names that are stored
//! whole or in two parts.

const std = @import("std");
const tar = @import("tar");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

/// One member to put in a test archive.
const Member = struct {
    name: []const u8,
    prefix: []const u8 = "",
    typ: u8 = '0',
    data: []const u8 = "",
    ustar: bool = true,
};

var archive_buf: [16 * 512]u8 = undefined;

/// Build an archive of `members` in `archive_buf`.
fn build(members: []const Member) []const u8 {
    @memset(&archive_buf, 0);
    var off: usize = 0;
    for (members) |m| {
        const h = archive_buf[off..][0..512];
        @memcpy(h[0..m.name.len], m.name);
        _ = std.fmt.bufPrint(h[124..136], "{o:0>11}", .{m.data.len}) catch unreachable;
        h[156] = m.typ;
        if (m.ustar) @memcpy(h[257..262], "ustar");
        @memcpy(h[345..][0..m.prefix.len], m.prefix);
        @memcpy(archive_buf[off + 512 ..][0..m.data.len], m.data);
        off += 512 + std.mem.alignForward(usize, m.data.len, 512);
    }
    return archive_buf[0 .. off + 1024]; // two empty blocks end an archive
}

test "tar: entries in order, with their contents" {
    const archive = build(&.{
        .{ .name = "./etc/motd", .data = "Welcome\n" },
        .{ .name = "./bin/", .typ = '5' },
        .{ .name = "./bin/hello", .data = &@as([600]u8, @splat('x')) }, // two blocks of data
        .{ .name = "last" },
    });
    var off: usize = 0;
    const motd = tar.next(archive, &off).?;
    try testing.expectEqualStrings("etc/motd", motd.name);
    try testing.expectEqualStrings("Welcome\n", motd.data);
    try expect(tar.isFile(motd));
    const dir = tar.next(archive, &off).?;
    try testing.expectEqualStrings("bin", dir.name);
    try expect(!tar.isFile(dir));
    const hello = tar.next(archive, &off).?;
    try expectEqual(600, hello.data.len);
    try testing.expectEqualStrings("last", tar.next(archive, &off).?.name);
    try expectEqual(null, tar.next(archive, &off)); // the end marker
    try expectEqual(null, tar.next(archive, &off));
}

test "tar: a truncated archive ends instead of reading past its end" {
    const archive = build(&.{.{ .name = "big", .data = &@as([1000]u8, @splat('y')) }});
    var off: usize = 0;
    try expectEqual(null, tar.next(archive[0..1024], &off)); // the data is cut short
    off = 0;
    try expectEqual(null, tar.next(archive[0..300], &off)); // so is the header
    off = 0;
    try expectEqual(null, tar.next("", &off));
}

test "tar: names are compared whatever way they are stored" {
    // The same file stored whole, and in every way it can be cut in two.
    const full = "usr/lib/x86_64-linux-gnu/libstdc++.so.6";
    var cut: usize = 0;
    while (cut <= full.len) : (cut += 1) {
        if (cut != 0 and (cut == full.len or full[cut] != '/')) continue; // the parts meet at a slash
        const member: Member = if (cut == 0) .{ .name = full } else .{ .prefix = full[0..cut], .name = full[cut + 1 ..] };
        const archive = build(&.{member});
        var off: usize = 0;
        const e = tar.next(archive, &off).?;

        try expect(e.named(full));
        try expect(!e.named(full[0 .. full.len - 1]) and !e.named(full ++ "x") and !e.named("") and !e.named(full[1..]));
        // It is below exactly the directories its name starts with.
        for (0..full.len + 1) |len| {
            const dir = full[0..len];
            const is_parent = len != 0 and len < full.len and full[len] == '/';
            if (len == 0) continue; // the root is not asked about
            try expectEqual(is_parent, e.below(dir));
        }
        try expect(!e.below("usr/lib/x86_64-linux-gnux") and !e.below("sr") and !e.below(full ++ "/more"));
    }
}

test "tar: the prefix field counts in ustar archives only" {
    // An old-format header may have anything where ustar has the prefix.
    const archive = build(&.{.{ .name = "file", .prefix = "junk", .ustar = false }});
    var off: usize = 0;
    const e = tar.next(archive, &off).?;
    try expect(e.named("file") and !e.named("junk/file"));
}

test "tar: names are normalized" {
    try testing.expectEqualStrings("bin/hello", tar.normalize("./bin/hello"));
    try testing.expectEqualStrings("bin/hello", tar.normalize("/bin/hello"));
    try testing.expectEqualStrings("bin", tar.normalize("/bin/"));
    try testing.expectEqualStrings("", tar.normalize("/"));
    try testing.expectEqualStrings("", tar.normalize("./"));
}

/// Every name `nextInDirectory` gives for `dir`, with a slash after the
/// directories, joined with spaces.
fn listing(archive: []const u8, dir: []const u8, out: []u8) []const u8 {
    var off: usize = 0;
    var len: usize = 0;
    var name_buf: [256]u8 = undefined;
    while (tar.nextInDirectory(archive, dir, &off, &name_buf)) |e| {
        if (len != 0) {
            out[len] = ' ';
            len += 1;
        }
        @memcpy(out[len..][0..e.name.len], e.name);
        len += e.name.len;
        if (e.directory) {
            out[len] = '/';
            len += 1;
        }
    }
    return out[0..len];
}

test "tar: what a directory holds, each name once" {
    // As `tar` writes a tree: directories have entries of their own, the
    // root's is "./".
    const archive = build(&.{
        .{ .name = "./", .typ = '5' },
        .{ .name = "./etc/", .typ = '5' },
        .{ .name = "./etc/motd", .data = "hi" },
        .{ .name = "./bin/", .typ = '5' },
        .{ .name = "./bin/sh" },
        .{ .name = "./bin/hello" },
        .{ .name = "./lib/x86_64/libc.so", .prefix = "" }, // "lib" and "x86_64" have no entries
        .{ .name = "libm.so", .prefix = "lib/x86_64" }, // a name in two parts
        .{ .name = "./empty/", .typ = '5' },
        .{ .name = "./top" },
    });
    var out: [256]u8 = undefined;
    try testing.expectEqualStrings("etc/ bin/ lib/ empty/ top", listing(archive, "", &out));
    try testing.expectEqualStrings("motd", listing(archive, "etc", &out));
    try testing.expectEqualStrings("sh hello", listing(archive, "bin", &out));
    try testing.expectEqualStrings("x86_64/", listing(archive, "lib", &out));
    try testing.expectEqualStrings("libc.so libm.so", listing(archive, "lib/x86_64", &out));
    try testing.expectEqualStrings("", listing(archive, "empty", &out));
    try testing.expectEqualStrings("", listing(archive, "nothing", &out));
    try testing.expectEqualStrings("", listing(archive, "etc/motd", &out)); // a file holds nothing
    try testing.expectEqualStrings("", listing(archive, "et", &out)); // a prefix of a name is not the name
}

test "tar: a listing goes on where it stopped" {
    const archive = build(&.{ .{ .name = "a" }, .{ .name = "b/c" }, .{ .name = "b/d" }, .{ .name = "e" } });
    var off: usize = 0;
    var name_buf: [16]u8 = undefined;
    try testing.expectEqualStrings("a", tar.nextInDirectory(archive, "", &off, &name_buf).?.name);
    const resume_at = off; // what a directory descriptor keeps between two calls
    try testing.expectEqualStrings("b", tar.nextInDirectory(archive, "", &off, &name_buf).?.name);
    try testing.expectEqualStrings("e", tar.nextInDirectory(archive, "", &off, &name_buf).?.name);
    try expectEqual(null, tar.nextInDirectory(archive, "", &off, &name_buf));
    try expectEqual(null, tar.nextInDirectory(archive, "", &off, &name_buf)); // and stays at the end
    off = resume_at;
    try testing.expectEqualStrings("b", tar.nextInDirectory(archive, "", &off, &name_buf).?.name);
    // A name longer than the caller's buffer is left out, not cut.
    var tiny: [1]u8 = undefined;
    const long = build(&.{ .{ .name = "long-name" }, .{ .name = "x" } });
    off = 0;
    try testing.expectEqualStrings("x", tar.nextInDirectory(long, "", &off, &tiny).?.name);
}

test "tar: the entry of a directory a name belongs to" {
    try testing.expectEqualStrings("bin", tar.childOf("bin/hello", "").?.name);
    try expect(!tar.childOf("bin/hello", "").?.exact and tar.childOf("bin", "").?.exact);
    try testing.expectEqualStrings("hello", tar.childOf("bin/hello", "bin").?.name);
    try expect(tar.childOf("bin/hello", "bin").?.exact);
    try testing.expectEqualStrings("x", tar.childOf("a/b/x/y/z", "a/b").?.name);
    try expectEqual(null, tar.childOf("bin", "bin")); // not below itself
    try expectEqual(null, tar.childOf("binary/x", "bin"));
    try expectEqual(null, tar.childOf("etc/motd", "bin"));
    try expectEqual(null, tar.childOf("", ""));
}

test "tar: fuzz with damaged archives" {
    // Whatever is in the headers, walking and listing must end and must
    // stay inside the archive (the bounds checks of a test build would
    // stop it otherwise).
    var prng: std.Random.DefaultPrng = .init(0x7461722d66757a7a);
    const random = prng.random();
    var name_buf: [64]u8 = undefined;
    var copy: [16 * 512]u8 = undefined;
    for (0..3000) |round| {
        const good = build(&.{
            .{ .name = "./etc/", .typ = '5' },
            .{ .name = "./etc/motd", .data = "Welcome\n" },
            .{ .name = "hello", .prefix = "bin" },
            .{ .name = "./lib/a/b/c", .data = &@as([700]u8, @splat('z')) },
        });
        @memcpy(copy[0..good.len], good);
        var image = copy[0..good.len];
        // Damage: some bytes anywhere, or in a header field that matters.
        for (0..random.uintLessThan(usize, 12) + 1) |_| {
            const header = random.uintLessThan(usize, image.len / 512) * 512;
            const at = switch (random.uintLessThan(u8, 4)) {
                0 => random.uintLessThan(usize, image.len),
                1 => header + 124 + random.uintLessThan(usize, 12), // the size
                2 => header + random.uintLessThan(usize, 100), // the name
                else => header + 345 + random.uintLessThan(usize, 155), // the prefix
            };
            if (at < image.len) image[at] = random.int(u8);
        }
        if (round % 3 == 0) image = image[0..random.uintLessThan(usize, image.len + 1)]; // cut short

        var off: usize = 0;
        var members: usize = 0;
        while (tar.next(image, &off)) |e| {
            members += 1;
            try expect(off <= image.len + 512 and members <= image.len / 512);
            // The contents are inside the archive.
            try expect(@intFromPtr(e.data.ptr) >= @intFromPtr(image.ptr) and @intFromPtr(e.data.ptr) + e.data.len <= @intFromPtr(image.ptr) + image.len);
            _ = e.named("etc/motd");
            _ = e.below("lib/a");
        }
        for ([_][]const u8{ "", "etc", "lib/a", "bin" }) |dir| {
            var at: usize = 0;
            var entries: usize = 0;
            while (tar.nextInDirectory(image, dir, &at, &name_buf)) |entry| {
                entries += 1;
                try expect(entry.name.len != 0 and entry.name.len <= name_buf.len);
                try expect(std.mem.indexOfScalar(u8, entry.name, '/') == null);
                try expect(entries <= image.len / 512);
            }
        }
    }
}
