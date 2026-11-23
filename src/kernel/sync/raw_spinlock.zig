//! The atomic core of a spinlock: one flag, taken with compare-and-swap.
//!
//! This is the part that makes the lock a real lock on several CPUs. It
//! knows nothing about interrupts; `spinlock.zig` adds that. No kernel
//! dependencies, so it is tested on the host with real threads.

const std = @import("std");

pub const RawSpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    /// Take the lock if it is free. Returns false if someone holds it.
    pub fn tryLock(self: *RawSpinLock) bool {
        return self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }

    /// Spin until the lock is taken, giving up after `max_spins` failed
    /// attempts. Returns false if it gave up. While waiting it only reads
    /// the flag (so the cache line is not bounced between CPUs) and tells
    /// the CPU it is spinning.
    pub fn lockBounded(self: *RawSpinLock, max_spins: usize) bool {
        var spins: usize = 0;
        while (!self.tryLock()) {
            while (self.locked.load(.monotonic)) {
                if (spins == max_spins) return false;
                spins += 1;
                std.atomic.spinLoopHint();
            }
        }
        return true;
    }

    /// Release the lock. The caller must hold it.
    pub fn unlock(self: *RawSpinLock) void {
        self.locked.store(false, .release);
    }

    /// True if someone holds the lock right now. For assertions.
    pub fn isLocked(self: *const RawSpinLock) bool {
        return self.locked.load(.monotonic);
    }
};
