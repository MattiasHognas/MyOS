//! Pipes: a buffer of bytes with a writing end and a reading end.
//!
//! What is written to one end is read from the other, in order. A reader
//! sleeps while the pipe is empty and a writer while it is full, unless
//! its descriptor is non-blocking. When the last descriptor for the
//! writing end is closed a reader gets what is left and then end of file;
//! when the last one for the reading end is closed a writer gets `EPIPE`.
//!
//! The buffer is one page: Linux gives a pipe sixteen. A write of up to a
//! page is atomic (it is not mixed with another writer's bytes), as POSIX
//! asks for `PIPE_BUF` bytes.
//!
//! One spinlock per pipe (rank `condition`) protects the buffer, the two
//! counts and the two wait queues. Bytes never go between the buffer and
//! a program with the lock held: the callers copy through a buffer of
//! their own, because touching a program's memory can fault and sleep.

const std = @import("std");
const heap = @import("heap.zig");
const SpinLock = @import("sync/spinlock.zig").SpinLock;
const WaitQueue = @import("sync/wait_queue.zig").WaitQueue;
const readiness = @import("readiness.zig");

/// Bytes a pipe holds, and the most a write puts in as one piece.
pub const SIZE = 4096;

pub const End = enum { read, write };

pub const Pipe = struct {
    lock: SpinLock = .{ .rank = .condition },
    buf: [SIZE]u8 = undefined,
    /// Index of the oldest byte, and how many there are.
    head: usize = 0,
    len: usize = 0,
    /// Open files for each end. The pipe goes when both are zero.
    readers: u32 = 1,
    writers: u32 = 1,
    /// Readers waiting for bytes or for the last writer to go.
    readable: WaitQueue = .{},
    /// Writers waiting for room or for the last reader to go.
    writable: WaitQueue = .{},
    /// Moves on whenever what `state` says may have changed: for
    /// edge-triggered `epoll`.
    version: u64 = 0,
};

/// The pipe's state may have changed: tell its pollers. With the lock.
fn moved(p: *Pipe) void {
    p.version +%= 1;
    readiness.changed();
}

/// `Pipe.version`, for `epoll`.
pub fn version(p: *Pipe) u64 {
    const held = p.lock.acquire();
    defer p.lock.release(held);
    return p.version;
}

pub const ReadResult = union(enum) {
    /// Bytes read; 0 is end of file (no writer left and nothing buffered).
    bytes: usize,
    /// Empty, a writer exists, and the caller would not wait.
    again,
    /// The calling thread's process is ending.
    killed,
};

pub const WriteResult = union(enum) {
    bytes: usize,
    /// Full, and the caller would not wait.
    again,
    /// No reader is left.
    broken,
    killed,
};

/// A new pipe with one open file for each end.
pub fn create() error{OutOfMemory}!*Pipe {
    const p = try heap.allocator.create(Pipe);
    p.* = .{};
    return p;
}

/// An open file for `end` was closed for the last time.
pub fn closeEnd(p: *Pipe, end: End) void {
    const gone = blk: {
        const held = p.lock.acquire();
        defer p.lock.release(held);
        switch (end) {
            .read => {
                p.readers -= 1;
                if (p.readers == 0) _ = p.writable.wakeAll();
            },
            .write => {
                p.writers -= 1;
                if (p.writers == 0) _ = p.readable.wakeAll();
            },
        }
        moved(p);
        break :blk p.readers == 0 and p.writers == 0;
    };
    // Nobody can reach it any more: both ends' last references are gone.
    if (gone) heap.allocator.destroy(p);
}

/// Take up to `dst.len` bytes out. Waits while the pipe is empty and has
/// a writer, unless `nonblock`.
pub fn read(p: *Pipe, dst: []u8, nonblock: bool) ReadResult {
    if (dst.len == 0) return .{ .bytes = 0 };
    const held = p.lock.acquire();
    defer p.lock.release(held);
    while (p.len == 0) {
        if (p.writers == 0) return .{ .bytes = 0 };
        if (nonblock) return .again;
        if (!p.readable.waitKillable(&p.lock)) return .killed;
    }
    const n = @min(dst.len, p.len);
    const first = @min(n, SIZE - p.head);
    @memcpy(dst[0..first], p.buf[p.head..][0..first]);
    @memcpy(dst[first..n], p.buf[0 .. n - first]);
    p.head = (p.head + n) % SIZE;
    p.len -= n;
    _ = p.writable.wakeAll();
    moved(p);
    return .{ .bytes = n };
}

/// Put `src` in, all of it if it is at most `SIZE` bytes (waiting for the
/// room), otherwise as much as fits (waiting for some room). `nonblock`
/// never waits.
pub fn write(p: *Pipe, src: []const u8, nonblock: bool) WriteResult {
    if (src.len == 0) return .{ .bytes = 0 };
    const need = @min(src.len, SIZE);
    const held = p.lock.acquire();
    defer p.lock.release(held);
    while (true) {
        if (p.readers == 0) return .broken;
        if (SIZE - p.len >= need) break;
        if (nonblock) return .again;
        if (!p.writable.waitKillable(&p.lock)) return .killed;
    }
    const tail = (p.head + p.len) % SIZE;
    const first = @min(need, SIZE - tail);
    @memcpy(p.buf[tail..][0..first], src[0..first]);
    @memcpy(p.buf[0 .. need - first], src[first..need]);
    p.len += need;
    _ = p.readable.wakeAll();
    moved(p);
    return .{ .bytes = need };
}

pub const State = struct { readable: bool, writable: bool, hung_up: bool, broken: bool };

/// What `poll` reports: bytes to read, room to write, no writer, no reader.
pub fn state(p: *Pipe) State {
    const held = p.lock.acquire();
    defer p.lock.release(held);
    return .{
        .readable = p.len != 0,
        .writable = p.len < SIZE,
        .hung_up = p.writers == 0,
        .broken = p.readers == 0,
    };
}

/// Threads asleep in `read` or `write`, for tests.
pub fn waiting(p: *Pipe) usize {
    const held = p.lock.acquire();
    defer p.lock.release(held);
    return p.readable.waiting() + p.writable.waiting();
}
