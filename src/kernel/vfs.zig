/// A file as the rest of the kernel sees it. `ctx` is filesystem-specific.
pub const Node = struct {
    size: u64,
    ctx: usize,
    ops: *const Ops,
};

pub const Ops = struct {
    read: *const fn (node: *const Node, offset: u64, buf: []u8) usize,
};

/// A mounted filesystem: turns paths into nodes.
pub const Fs = struct {
    ctx: *anyopaque,
    lookup: *const fn (ctx: *anyopaque, path: []const u8) ?Node,
};

/// What a file descriptor points at: the node plus a read position.
pub const OpenFile = struct {
    node: Node,
    offset: u64 = 0,
};

var root_fs: ?Fs = null;

pub fn mountRoot(fs: Fs) void {
    root_fs = fs;
}

pub fn lookup(path: []const u8) ?Node {
    const fs = root_fs orelse return null;
    return fs.lookup(fs.ctx, path);
}

pub fn read(node: *const Node, offset: u64, buf: []u8) usize {
    return node.ops.read(node, offset, buf);
}
