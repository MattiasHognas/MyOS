//! Kernel time in ticks, and timeouts.
//!
//! The timer interrupt calls `tick` `HZ` times a second. Each tick advances
//! `now` and runs the callbacks of the timers that are due
//! (`sync/timer_queue.zig` keeps them in order). Sleeping, waits with a
//! timeout and (later) driver and network timeouts are built on this.
//!
//! Callbacks run in the timer interrupt, with interrupts off: they must be
//! short and must not block. Waking a thread is the usual thing to do.
//!
//! Resolution is one tick (10 ms). A timeout of `n` ticks fires at the
//! n-th tick from now, which is between `n - 1` and `n` tick periods away;
//! `sleepTicks` adds one so that a sleep is never shorter than asked.

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

var lock: SpinLock = .{};
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

/// Disarm `timer`. Returns true if it was still pending, false if it had
/// fired already (or was never armed).
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

/// State of one sleeping thread, on its stack.
const Sleeper = struct {
    timer: Timer,
    fired: bool = false,
};

/// Timer callback of `sleepTicks`: note that time is up and wake the thread.
fn wakeSleeper(timer: *Timer) void {
    const sleeper: *Sleeper = @fieldParentPtr("timer", timer);
    sleeper.fired = true;
    thread.wake(@ptrFromInt(timer.context));
}

/// Block the calling thread for at least `n` tick periods. Other threads
/// run meanwhile; if none is ready the CPU idles. Not for interrupt
/// handlers.
pub fn sleepTicks(n: u64) void {
    const me = thread.current();
    var sleeper: Sleeper = .{ .timer = .{ .callback = wakeSleeper, .context = @intFromPtr(me) } };
    // Interrupts stay off from arming the timer until the thread blocks,
    // so the timer cannot fire in between.
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    {
        const held = lock.acquire();
        defer lock.release(held);
        queue.add(&sleeper.timer, ticks + n + 1);
    }
    // An unrelated wake-up may end `block` early; only the timer ends the sleep.
    while (!sleeper.fired) thread.block();
}

/// Block the calling thread for at least `ms` milliseconds.
pub fn sleepMs(ms: u64) void {
    sleepTicks(msToTicks(ms));
}
