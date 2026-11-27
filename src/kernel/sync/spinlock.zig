//! Spinlocks for short critical sections, usable from interrupt handlers.
//!
//! Taking a `SpinLock` turns interrupts off and gives back the previous
//! interrupt state, which `release` restores. So:
//!
//! - an interrupt handler on this CPU can never find the lock held by the
//!   code it interrupted (which would be a deadlock);
//! - the holder is never preempted, so the lock is held for a short,
//!   bounded time;
//! - locks nest: the innermost `release` leaves interrupts off if they were
//!   off when it was taken.
//!
//! The lock itself is a real atomic flag (`raw_spinlock.zig`): with several
//! CPUs it is what keeps the others out.
//!
//! Rules (`docs/locking.md`): never block, yield or call anything that
//! might, while holding a spinlock (use a `Mutex` for that); never take the
//! same lock twice; take locks in the order of their ranks
//! (`lock_order.zig`) and release them in the opposite order. In builds
//! with assertions each CPU records the locks it holds, and breaking the
//! order panics at once, on one CPU as on several, instead of deadlocking
//! one day. A lock that stays held for an absurd time is reported as a
//! panic instead of a silent hang.
//!
//! `take` and `drop` are the two halves without the interrupt flag, for
//! code that has interrupts off anyway and hands a lock over: a wait queue
//! releasing its condition's lock while the thread sleeps, the scheduler
//! keeping its lock across a context switch.

const std = @import("std");
const stats = @import("../stats.zig");

const cpu = @import("../../arch/x86_64/cpu.zig");
const ipi = @import("../../arch/x86_64/ipi.zig");
const percpu = @import("../../arch/x86_64/percpu.zig");
const assert = @import("../debug/assert.zig");
const panicFmt = @import("../debug/panic.zig").panicFmt;
const lock_order = @import("lock_order.zig");
const RawSpinLock = @import("raw_spinlock.zig").RawSpinLock;

pub const Rank = lock_order.Rank;

/// Failed attempts before `acquire` gives up and panics. Far beyond any
/// legitimate wait: critical sections are a handful of instructions.
const STUCK_SPINS = 1 << 28;

/// Whether lock ranks are recorded and checked. Turned off for good by a
/// CPU that is reporting a panic or a kernel fault: it prints whatever it
/// holds, and a second report from inside the first helps nobody.
var checking: bool = assert.enabled;

/// Stop recording and checking lock ranks (see `checking`).
pub fn stopChecking() void {
    checking = false;
}

/// Number of spinlocks the running CPU holds, or null if that is not
/// recorded (assertions compiled out, or too early in boot). Interrupts
/// must be off, or the answer may be about another CPU by the time it is used.
pub fn heldCount() ?usize {
    if (!assert.enabled or !checking) return null;
    const c = percpu.currentIfReady() orelse return null;
    return c.locks.count();
}

/// Panic unless the running CPU holds exactly `want` spinlocks. Does
/// nothing where that is not recorded. `what` says who is asking.
pub inline fn assertHeld(want: usize, comptime what: []const u8) void {
    if (heldCount()) |n| assert.check(.spinlock, n == want, what ++ " with {d} spinlocks held, not {d}", .{ n, want });
}

pub const SpinLock = struct {
    raw: RawSpinLock = .{},
    /// Where the lock stands in the lock order.
    rank: Rank = .condition,

    /// What `acquire` returns: the interrupt state to restore.
    pub const Held = struct { flags: u64 };

    /// Turn interrupts off and take the lock. Pass the result to `release`.
    pub fn acquire(self: *SpinLock) Held {
        const flags = cpu.saveAndDisableInterrupts();
        self.take();
        return .{ .flags = flags };
    }

    /// Like `acquire`, but returns null at once if the lock is held.
    pub fn tryAcquire(self: *SpinLock) ?Held {
        const flags = cpu.saveAndDisableInterrupts();
        if (self.raw.tryLock()) {
            self.noteTaken();
            return .{ .flags = flags };
        }
        cpu.restoreInterrupts(flags);
        return null;
    }

    /// Release the lock and restore the interrupt state from `acquire`.
    pub fn release(self: *SpinLock, held: Held) void {
        self.drop();
        cpu.restoreInterrupts(held.flags);
    }

    /// Take the lock with interrupts already off; they stay off.
    pub fn take(self: *SpinLock) void {
        assert.check(.spinlock, cpu.readFlags() & (1 << 9) == 0, "taking a {t} lock with interrupts on", .{self.rank});
        self.noteTaken();
        if (self.raw.tryLock()) return;
        // It has to wait: counted, with how long (`stats.zig`).
        const waited_from = stats.rdtsc();
        defer stats.contended(self.rank, stats.rdtsc() - waited_from);
        var spins: usize = 0;
        while (!self.raw.tryLock()) {
            // Only read the flag while waiting, so the cache line is not
            // bounced between CPUs. The holder may be waiting for this CPU
            // to answer a request, which it cannot take as an interrupt
            // now: look for one (`ipi.zig`).
            while (self.raw.isLocked()) {
                ipi.poll();
                spins += 1;
                if (spins == STUCK_SPINS) @panic("spinlock: stuck (taken twice, or its holder never released it)");
                std.atomic.spinLoopHint();
            }
        }
    }

    /// Release the lock and leave interrupts off. The other half of `take`,
    /// or of an `acquire` whose interrupt state the caller restores later.
    pub fn drop(self: *SpinLock) void {
        self.noteDropped();
        self.raw.unlock();
    }

    /// True if the lock is held (by anyone). For assertions.
    pub fn isHeld(self: *const SpinLock) bool {
        return self.raw.isLocked();
    }

    /// Record the lock in this CPU's list, checking the order first: a
    /// lock taken out of order is reported before the CPU spins on it.
    fn noteTaken(self: *SpinLock) void {
        if (!assert.enabled or !checking) return;
        const c = percpu.currentIfReady() orelse return;
        c.locks.push(self.rank) catch |e| switch (e) {
            error.OutOfOrder => panicFmt("spinlock: taking a {t} lock while holding a {t} lock (docs/locking.md, lock order)", .{ self.rank, c.locks.innermost().? }),
            error.TooDeep => panicFmt("spinlock: more than {d} locks held", .{lock_order.Stack.capacity}),
        };
    }

    fn noteDropped(self: *SpinLock) void {
        if (!assert.enabled or !checking) return;
        const c = percpu.currentIfReady() orelse return;
        c.locks.pop(self.rank) catch {
            if (c.locks.innermost()) |inner|
                panicFmt("spinlock: releasing a {t} lock while a {t} lock taken after it is held", .{ self.rank, inner });
            panicFmt("spinlock: releasing a {t} lock this CPU does not hold", .{self.rank});
        };
    }
};
