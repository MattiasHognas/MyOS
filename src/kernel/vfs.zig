// The root filesystem, if any, is mounted at "/". The kernel calls `mountRoot` to set it up.
var root_fs: ?Fs = null;

// A file as the rest of the kernel sees it. `ctx` is filesystem-specific.
pub const Node = struct {
    size: u64,
    ctx: usize,
    ops: *const Ops,
};

// Operations on a file node. Only `read` is needed for the tests.
pub const Ops = struct {
    read: *const fn (node: *const Node, offset: u64, buf: []u8) usize,
};

// A mounted filesystem: turns paths into nodes.
pub const Fs = struct {
    ctx: *anyopaque,
    lookup: *const fn (ctx: *anyopaque, path: []const u8) ?Node,
};

// What a file descriptor points at: the node plus a read position.
pub const OpenFile = struct {
    node: Node,
    offset: u64 = 0,
};

// Mount a filesystem at the root path "/". The kernel calls this once during boot.
pub fn mountRoot(fs: Fs) void {
    root_fs = fs;
}

// Look up a file by path. Returns null if the file does not exist or if no root filesystem is mounted.
pub fn lookup(path: []const u8) ?Node {
    const fs = root_fs orelse return null;
    return fs.lookup(fs.ctx, path);
}

// Read from a file node. Returns the number of bytes read, or 0 if `offset` is at or beyond the end of the file.
pub fn read(node: *const Node, offset: u64, buf: []u8) usize {
    return node.ops.read(node, offset, buf);
}
