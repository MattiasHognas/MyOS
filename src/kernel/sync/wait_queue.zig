//! Wait queues: threads sleeping until something happens.
//!
//! A `WaitQueue` belongs to the thing being waited for: a keyboard buffer
//! (waiting for a key), a process (waiting for it to exit), a mutex. Any
//! number of threads can wait on one queue, and they are woken in the order
//! they arrived.
//!
//! The pattern, on both sides, with interrupts off:
//!
//!     // waiter                          // waker
//!     while (!condition) queue.wait();   condition = true;
//!                                        queue.wakeAll();   // or wakeOne
//!
//! The waiter checks the condition and goes to sleep without interrupts in
//! between, so the wake-up cannot slip through the gap; and it checks again
//! when it wakes, because another thread may have got there first. A
//! wake-up with nobody waiting is not remembered: the condition is what is
//! remembered, and the next waiter sees it before sleeping.
//!
//! With several CPUs the check and the sleep must also be covered by a
//! lock the waker takes (milestone 3); the queue's own list is already
//! protected by a spinlock.

const cpu = @import("../../arch/x86_64/cpu.zig");
const assert = @import("../debug/assert.zig");
const thread = @import("../thread.zig");
const Thread = thread.Thread;
const timer = @import("../timer.zig");
const SpinLock = @import("spinlock.zig").SpinLock;

pub const WaitQueue = struct {
    lock: SpinLock = .{},
    head: ?*Thread = null,
    tail: ?*Thread = null,

    /// Add `t` at the end. It must not be waiting on any queue.
    fn append(self: *WaitQueue, t: *Thread) void {
        const held = self.lock.acquire();
        defer self.lock.release(held);
        assert.check(.wait_queue, t.wait_queue == null, "thread {d} is already on a wait queue", .{t.id});
        t.wait_queue = self;
        t.wait_next = null;
        if (self.tail) |last| last.wait_next = t else self.head = t;
        self.tail = t;
    }

    /// Remove and return the first thread, or null if the queue is empty.
    fn popFirst(self: *WaitQueue) ?*Thread {
        const held = self.lock.acquire();
        defer self.lock.release(held);
        const t = self.head orelse return null;
        self.head = t.wait_next;
        if (self.head == null) self.tail = null;
        t.wait_next = null;
        t.wait_queue = null;
        return t;
    }

    /// Remove `t` wherever it is. Returns false if it is not on this queue.
    fn remove(self: *WaitQueue, t: *Thread) bool {
        const held = self.lock.acquire();
        defer self.lock.release(held);
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

    /// Sleep until a `wakeOne` or `wakeAll` on this queue picks the calling
    /// thread. Interrupts must be off (see the pattern above); they are off
    /// again on return, though other threads ran in between.
    pub fn wait(self: *WaitQueue) void {
        assert.check(.wait_queue, cpu.readFlags() & (1 << 9) == 0, "wait with interrupts on: the wake-up could be lost", .{});
        const me = thread.current();
        self.append(me);
        // `block` can return for a wake-up meant for something else; only
        // being taken off the queue ends the wait.
        while (me.wait_queue == self) thread.block();
    }

    /// Like `wait`, but give up after `ticks` timer ticks. Returns true if
    /// the thread was woken through the queue, false if time ran out.
    pub fn waitTimeout(self: *WaitQueue, ticks: u64) bool {
        assert.check(.wait_queue, cpu.readFlags() & (1 << 9) == 0, "wait with interrupts on: the wake-up could be lost", .{});
        const me = thread.current();
        var timeout: Timeout = .{ .timer = .{ .callback = Timeout.fire, .context = @intFromPtr(me) } };
        self.append(me);
        timer.add(&timeout.timer, ticks);
        while (me.wait_queue == self and !timeout.fired) thread.block();
        _ = timer.cancel(&timeout.timer);
        // Woken and timed out at once counts as woken: the waker took this
        // thread off the queue and expects it to act.
        return !self.remove(me);
    }

    /// Wake the thread that has waited longest. Returns it, or null if
    /// nobody is waiting. Safe from interrupt handlers.
    pub fn wakeOne(self: *WaitQueue) ?*Thread {
        const flags = cpu.saveAndDisableInterrupts();
        defer cpu.restoreInterrupts(flags);
        const t = self.popFirst() orelse return null;
        thread.wake(t);
        return t;
    }

    /// Wake every waiting thread, in the order they arrived. Returns how
    /// many there were. Safe from interrupt handlers.
    pub fn wakeAll(self: *WaitQueue) usize {
        const flags = cpu.saveAndDisableInterrupts();
        defer cpu.restoreInterrupts(flags);
        var n: usize = 0;
        while (self.popFirst()) |t| : (n += 1) thread.wake(t);
        return n;
    }

    /// Number of threads waiting.
    pub fn waiting(self: *WaitQueue) usize {
        const held = self.lock.acquire();
        defer self.lock.release(held);
        var n: usize = 0;
        var t = self.head;
        while (t) |c| : (t = c.wait_next) n += 1;
        return n;
    }
};

/// The timer of one `waitTimeout`, on the waiting thread's stack.
const Timeout = struct {
    timer: timer.Timer,
    fired: bool = false,

    /// Timer callback: note that time is up and let the thread look.
    fn fire(t: *timer.Timer) void {
        const self: *Timeout = @fieldParentPtr("timer", t);
        self.fired = true;
        thread.wake(@ptrFromInt(t.context));
    }
};
