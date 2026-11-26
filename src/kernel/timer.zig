//! Kernel time in ticks, and timeouts.
//!
//! The timer interrupt calls `tick` `HZ` times a second. Each tick advances
//! `now` and runs the callbacks of the timers that are due
//! (`sync/timer_queue.zig` keeps them in order). Sleeping, waits with a
//! timeout and (later) driver and network timeouts are built on this.
//!
//! Callbacks run in the timer interrupt, with interrupts off and the timer
//! lock released: they must be short and must not block. Waking a thread is
//! the usual thing to do, and they may arm and cancel timers.
//!
//! With several CPUs a callback can run on one CPU while the thread that
//! armed the timer runs on another. A timer that lives in a waiting
//! thread's stack frame therefore needs `WakeTimer`, which makes the waiter
//! stay until the callback is done with it (`docs/locking.md`).
//!
//! Resolution is one tick (10 ms). A timeout of `n` ticks fires at the
//! n-th tick from now, which is between `n - 1` and `n` tick periods away;
//! `sleepTicks` adds one so that a sleep is never shorter than asked.

const std = @import("std");

const thread = @import("thread.zig");
const timer_queue = @import("sync/timer_queue.zig");
const SpinLock = @import("sync/spinlock.zig").SpinLock;
const assert = @import("debug/assert.zig");
const cpu = @import("../arch/x86_64/cpu.zig");

pub const Timer = timer_queue.Timer;

/// Timer interrupts per second.
pub const HZ = 100;
/// Nanoseconds per tick.
pub const NS_PER_TICK = 1_000_000_000 / HZ;

var lock: SpinLock = .{ .rank = .timer };
var queue: timer_queue.Queue = .{};
var ticks: u64 = 0;

/// Ticks since boot.
pub fn now() u64 {
    const held = lock.acquire();
    defer lock.release(held);
    return ticks;
}

/// Arm `timer` to fire `delay` ticks from now (at least one). It must not
/// be armed, and must stay valid until it fires or is cancelled.
pub fn add(timer: *Timer, delay: u64) void {
    const held = lock.acquire();
    defer lock.release(held);
    assert.check(.timer, !timer.armed, "arming a timer that is already armed", .{});
    queue.add(timer, ticks + @max(delay, 1));
}

/// Disarm `timer`. Returns true if it was still pending: its callback will
/// not run. Returns false if it was never armed, or if it has been taken
/// out of the queue to fire: then its callback has started, and with
/// several CPUs it may still be running. Whoever owns the timer's memory
/// must then wait for the callback before letting the memory go
/// (`WakeTimer.finish`).
pub fn cancel(timer: *Timer) bool {
    const held = lock.acquire();
    defer lock.release(held);
    return queue.cancel(timer);
}

/// Number of timers pending.
pub fn pending() usize {
    const held = lock.acquire();
    defer lock.release(held);
    return queue.count();
}

/// Advance time by one tick and run the timers that are due, earliest
/// first. Called from the timer interrupt, before the scheduler's tick, so
/// a thread a timer wakes can be chosen right away.
pub fn tick() void {
    var held = lock.acquire();
    ticks += 1;
    while (queue.popExpired(ticks)) |timer| {
        // Not under the lock: the callback may arm timers itself.
        lock.release(held);
        timer.callback(timer);
        held = lock.acquire();
    }
    lock.release(held);
}

/// Ticks needed to cover `ms` milliseconds, rounded up.
pub fn msToTicks(ms: u64) u64 {
    return (ms * HZ + 999) / 1000;
}

/// A timer that wakes a thread, made to live in that thread's stack frame.
///
/// The callback sets `fired`, wakes the thread, and sets `finished` as the
/// last thing it does. The thread loops on `fired` (or on whatever else
/// ends its wait) and calls `finish` before it returns; `finish` does not
/// return while the callback can still touch the timer or the thread.
///
/// Two flags, because one cannot do both jobs: a flag set before the wake
/// lets the thread leave, and even exit, while the callback is still about
/// to wake it; a flag set after the wake can be found unset by the woken
/// thread, which then sleeps again with nobody left to wake it
/// (`tests/models/timeout.zig` shows both).
pub const WakeTimer = struct {
    timer: Timer,
    fired: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),

    /// A timer that wakes `t`. Arm it with `timer.add(&w.timer, delay)`.
    pub fn init(t: *thread.Thread) WakeTimer {
        return .{ .timer = .{ .callback = fire, .context = @intFromPtr(t) } };
    }

    fn fire(timer: *Timer) void {
        const self: *WakeTimer = @fieldParentPtr("timer", timer);
        self.fired.store(true, .release);
        // The thread is still there: it does not leave before `finished`.
        thread.wake(@ptrFromInt(timer.context));
        self.finished.store(true, .release); // nothing of the waiter's is touched after this
    }

    /// True once time is up.
    pub fn hasFired(self: *const WakeTimer) bool {
        return self.fired.load(.acquire);
    }

    /// Disarm the timer, or, if its callback has already started, wait
    /// until the callback is done. Must be called once the timer has been
    /// armed, before the `WakeTimer` goes out of scope. The callback is a
    /// few instructions in an interrupt handler on another CPU, so the
    /// wait is a short spin. The caller may hold its condition's lock (the
    /// callback takes only the scheduler lock) but not the scheduler lock.
    pub fn finish(self: *WakeTimer) void {
        if (cancel(&self.timer)) return;
        while (!self.finished.load(.acquire)) std.atomic.spinLoopHint();
    }
};

/// Block the calling thread for at least `n` tick periods. Other threads
/// run meanwhile; if none is ready the CPU idles. Not for interrupt
/// handlers.
pub fn sleepTicks(n: u64) void {
    var sleeper = WakeTimer.init(thread.current());
    // Interrupts stay off from here on, as `block` wants. If the timer
    // fires before the thread blocks, the wake-up leaves a permit.
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    {
        const held = lock.acquire();
        defer lock.release(held);
        queue.add(&sleeper.timer, ticks + n + 1);
    }
    // An unrelated wake-up may end `block` early; only the timer ends the sleep.
    while (!sleeper.hasFired()) thread.block();
    sleeper.finish();
}

/// Like `sleepTicks`, for a sleep a program asked for: it ends early if
/// the calling thread's process is ending. Returns true if the whole time
/// passed.
pub fn sleepTicksKillable(n: u64) bool {
    var sleeper = WakeTimer.init(thread.current());
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    {
        const held = lock.acquire();
        defer lock.release(held);
        queue.add(&sleeper.timer, ticks + n + 1);
    }
    while (!sleeper.hasFired() and !thread.interrupted()) thread.block();
    sleeper.finish();
    return sleeper.hasFired();
}

/// Block the calling thread for at least `ms` milliseconds.
pub fn sleepMs(ms: u64) void {
    sleepTicks(msToTicks(ms));
}
