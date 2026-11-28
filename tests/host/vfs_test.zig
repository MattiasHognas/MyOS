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

/// `ListFs` with symbolic links: `links` pairs a path with its target.
const LinkFs = struct {
    list: ListFs,
    links: []const [2][]const u8,

    fn readlink(ctx: *anyopaque, path: []const u8, buf: []u8) ?usize {
        const self: *LinkFs = @ptrCast(@alignCast(ctx));
        for (self.links) |l| {
            if (!std.mem.eql(u8, l[0], path)) continue;
            const n = @min(l[1].len, buf.len);
            @memcpy(buf[0..n], l[1][0..n]);
            return l[1].len;
        }
        return null;
    }

    fn lookup(ctx: *anyopaque, path: []const u8) ?vfs.Node {
        const self: *LinkFs = @ptrCast(@alignCast(ctx));
        return ListFs.lookup(&self.list, path);
    }

    fn isDir(ctx: *anyopaque, path: []const u8) bool {
        const self: *LinkFs = @ptrCast(@alignCast(ctx));
        return ListFs.isDir(&self.list, path);
    }

    fn fs(self: *LinkFs) vfs.Fs {
        return .{ .ctx = self, .lookup = lookup, .is_dir = isDir, .readlink = readlink };
    }
};

fn follow(path: []const u8, follow_last: bool) ![]const u8 {
    const S = struct {
        var out: [256]u8 = undefined;
        var scratch: [256]u8 = undefined;
    };
    return vfs.followLinks(&S.out, &S.scratch, path, follow_last);
}

test "VFS: symbolic links are followed in every part of a path" {
    vfs.unmountAll();
    defer vfs.unmountAll();
    // The layout of a merged /usr, with a chain for the loader as Debian
    // has it, a link to a link, one pointing upwards, one absolute.
    var root: LinkFs = .{
        .list = .{ .files = &.{ "/usr/bin/sh", "/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2", "/etc/motd", "/tmp/note" } },
        .links = &.{
            .{ "/bin", "usr/bin" },
            .{ "/lib", "usr/lib" },
            .{ "/lib64", "usr/lib64" },
            .{ "/usr/lib64", "lib" },
            .{ "/usr/lib/ld.so", "x86_64-linux-gnu/ld-linux-x86-64.so.2" },
            .{ "/usr/lib/x86_64-linux-gnu/loader", "../ld.so" },
            .{ "/etc/welcome", "/etc/motd" },
            .{ "/etc/self", "self" },
            .{ "/etc/a", "b" },
            .{ "/etc/b", "a" },
            .{ "/etc/nowhere", "does/not/exist" },
            .{ "/etc/empty", "" },
        },
    };
    vfs.mountRoot(root.fs());

    try std.testing.expectEqualStrings("/usr/bin/sh", try follow("/bin/sh", true));
    try std.testing.expectEqualStrings("/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2", try follow("/lib64/x86_64-linux-gnu/ld-linux-x86-64.so.2", true)); // two links
    try std.testing.expectEqualStrings("/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2", try follow("/lib/x86_64-linux-gnu/loader", true)); // three, one upwards
    try std.testing.expectEqualStrings("/etc/motd", try follow("/etc/welcome", true));
    try std.testing.expectEqualStrings("/usr/bin", try follow("/bin", true));
    // The last part is left alone when asked: what lstat and readlink see.
    try std.testing.expectEqualStrings("/bin", try follow("/bin", false));
    try std.testing.expectEqualStrings("/usr/lib/ld.so", try follow("/lib/ld.so", false));
    // Paths without links, and links to what does not exist (followed: it
    // is for the caller to find nothing there).
    try std.testing.expectEqualStrings("/etc/motd", try follow("/etc/motd", true));
    try std.testing.expectEqualStrings("/", try follow("/", true));
    try std.testing.expectEqualStrings("/etc/does/not/exist", try follow("/etc/nowhere", true));
    try std.testing.expectEqualStrings("/etc", try follow("/etc/empty", true));
    // Loops end.
    try std.testing.expectError(error.Loop, follow("/etc/self", true));
    try std.testing.expectError(error.Loop, follow("/etc/a", true));
    try std.testing.expectError(error.Loop, follow("/etc/a/x", false)); // a loop in the middle, too
    try std.testing.expectEqualStrings("/etc/a", try follow("/etc/a", false));
    // What does not fit.
    var small_out: [8]u8 = undefined;
    var small_scratch: [8]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, vfs.followLinks(&small_out, &small_scratch, "/bin/sh", true));
    var target: [16]u8 = undefined;
    const len = vfs.readLink("/bin", &target);
    try std.testing.expectEqual(@as(?usize, 7), len);
    try std.testing.expectEqualStrings("usr/bin", target[0..7]);
    try std.testing.expectEqual(@as(?usize, 7), vfs.readLink("/bin", target[0..2])); // the whole length, what fits copied
    try std.testing.expectEqual(@as(?usize, null), vfs.readLink("/etc/motd", &target));
    try std.testing.expect(vfs.isLink("/bin") and !vfs.isLink("/etc/motd"));
}

test "VFS: a link may lead into another filesystem" {
    vfs.unmountAll();
    defer vfs.unmountAll();
    var root: LinkFs = .{ .list = .{ .files = &.{"/etc/motd"} }, .links = &.{ .{ "/var/tmp", "/tmp" }, .{ "/scratch", "tmp/inner" } } };
    var tmp: LinkFs = .{ .list = .{ .files = &.{"/inner/file"} }, .links = &.{.{ "/up", "../etc" }} };
    vfs.mountRoot(root.fs());
    try vfs.mount("/tmp", tmp.fs());
    try std.testing.expectEqualStrings("/tmp/inner/file", try follow("/var/tmp/inner/file", true));
    try std.testing.expectEqualStrings("/tmp/inner/file", try follow("/scratch/file", true));
    try std.testing.expectEqualStrings("/etc/motd", try follow("/tmp/up/motd", true)); // and out of it again
    try std.testing.expect(vfs.lookup("/tmp/inner/file") != null);
}
