//! Host tests for the lock order and the record of the locks a CPU holds
//! (`src/kernel/sync/lock_order.zig`).

const std = @import("std");
const lock_order = @import("lock_order");
const Rank = lock_order.Rank;
const Stack = lock_order.Stack;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test "the ranks are in the order docs/locking.md gives" {
    const order = [_]Rank{ .process_tree, .address_space, .descriptor_table, .condition, .condition_nested, .readiness, .timer, .scheduler, .heap_cache, .kernel_region, .page_cache, .page_allocator, .random, .console };
    try expectEqual(std.enums.values(Rank).len, order.len); // a new rank must be placed here too
    for (order[0 .. order.len - 1], order[1..]) |outer, inner| {
        try expect(@backingInt(outer) < @backingInt(inner));
    }
}

test "locks nest from outer to inner and come off in reverse" {
    var s: Stack = .{};
    try expectEqual(0, s.count());
    try expectEqual(null, s.innermost());
    try s.push(.process_tree);
    try s.push(.condition);
    try s.push(.scheduler);
    try s.push(.console);
    try expectEqual(4, s.count());
    try expectEqual(Rank.console, s.innermost().?);
    try expect(s.holds(.condition) and !s.holds(.timer));
    try s.pop(.console);
    try s.pop(.scheduler);
    try expectEqual(Rank.condition, s.innermost().?);
    try s.pop(.condition);
    try s.pop(.process_tree);
    try expectEqual(0, s.count());
}

test "every pair of ranks: allowed exactly when the second is further in" {
    for (std.enums.values(Rank)) |outer| {
        for (std.enums.values(Rank)) |inner| {
            var s: Stack = .{};
            try s.push(outer);
            const result = s.push(inner);
            if (@backingInt(inner) > @backingInt(outer)) {
                try result;
                try expectEqual(2, s.count());
            } else {
                try expectError(error.OutOfOrder, result);
                try expectEqual(1, s.count()); // nothing recorded
            }
        }
    }
}

test "the order is against every lock held, not only the last" {
    var s: Stack = .{};
    try s.push(.condition);
    try s.push(.scheduler);
    try s.pop(.scheduler);
    try expectError(error.OutOfOrder, s.push(.process_tree)); // `condition` is still held
    try expectError(error.OutOfOrder, s.push(.condition)); // the same rank twice
    try s.push(.timer);
}

test "two regions of kernel address space are never held together" {
    var s: Stack = .{};
    try s.push(.kernel_region); // the heap, say
    try expectError(error.OutOfOrder, s.push(.kernel_region)); // the kernel stacks
    try s.push(.page_allocator);
}

test "a lock that is not the innermost cannot be released" {
    var s: Stack = .{};
    try expectError(error.NotInnermost, s.pop(.condition)); // nothing held
    try s.push(.condition);
    try s.push(.timer);
    try expectError(error.NotInnermost, s.pop(.condition));
    try expectError(error.NotInnermost, s.pop(.console)); // not held at all
    try expectEqual(2, s.count());
    try s.pop(.timer);
    try s.pop(.condition);
}

test "the record has room for every rank at once, and no more" {
    const ranks = std.enums.values(Rank);
    try expect(Stack.capacity >= ranks.len);
    var s: Stack = .{};
    for (ranks) |r| try s.push(r);
    try expectEqual(ranks.len, s.count());
    // Ranks only go up, so the record cannot be made to overflow through
    // `push`; fill it by hand to see the bound hold.
    s.len = Stack.capacity;
    s.ranks[Stack.capacity - 1] = @backingInt(Rank.process_tree);
    try expectError(error.TooDeep, s.push(.console));
    try expectEqual(Stack.capacity, s.count());
}
