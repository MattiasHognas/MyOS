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
