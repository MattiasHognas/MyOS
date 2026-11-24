//! A mutex for kernel code that may block while holding it.
//!
//! Unlike a spinlock, a `Mutex` leaves interrupts on and lets its holder be
//! preempted, sleep, or wait for I/O; threads that want it meanwhile sleep
//! on its wait queue instead of spinning. Use it for anything longer than a
//! few instructions. Never from an interrupt handler, and never while
//! holding a spinlock.
//!
//! `unlock` hands the mutex directly to the thread that has waited longest:
//! it becomes the owner before it even runs, so a thread that keeps taking
//! and releasing the mutex cannot starve the others.
//!
//! Not recursive: locking a mutex the caller already holds is a bug and
//! panics, as does unlocking one it does not hold.
//!
//! The owner and the queue of waiters are protected by a spinlock inside
//! the mutex (`guard`), held for a few instructions: looking at the owner
//! and taking the mutex, or joining the queue, is one step that no other
//! CPU can get into (`tests/models/mutex.zig`).

const thread = @import("../thread.zig");
const WaitQueue = @import("wait_queue.zig").WaitQueue;
const spinlock = @import("spinlock.zig");
const SpinLock = spinlock.SpinLock;
const panicFmt = @import("../debug/panic.zig").panicFmt;

const Thread = thread.Thread;

pub const Mutex = struct {
    /// Protects `owner` and `waiters`.
    guard: SpinLock = .{ .rank = .condition },
    /// The thread that holds the mutex, or null if it is free.
    owner: ?*Thread = null,
    waiters: WaitQueue = .{},

    /// Take the mutex, sleeping until it is handed over if it is held.
    pub fn lock(self: *Mutex) void {
        const held = self.guard.acquire();
        defer self.guard.release(held);
        spinlock.assertHeld(1, "locking a mutex"); // it may sleep
        const me = thread.current();
        if (self.owner == me) panicFmt("mutex: thread {d} locks a mutex it already holds", .{me.id});
        if (self.owner == null) {
            self.owner = me;
            return;
        }
        // `unlock` makes this thread the owner before waking it.
        while (self.owner != me) self.waiters.wait(&self.guard);
    }

    /// Take the mutex if it is free. Returns false, without waiting, if it is not.
    pub fn tryLock(self: *Mutex) bool {
        const held = self.guard.acquire();
        defer self.guard.release(held);
        if (self.owner != null) return false;
        self.owner = thread.current();
        return true;
    }

    /// Release the mutex. If threads are waiting, the first becomes the owner.
    pub fn unlock(self: *Mutex) void {
        const held = self.guard.acquire();
        defer self.guard.release(held);
        const me = thread.current();
        if (self.owner != me) panicFmt("mutex: thread {d} unlocks a mutex it does not hold", .{me.id});
        // Under the guard, so the woken thread cannot look before it has
        // been made the owner, and nobody else can take the mutex in between.
        self.owner = self.waiters.wakeOne();
    }

    /// True if the calling thread holds the mutex.
    pub fn heldByMe(self: *Mutex) bool {
        const held = self.guard.acquire();
        defer self.guard.release(held);
        return self.owner == thread.current();
    }

    /// Number of threads waiting for the mutex.
    pub fn waiterCount(self: *Mutex) usize {
        const held = self.guard.acquire();
        defer self.guard.release(held);
        return self.waiters.waiting();
    }
};
