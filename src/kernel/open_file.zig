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
};

/// Free an open file whose last reference is gone, and tell what it was
/// open on.
pub fn destroy(of: *OpenFile) void {
    switch (of.kind) {
        .pipe_read => pipe.closeEnd(of.pipe, .read),
        .pipe_write => pipe.closeEnd(of.pipe, .write),
        .file, .console => {},
    }
    heap.allocator.destroy(of);
}
