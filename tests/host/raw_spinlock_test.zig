//! Host tests for the atomic core of the kernel's spinlock
//! (`src/kernel/sync/raw_spinlock.zig`), with real threads on real CPUs:
//! the one place the lock can be tested under true parallelism before the
//! kernel runs on several cores.

const std = @import("std");
const RawSpinLock = @import("raw_spinlock").RawSpinLock;
const expect = std.testing.expect;

test "a free lock can be taken once" {
    var lock: RawSpinLock = .{};
    try expect(!lock.isLocked());
    try expect(lock.tryLock());
    try expect(lock.isLocked());
    try expect(!lock.tryLock()); // held
    try expect(!lock.tryLock());
    lock.unlock();
    try expect(!lock.isLocked());
    try expect(lock.tryLock()); // free again
    lock.unlock();
}

test "lockBounded gives up on a lock that stays held" {
    var lock: RawSpinLock = .{};
    try expect(lock.lockBounded(10));
    try expect(!lock.lockBounded(0));
    try expect(!lock.lockBounded(1000));
    try expect(lock.isLocked()); // giving up did not disturb the holder
    lock.unlock();
    try expect(lock.lockBounded(0)); // a free lock needs no spinning
    lock.unlock();
}

const Shared = struct {
    lock: RawSpinLock = .{},
    /// Deliberately not atomic: only the lock makes the updates safe.
    counter: u64 = 0,
    /// Threads inside the critical section right now.
    inside: u32 = 0,
    overlaps: std.atomic.Value(u32) = .init(0),
};

const ROUNDS = 200_000;

fn worker(shared: *Shared) void {
    for (0..ROUNDS) |_| {
        if (!shared.lock.lockBounded(std.math.maxInt(usize))) unreachable;
        shared.inside += 1;
        if (shared.inside != 1) _ = shared.overlaps.fetchAdd(1, .monotonic);
        const seen = shared.counter;
        std.atomic.spinLoopHint(); // widen the window a lost update needs
        shared.counter = seen + 1;
        shared.inside -= 1;
        shared.lock.unlock();
    }
}

test "threads on several CPUs never hold the lock together" {
    var shared: Shared = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, worker, .{&shared});
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 0), shared.overlaps.load(.monotonic));
    try std.testing.expectEqual(@as(u64, threads.len * ROUNDS), shared.counter); // no update lost
    try expect(!shared.lock.isLocked());
}
