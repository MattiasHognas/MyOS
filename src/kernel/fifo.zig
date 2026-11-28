//! FIFOs (named pipes): a name in a filesystem (`mkfifo`, `mknod` with
//! `S_IFIFO`) that opens to the ends of a pipe (`pipe.zig`).
//!
//! The filesystem keeps only the name and a number (`vfs.makeFifo`); the
//! pipe is here, made when the first end is opened and gone with the
//! last, so the next opener starts with an empty one, as on Linux.
//!
//! Opening waits for the other end, as on Linux: for reading, until a
//! writer has opened it (with `O_NONBLOCK`, not at all); for writing,
//! until a reader has (with `O_NONBLOCK` and no reader, `ENXIO`). An end
//! that came and went while a waiter slept still counts. A signal ends
//! the wait (`EINTR`). Opening for reading and writing at once is not
//! offered (`EINVAL`; Linux allows it).
//!
//! One spinlock (rank `fifo_table`) covers the table and every FIFO's
//! counts, and is what waiters wait under; it is taken before a pipe's.

const std = @import("std");

const heap = @import("heap.zig");
const pipe = @import("pipe.zig");
const SpinLock = @import("sync/spinlock.zig").SpinLock;
const WaitQueue = @import("sync/wait_queue.zig").WaitQueue;

const Fifo = struct {
    id: u64,
    /// The pipe while any end is open.
    pipe: ?*pipe.Pipe = null,
    /// How many readers and writers have opened it since it was made,
    /// for a waiter to see one that came and went.
    reader_opens: u64 = 0,
    writer_opens: u64 = 0,
    /// Openers waiting for the other end.
    waiting: WaitQueue = .{},
    /// Threads in `open` now: the entry stays while there are any.
    opening: u32 = 0,
    next: ?*Fifo = null,
};

var lock: SpinLock = .{ .rank = .fifo_table };
var table: ?*Fifo = null;
var next_id: std.atomic.Value(u64) = .init(1);

/// A number for a new FIFO's name (`vfs.makeFifo`).
pub fn newId() u64 {
    return next_id.fetchAdd(1, .monotonic);
}

fn find(id: u64) ?*Fifo {
    var f = table;
    while (f) |one| : (f = one.next) {
        if (one.id == id) return one;
    }
    return null;
}

fn unlinkLocked(f: *Fifo) void {
    var link = &table;
    while (link.*) |one| : (link = &one.next) {
        if (one == f) {
            link.* = f.next;
            return;
        }
    }
}

pub const OpenError = error{
    /// For writing, without waiting, and nobody reads (`ENXIO`).
    NoReader,
    /// A signal came while waiting (`EINTR`).
    Interrupted,
    OutOfMemory,
};

/// Open an end of the FIFO `id`; returns its pipe, with the end counted
/// (closed with `pipe.closeEnd`, as any pipe's).
pub fn open(id: u64, end: pipe.End, nonblock: bool) OpenError!*pipe.Pipe {
    // A new pipe and entry, in case they are needed, made before the lock.
    var fresh_pipe: ?*pipe.Pipe = pipe.createEmpty() catch return error.OutOfMemory;
    defer if (fresh_pipe) |p| pipe.destroyUnused(p);
    var fresh: ?*Fifo = heap.allocator.create(Fifo) catch return error.OutOfMemory;
    defer if (fresh) |f| heap.allocator.destroy(f);

    const held = lock.acquire();
    defer lock.release(held);
    const f = find(id) orelse blk: {
        const f = fresh.?;
        fresh = null;
        f.* = .{ .id = id, .next = table };
        table = f;
        break :blk f;
    };
    if (f.pipe == null) {
        f.pipe = fresh_pipe;
        fresh_pipe = null;
        pipe.setFifo(f.pipe.?, f.id);
    }
    const p = f.pipe.?;
    // Counted now, so that the other side, already waiting, sees it.
    pipe.openEnd(p, end);
    switch (end) {
        .read => f.reader_opens += 1,
        .write => f.writer_opens += 1,
    }
    _ = f.waiting.wakeAll();
    const ends = pipe.ends(p);
    const other_now = if (end == .read) ends.writers else ends.readers;
    if (other_now != 0) return p;
    if (nonblock) {
        if (end == .read) return p; // a reader may open alone
        closeEndLocked(f, p, .write);
        return error.NoReader;
    }
    const seen = if (end == .read) f.writer_opens else f.reader_opens;
    // Counted as opening while it waits, so that the entry stays even if
    // the pipe goes meanwhile; no longer when it gives up its end, so
    // that the entry goes with the pipe then.
    f.opening += 1;
    while ((if (end == .read) f.writer_opens else f.reader_opens) == seen) {
        if (!f.waiting.waitKillable(&lock)) {
            f.opening -= 1;
            closeEndLocked(f, p, end);
            return error.Interrupted;
        }
    }
    f.opening -= 1;
    return p;
}

/// Close `end` of the FIFO's pipe `p` with the lock held (an opener that
/// gives up); the pipe goes with its last end.
fn closeEndLocked(f: *Fifo, p: *pipe.Pipe, end: pipe.End) void {
    if (pipe.closeEndKeep(p, end)) {
        f.pipe = null;
        pipe.destroyUnused(p);
        if (f.opening == 0) {
            unlinkLocked(f);
            heap.allocator.destroy(f);
        }
    }
}

/// `pipe.closeEnd` for a FIFO's pipe (whose `fifo` it is): the table is
/// told under its lock, so that an opener never finds a pipe that is
/// going.
pub fn closeEnd(p: *pipe.Pipe, id: u64, end: pipe.End) void {
    const held = lock.acquire();
    defer lock.release(held);
    const f = find(id) orelse return; // (cannot happen: the pipe is in the table)
    if (pipe.closeEndKeep(p, end)) {
        f.pipe = null;
        pipe.destroyUnused(p);
        if (f.opening == 0) {
            unlinkLocked(f);
            heap.allocator.destroy(f);
        }
    }
}

/// FIFOs with a pipe now, for tests.
pub fn count() usize {
    const held = lock.acquire();
    defer lock.release(held);
    var n: usize = 0;
    var f = table;
    while (f) |one| : (f = one.next) n += 1;
    return n;
}
