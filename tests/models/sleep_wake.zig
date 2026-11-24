//! Model of sleeping and waking on several CPUs (`docs/locking.md`,
//! "Sleeping and waking"): `WaitQueue.wait`, `wakeOne`, `thread.block`,
//! `thread.wake` and the context switch in `src/kernel/`.
//!
//! Some threads each wait for an event; a waker posts as many events as
//! there are waiters, waking the longest waiter each time; other CPUs pick
//! up threads that became ready; a CPU whose thread blocks may find nothing
//! else to run and idle on that thread's stack. Every step that the kernel does under one
//! lock without releasing it is one action here; a lock that is held from
//! one action to the next is a variable.
//!
//! What must hold: every waiter gets its event (no wake-up is lost), no
//! thread is on the wait queue or the ready queue twice, no thread runs on
//! two CPUs at once, and nothing is done to a thread that has exited.
//!
//! The rules under test can be switched off one by one (`Config`), to show
//! that the model notices.

const std = @import("std");

pub const Config = struct {
    /// The waiter checks the condition and joins the wait queue under the
    /// condition's lock, which the waker takes too. Off: it checks first
    /// and joins afterwards, as is enough on one CPU with interrupts off.
    check_under_lock: bool = true,
    /// A thread that blocks keeps the scheduler lock until its CPU has left
    /// its stack. Off: the lock is released once the thread is marked blocked.
    hold_across_switch: bool = true,
    /// The waker wakes the thread before it releases the condition's lock.
    wake_under_lock: bool = true,
    /// A blocked thread whose CPU found nothing else to run idles on the
    /// thread's own stack (there is no idle thread), and waking it lets it
    /// carry on there. Off: it is put in the ready queue like any blocked
    /// thread, as if "blocked" meant "off its stack".
    wake_idle_in_place: bool = true,
};

/// Number of waiting threads, and of events posted.
pub const waiters = 2;
const none = waiters;
const waker_id = waiters + 1; // as a lock holder; waiter i holds as i + 1

pub fn Model(comptime cfg: Config) type {
    return struct {
        const Pc = enum(u8) { check, test_condition, lock_to_join, join, block_lock, block_decide, switch_out, idle, idle_lock, asleep, recheck, done };
        const Run = enum(u8) { running, ready, blocked };
        const WakerPc = enum(u8) { start, post, wake_lock, wake, end };

        pub const State = struct {
            /// Holder of the condition's lock and of the scheduler lock; 0 = free.
            cond_lock: u8 = 0,
            sched_lock: u8 = 0,
            /// Events posted and not yet taken: the condition is "events > 0".
            events: u8 = 0,
            queue: [waiters]u8 = @splat(none),
            queue_len: u8 = 0,

            pc: [waiters]Pc = @splat(.check),
            run: [waiters]Run = @splat(.running),
            permit: [waiters]bool = @splat(false),
            /// A CPU is executing on this thread's stack.
            on_stack: [waiters]bool = @splat(true),
            in_ready_queue: [waiters]bool = @splat(false),
            exited: [waiters]bool = @splat(false),

            waker: WakerPc = .start,
            posted: u8 = 0,
            target: u8 = none,

            two_cpus: bool = false,
            queued_twice: bool = false,
            woke_exited: bool = false,
        };

        /// Waiter i, the waker, "a CPU picks thread i from the ready queue",
        /// and "waiter i's CPU has nothing else to run, and idles".
        pub const action_count = waiters + 1 + waiters + waiters;

        pub fn initial() State {
            return .{};
        }

        fn onQueue(s: State, t: u8) bool {
            return std.mem.indexOfScalar(u8, s.queue[0..s.queue_len], t) != null;
        }

        fn waiter(s: State, i: u8) ?State {
            var n = s;
            const me = i + 1;
            switch (s.pc[i]) {
                .check => {
                    if (cfg.check_under_lock) {
                        if (s.cond_lock != 0) return null;
                        n.cond_lock = me;
                    }
                    n.pc[i] = .test_condition;
                },
                .test_condition => if (s.events > 0) {
                    n.events -= 1;
                    if (cfg.check_under_lock) n.cond_lock = 0;
                    n.pc[i] = .done;
                    n.exited[i] = true; // it may be gone the moment it has what it came for
                } else {
                    n.pc[i] = if (cfg.check_under_lock) .join else .lock_to_join;
                },
                .lock_to_join => {
                    if (s.cond_lock != 0) return null;
                    n.cond_lock = me;
                    n.pc[i] = .join;
                },
                .join => {
                    if (onQueue(s, i)) n.queued_twice = true;
                    n.queue[s.queue_len] = i;
                    n.queue_len += 1;
                    n.cond_lock = 0;
                    n.pc[i] = .block_lock;
                },
                // thread.block
                .block_lock => {
                    if (s.sched_lock != 0) return null;
                    n.sched_lock = me;
                    n.pc[i] = .block_decide;
                },
                .block_decide => if (s.permit[i]) {
                    n.permit[i] = false;
                    n.sched_lock = 0;
                    n.pc[i] = .recheck;
                } else {
                    n.run[i] = .blocked;
                    if (!cfg.hold_across_switch) n.sched_lock = 0;
                    n.pc[i] = .switch_out;
                },
                .switch_out => {
                    n.on_stack[i] = false;
                    if (cfg.hold_across_switch) n.sched_lock = 0;
                    n.pc[i] = .asleep;
                },
                // Off its stack. It goes on when a CPU has picked it up; being
                // marked running is not enough if no CPU is there to run it.
                .asleep => {
                    if (s.run[i] != .running or !s.on_stack[i]) return null;
                    n.permit[i] = false;
                    n.pc[i] = .recheck;
                },
                // Halted in `block`, on its own stack, the scheduler lock
                // released. An interrupt ends the halt at any time.
                .idle => {
                    if (s.sched_lock != 0) return null;
                    n.sched_lock = me;
                    n.pc[i] = .idle_lock;
                },
                // Woken in place: carry on. Still blocked, and another
                // thread is ready: switch to it after all, leaving this
                // stack under the lock like any switch. Otherwise halt again.
                .idle_lock => {
                    n.sched_lock = 0;
                    if (s.run[i] == .running) {
                        n.permit[i] = false;
                        n.pc[i] = .recheck;
                    } else if (std.mem.indexOfScalar(bool, &s.in_ready_queue, true) != null) {
                        n.on_stack[i] = false;
                        n.pc[i] = .asleep;
                    } else n.pc[i] = .idle;
                },
                // WaitQueue.wait: still on the queue means "not woken yet".
                .recheck => {
                    if (s.cond_lock != 0) return null;
                    n.pc[i] = if (onQueue(s, i)) .block_lock else .check;
                },
                .done => return null,
            }
            return n;
        }

        fn waker(s: State) ?State {
            var n = s;
            switch (s.waker) {
                .start => {
                    if (s.posted == waiters) {
                        n.waker = .end;
                        return n;
                    }
                    if (s.cond_lock != 0) return null;
                    n.cond_lock = waker_id;
                    n.waker = .post;
                },
                .post => {
                    n.events += 1;
                    n.posted += 1;
                    if (s.queue_len > 0) {
                        n.target = s.queue[0];
                        for (0..waiters - 1) |k| n.queue[k] = s.queue[k + 1];
                        n.queue[waiters - 1] = none;
                        n.queue_len -= 1;
                        n.waker = .wake_lock;
                        if (!cfg.wake_under_lock) n.cond_lock = 0;
                    } else {
                        n.cond_lock = 0;
                        n.waker = .start;
                    }
                },
                // thread.wake
                .wake_lock => {
                    if (s.sched_lock != 0) return null;
                    n.sched_lock = waker_id;
                    n.waker = .wake;
                },
                .wake => {
                    const t = s.target;
                    if (s.exited[t]) n.woke_exited = true;
                    n.permit[t] = true;
                    if (s.run[t] == .blocked) {
                        if (cfg.wake_idle_in_place and s.on_stack[t]) {
                            n.run[t] = .running; // its CPU idles on its stack: it carries on there
                        } else {
                            if (s.in_ready_queue[t]) n.queued_twice = true;
                            n.run[t] = .ready;
                            n.in_ready_queue[t] = true;
                        }
                    }
                    n.sched_lock = 0;
                    if (cfg.wake_under_lock) n.cond_lock = 0;
                    n.target = none;
                    n.waker = .start;
                },
                .end => return null,
            }
            return n;
        }

        /// Some CPU takes thread `i` from the ready queue and runs it.
        fn pick(s: State, i: u8) ?State {
            if (!s.in_ready_queue[i] or s.sched_lock != 0) return null;
            var n = s;
            n.in_ready_queue[i] = false;
            if (s.on_stack[i]) n.two_cpus = true; // its old CPU has not left the stack yet
            n.run[i] = .running;
            n.on_stack[i] = true;
            return n;
        }

        /// The CPU of waiter `i`, which is about to switch away from it,
        /// finds the ready queue empty instead: it releases the scheduler
        /// lock and halts where it is. The thread stays blocked, with a
        /// CPU on its stack.
        fn idle(s: State, i: u8) ?State {
            if (s.pc[i] != .switch_out) return null;
            for (s.in_ready_queue) |queued| {
                if (queued) return null; // something to run: it switches
            }
            var n = s;
            n.sched_lock = 0;
            n.pc[i] = .idle;
            return n;
        }

        pub fn step(s: State, action: usize) ?State {
            if (action < waiters) return waiter(s, @intCast(action));
            if (action == waiters) return waker(s);
            if (action < 2 * waiters + 1) return pick(s, @intCast(action - waiters - 1));
            return idle(s, @intCast(action - 2 * waiters - 1));
        }

        pub fn invariant(s: State) ?[]const u8 {
            if (s.two_cpus) return "a thread runs on two CPUs at once";
            if (s.queued_twice) return "a thread is on a queue twice";
            if (s.woke_exited) return "a thread was woken after it had exited";
            return null;
        }

        pub fn finished(s: State) bool {
            for (s.pc) |pc| {
                if (pc != .done) return false;
            }
            return s.waker == .end and s.events == 0;
        }

        pub fn actionName(action: usize) []const u8 {
            const names = [action_count][]const u8{ "waiter 0", "waiter 1", "waker", "a CPU picks waiter 0", "a CPU picks waiter 1", "waiter 0's CPU idles", "waiter 1's CPU idles" };
            return names[action];
        }
    };
}
