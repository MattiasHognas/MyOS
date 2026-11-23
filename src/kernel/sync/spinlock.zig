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
//! The lock itself is a real atomic flag (`raw_spinlock.zig`). With one CPU
//! it is always free when asked for; with several (milestone 3) it is what
//! keeps the other CPUs out, with no change to the users.
//!
//! Rules: never block, yield or call anything that might, while holding a
//! spinlock (use a `Mutex` for that); never take the same lock twice. A
//! lock that stays held for an absurd time is reported as a panic instead
//! of a silent hang.

const cpu = @import("../../arch/x86_64/cpu.zig");
const RawSpinLock = @import("raw_spinlock.zig").RawSpinLock;

/// Failed attempts before `acquire` gives up and panics. Far beyond any
/// legitimate wait: critical sections are a handful of instructions.
const STUCK_SPINS = 1 << 28;

pub const SpinLock = struct {
    raw: RawSpinLock = .{},

    /// What `acquire` returns: the interrupt state to restore.
    pub const Held = struct { flags: u64 };

    /// Turn interrupts off and take the lock. Pass the result to `release`.
    pub fn acquire(self: *SpinLock) Held {
        const flags = cpu.saveAndDisableInterrupts();
        if (!self.raw.lockBounded(STUCK_SPINS)) @panic("spinlock: stuck (taken twice, or its holder never released it)");
        return .{ .flags = flags };
    }

    /// Like `acquire`, but returns null at once if the lock is held.
    pub fn tryAcquire(self: *SpinLock) ?Held {
        const flags = cpu.saveAndDisableInterrupts();
        if (self.raw.tryLock()) return .{ .flags = flags };
        cpu.restoreInterrupts(flags);
        return null;
    }

    /// Release the lock and restore the interrupt state from `acquire`.
    pub fn release(self: *SpinLock, held: Held) void {
        self.raw.unlock();
        cpu.restoreInterrupts(held.flags);
    }

    /// True if the lock is held (by anyone). For assertions.
    pub fn isHeld(self: *const SpinLock) bool {
        return self.raw.isLocked();
    }
};
