//! Model of waiting with a timeout on several CPUs (`docs/locking.md`,
//! "Sleeping and waking"): `WaitQueue.waitTimeout` and the timer callback
//! it arms (`src/kernel/sync/wait_queue.zig`, `timer.WakeTimer` in
//! `src/kernel/timer.zig`). `timer.sleepTicks` is the same without the
//! wait queue.
//!
//! One thread waits with a timeout. A waker may wake it, or never come. The
//! timer may fire at any moment, on another CPU: its callback runs
//! alongside the waiter, not inside an interrupt that finishes first. The
//! timer itself lives in the waiter's stack frame, and when the waiter
//! returns that frame is gone; the thread may then exit as well.
//!
//! What must hold: the waiter always returns; it reports "woken" exactly
//! when the waker took it off the queue; and neither the callback nor the
//! waker touches the frame or the thread after the waiter has gone.
//!
//! Blocking and waking are single actions here; `sleep_wake.zig` models
//! what is inside them.

pub const Config = struct {
    /// How the waiter and the timer callback agree that the callback is done.
    callback: enum {
        /// No agreement: the waiter cancels the timer and returns (enough on
        /// one CPU, where the callback cannot be running at that moment).
        unsynchronized,
        /// One flag, set before the callback wakes the thread; a waiter
        /// whose cancel came too late waits for it.
        one_flag_before_wake,
        /// One flag, set after the wake.
        one_flag_after_wake,
        /// "fired" before the wake, for the waiter's loop; "finished" as the
        /// callback's last act, for a waiter whose cancel came too late.
        two_flags,
    } = .two_flags,
    /// The waker wakes the thread before it releases the condition's lock,
    /// which the waiter needs to leave the queue.
    wake_under_lock: bool = true,
};

pub fn Model(comptime cfg: Config) type {
    return struct {
        const Pc = enum(u8) { join, arm, loop, block, asleep, cancel, wait_for_callback, leave, done };
        const Callback = enum(u8) { idle, first, second, third, end };
        const WakerPc = enum(u8) { idle, took_it, end };
        const Outcome = enum(u8) { none, woken, timed_out };

        pub const State = struct {
            pc: Pc = .join,
            on_queue: bool = false,
            blocked: bool = false,
            permit: bool = false,
            outcome: Outcome = .none,
            frame_alive: bool = true,
            thread_alive: bool = true,

            /// The timer is in the timer queue.
            armed: bool = false,
            fired: bool = false,
            finished: bool = false,
            callback: Callback = .idle,

            waker: WakerPc = .idle,
            /// The waker took the thread off the wait queue.
            delivered: bool = false,

            touched_dead_frame: bool = false,
            touched_dead_thread: bool = false,
        };

        /// The waiter, the waker waking, the waker never coming, the callback.
        pub const action_count = 4;

        pub fn initial() State {
            return .{};
        }

        /// thread.wake, by the callback or the waker.
        fn wake(n: *State) void {
            if (!n.thread_alive) n.touched_dead_thread = true;
            n.permit = true;
            n.blocked = false;
        }

        fn touchFrame(n: *State) void {
            if (!n.frame_alive) n.touched_dead_frame = true;
        }

        fn waiter(s: State) ?State {
            var n = s;
            switch (s.pc) {
                .join => {
                    n.on_queue = true;
                    n.pc = .arm;
                },
                .arm => {
                    n.armed = true;
                    n.pc = .loop;
                },
                .loop => n.pc = if (s.on_queue and !s.fired) .block else .cancel,
                .block => if (s.permit) {
                    n.permit = false;
                    n.pc = .loop;
                } else {
                    n.blocked = true;
                    n.pc = .asleep;
                },
                .asleep => {
                    if (s.blocked) return null;
                    n.permit = false;
                    n.pc = .loop;
                },
                .cancel => if (s.armed) {
                    n.armed = false; // taken out of the timer queue: the callback will not run
                    n.pc = .leave;
                } else {
                    n.pc = if (cfg.callback == .unsynchronized) .leave else .wait_for_callback;
                },
                .wait_for_callback => {
                    const over = if (cfg.callback == .two_flags) s.finished else s.fired;
                    if (!over) return null;
                    n.pc = .leave;
                },
                // Leave the wait queue, under the condition's lock, and return.
                .leave => {
                    if (cfg.wake_under_lock and s.waker == .took_it) return null; // the waker holds the lock
                    n.outcome = if (s.on_queue) .timed_out else .woken;
                    n.on_queue = false;
                    n.frame_alive = false;
                    n.thread_alive = false; // it may exit right away
                    n.pc = .done;
                },
                .done => return null,
            }
            return n;
        }

        fn callback(s: State) ?State {
            var n = s;
            switch (s.callback) {
                .idle => {
                    if (!s.armed) return null;
                    n.armed = false; // the timer interrupt took it out of the queue
                    n.callback = .first;
                },
                .first => {
                    if (cfg.callback == .one_flag_after_wake) wake(&n) else {
                        touchFrame(&n);
                        n.fired = true;
                    }
                    n.callback = .second;
                },
                .second => {
                    if (cfg.callback == .one_flag_after_wake) {
                        touchFrame(&n);
                        n.fired = true;
                    } else wake(&n);
                    n.callback = if (cfg.callback == .two_flags) .third else .end;
                },
                .third => {
                    touchFrame(&n);
                    n.finished = true;
                    n.callback = .end;
                },
                .end => return null,
            }
            return n;
        }

        pub fn step(s: State, action: usize) ?State {
            var n = s;
            switch (action) {
                0 => return waiter(s),
                1 => switch (s.waker) { // wakeOne
                    .idle => {
                        if (s.on_queue) {
                            n.on_queue = false;
                            n.delivered = true;
                            n.waker = .took_it;
                        } else n.waker = .end;
                        return n;
                    },
                    .took_it => {
                        wake(&n);
                        n.waker = .end;
                        return n;
                    },
                    .end => return null,
                },
                2 => { // nobody ever wakes it: only the timeout can end the wait
                    if (s.waker != .idle) return null;
                    n.waker = .end;
                    return n;
                },
                else => return callback(s),
            }
        }

        pub fn invariant(s: State) ?[]const u8 {
            if (s.touched_dead_frame) return "the callback used the timer after the waiter had returned";
            if (s.touched_dead_thread) return "a thread was woken after it had gone";
            if (s.pc == .done and (s.outcome == .woken) != s.delivered) return "the waiter's result does not say whether it was woken";
            return null;
        }

        pub fn finished(s: State) bool {
            return s.pc == .done and s.waker == .end and (s.callback == .idle or s.callback == .end);
        }

        pub fn actionName(action: usize) []const u8 {
            const names = [action_count][]const u8{ "waiter", "waker", "waker never comes", "timer callback" };
            return names[action];
        }
    };
}
