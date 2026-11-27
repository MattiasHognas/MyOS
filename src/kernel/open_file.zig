//! Open files: what a file descriptor refers to.
//!
//! A descriptor is an index into its process's table of open files
//! (`Process.files`). Several descriptors can refer to one open file
//! (`dup`); it goes when the last of them is closed and no system call is
//! using it any more.
//!
//! ## What is whose
//!
//! - **The open file** holds the offset, what it was opened for, the
//!   `O_APPEND` and `O_NONBLOCK` flags, and what it is open on (a file, a
//!   pipe end, the terminal). Every descriptor on it shares them: `dup`,
//!   `fork` and `execve` make descriptors on the same open file, never a
//!   new one, so a parent and its child read on from the same offset, as
//!   on Linux. Its reference count and these fields are changed
//!   atomically, since the processes that share it have locks of their
//!   own (`retain`, `unref`, `offset`).
//! - **The descriptor** holds only `FD_CLOEXEC` (`Process.fd_cloexec`),
//!   set by `O_CLOEXEC` and the like, cleared by `dup` and `dup2`.
//! - **Inheritance**: a child made by `fork` gets a copy of the table,
//!   each descriptor on the same open file with its flag; `execve` closes
//!   the descriptors marked close-on-exec and keeps the others; threads
//!   share one table. A process the kernel starts gets 0, 1 and 2 on the
//!   terminal and nothing else.

const std = @import("std");
const heap = @import("heap.zig");
const epoll = @import("epoll.zig");
const pipe = @import("pipe.zig");
const vfs = @import("vfs.zig");

/// What a file descriptor points at: the node plus the current read position.
pub const OpenFile = struct {
    /// What the descriptor is for.
    kind: Kind = .file,
    /// The file, for `kind == .file`. The open file holds it
    /// (`vfs.release` when it goes), unless its text is `generated`.
    node: vfs.Node = undefined,
    /// Where the next `read` or `write` goes; read and changed with
    /// `getOffset`, `setOffset` and `advance` (atomically: see above).
    offset: u64 = 0,
    /// What the descriptor was opened for (`O_RDONLY`, `O_WRONLY`,
    /// `O_RDWR`), and `O_APPEND`: every write goes to the end.
    readable: bool = true,
    writable: bool = false,
    append: bool = false,
    /// For a file whose contents were made when it was opened (the text
    /// files of `/proc`): the memory `node` reads from, freed with the
    /// open file. Such a file cannot be mapped, since a mapping would
    /// outlive it.
    generated: ?[]u8 = null,
    /// For a directory: its path, absolute and normalized, in memory of
    /// the open file's own. `offset` is then the place in its listing.
    path: []u8 = &.{},
    /// The counter, for an eventfd; the watch list, for an epoll instance.
    eventfd: *epoll.EventFd = undefined,
    epoll: *epoll.Epoll = undefined,
    /// The pipe, for the two pipe kinds.
    pipe: *pipe.Pipe = undefined,
    /// `O_NONBLOCK`: reads and writes that would wait fail with `EAGAIN`.
    /// Read and written atomically: descriptors of several processes may
    /// share the open file (after `fork`).
    nonblock: bool = false,
    /// A reference for each descriptor, of any process, and one for every
    /// system call that is using the file right now: another thread may
    /// close the descriptor meanwhile. Changed atomically (`retain`,
    /// `unref`), since processes that share the file have locks of their
    /// own.
    refs: u32 = 1,
    /// A number no other open file has had since boot, given out the
    /// first time it is asked for (`id`). 0 until then. Not the address:
    /// a new open file may be put where a closed one was.
    serial: u64 = 0,
};

var next_serial: std.atomic.Value(u64) = .init(1);

/// `of.serial`, given out now if `of` has none yet. What `epoll` keeps to
/// know a watched open file again.
pub fn id(of: *OpenFile) u64 {
    const have = @atomicLoad(u64, &of.serial, .acquire);
    if (have != 0) return have;
    const fresh = next_serial.fetchAdd(1, .monotonic);
    return @cmpxchgStrong(u64, &of.serial, 0, fresh, .acq_rel, .acquire) orelse fresh;
}

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
    /// A directory: listed with `getdents64`, and what paths relative to
    /// its descriptor start from.
    directory,
    /// `/dev/null`: reads find the end, writes are thrown away.
    null_device,
    /// `/dev/urandom` and `/dev/random`: reads give random bytes, writes
    /// are thrown away.
    random_device,
    /// A counter to wait on (`eventfd`), and a set of descriptors to wait
    /// on together (`epoll_create1`): `epoll.zig`.
    eventfd,
    epoll,
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
        .file => if (of.generated == null) vfs.release(&of.node),
        .eventfd => epoll.destroyEventFd(of.eventfd),
        .epoll => epoll.destroyEpoll(of.epoll),
        .console, .null_device, .random_device, .directory => {},
    }
    freeContents(of);
    heap.allocator.destroy(of);
}

/// Free the memory an open file owns besides itself.
pub fn freeContents(of: *OpenFile) void {
    if (of.generated) |text| heap.allocator.free(text);
    if (of.path.len != 0) heap.allocator.free(of.path);
    of.generated = null;
    of.path = &.{};
}

/// Take another reference to `of`; the caller holds one already.
pub fn retain(of: *OpenFile) void {
    _ = @atomicRmw(u32, &of.refs, .Add, 1, .monotonic);
}

/// Give up a reference to `of`; frees it with the last one.
pub fn unref(of: *OpenFile) void {
    if (@atomicRmw(u32, &of.refs, .Sub, 1, .acq_rel) == 1) destroy(of);
}

pub fn isNonblocking(of: *const OpenFile) bool {
    return @atomicLoad(bool, &of.nonblock, .monotonic);
}

pub fn setNonblocking(of: *OpenFile, on: bool) void {
    @atomicStore(bool, &of.nonblock, on, .monotonic);
}

pub fn getOffset(of: *const OpenFile) u64 {
    return @atomicLoad(u64, &of.offset, .monotonic);
}

pub fn setOffset(of: *OpenFile, to: u64) void {
    @atomicStore(u64, &of.offset, to, .monotonic);
}

/// Move the offset on by `n`; returns where it was.
pub fn advance(of: *OpenFile, n: u64) u64 {
    return @atomicRmw(u64, &of.offset, .Add, n, .monotonic);
}
