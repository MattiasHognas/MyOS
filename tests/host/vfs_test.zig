const std = @import("std");
const vfs = @import("vfs");

const FakeFs = struct {
    data: []const u8,
    lookups: usize = 0,
    reads: usize = 0,
    last_offset: u64 = 0,

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
