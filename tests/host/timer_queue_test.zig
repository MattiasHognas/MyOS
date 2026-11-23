//! Host tests for the ordering logic of kernel timers
//! (`src/kernel/sync/timer_queue.zig`).

const std = @import("std");
const timer_queue = @import("timer_queue");
const Timer = timer_queue.Timer;
const Queue = timer_queue.Queue;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn nothing(_: *Timer) void {}

fn timers(comptime n: usize) [n]Timer {
    var all: [n]Timer = undefined;
    for (&all, 0..) |*t, i| t.* = .{ .callback = nothing, .context = i };
    return all;
}

test "an empty queue has nothing due" {
    var q: Queue = .{};
    try expectEqual(@as(?*Timer, null), q.popExpired(1000));
    try expectEqual(@as(?u64, null), q.nextDeadline());
    try expectEqual(@as(usize, 0), q.count());
}

test "timers come out in deadline order, whatever order they went in" {
    var q: Queue = .{};
    var t = timers(5);
    const deadlines = [_]u64{ 50, 10, 40, 20, 30 };
    for (&t, deadlines) |*timer, d| q.add(timer, d);
    try expectEqual(@as(usize, 5), q.count());
    try expectEqual(@as(?u64, 10), q.nextDeadline());
    var last: u64 = 0;
    for (0..5) |_| {
        const timer = q.popExpired(100).?;
        try expect(timer.deadline > last);
        try expect(!timer.armed and timer.next == null);
        last = timer.deadline;
    }
    try expectEqual(@as(?*Timer, null), q.popExpired(100));
}

test "timers with the same deadline fire in the order they were armed" {
    var q: Queue = .{};
    var t = timers(4);
    q.add(&t[0], 7);
    q.add(&t[1], 7);
    q.add(&t[2], 3);
    q.add(&t[3], 7);
    try expectEqual(@as(usize, 2), q.popExpired(7).?.context);
    try expectEqual(@as(usize, 0), q.popExpired(7).?.context);
    try expectEqual(@as(usize, 1), q.popExpired(7).?.context);
    try expectEqual(@as(usize, 3), q.popExpired(7).?.context);
}

test "nothing fires before its deadline, everything at or after it" {
    var q: Queue = .{};
    var t = timers(3);
    q.add(&t[0], 10);
    q.add(&t[1], 11);
    q.add(&t[2], 20);
    try expectEqual(@as(?*Timer, null), q.popExpired(0));
    try expectEqual(@as(?*Timer, null), q.popExpired(9));
    try expectEqual(@as(usize, 0), q.popExpired(10).?.context); // exactly at the deadline
    try expectEqual(@as(?*Timer, null), q.popExpired(10));
    // A late look (a missed tick) delivers all that is overdue.
    try expectEqual(@as(usize, 1), q.popExpired(25).?.context);
    try expectEqual(@as(usize, 2), q.popExpired(25).?.context);
    try expectEqual(@as(?*Timer, null), q.popExpired(25));
}

test "cancel removes a timer from the head, the middle and the end" {
    var q: Queue = .{};
    var t = timers(5);
    for (&t, 0..) |*timer, i| q.add(timer, 10 * (i + 1));
    try expect(t[2].armed);
    try expect(q.cancel(&t[2])); // middle
    try expect(!t[2].armed);
    try expect(q.cancel(&t[0])); // head
    try expect(q.cancel(&t[4])); // end
    try expectEqual(@as(usize, 2), q.count());
    try expectEqual(@as(usize, 1), q.popExpired(100).?.context);
    try expectEqual(@as(usize, 3), q.popExpired(100).?.context);
    try expectEqual(@as(?*Timer, null), q.popExpired(100));
}

test "cancelling a timer that is not pending does nothing" {
    var q: Queue = .{};
    var t = timers(2);
    try expect(!q.cancel(&t[0])); // never armed
    q.add(&t[0], 5);
    q.add(&t[1], 6);
    try expect(q.popExpired(5).? == &t[0]);
    try expect(!q.cancel(&t[0])); // already fired
    try expect(q.cancel(&t[1]));
    try expect(!q.cancel(&t[1])); // already cancelled
    try expectEqual(@as(usize, 0), q.count());
}

test "a timer can be armed again after it fired or was cancelled" {
    var q: Queue = .{};
    var t = timers(1);
    q.add(&t[0], 5);
    try expect(q.popExpired(5).? == &t[0]);
    q.add(&t[0], 9);
    try expect(q.cancel(&t[0]));
    q.add(&t[0], 12);
    try expectEqual(@as(?u64, 12), q.nextDeadline());
    try expect(q.popExpired(12).? == &t[0]);
}

test "random arming, cancelling and expiry agree with a model" {
    const N = 64;
    var q: Queue = .{};
    var t = timers(N);
    // The model: for each timer, its deadline and arming sequence number if pending.
    var pending: [N]?struct { deadline: u64, seq: u64 } = @splat(null);
    var seq: u64 = 0;
    var now: u64 = 0;
    var prng = std.Random.DefaultPrng.init(0x7469_6D65_7273); // fixed seed
    const random = prng.random();

    for (0..100_000) |_| {
        const i = random.uintLessThan(usize, N);
        switch (random.uintLessThan(u8, 10)) {
            0...4 => if (pending[i] == null) {
                const deadline = now + random.uintLessThan(u64, 40);
                q.add(&t[i], deadline);
                seq += 1;
                pending[i] = .{ .deadline = deadline, .seq = seq };
            },
            5...6 => {
                try expectEqual(pending[i] != null, q.cancel(&t[i]));
                pending[i] = null;
            },
            else => {
                now += random.uintLessThan(u64, 6);
                while (q.popExpired(now)) |fired| {
                    // It must be the pending timer with the earliest
                    // deadline, and among equals the one armed first.
                    const got = pending[fired.context].?;
                    try expect(got.deadline <= now);
                    for (pending) |other| {
                        const o = other orelse continue;
                        try expect(o.deadline > got.deadline or (o.deadline == got.deadline and o.seq >= got.seq));
                    }
                    pending[fired.context] = null;
                }
                // Nothing that is due was left behind.
                for (pending) |other| {
                    if (other) |o| try expect(o.deadline > now);
                }
            },
        }
        var count: usize = 0;
        for (pending, 0..) |p, k| {
            try expectEqual(p != null, t[k].armed);
            if (p != null) count += 1;
        }
        try expectEqual(count, q.count());
    }
}
