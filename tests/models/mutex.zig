//! Model of the mutex on several CPUs (`docs/locking.md`): `Mutex.lock` and
//! `unlock` in `src/kernel/sync/mutex.zig`, which hands the mutex to the
//! longest waiter.
//!
//! Three threads each take the mutex once and release it.
//!
//! What must hold: at most one thread is inside at a time, it is the one
//! the mutex names as its owner, and every thread gets in.
//!
//! Blocking and waking are single actions here; `sleep_wake.zig` models
//! what is inside them.

pub const Config = struct {
    /// `lock` looks at the owner and takes the mutex (or joins the waiters)
    /// under the mutex's internal spinlock. Off: it looks, then acts, as
    /// is enough on one CPU with interrupts off.
    internal_lock: bool = true,
};

pub const threads = 3;
const none = threads;

pub fn Model(comptime cfg: Config) type {
    return struct {
        const Pc = enum(u8) { lock, take, block, asleep, recheck, inside, done };

        pub const State = struct {
            /// Thread number + 1, or 0 for nobody.
            owner: u8 = 0,
            queue: [threads]u8 = @splat(none),
            queue_len: u8 = 0,
            pc: [threads]Pc = @splat(.lock),
            blocked: [threads]bool = @splat(false),
            permit: [threads]bool = @splat(false),
        };

        pub const action_count = threads;

        pub fn initial() State {
            return .{};
        }

        fn join(n: *State, i: u8) void {
            n.queue[n.queue_len] = i;
            n.queue_len += 1;
            n.pc[i] = .block;
        }

        pub fn step(s: State, action: usize) ?State {
            const i: u8 = @intCast(action);
            var n = s;
            switch (s.pc[i]) {
                .lock => if (s.owner == 0) {
                    if (cfg.internal_lock) {
                        n.owner = i + 1;
                        n.pc[i] = .inside;
                    } else n.pc[i] = .take; // saw it free; takes it in the next step
                } else join(&n, i),
                .take => {
                    n.owner = i + 1;
                    n.pc[i] = .inside;
                },
                .block => if (s.permit[i]) {
                    n.permit[i] = false;
                    n.pc[i] = .recheck;
                } else {
                    n.blocked[i] = true;
                    n.pc[i] = .asleep;
                },
                .asleep => {
                    if (s.blocked[i]) return null;
                    n.permit[i] = false;
                    n.pc[i] = .recheck;
                },
                .recheck => n.pc[i] = if (s.owner == i + 1) .inside else .block,
                // unlock: hand over to the longest waiter and wake it, under the internal lock.
                .inside => {
                    if (s.queue_len > 0) {
                        const t = s.queue[0];
                        for (0..threads - 1) |k| n.queue[k] = s.queue[k + 1];
                        n.queue[threads - 1] = none;
                        n.queue_len -= 1;
                        n.owner = t + 1;
                        n.permit[t] = true;
                        n.blocked[t] = false;
                    } else n.owner = 0;
                    n.pc[i] = .done;
                },
                .done => return null,
            }
            return n;
        }

        pub fn invariant(s: State) ?[]const u8 {
            var inside: u8 = 0;
            for (s.pc, 0..) |pc, i| {
                if (pc != .inside) continue;
                inside += 1;
                if (s.owner != i + 1) return "a thread is inside without being the owner";
            }
            if (inside > 1) return "two threads are inside at once";
            return null;
        }

        pub fn finished(s: State) bool {
            for (s.pc) |pc| {
                if (pc != .done) return false;
            }
            return s.owner == 0 and s.queue_len == 0;
        }

        pub fn actionName(action: usize) []const u8 {
            const names = [action_count][]const u8{ "thread 0", "thread 1", "thread 2" };
            return names[action];
        }
    };
}
