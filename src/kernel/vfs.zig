//! Virtual filesystem layer.
//!
//! A single filesystem is mounted at "/". Filesystems turn paths into `Node`s,
//! and each node carries the operations used to read it. This module has no
//! kernel dependencies, so it is also tested natively on the host.

/// The filesystem mounted at "/" by `mountRoot`, if any.
var root_fs: ?Fs = null;

/// A file as the rest of the kernel sees it.
pub const Node = struct {
    /// File size in bytes.
    size: u64,
    /// Filesystem-specific data (e.g. a pointer to the file contents).
    ctx: usize,
    /// Operations implemented by the node's filesystem.
    ops: *const Ops,
};

/// Operations a filesystem implements for its nodes.
pub const Ops = struct {
    /// Copy up to `buf.len` bytes starting at `offset` into `buf`. Returns the
    /// number of bytes copied, or 0 at or past the end of the file.
    read: *const fn (node: *const Node, offset: u64, buf: []u8) usize,
};

/// A mounted filesystem: turns paths into nodes.
pub const Fs = struct {
    /// Filesystem-specific state passed back to `lookup`.
    ctx: *anyopaque,
    /// Return the node for `path`, or null if it doesn't exist.
    lookup: *const fn (ctx: *anyopaque, path: []const u8) ?Node,
};

/// What a file descriptor points at: the node plus the current read position.
pub const OpenFile = struct {
    node: Node,
    offset: u64 = 0,
    /// The descriptor's reference, and one for every system call that is
    /// using the file right now: another thread may close the descriptor
    /// meanwhile. Under the process's `files_lock`.
    refs: u32 = 1,
};

/// Mount `fs` as the root filesystem, replacing any previous one. The kernel calls this once during boot.
pub fn mountRoot(fs: Fs) void {
    root_fs = fs;
}

/// Look up the file at `path` in the root filesystem. Returns null if it does
/// not exist or no root filesystem is mounted.
pub fn lookup(path: []const u8) ?Node {
    const fs = root_fs orelse return null;
    return fs.lookup(fs.ctx, path);
}

/// Read up to `buf.len` bytes from `node` starting at `offset`. Returns the
/// number of bytes read, or 0 if `offset` is at or beyond the end of the file.
pub fn read(node: *const Node, offset: u64, buf: []u8) usize {
    return node.ops.read(node, offset, buf);
}
