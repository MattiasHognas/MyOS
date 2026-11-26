//! `eventfd` and `epoll`: a counter to wait on, and a set of descriptors
//! to wait on together.
//!
//! An eventfd holds a 64-bit counter. A write adds to it; a read takes it
//! (or, in semaphore mode, takes one) and waits while it is zero. Runtimes
//! use one to wake a thread that waits in `epoll_wait`: Go's network
//! poller, which its timers and `time.Sleep` sit on, is the first user.
//!
//! An epoll instance is a list of descriptors with the events each is
//! watched for, and `epoll_wait` reports those that are ready. Readiness
//! is what `poll` sees (`syscall.pollState`), looked at again every timer
//! tick while nothing is ready: descriptors have no way yet to wake a
//! waiter themselves. Two simplifications follow, both documented in
//! `docs/syscalls.md`: edge-triggered watching (`EPOLLET`) is reported as
//! level-triggered (a descriptor that stays ready is reported again), and
//! a descriptor is watched by its number in the process, not by the open
//! file behind it (closing it ends the watch; another file opened under
//! the same number would be watched in its place).
//!
//! Each object has a spinlock of rank `condition`, held for a few
//! instructions; bytes are copied to and from programs without it.

const std = @import("std");

const heap = @import("heap.zig");
const SpinLock = @import("sync/spinlock.zig").SpinLock;
const WaitQueue = @import("sync/wait_queue.zig").WaitQueue;

// ---------------------------------------------------------------------------
// eventfd

pub const EventFd = struct {
    lock: SpinLock = .{ .rank = .condition },
    value: u64 = 0,
    /// `EFD_SEMAPHORE`: a read takes 1 instead of all.
    semaphore: bool = false,
    readers: WaitQueue = .{},
    writers: WaitQueue = .{},
};

/// The most the counter can hold.
pub const EVENTFD_MAX: u64 = std.math.maxInt(u64) - 1;

pub fn createEventFd(initial: u32, semaphore: bool) error{OutOfMemory}!*EventFd {
    const e = try heap.allocator.create(EventFd);
    e.* = .{ .value = initial, .semaphore = semaphore };
    return e;
}

pub fn destroyEventFd(e: *EventFd) void {
    heap.allocator.destroy(e);
}

pub const Result = union(enum) { value: u64, again, killed };

/// Take what a read of the counter gets: all of it, or 1 in semaphore
/// mode. Waits while it is zero, unless `nonblock`.
pub fn eventRead(e: *EventFd, nonblock: bool) Result {
    const held = e.lock.acquire();
    defer e.lock.release(held);
    while (e.value == 0) {
        if (nonblock) return .again;
        if (!e.readers.waitKillable(&e.lock)) return .killed;
    }
    const taken = if (e.semaphore) 1 else e.value;
    e.value -= taken;
    _ = e.writers.wakeAll();
    return .{ .value = taken };
}

/// Add `n` to the counter. Waits while that would go past `EVENTFD_MAX`,
/// unless `nonblock`.
pub fn eventWrite(e: *EventFd, n: u64, nonblock: bool) Result {
    const held = e.lock.acquire();
    defer e.lock.release(held);
    while (EVENTFD_MAX - e.value < n) {
        if (nonblock) return .again;
        if (!e.writers.waitKillable(&e.lock)) return .killed;
    }
    e.value += n;
    _ = e.readers.wakeAll();
    return .{ .value = n };
}

/// Whether a read would not wait, and whether a write of 1 would not.
pub fn eventState(e: *EventFd) struct { readable: bool, writable: bool } {
    const held = e.lock.acquire();
    defer e.lock.release(held);
    return .{ .readable = e.value != 0, .writable = e.value < EVENTFD_MAX };
}

// ---------------------------------------------------------------------------
// epoll

pub const Interest = struct {
    fd: u32,
    /// The events asked for, and the flags (`EPOLLET`, `EPOLLONESHOT`).
    events: u32,
    /// Given back as it is with each event.
    data: u64,
    /// `EPOLLONESHOT` after its event: no more until `EPOLL_CTL_MOD`.
    disabled: bool = false,
};

pub const Epoll = struct {
    lock: SpinLock = .{ .rank = .condition },
    list: std.ArrayListUnmanaged(Interest) = .empty,
};

pub fn createEpoll() error{OutOfMemory}!*Epoll {
    const ep = try heap.allocator.create(Epoll);
    ep.* = .{};
    return ep;
}

pub fn destroyEpoll(ep: *Epoll) void {
    ep.list.deinit(heap.allocator);
    heap.allocator.destroy(ep);
}

pub const CtlError = error{ Exists, NotFound, OutOfMemory, TooMany };

/// Most descriptors one instance watches.
pub const MAX_WATCHED = 1024;

pub const Op = enum { add, del, mod };

/// `epoll_ctl`'s changes to the list.
pub fn control(ep: *Epoll, op: Op, fd: u32, events: u32, data: u64) CtlError!void {
    // Room first, without the lock: allocation does not belong under it.
    if (op == .add) {
        const held = ep.lock.acquire();
        const need = ep.list.items.len + 1;
        const have = ep.list.capacity;
        ep.lock.release(held);
        if (need > MAX_WATCHED) return error.TooMany;
        if (need > have) {
            var bigger: std.ArrayListUnmanaged(Interest) = .empty;
            bigger.ensureTotalCapacity(heap.allocator, @max(8, have * 2)) catch return error.OutOfMemory;
            const held2 = ep.lock.acquire();
            if (ep.list.capacity < need) {
                bigger.appendSliceAssumeCapacity(ep.list.items);
                std.mem.swap(std.ArrayListUnmanaged(Interest), &bigger, &ep.list);
            }
            ep.lock.release(held2);
            bigger.deinit(heap.allocator);
        }
    }
    const held = ep.lock.acquire();
    defer ep.lock.release(held);
    const at: ?usize = for (ep.list.items, 0..) |w, i| {
        if (w.fd == fd) break i;
    } else null;
    switch (op) {
        .add => {
            if (at != null) return error.Exists;
            if (ep.list.items.len == ep.list.capacity) return error.OutOfMemory; // taken by another thread meanwhile
            ep.list.appendAssumeCapacity(.{ .fd = fd, .events = events, .data = data });
        },
        .mod => {
            const i = at orelse return error.NotFound;
            ep.list.items[i] = .{ .fd = fd, .events = events, .data = data };
        },
        .del => {
            const i = at orelse return error.NotFound;
            _ = ep.list.swapRemove(i);
        },
    }
}

/// A copy of the list, to look at without the lock (readiness is asked of
/// other objects, under their own locks). In `buf` if it fits; null if
/// there is no memory for a larger one.
pub fn snapshot(ep: *Epoll, buf: []Interest) ?[]Interest {
    while (true) {
        const len = blk: {
            const held = ep.lock.acquire();
            defer ep.lock.release(held);
            if (ep.list.items.len <= buf.len) {
                @memcpy(buf[0..ep.list.items.len], ep.list.items);
                return buf[0..ep.list.items.len];
            }
            break :blk ep.list.items.len;
        };
        _ = len;
        return null;
    }
}

/// After an event for `fd` with `EPOLLONESHOT`: no more for it.
pub fn disable(ep: *Epoll, fd: u32) void {
    const held = ep.lock.acquire();
    defer ep.lock.release(held);
    for (ep.list.items) |*w| {
        if (w.fd == fd) w.disabled = true;
    }
}
