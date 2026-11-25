//! Host unit tests for `src/kernel/vfs.zig`, using an in-memory fake filesystem.

const std = @import("std");

const vfs = @import("vfs");

/// Fake filesystem with a single file, `/hello`, that records how it is called.
const FakeFs = struct {
    data: []const u8,
    lookups: usize = 0,
    reads: usize = 0,
    last_offset: u64 = 0,

    /// `vfs.Fs.lookup` implementation: only `/hello` exists. Counts calls.
    fn lookup(
        ctx: *anyopaque,
        path: []const u8,
    ) ?vfs.Node {
        const self: *FakeFs =
            @ptrCast(@alignCast(ctx));

        self.lookups += 1;

        if (!std.mem.eql(u8, path, "/hello")) {
            return null;
        }

        return .{
            .size = self.data.len,
            .ctx = @intFromPtr(self),
            .ops = &ops,
        };
    }

    /// `vfs.Ops.read` implementation over `data`. Counts calls and records the offset.
    fn read(
        node: *const vfs.Node,
        offset: u64,
        buf: []u8,
    ) usize {
        const self: *FakeFs = @ptrFromInt(node.ctx);

        self.reads += 1;
        self.last_offset = offset;

        if (offset >= self.data.len) return 0;

        const start: usize = @intCast(offset);
        const n = @min(
            buf.len,
            self.data.len - start,
        );

        @memcpy(
            buf[0..n],
            self.data[start..][0..n],
        );

        return n;
    }

    const ops = vfs.Ops{
        .read = read,
    };

    /// Mount this fake as the VFS root filesystem.
    fn mount(self: *FakeFs) void {
        vfs.mountRoot(.{
            .ctx = self,
            .lookup = lookup,
        });
    }
};

test "VFS delegates file lookup to fake filesystem" {
    var fake = FakeFs{
        .data = "hello from fake",
    };

    fake.mount();

    try std.testing.expect(
        vfs.lookup("/missing") == null,
    );

    const node = vfs.lookup("/hello") orelse
        return error.MissingFile;

    try std.testing.expectEqual(
        @as(usize, 2),
        fake.lookups,
    );

    try std.testing.expectEqual(
        @as(u64, fake.data.len),
        node.size,
    );
}

test "VFS forwards offset and contents to fake read" {
    var fake = FakeFs{
        .data = "hello from fake",
    };

    fake.mount();

    const node = vfs.lookup("/hello") orelse
        return error.MissingFile;

    var buf: [4]u8 = undefined;
    const n = vfs.read(&node, 6, &buf);

    try std.testing.expectEqual(
        @as(usize, 4),
        n,
    );

    try std.testing.expectEqualStrings(
        "from",
        buf[0..n],
    );

    try std.testing.expectEqual(
        @as(u64, 6),
        fake.last_offset,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        fake.reads,
    );
}

test "VFS passes short buffers and EOF correctly" {
    var fake = FakeFs{
        .data = "abc",
    };

    fake.mount();

    const node = vfs.lookup("/hello") orelse
        return error.MissingFile;

    var buf: [8]u8 = @splat(0xEE);

    try std.testing.expectEqual(
        @as(usize, 2),
        vfs.read(&node, 1, buf[0..2]),
    );

    try std.testing.expectEqualStrings(
        "bc",
        buf[0..2],
    );

    try std.testing.expectEqual(
        @as(u8, 0xEE),
        buf[2],
    );

    try std.testing.expectEqual(
        @as(usize, 0),
        vfs.read(&node, node.size, &buf),
    );

    try std.testing.expectEqual(
        @as(usize, 0),
        vfs.read(&node, node.size + 1, &buf),
    );
}

test "VFS mount switches the active filesystem" {
    var first = FakeFs{ .data = "first" };
    first.mount();

    var second = FakeFs{ .data = "second" };
    second.mount();

    const node = vfs.lookup("/hello") orelse
        return error.MissingFile;

    var buf: [16]u8 = undefined;
    const n = vfs.read(&node, 0, &buf);

    try std.testing.expectEqualStrings(
        "second",
        buf[0..n],
    );

    try std.testing.expectEqual(
        @as(usize, 0),
        first.lookups,
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        second.lookups,
    );
}

/// A filesystem that is a list of file paths; a directory is whatever a
/// file is in. Reading a file gives its own path.
const ListFs = struct {
    files: []const []const u8,

    fn lookup(ctx: *anyopaque, path: []const u8) ?vfs.Node {
        const self: *ListFs = @ptrCast(@alignCast(ctx));
        for (self.files) |f| {
            if (std.mem.eql(u8, f, path)) return .{ .size = f.len, .ctx = @intFromPtr(f.ptr), .ops = &ops };
        }
        return null;
    }

    fn isDir(ctx: *anyopaque, path: []const u8) bool {
        const self: *ListFs = @ptrCast(@alignCast(ctx));
        for (self.files) |f| {
            if (f.len > path.len and std.mem.startsWith(u8, f, path) and f[path.len] == '/') return true;
        }
        return false;
    }

    /// The cookie is the index of the next file to look at.
    fn next(ctx: *anyopaque, dir: []const u8, cookie: *u64, name_buf: []u8) ?vfs.DirEntry {
        const self: *ListFs = @ptrCast(@alignCast(ctx));
        const base: usize = if (dir.len == 1) 1 else dir.len + 1;
        while (cookie.* < self.files.len) {
            const index: usize = @intCast(cookie.*);
            cookie.* += 1;
            const f = self.files[index];
            if (f.len <= base or !std.mem.startsWith(u8, f, dir) or f[base - 1] != '/') continue;
            const rest = f[base..];
            const slash = std.mem.indexOfScalar(u8, rest, '/');
            const name = rest[0 .. slash orelse rest.len];
            // Once only: not if an earlier file gave the same name.
            var seen = false;
            for (self.files[0..index]) |earlier| {
                if (earlier.len > base and std.mem.startsWith(u8, earlier, dir) and earlier[base - 1] == '/' and
                    std.mem.startsWith(u8, earlier[base..], name) and
                    (earlier.len == base + name.len or earlier[base + name.len] == '/')) seen = true;
            }
            if (seen) continue;
            @memcpy(name_buf[0..name.len], name);
            return .{ .name = name_buf[0..name.len], .kind = if (slash == null) .file else .directory };
        }
        return null;
    }

    fn read(node: *const vfs.Node, offset: u64, buf: []u8) usize {
        const text: [*]const u8 = @ptrFromInt(node.ctx);
        if (offset >= node.size) return 0;
        const n = @min(buf.len, node.size - offset);
        @memcpy(buf[0..n], text[offset..][0..n]);
        return n;
    }

    const ops = vfs.Ops{ .read = read };

    fn fs(self: *ListFs) vfs.Fs {
        return .{ .ctx = self, .lookup = lookup, .is_dir = isDir, .next = next };
    }
};

/// The names in the directory `dir`, directories with a slash, joined
/// with spaces.
fn list(dir: []const u8, out: []u8) []const u8 {
    var cookie: u64 = 0;
    var len: usize = 0;
    var name_buf: [64]u8 = undefined;
    while (vfs.next(dir, &cookie, &name_buf)) |e| {
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

test "VFS: paths are made absolute and plain" {
    var buf: [64]u8 = undefined;
    const cases = [_]struct { base: []const u8, path: []const u8, want: []const u8 }{
        .{ .base = "/", .path = "/", .want = "/" },
        .{ .base = "/", .path = "/etc/motd", .want = "/etc/motd" },
        .{ .base = "/", .path = "etc/motd", .want = "/etc/motd" },
        .{ .base = "/home/me", .path = "notes", .want = "/home/me/notes" },
        .{ .base = "/home/me", .path = "/notes", .want = "/notes" }, // absolute: the base does not count
        .{ .base = "/home/me", .path = ".", .want = "/home/me" },
        .{ .base = "/home/me", .path = "..", .want = "/home" },
        .{ .base = "/home/me", .path = "../../..", .want = "/" }, // not above the root
        .{ .base = "/home/me", .path = "../you/./x//y/", .want = "/home/you/x/y" },
        .{ .base = "/", .path = "//etc///motd", .want = "/etc/motd" },
        .{ .base = "/", .path = "/a/b/../../c", .want = "/c" },
        .{ .base = "/", .path = "/..", .want = "/" },
        .{ .base = "/", .path = "...", .want = "/..." }, // three dots are a name
        .{ .base = "/", .path = "/.hidden/..x", .want = "/.hidden/..x" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c.want, try vfs.normalize(&buf, c.base, c.path));

    try std.testing.expectError(error.NotFound, vfs.normalize(&buf, "/", ""));
    // What does not fit, in whole or in one part.
    var small: [8]u8 = undefined;
    try std.testing.expectEqualStrings("/abc/def", try vfs.normalize(&small, "/", "/abc/def"));
    try std.testing.expectError(error.NameTooLong, vfs.normalize(&small, "/", "/abc/defg"));
    try std.testing.expectError(error.NameTooLong, vfs.normalize(&small, "/abc/def", "x"));
    try std.testing.expectEqualStrings("/abc", try vfs.normalize(&small, "/abc/def", "..")); // the base alone fits
    var long: [600]u8 = undefined;
    const name = "/" ++ &@as([vfs.NAME_MAX]u8, @splat('n'));
    try std.testing.expectEqualStrings(name, try vfs.normalize(&long, "/", name));
    try std.testing.expectError(error.NameTooLong, vfs.normalize(&long, "/", name ++ "n"));
}

test "VFS: a path goes to the filesystem mounted nearest above it" {
    vfs.unmountAll();
    defer vfs.unmountAll();
    var root: ListFs = .{ .files = &.{ "/etc/motd", "/bin/sh", "/tmp/shadowed", "/mnt/usb/README" } };
    var tmp: ListFs = .{ .files = &.{ "/note", "/dir/inner" } };
    var deep: ListFs = .{ .files = &.{"/file"} };
    vfs.mountRoot(root.fs());
    try vfs.mount("/tmp", tmp.fs());
    try vfs.mount("/srv/data/deep", deep.fs());

    var buf: [32]u8 = undefined;
    const read = struct {
        fn all(path: []const u8, out: []u8) ?[]const u8 {
            const node = vfs.lookup(path) orelse return null;
            return out[0..vfs.read(&node, 0, out)];
        }
    }.all;
    // Each filesystem is asked with the path inside it.
    try std.testing.expectEqualStrings("/etc/motd", read("/etc/motd", &buf).?);
    try std.testing.expectEqualStrings("/note", read("/tmp/note", &buf).?);
    try std.testing.expectEqualStrings("/dir/inner", read("/tmp/dir/inner", &buf).?);
    try std.testing.expectEqualStrings("/file", read("/srv/data/deep/file", &buf).?);
    // What the mount covers is gone; what only looks like its path is not it.
    try std.testing.expectEqual(null, read("/tmp/shadowed", &buf));
    try std.testing.expectEqual(null, read("/tmpfile", &buf));
    try std.testing.expectEqual(null, read("/note", &buf));
    try std.testing.expectEqual(null, read("tmp/note", &buf)); // not absolute

    // Directories: mount points, what leads to one, and each filesystem's own.
    for ([_][]const u8{ "/", "/etc", "/tmp", "/tmp/dir", "/srv", "/srv/data", "/srv/data/deep", "/mnt/usb" }) |d| try std.testing.expect(vfs.isDirectory(d));
    for ([_][]const u8{ "/etc/motd", "/tmp/note", "/nothing", "/srv/other", "/tmp/shadowed", "/sr", "" }) |d| try std.testing.expect(!vfs.isDirectory(d));

    // Listings: a filesystem's entries, then the mount points it does not
    // have itself ("/tmp" is in the root's own list, "/srv" is not).
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("etc/ bin/ tmp/ mnt/ srv/", list("/", &out));
    try std.testing.expectEqualStrings("note dir/", list("/tmp", &out));
    try std.testing.expectEqualStrings("inner", list("/tmp/dir", &out));
    try std.testing.expectEqualStrings("file", list("/srv/data/deep", &out));
    // A directory that is only the way to a mount point holds the next
    // step of that way, once however many mounts lie beyond it.
    try std.testing.expectEqualStrings("data/", list("/srv", &out));
    try std.testing.expectEqualStrings("deep/", list("/srv/data", &out));
    var beside: ListFs = .{ .files = &.{"/other"} };
    try vfs.mount("/srv/data/beside", beside.fs());
    try vfs.mount("/srv/more", beside.fs());
    try std.testing.expectEqualStrings("data/ more/", list("/srv", &out));
    try std.testing.expectEqualStrings("deep/ beside/", list("/srv/data", &out));
    try std.testing.expectEqualStrings("", list("/etc/motd", &out));
    try std.testing.expectEqualStrings("", list("/nothing", &out));

    // The table is small and says so when it is full.
    var extra: ListFs = .{ .files = &.{} };
    var failed = false;
    for (0..vfs.MAX_MOUNTS) |_| vfs.mount("/x", extra.fs()) catch {
        failed = true;
    };
    try std.testing.expect(failed);
}
