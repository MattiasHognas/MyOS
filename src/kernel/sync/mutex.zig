//! A mutex for kernel code that may block while holding it.
//!
//! Unlike a spinlock, a `Mutex` leaves interrupts on and lets its holder be
//! preempted, sleep, or wait for I/O; threads that want it meanwhile sleep
//! on its wait queue instead of spinning. Use it for anything longer than a
//! few instructions. Never from an interrupt handler.
//!
//! `unlock` hands the mutex directly to the thread that has waited longest:
//! it becomes the owner before it even runs, so a thread that keeps taking
//! and releasing the mutex cannot starve the others.
//!
//! Not recursive: locking a mutex the caller already holds is a bug and
//! panics, as does unlocking one it does not hold.

const thread = @import("../thread.zig");
const WaitQueue = @import("wait_queue.zig").WaitQueue;
const cpu = @import("../../arch/x86_64/cpu.zig");
const panicFmt = @import("../debug/panic.zig").panicFmt;

const Thread = thread.Thread;

pub const Mutex = struct {
    /// The thread that holds the mutex, or null if it is free.
    owner: ?*Thread = null,
    waiters: WaitQueue = .{},

    /// Take the mutex, sleeping until it is handed over if it is held.
    pub fn lock(self: *Mutex) void {
        const flags = cpu.saveAndDisableInterrupts();
        defer cpu.restoreInterrupts(flags);
        const me = thread.current();
        if (self.owner == me) panicFmt("mutex: thread {d} locks a mutex it already holds", .{me.id});
        if (self.owner == null) {
            self.owner = me;
            return;
        }
        // `unlock` makes this thread the owner before waking it.
        while (self.owner != me) self.waiters.wait();
    }

    /// Take the mutex if it is free. Returns false, without waiting, if it is not.
    pub fn tryLock(self: *Mutex) bool {
        const flags = cpu.saveAndDisableInterrupts();
        defer cpu.restoreInterrupts(flags);
        if (self.owner != null) return false;
        self.owner = thread.current();
        return true;
    }

    /// Release the mutex. If threads are waiting, the first becomes the owner.
    pub fn unlock(self: *Mutex) void {
        const flags = cpu.saveAndDisableInterrupts();
        defer cpu.restoreInterrupts(flags);
        const me = thread.current();
        if (self.owner != me) panicFmt("mutex: thread {d} unlocks a mutex it does not hold", .{me.id});
        // Interrupts are off, so the woken thread cannot run before it has
        // been made the owner.
        self.owner = self.waiters.wakeOne();
    }

    /// True if the calling thread holds the mutex.
    pub fn heldByMe(self: *const Mutex) bool {
        return self.owner == thread.current();
    }
};
