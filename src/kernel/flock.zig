//! `flock`: advisory locks on whole files, as Linux keeps them.
//!
//! A lock is held by an open file (so a descriptor and its duplicates,
//! in this process or another after `fork`, share it) on a file, known
//! by its node. Any number of open files may hold a shared lock on one
//! file, or one open file an exclusive lock. Asking for a lock that
//! conflicts waits until it is free, or fails at once with `LOCK_NB`.
//! Changing a lock from shared to exclusive or back gives up the old one
//! first, as on Linux, so it is not atomic. The lock goes when the open
//! file's last descriptor is closed (`releaseAll`), or with `LOCK_UN`.
//!
//! Advisory: nothing stops a program that does not ask from reading or
//! writing the file. The .NET runtime takes one on every file it opens
//! (shared to read, exclusive to write) to give `FileShare` its meaning.
//!
//! The locks are one list under one lock of rank `condition`: few files
//! are locked at once.

const std = @import("std");

const heap = @import("heap.zig");
const SpinLock = @import("sync/spinlock.zig").SpinLock;
const WaitQueue = @import("sync/wait_queue.zig").WaitQueue;

/// The file a lock is on: its filesystem's operations and its node's
/// data, which together tell one file from every other while it is open.
pub const Key = struct { a: usize, b: usize };

const Lock = struct {
    next: ?*Lock = null,
    key: Key,
    /// The open file that holds it (`open_file.id`).
    owner: u64,
    exclusive: bool,
};

var lock: SpinLock = .{};
var locks: ?*Lock = null;
/// Threads waiting for a lock to be given up.
var released: WaitQueue = .{};

pub const Error = error{
    /// `LOCK_NB`, and another open file holds a lock in the way (`EWOULDBLOCK`).
    WouldBlock,
    /// A signal came while waiting (`EINTR`), or the process is ending.
    Interrupted,
    /// No memory for the lock (`ENOLCK`).
    NoLocks,
};

/// Give `owner` a lock on `key`, shared or `exclusive`, waiting for one
/// in the way to go unless `nonblock`.
pub fn acquire(key: Key, owner: u64, exclusive: bool, nonblock: bool) Error!void {
    // Allocated before the lock is taken: allocation does not belong under it.
    const fresh = heap.allocator.create(Lock) catch return error.NoLocks;
    fresh.* = .{ .key = key, .owner = owner, .exclusive = exclusive };
    var used = false;
    defer if (!used) heap.allocator.destroy(fresh);
    var dropped: ?*Lock = null;
    defer if (dropped) |d| heap.allocator.destroy(d);

    const held = lock.acquire();
    defer lock.release(held);
    // A lock of its own on the file: the same kind is nothing to do; the
    // other kind is given up first.
    if (findOwn(key, owner)) |own| {
        if (own.exclusive == exclusive) return;
        dropped = unlinkLocked(own);
        _ = released.wakeAll();
    }
    while (conflicts(key, owner, exclusive)) {
        if (nonblock) return error.WouldBlock;
        if (!released.waitKillable(&lock)) return error.Interrupted;
    }
    fresh.next = locks;
    locks = fresh;
    used = true;
}

/// Give up `owner`'s lock on `key`, if it has one (`LOCK_UN`).
pub fn release(key: Key, owner: u64) void {
    const gone = blk: {
        const held = lock.acquire();
        defer lock.release(held);
        const own = findOwn(key, owner) orelse return;
        const l = unlinkLocked(own);
        _ = released.wakeAll();
        break :blk l;
    };
    heap.allocator.destroy(gone);
}

/// Give up every lock of `owner`: its open file is closed.
pub fn releaseAll(owner: u64) void {
    var gone: ?*Lock = null;
    {
        const held = lock.acquire();
        defer lock.release(held);
        var link = &locks;
        while (link.*) |l| {
            if (l.owner == owner) {
                link.* = l.next;
                l.next = gone;
                gone = l;
            } else link = &l.next;
        }
        if (gone != null) _ = released.wakeAll();
    }
    while (gone) |l| {
        gone = l.next;
        heap.allocator.destroy(l);
    }
}

/// How many locks there are: for tests, which check that none is left.
pub fn count() usize {
    const held = lock.acquire();
    defer lock.release(held);
    var n: usize = 0;
    var l = locks;
    while (l) |one| : (l = one.next) n += 1;
    return n;
}

fn findOwn(key: Key, owner: u64) ?*Lock {
    var l = locks;
    while (l) |one| : (l = one.next) {
        if (one.owner == owner and std.meta.eql(one.key, key)) return one;
    }
    return null;
}

/// Whether another open file's lock on `key` is in the way of one that
/// is `exclusive` or not.
fn conflicts(key: Key, owner: u64, exclusive: bool) bool {
    var l = locks;
    while (l) |one| : (l = one.next) {
        if (one.owner == owner or !std.meta.eql(one.key, key)) continue;
        if (exclusive or one.exclusive) return true;
    }
    return false;
}

fn unlinkLocked(target: *Lock) *Lock {
    var link = &locks;
    while (link.*) |l| : (link = &l.next) {
        if (l == target) {
            link.* = l.next;
            l.next = null;
            return l;
        }
    }
    unreachable;
}
