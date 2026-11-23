//! A queue of timers ordered by deadline.
//!
//! Only the ordering logic: no clock, no locking, no kernel dependencies.
//! `timer.zig` drives it from the timer interrupt. Tested on the host.
//!
//! A `Timer` is owned by whoever arms it (it usually lives in another
//! structure or on a waiting thread's stack) and must stay valid until it
//! has fired or been cancelled.

/// One pending timeout.
pub const Timer = struct {
    /// Called when the deadline is reached, with the timer already out of
    /// the queue (so it may be armed again from inside).
    callback: *const fn (*Timer) void,
    /// For the owner's use.
    context: usize = 0,
    /// When it fires. Set by `Queue.add`.
    deadline: u64 = 0,
    /// True while it is in a queue.
    armed: bool = false,
    next: ?*Timer = null,
};

pub const Queue = struct {
    /// Earliest deadline first.
    head: ?*Timer = null,

    /// Put `timer` in the queue to fire at `deadline`. Timers with the same
    /// deadline fire in the order they were added. The timer must not be
    /// armed already.
    pub fn add(self: *Queue, timer: *Timer, deadline: u64) void {
        timer.deadline = deadline;
        timer.armed = true;
        var link = &self.head;
        while (link.*) |t| : (link = &t.next) {
            if (t.deadline > deadline) break;
        }
        timer.next = link.*;
        link.* = timer;
    }

    /// Take `timer` out of the queue. Returns true if it was armed, false
    /// if it had already fired or been cancelled (nothing happens then).
    pub fn cancel(self: *Queue, timer: *Timer) bool {
        if (!timer.armed) return false;
        var link = &self.head;
        while (link.*) |t| : (link = &t.next) {
            if (t != timer) continue;
            link.* = timer.next;
            timer.next = null;
            timer.armed = false;
            return true;
        }
        return false; // armed in some other queue
    }

    /// Remove and return the earliest timer if its deadline is at or
    /// before `now`; null if nothing is due.
    pub fn popExpired(self: *Queue, now: u64) ?*Timer {
        const t = self.head orelse return null;
        if (t.deadline > now) return null;
        self.head = t.next;
        t.next = null;
        t.armed = false;
        return t;
    }

    /// The earliest deadline in the queue, or null if it is empty.
    pub fn nextDeadline(self: *const Queue) ?u64 {
        return if (self.head) |t| t.deadline else null;
    }

    /// Number of timers waiting.
    pub fn count(self: *const Queue) usize {
        var n: usize = 0;
        var t = self.head;
        while (t) |timer| : (t = timer.next) n += 1;
        return n;
    }
};
