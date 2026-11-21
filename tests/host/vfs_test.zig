const std = @import("std");
const vfs = @import("vfs");

const FakeFs = struct {
    data: []const u8,

    fn lookup(ctx: *anyopaque, path: []const u8) ?vfs.Node {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, path, "/hello")) return null;
        return .{
            .size = self.data.len,
            .ctx = @intFromPtr(self),
            .ops = &ops,
        };
    }

    fn read(node: *const vfs.Node, offset: u64, buf: []u8) usize {
        const self: *FakeFs = @ptrFromInt(node.ctx);
        if (offset >= self.data.len) return 0;
        const start: usize = @intCast(offset);
        const count = @min(buf.len, self.data.len - start);
        @memcpy(buf[0..count], self.data[start..][0..count]);
        return count;
    }

    const ops = vfs.Ops{ .read = read };
};

test "VFS dispatches lookup and reads to injected fake filesystem" {
    var fake = FakeFs{ .data = "hello from fake" };
    vfs.mountRoot(.{ .ctx = &fake, .lookup = FakeFs.lookup });

    try std.testing.expect(vfs.lookup("/missing") == null);
    const node = vfs.lookup("/hello") orelse return error.MissingFile;
    try std.testing.expectEqual(@as(u64, fake.data.len), node.size);

    var buf: [32]u8 = undefined;
    const n = vfs.read(&node, 0, &buf);
    try std.testing.expectEqualStrings(fake.data, buf[0..n]);
    try std.testing.expectEqual(@as(usize, 0), vfs.read(&node, node.size, &buf));
}
