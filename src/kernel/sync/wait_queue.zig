//! Wait queues: threads sleeping until something happens.
//!
//! A `WaitQueue` belongs to the thing being waited for: a keyboard buffer
//! (waiting for a key), a process (waiting for it to exit), a mutex. Any
//! number of threads can wait on one queue, and they are woken in the order
//! they arrived.
//!
//! The condition waited for and its queue are protected by one spinlock,
//! the condition's lock, which both sides hold (`docs/locking.md`):
//!
//!     // waiter                            // waker
//!     const held = lock.acquire();         const held = lock.acquire();
//!     while (!condition)                   condition = true;
//!         queue.wait(&lock);               _ = queue.wakeAll();   // or wakeOne
//!     lock.release(held);                  lock.release(held);
//!
//! `wait` puts the thread on the queue, releases the lock, sleeps, and takes
//! the lock again. A waker that comes after the waiter looked at the
//! condition finds it on the queue, and one that came before has made the
//! condition true: no wake-up can fall in between. The waiter looks again
//! when it wakes, because another thread may have got there first. A
//! wake-up with nobody waiting is not remembered: the condition is what is
//! remembered, and the next waiter sees it before sleeping.
//!
//! The waker wakes while it still holds the lock. A waiter with a timeout
//! can leave the queue on its own, return and exit, but it needs the lock
//! for that; so while the waker holds it, the thread it took off the queue
//! is still there to be woken.
//!
//! The queue has no lock of its own: every function here is called with
//! the condition's lock held.

const cpu = @import("../../arch/x86_64/cpu.zig");
const assert = @import("../debug/assert.zig");
const thread = @import("../thread.zig");
const Thread = thread.Thread;
const timer = @import("../timer.zig");
const spinlock = @import("spinlock.zig");
const SpinLock = spinlock.SpinLock;

pub const WaitQueue = struct {
    head: ?*Thread = null,
    tail: ?*Thread = null,

    /// Add `t` at the end. It must not be waiting on any queue.
    fn append(self: *WaitQueue, t: *Thread) void {
        assert.check(.wait_queue, t.wait_queue == null, "thread {d} is already on a wait queue", .{t.id});
        t.wait_queue = self;
        t.wait_next = null;
        if (self.tail) |last| last.wait_next = t else self.head = t;
        self.tail = t;
    }

    /// Remove and return the first thread, or null if the queue is empty.
    fn popFirst(self: *WaitQueue) ?*Thread {
        const t = self.head orelse return null;
        self.head = t.wait_next;
        if (self.head == null) self.tail = null;
        t.wait_next = null;
        t.wait_queue = null;
        return t;
    }

    /// Remove `t` wherever it is. Returns false if it is not on this queue.
    fn remove(self: *WaitQueue, t: *Thread) bool {
        if (t.wait_queue != self) return false;
        var prev: ?*Thread = null;
        var cur = self.head;
        while (cur) |c| : ({
            prev = c;
            cur = c.wait_next;
        }) {
            if (c != t) continue;
            if (prev) |p| p.wait_next = t.wait_next else self.head = t.wait_next;
            if (self.tail == t) self.tail = prev;
            t.wait_next = null;
            t.wait_queue = null;
            return true;
        }
        return false;
    }

    /// The caller is to hold the condition's lock, and nothing else: it is
    /// released while the thread sleeps.
    fn assertOnlyLock(lock: *const SpinLock) void {
        assert.check(.wait_queue, lock.isHeld(), "wait without the condition's lock: the wake-up could be lost", .{});
        spinlock.assertHeld(1, "waiting");
    }

    /// Release the condition's lock, sleep until woken, take the lock again.
    fn sleep(lock: *SpinLock) void {
        lock.drop();
        thread.block();
        lock.take();
    }

    /// Sleep until a `wakeOne` or `wakeAll` on this queue picks the calling
    /// thread. `lock` is the condition's lock, held by the caller and no
    /// other spinlock with it; it is released while the thread sleeps and
    /// held again on return, though other threads ran in between.
    pub fn wait(self: *WaitQueue, lock: *SpinLock) void {
        assertOnlyLock(lock);
        const me = thread.current();
        self.append(me);
        // `block` can return for a wake-up meant for something else; only
        // being taken off the queue ends the wait.
        while (me.wait_queue == self) sleep(lock);
    }

    /// Like `wait`, for a wait that may last as long as a program likes
    /// (for a key, for a child): it also ends when the calling thread's
    /// process is ending (`thread.dying`). Returns true if the thread was
    /// woken through the queue, false if it is to die; then it is off the
    /// queue, and the caller gets out of the way without what it waited for.
    pub fn waitKillable(self: *WaitQueue, lock: *SpinLock) bool {
        assertOnlyLock(lock);
        const me = thread.current();
        self.append(me);
        while (me.wait_queue == self and !thread.dying()) sleep(lock);
        return !self.remove(me);
    }

    /// Like `wait`, but give up after `ticks` timer ticks. Returns true if
    /// the thread was woken through the queue, false if time ran out.
    pub fn waitTimeout(self: *WaitQueue, lock: *SpinLock, ticks: u64) bool {
        assertOnlyLock(lock);
        const me = thread.current();
        var timeout = timer.WakeTimer.init(me);
        self.append(me);
        timer.add(&timeout.timer, ticks);
        while (me.wait_queue == self and !timeout.hasFired()) sleep(lock);
        // The callback may be running on another CPU right now: it must be
        // done with this stack frame and this thread before either can go.
        timeout.finish();
        // Woken and timed out at once counts as woken: the waker took this
        // thread off the queue and expects it to act.
        return !self.remove(me);
    }

    /// Wake the thread that has waited longest. Returns it, or null if
    /// nobody is waiting. The caller holds the condition's lock and keeps
    /// it until this has returned. Safe from interrupt handlers.
    pub fn wakeOne(self: *WaitQueue) ?*Thread {
        assertLocked();
        const t = self.popFirst() orelse return null;
        thread.wake(t);
        return t;
    }

    /// Wake every waiting thread, in the order they arrived. Returns how
    /// many there were. The caller holds the condition's lock, as for
    /// `wakeOne`. Safe from interrupt handlers.
    pub fn wakeAll(self: *WaitQueue) usize {
        assertLocked();
        var n: usize = 0;
        while (self.popFirst()) |t| : (n += 1) thread.wake(t);
        return n;
    }

    /// Number of threads waiting. The caller holds the condition's lock.
    pub fn waiting(self: *const WaitQueue) usize {
        assertLocked();
        var n: usize = 0;
        var t = self.head;
        while (t) |c| : (t = c.wait_next) n += 1;
        return n;
    }

    /// The queue does not know its condition's lock, so this can only see
    /// that the CPU holds some spinlock.
    fn assertLocked() void {
        assert.check(.wait_queue, cpu.readFlags() & (1 << 9) == 0, "wait queue used with interrupts on", .{});
        if (spinlock.heldCount()) |n| assert.check(.wait_queue, n > 0, "wait queue used without its condition's lock", .{});
    }
};
