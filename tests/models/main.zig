//! Model checks of the kernel's blocking protocols for several CPUs.
//!
//! Each model (`sleep_wake.zig`, `timeout.zig`, `mutex.zig`) describes a
//! protocol as `docs/locking.md` says it works, and is checked here in
//! every order its steps can happen (`tools/modelcheck`). Each rule the
//! protocol depends on can be switched off, and for each there is a test
//! that expects the check to fail then, and how: a model that could not
//! fail would prove nothing.
//!
//! Run with `zig build check-models`.

const std = @import("std");
const testing = std.testing;
const modelcheck = @import("modelcheck");

const sleep_wake = @import("sleep_wake.zig");
const timeout = @import("timeout.zig");
const mutex = @import("mutex.zig");

/// More than any model here needs; reaching it means a model grew by mistake.
const max_states = 2_000_000;

/// Check `Model` and expect the outcome `want` (null: no failure). On any
/// other outcome, print what was found and the steps that lead to it.
fn expectOutcome(comptime Model: type, want: ?modelcheck.Kind) !void {
    var result = try modelcheck.check(Model, testing.allocator, max_states);
    defer result.deinit();
    if (result.kind() != want) {
        result.dump();
        return error.UnexpectedOutcome;
    }
}

/// As `expectOutcome` for an invariant violation, which must be `message`.
fn expectViolation(comptime Model: type, message: []const u8) !void {
    var result = try modelcheck.check(Model, testing.allocator, max_states);
    defer result.deinit();
    if (result.kind() != .invariant or !std.mem.eql(u8, result.failure.?.message, message)) {
        result.dump();
        return error.UnexpectedOutcome;
    }
}

test "sleep and wake: no wake-up lost, no thread queued twice or on two CPUs" {
    try expectOutcome(sleep_wake.Model(.{}), null);
}

test "sleep and wake: checking the condition outside the lock loses a wake-up" {
    try expectOutcome(sleep_wake.Model(.{ .check_under_lock = false }), .stuck);
}

test "sleep and wake: releasing the scheduler lock before the switch puts a thread on two CPUs" {
    try expectViolation(sleep_wake.Model(.{ .hold_across_switch = false, .wake_idle_in_place = false }), "a thread runs on two CPUs at once");
}

test "sleep and wake: releasing the scheduler lock before the switch strands a thread woken in place" {
    // "Blocked, with a CPU on its stack" means "idling" only because the
    // lock covers the switch. Without that, the waker can find a thread
    // that is just leaving, tell it to carry on, and nobody ever runs it.
    try expectOutcome(sleep_wake.Model(.{ .hold_across_switch = false }), .stuck);
}

test "sleep and wake: without timeouts, waking after releasing the condition's lock is safe too" {
    // A waiter that joined the queue blocks exactly once for it and cannot
    // leave before it is woken, so the waker never finds it gone. With
    // timeouts that is no longer true: see the timeout model.
    try expectOutcome(sleep_wake.Model(.{ .wake_under_lock = false }), null);
}

test "sleep and wake: waking a thread whose CPU idles on its stack as if it had left puts it on two CPUs" {
    try expectViolation(sleep_wake.Model(.{ .wake_idle_in_place = false }), "a thread runs on two CPUs at once");
}

test "timeout: the waiter returns, knows whether it was woken, and is not touched afterwards" {
    try expectOutcome(timeout.Model(.{}), null);
}

test "timeout: a callback the waiter does not wait for touches the waiter after it returned" {
    // The shortest way there ends in a wake of the thread that has gone;
    // a write to the timer in its dead stack frame is a few steps further.
    try expectViolation(timeout.Model(.{ .callback = .unsynchronized }), "a thread was woken after it had gone");
}

test "timeout: one flag set before the wake lets the waiter go while the callback still wakes it" {
    try expectViolation(timeout.Model(.{ .callback = .one_flag_before_wake }), "a thread was woken after it had gone");
}

test "timeout: one flag set after the wake loses the wake-up" {
    try expectOutcome(timeout.Model(.{ .callback = .one_flag_after_wake }), .stuck);
}

test "timeout: waking after releasing the condition's lock wakes a thread that has gone" {
    try expectViolation(timeout.Model(.{ .wake_under_lock = false }), "a thread was woken after it had gone");
}

test "mutex: one owner at a time, and every thread gets in" {
    try expectOutcome(mutex.Model(.{}), null);
}

test "mutex: looking and taking in two steps lets two threads in" {
    try expectOutcome(mutex.Model(.{ .internal_lock = false }), .invariant);
}
