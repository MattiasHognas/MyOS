//! A small explicit-state model checker.
//!
//! A model is a state and a fixed set of actions, each of which either
//! turns a state into the next one or is not enabled in it. `check` visits
//! every state that can be reached from the initial one, by every order in
//! which the actions can happen, and reports the first of:
//!
//! - **invariant**: a reachable state the model's `invariant` rejects;
//! - **stuck**: a state in which no action is enabled although the model is
//!   not `finished` (a deadlock, or a wake-up that never comes);
//! - **cannot_finish**: a state from which no finished state can be reached
//!   any more, whatever happens next (the model can only go round in
//!   circles from there).
//!
//! With the failure comes the shortest sequence of actions that leads to it
//! (the search is breadth first).
//!
//! What this is for: the kernel's blocking and locking protocols are a
//! handful of variables and steps per thread, and their bugs are orders of
//! events nobody thought of. A model of such a protocol has a few thousand
//! states, so every order can be tried. The models are in `tests/models/`.
//!
//! What it does not do: it checks a model, not the kernel's code, so a
//! model has to be kept in step with the code it describes. And it has no
//! notion of fairness: "this always happens eventually" is checked only as
//! the two conditions above (nothing gets stuck, and finishing always stays
//! possible), which is enough for protocols that take a bounded number of
//! steps.
//!
//! A model is a type with:
//!
//! - `State`: plain data (integers, enums, booleans, arrays and structs of
//!   them), compared and hashed field by field;
//! - `action_count`: how many actions there are, numbered from 0;
//! - `initial() State`;
//! - `step(state, action) ?State`: the state after `action`, or null if it
//!   is not enabled. Everything an action does happens at once, so one
//!   action is one step that nothing can interleave with;
//! - `invariant(state) ?[]const u8`: null, or what is wrong with the state;
//! - `finished(state) bool`: whether this is a state the model may end in;
//! - `actionName(action) []const u8`: for printing a trace.

const std = @import("std");

/// What kind of problem `check` found.
pub const Kind = enum { invariant, stuck, cannot_finish };

/// A problem found by `check`.
pub const Failure = struct {
    kind: Kind,
    /// What `invariant` said; empty for the other kinds.
    message: []const u8,
    /// The actions that lead from the initial state to the failing one.
    trace: []const usize,
};

/// What `check` returns.
pub fn Result(comptime Model: type) type {
    return struct {
        /// Number of distinct states visited.
        states: usize,
        /// The first problem found, or null if there is none.
        failure: ?Failure,
        /// The state the failure is in.
        failing_state: ?Model.State,
        gpa: std.mem.Allocator,

        pub fn deinit(self: *@This()) void {
            if (self.failure) |f| self.gpa.free(f.trace);
            self.* = undefined;
        }

        /// The kind of failure, or null: for comparing with what a test expects.
        pub fn kind(self: *const @This()) ?Kind {
            return if (self.failure) |f| f.kind else null;
        }

        /// Print the failure and the actions that lead to it, for a test
        /// that did not expect one.
        pub fn dump(self: *const @This()) void {
            const f = self.failure orelse return std.debug.print("no failure in {d} states\n", .{self.states});
            std.debug.print("{t} after {d} steps ({d} states visited){s}{s}\n", .{
                f.kind,                              f.trace.len, self.states,
                if (f.message.len > 0) ": " else "", f.message,
            });
            for (f.trace, 1..) |action, n| std.debug.print("  {d:>3}. {s}\n", .{ n, Model.actionName(action) });
            std.debug.print("  state: {any}\n", .{self.failing_state.?});
        }
    };
}

/// Too many states: the model is larger than `max_states`.
pub const Error = error{ TooManyStates, OutOfMemory };

/// Visit every reachable state of `Model` (at most `max_states`) and report
/// the first failure, or none. Free the result with `deinit`.
pub fn check(comptime Model: type, gpa: std.mem.Allocator, max_states: usize) Error!Result(Model) {
    const State = Model.State;
    const none = std.math.maxInt(u32);

    var states: std.ArrayList(State) = .empty;
    defer states.deinit(gpa);
    // How each state was first reached: from which state, by which action.
    var parents: std.ArrayList(u32) = .empty;
    defer parents.deinit(gpa);
    var via: std.ArrayList(u32) = .empty;
    defer via.deinit(gpa);
    // The states each state leads to: `edges[edge_start[i]..edge_start[i + 1]]`.
    var edges: std.ArrayList(u32) = .empty;
    defer edges.deinit(gpa);
    var edge_start: std.ArrayList(u32) = .empty;
    defer edge_start.deinit(gpa);
    var ids = std.AutoHashMap(State, u32).init(gpa);
    defer ids.deinit();

    const first = Model.initial();
    try states.append(gpa, first);
    try parents.append(gpa, none);
    try via.append(gpa, 0);
    try ids.put(first, 0);

    var found: ?struct { kind: Kind, message: []const u8, state: u32 } = null;

    var next: u32 = 0;
    search: while (next < states.items.len) : (next += 1) {
        const state = states.items[next];
        try edge_start.append(gpa, @intCast(edges.items.len));
        if (Model.invariant(state)) |message| {
            found = .{ .kind = .invariant, .message = message, .state = next };
            break :search;
        }
        var enabled = false;
        for (0..Model.action_count) |action| {
            const after = Model.step(state, action) orelse continue;
            enabled = true;
            const entry = try ids.getOrPut(after);
            if (!entry.found_existing) {
                if (states.items.len >= max_states) return error.TooManyStates;
                entry.value_ptr.* = @intCast(states.items.len);
                try states.append(gpa, after);
                try parents.append(gpa, next);
                try via.append(gpa, @intCast(action));
            }
            try edges.append(gpa, entry.value_ptr.*);
        }
        if (!enabled and !Model.finished(state)) {
            found = .{ .kind = .stuck, .message = "", .state = next };
            break :search;
        }
    }

    // Every state must still be able to reach a finished one. Work
    // backwards: a state can if it is finished or leads to one that can.
    if (found == null) {
        try edge_start.append(gpa, @intCast(edges.items.len));
        const can = try gpa.alloc(bool, states.items.len);
        defer gpa.free(can);
        for (states.items, can) |state, *c| c.* = Model.finished(state);
        var changed = true;
        while (changed) {
            changed = false;
            var i = states.items.len;
            while (i > 0) {
                i -= 1;
                if (can[i]) continue;
                for (edges.items[edge_start.items[i]..edge_start.items[i + 1]]) |to| {
                    if (!can[to]) continue;
                    can[i] = true;
                    changed = true;
                    break;
                }
            }
        }
        for (can, 0..) |c, i| {
            if (c) continue;
            found = .{ .kind = .cannot_finish, .message = "", .state = @intCast(i) };
            break;
        }
    }

    const f = found orelse return .{ .states = states.items.len, .failure = null, .failing_state = null, .gpa = gpa };

    // The way there, last action first, then turned round.
    var trace: std.ArrayList(usize) = .empty;
    errdefer trace.deinit(gpa);
    var at = f.state;
    while (parents.items[at] != none) : (at = parents.items[at]) try trace.append(gpa, via.items[at]);
    std.mem.reverse(usize, trace.items);
    return .{
        .states = states.items.len,
        .failure = .{ .kind = f.kind, .message = f.message, .trace = try trace.toOwnedSlice(gpa) },
        .failing_state = states.items[f.state],
        .gpa = gpa,
    };
}

// ---------------------------------------------------------------------------
// Tests of the checker itself, on models small enough to work out by hand.

const testing = std.testing;

/// Two counters, each of which may be raised up to `limit`. Finished when
/// both are there. With `forbidden`, the state where both are 1 breaks the
/// invariant; with `stuck_at_one`, nothing can move once both are 1.
fn Counters(comptime limit: u8, comptime forbidden: bool, comptime stuck_at_one: bool) type {
    return struct {
        pub const State = struct { a: u8, b: u8 };
        pub const action_count = 2;
        pub fn initial() State {
            return .{ .a = 0, .b = 0 };
        }
        pub fn step(s: State, action: usize) ?State {
            if (stuck_at_one and s.a == 1 and s.b == 1) return null; // nothing moves from here
            switch (action) {
                0 => return if (s.a < limit) .{ .a = s.a + 1, .b = s.b } else null,
                else => return if (s.b < limit) .{ .a = s.a, .b = s.b + 1 } else null,
            }
        }
        pub fn invariant(s: State) ?[]const u8 {
            return if (forbidden and s.a == 1 and s.b == 1) "both are 1" else null;
        }
        pub fn finished(s: State) bool {
            return s.a == limit and s.b == limit;
        }
        pub fn actionName(action: usize) []const u8 {
            return if (action == 0) "raise a" else "raise b";
        }
    };
}

test "every state is visited once" {
    var r = try check(Counters(3, false, false), testing.allocator, 1000);
    defer r.deinit();
    try testing.expectEqual(@as(?Kind, null), r.kind());
    try testing.expectEqual(@as(usize, 16), r.states); // 4 values of a times 4 of b
}

test "an invariant violation comes with the shortest way to it" {
    var r = try check(Counters(3, true, false), testing.allocator, 1000);
    defer r.deinit();
    try testing.expectEqual(@as(?Kind, .invariant), r.kind());
    try testing.expectEqualStrings("both are 1", r.failure.?.message);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, r.failure.?.trace); // raise a, raise b
    try testing.expectEqual(@as(u8, 1), r.failing_state.?.a);
}

test "a state where nothing can move and the model is not finished is stuck" {
    var r = try check(Counters(3, false, true), testing.allocator, 1000);
    defer r.deinit();
    try testing.expectEqual(@as(?Kind, .stuck), r.kind());
    try testing.expectEqual(@as(usize, 2), r.failure.?.trace.len);
}

/// A light that can be switched on and off for ever, and a door that can be
/// closed once. Finished means: door closed with the light on. With
/// `jam`, closing the door with the light off also breaks the switch off,
/// after which the light only blinks between two "off" states: nothing is
/// stuck, yet it can never finish.
fn Blinker(comptime jam: bool) type {
    return struct {
        pub const State = struct { light: bool, door_closed: bool, jammed: bool, tick: bool };
        pub const action_count = 2;
        pub fn initial() State {
            return .{ .light = false, .door_closed = false, .jammed = false, .tick = false };
        }
        pub fn step(s: State, action: usize) ?State {
            var n = s;
            switch (action) {
                0 => if (s.jammed) {
                    n.tick = !s.tick; // still "moves", but the light stays off
                } else {
                    n.light = !s.light;
                },
                else => {
                    if (s.door_closed) return null;
                    n.door_closed = true;
                    if (jam and !s.light) n.jammed = true;
                },
            }
            return n;
        }
        pub fn invariant(_: State) ?[]const u8 {
            return null;
        }
        pub fn finished(s: State) bool {
            return s.door_closed and s.light;
        }
        pub fn actionName(action: usize) []const u8 {
            return if (action == 0) "switch" else "close the door";
        }
    };
}

test "going round in circles is fine as long as finishing stays possible" {
    var r = try check(Blinker(false), testing.allocator, 1000);
    defer r.deinit();
    try testing.expectEqual(@as(?Kind, null), r.kind());
}

test "a state from which the model can never finish is reported" {
    var r = try check(Blinker(true), testing.allocator, 1000);
    defer r.deinit();
    try testing.expectEqual(@as(?Kind, .cannot_finish), r.kind());
    try testing.expect(r.failing_state.?.jammed);
}

test "a model larger than the limit is an error, not a wrong answer" {
    try testing.expectError(error.TooManyStates, check(Counters(100, false, false), testing.allocator, 50));
}
