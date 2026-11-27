//! How `poll` and `epoll_wait` learn that something they watch may have
//! become ready, instead of looking again every timer tick.
//!
//! Every object a program can wait on through a descriptor (a pipe, the
//! terminal, an eventfd) calls `changed` when it becomes readable or
//! writable or hangs up. That moves one sequence number on and wakes every
//! thread waiting in `waitForChange`, which then looks at what it watches
//! again. One sequence for everything: a poller is woken for changes it
//! does not watch too, and finds nothing new. That costs a look; it never
//! misses one. Per-object wake lists are the step after this one, if
//! measurements ask for it.
//!
//! `changed` takes no lock unless somebody waits: a pipe written on one
//! CPU while nothing polls touches the counter only. The order makes that
//! safe: a waiter counts itself in before it looks at the sequence for the
//! last time, and `changed` moves the sequence before it looks at the
//! count, both sequentially consistent, so one of the two sees the other.
//!
//! The lock has rank `readiness`, just inside the condition locks, so an
//! object may call `changed` holding its own.

const std = @import("std");

const SpinLock = @import("sync/spinlock.zig").SpinLock;
const WaitQueue = @import("sync/wait_queue.zig").WaitQueue;
const thread = @import("thread.zig");

var lock: SpinLock = .{ .rank = .readiness };
var queue: WaitQueue = .{};
var sequence: std.atomic.Value(u64) = .init(0);
var waiting: std.atomic.Value(u32) = .init(0);

/// Something a descriptor refers to may be ready now: wake the pollers.
pub fn changed() void {
    _ = sequence.fetchAdd(1, .seq_cst);
    if (waiting.load(.seq_cst) == 0) return;
    const held = lock.acquire();
    defer lock.release(held);
    _ = queue.wakeAll();
}

/// The sequence as it is now; give it to `waitForChange` after looking.
pub fn now() u64 {
    return sequence.load(.seq_cst);
}

pub const Outcome = enum { changed, timed_out, interrupted };

/// Wait until `changed` has been called since `since` was read, for at
/// most `ticks` timer ticks (null: for ever). A signal or the end of the
/// process ends the wait (`interrupted`).
pub fn waitForChange(since: u64, ticks: ?u64) Outcome {
    const held = lock.acquire();
    defer lock.release(held);
    _ = waiting.fetchAdd(1, .seq_cst);
    defer _ = waiting.fetchSub(1, .seq_cst);
    while (sequence.load(.seq_cst) == since) {
        if (thread.interrupted()) return .interrupted;
        if (ticks) |t| {
            if (t == 0) return .timed_out;
            switch (queue.waitTimeoutKillable(&lock, t)) {
                .woken => {},
                .timed_out => return if (sequence.load(.seq_cst) != since) .changed else .timed_out,
                .interrupted => return .interrupted,
            }
        } else if (!queue.waitKillable(&lock)) return .interrupted;
    }
    return .changed;
}
