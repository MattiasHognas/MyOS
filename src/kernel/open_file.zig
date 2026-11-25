//! Open files: what a file descriptor refers to.
//!
//! A descriptor is an index into its process's table of open files
//! (`Process.files`). Several descriptors can refer to one open file
//! (`dup`); it goes when the last of them is closed and no system call is
//! using it any more.

const heap = @import("heap.zig");
const pipe = @import("pipe.zig");
const vfs = @import("vfs.zig");

/// What a file descriptor points at: the node plus the current read position.
pub const OpenFile = struct {
    /// What the descriptor is for.
    kind: Kind = .file,
    /// The file, for `kind == .file`.
    node: vfs.Node = undefined,
    offset: u64 = 0,
    /// For a file whose contents were made when it was opened (the text
    /// files of `/proc`): the memory `node` reads from, freed with the
    /// open file. Such a file cannot be mapped, since a mapping would
    /// outlive it.
    generated: ?[]u8 = null,
    /// The pipe, for the two pipe kinds.
    pipe: *pipe.Pipe = undefined,
    /// `O_NONBLOCK`: reads and writes that would wait fail with `EAGAIN`.
    /// Under the process's `files_lock`, like `refs`.
    nonblock: bool = false,
    /// The descriptor's reference, and one for every system call that is
    /// using the file right now: another thread may close the descriptor
    /// meanwhile. Under the process's `files_lock`.
    refs: u32 = 1,
};

/// What an open descriptor refers to.
pub const Kind = enum {
    /// A file of the filesystem: read with an offset.
    file,
    /// The console: what a process starts with as descriptors 0, 1 and 2.
    /// Writing prints; there is nothing to read from it yet (the keyboard
    /// becomes its input with the terminal, milestone 6).
    console,
    /// The reading and the writing end of a pipe (`pipe.zig`).
    pipe_read,
    pipe_write,
    /// `/dev/null`: reads find the end, writes are thrown away.
    null_device,
    /// `/dev/urandom` and `/dev/random`: reads give random bytes, writes
    /// are thrown away.
    random_device,
};

/// A node for a file that is `text` in memory.
pub fn memoryNode(text: []const u8) vfs.Node {
    return .{ .size = text.len, .ctx = @intFromPtr(text.ptr), .ops = &memory_ops };
}

const memory_ops = vfs.Ops{ .read = readMemory };

fn readMemory(node: *const vfs.Node, offset: u64, buf: []u8) usize {
    if (offset >= node.size) return 0;
    const data: [*]const u8 = @ptrFromInt(node.ctx);
    const n = @min(buf.len, node.size - offset);
    @memcpy(buf[0..n], data[offset..][0..n]);
    return n;
}

/// Free an open file whose last reference is gone, and tell what it was
/// open on.
pub fn destroy(of: *OpenFile) void {
    switch (of.kind) {
        .pipe_read => pipe.closeEnd(of.pipe, .read),
        .pipe_write => pipe.closeEnd(of.pipe, .write),
        .file, .console, .null_device, .random_device => {},
    }
    if (of.generated) |text| heap.allocator.free(text);
    heap.allocator.destroy(of);
}
