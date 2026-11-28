//! Record locks (`fcntl` `F_SETLK`, `F_SETLKW`, `F_GETLK`, and the
//! open-file-description forms `F_OFD_*`): advisory locks on byte ranges
//! of a file, as Linux keeps them.
//!
//! A lock covers `[start, end)` of a file (known by the same key as
//! `flock`'s), for reading (shared) or writing (exclusive), and has an
//! owner: a process for POSIX locks, an open file for OFD locks. Locks of
//! different owners conflict where their ranges overlap and either is a
//! write lock. Setting a lock replaces the owner's own locks over that
//! range (cutting them where it begins and ends), so a lock can be made
//! shorter, longer or of the other type; unlocking cuts the range out.
//!
//! POSIX locks go when their process ends, and also, as POSIX has it,
//! when the process closes any descriptor of the file (`closedBy`). OFD
//! locks go with the last descriptor of their open file (`releaseOwner`).
//!
//! Deadlocks between two waiting owners are not looked for (Linux finds
//! the simple ones, `EDEADLK`). One list under one lock, as for `flock`.

const std = @import("std");

const heap = @import("heap.zig");
const SpinLock = @import("sync/spinlock.zig").SpinLock;
const WaitQueue = @import("sync/wait_queue.zig").WaitQueue;

pub const Key = @import("flock.zig").Key;

/// Who holds a lock: a process (by ID) or an open file (by `open_file.id`).
pub const Owner = union(enum) {
    process: u64,
    open_file: u64,

    fn eql(a: Owner, b: Owner) bool {
        return std.meta.eql(a, b);
    }
};

/// An end past every offset: a lock "to the end of the file", however it
/// grows.
pub const TO_END: u64 = std.math.maxInt(u64);

const Lock = struct {
    next: ?*Lock = null,
    key: Key,
    owner: Owner,
    start: u64,
    end: u64,
    write: bool,
};

var lock: SpinLock = .{};
var locks: ?*Lock = null;
/// Threads waiting for a lock in their way to go.
var released: WaitQueue = .{};

pub const Error = error{
    /// Without waiting, and a lock of another owner is in the way (`EAGAIN`).
    WouldBlock,
    /// A signal came while waiting (`EINTR`).
    Interrupted,
    /// No memory for the locks (`ENOLCK`).
    NoLocks,
};

/// What is in the way of a lock: the first conflicting lock's range, type
/// and owner (`F_GETLK`).
pub const Conflict = struct { start: u64, end: u64, write: bool, owner: Owner };

fn overlaps(l: *const Lock, start: u64, end: u64) bool {
    return l.start < end and start < l.end;
}

fn conflictLocked(key: Key, owner: Owner, start: u64, end: u64, write: bool) ?*Lock {
    var l = locks;
    while (l) |one| : (l = one.next) {
        if (!std.meta.eql(one.key, key) or one.owner.eql(owner)) continue;
        if (overlaps(one, start, end) and (write or one.write)) return one;
    }
    return null;
}

/// The lock in the way of `owner` locking `[start, end)` of `key` (for
/// writing if `write`), or null if there is none.
pub fn test_(key: Key, owner: Owner, start: u64, end: u64, write: bool) ?Conflict {
    const held = lock.acquire();
    defer lock.release(held);
    const c = conflictLocked(key, owner, start, end, write) orelse return null;
    return .{ .start = c.start, .end = c.end, .write = c.write, .owner = c.owner };
}

/// Most locks one change can need: the new one, and the piece of an old
/// one it cuts in two.
const SPARE = 2;

/// Set (`kind` `.read` or `.write`) or remove (`.unlock`) `owner`'s lock on
/// `[start, end)` of `key`, waiting for locks in the way unless `nonblock`.
pub fn set(key: Key, owner: Owner, start: u64, end: u64, kind: enum { read, write, unlock }, nonblock: bool) Error!void {
    // Memory first: allocation does not belong under the lock.
    var spare: [SPARE]?*Lock = .{ null, null };
    defer for (spare) |s| if (s) |l| heap.allocator.destroy(l);
    for (&spare) |*s| s.* = heap.allocator.create(Lock) catch return error.NoLocks;

    const held = lock.acquire();
    defer lock.release(held);
    if (kind != .unlock) {
        while (conflictLocked(key, owner, start, end, kind == .write) != null) {
            if (nonblock) return error.WouldBlock;
            if (!released.waitKillable(&lock)) return error.Interrupted;
        }
    }
    // The owner's own locks over the range: cut out, the parts outside it kept.
    var freed: ?*Lock = null;
    var link = &locks;
    while (link.*) |one| {
        if (!std.meta.eql(one.key, key) or !one.owner.eql(owner) or !overlaps(one, start, end)) {
            link = &one.next;
            continue;
        }
        if (one.start < start and one.end > end) {
            // Inside it: the part after the range becomes a lock of its own.
            const after = takeSpare(&spare);
            after.* = .{ .key = key, .owner = owner, .start = end, .end = one.end, .write = one.write, .next = one.next };
            one.end = start;
            one.next = after;
            link = &after.next;
        } else if (one.start < start) {
            one.end = start;
            link = &one.next;
        } else if (one.end > end) {
            one.start = end;
            link = &one.next;
        } else {
            link.* = one.next; // wholly inside: gone
            one.next = freed;
            freed = one;
        }
    }
    if (kind != .unlock) {
        const new = takeSpare(&spare);
        new.* = .{ .key = key, .owner = owner, .start = start, .end = end, .write = kind == .write, .next = locks };
        locks = new;
    }
    _ = released.wakeAll(); // what was in someone's way may be gone
    // (Freed with the lock held, which the lock order allows: the heap's
    // ranks after it. What is left in `spare` the defer frees.)
    while (freed) |f| {
        freed = f.next;
        heap.allocator.destroy(f);
    }
}

fn takeSpare(spare: *[SPARE]?*Lock) *Lock {
    for (spare) |*s| {
        if (s.*) |l| {
            s.* = null;
            return l;
        }
    }
    unreachable; // a change needs at most `SPARE`
}

/// Give up every lock of `owner` (a process that ends, an open file that
/// goes), or only those on `key` (a process that closes a descriptor of
/// that file, as POSIX has it).
pub fn releaseOwner(owner: Owner, key: ?Key) void {
    var freed: ?*Lock = null;
    {
        const held = lock.acquire();
        defer lock.release(held);
        var link = &locks;
        while (link.*) |one| {
            if (one.owner.eql(owner) and (key == null or std.meta.eql(one.key, key.?))) {
                link.* = one.next;
                one.next = freed;
                freed = one;
            } else link = &one.next;
        }
        if (freed != null) _ = released.wakeAll();
    }
    while (freed) |f| {
        freed = f.next;
        heap.allocator.destroy(f);
    }
}

/// Locks there are, for tests.
pub fn count() usize {
    const held = lock.acquire();
    defer lock.release(held);
    var n: usize = 0;
    var l = locks;
    while (l) |one| : (l = one.next) n += 1;
    return n;
}
