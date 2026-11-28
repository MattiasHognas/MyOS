//! Futexes: the kernel's half of every lock a threaded program takes.
//!
//! A program's mutex or condition variable is a 32-bit word in its own
//! memory. As long as nobody has to wait, the program changes the word
//! itself and the kernel is not involved. When a thread must wait, it asks
//! the kernel to put it to sleep *if the word still has the value it saw*
//! (`wait`); whoever changes the word wakes sleepers (`wake`). The
//! comparison and the going to sleep are one step as far as wakers can
//! tell, so no wake-up falls between them: that is the whole point.
//!
//! ## How
//!
//! Waiters are found by the address they wait on, in the address space
//! they are in. They hang in a hash table, each as a record on its own
//! kernel stack, and each bucket has a spinlock of its own (as Linux's
//! hash buckets do), so threads waiting on different futexes do not meet
//! on one lock. Taking the bucket's lock is what makes "compare and sleep"
//! atomic against "wake".
//!
//! `requeue` moves waiters from one address to another (condition
//! variables use it, so that a broadcast does not wake every thread only
//! for all but one to sleep again on the mutex), from one bucket to
//! another, holding both locks (the one at the lower address first; the
//! second is `condition_nested` in the lock order), so that a wake on the
//! new address cannot miss them on the way. A waiter's bucket can change
//! while it sleeps (`Waiter.bucket`): it always locks the one it is
//! recorded in, and looks again once it has the lock.
//!
//! The word is read under the bucket's lock, with page faults off: a fault would
//! need the address-space lock, which ranks before this one. So `wait`
//! reads the word once without the lock first, which brings the page in,
//! and tries again in the rare case that it is gone a moment later.
//!
//! A wait ends when the thread is woken, when its timeout runs out, or
//! when its process is ending.

const std = @import("std");

const abi = @import("abi");
const hpet = @import("../drivers/hpet.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const Process = @import("process.zig").Process;
const SpinLock = @import("sync/spinlock.zig").SpinLock;
const thread = @import("thread.zig");
const timer = @import("timer.zig");
const uaccess = @import("uaccess.zig");

/// A bit set that matches every waiter.
pub const ANY: u32 = 0xFFFF_FFFF;

const BUCKETS = 256;

const Bucket = struct {
    lock: SpinLock = .{ .rank = .condition },
    head: ?*Waiter = null,
};

/// One sleeping thread, on its own kernel stack.
const Waiter = struct {
    /// The bucket it is in; changed under the locks of both buckets
    /// (`requeue`), read atomically.
    bucket: *Bucket = undefined,
    /// The address space (a `Process`, by address) and the address waited on.
    space: usize,
    addr: u64,
    /// Which wake-ups it answers to (`FUTEX_WAIT_BITSET`).
    bitset: u32,
    thread: *thread.Thread,
    /// Set by a waker, which has taken the record out of the table.
    woken: bool = false,
    next: ?*Waiter = null,
};

/// Each bucket's lock protects its list and every `Waiter` in it.
var table: [BUCKETS]Bucket = @splat(.{});

fn bucket(space: usize, addr: u64) *Bucket {
    const h = ((addr >> 2) +% space *% 31) *% 0x9E37_79B9_7F4A_7C15;
    return &table[@intCast(h >> 56)];
}

comptime {
    std.debug.assert(BUCKETS == 256); // the top eight bits of the hash
}

/// Put `w` at the end of `b` (waiters are woken in the order they came).
/// `b`'s lock held.
fn insert(b: *Bucket, w: *Waiter) void {
    var link = &b.head;
    while (link.*) |other| link = &other.next;
    w.next = null;
    @atomicStore(*Bucket, &w.bucket, b, .release);
    link.* = w;
}

/// Lock the bucket `w` is in (or moving to): it may change until its lock
/// is held, so look again then.
fn lockOwn(w: *Waiter) *Bucket {
    while (true) {
        const b = @atomicLoad(*Bucket, &w.bucket, .acquire);
        b.lock.take();
        if (@atomicLoad(*Bucket, &w.bucket, .acquire) == b) return b;
        b.lock.drop();
    }
}

/// Take `w` out of its bucket, whose lock is held. False if it is not in
/// it (a waker took it).
fn remove(b: *Bucket, w: *Waiter) bool {
    var link = &b.head;
    while (link.*) |other| : (link = &other.next) {
        if (other != w) continue;
        link.* = w.next;
        w.next = null;
        return true;
    }
    return false;
}

pub const WaitError = error{
    /// The word did not have the expected value: something changed it
    /// already, and the caller looks again instead of sleeping.
    Again,
    /// The time ran out.
    TimedOut,
    /// The word cannot be read.
    Fault,
    /// The thread's process is ending.
    Interrupted,
};

/// Read the 32-bit word at the user address `addr`.
fn readWord(addr: u64) ?u32 {
    var word: u32 = undefined;
    uaccess.copyFromUser(std.mem.asBytes(&word), addr) catch return null;
    return word;
}

/// Sleep until woken on the word at `addr` in the address space of `p`,
/// if that word is `expected` now. `ticks` is the longest to sleep, in
/// timer ticks, or null for no limit.
pub fn wait(p: *Process, addr: u64, expected: u32, bitset: u32, ticks: ?u64) WaitError!void {
    if (addr % 4 != 0) return error.Fault;
    const me = thread.current();
    const space = @intFromPtr(p);
    var waiter: Waiter = .{ .space = space, .addr = addr, .bitset = bitset, .thread = me };
    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        // Bring the page in, and save a sleep that is not wanted anyway.
        if ((readWord(addr) orelse return error.Fault) != expected) return error.Again;

        const home = bucket(space, addr);
        const flags = cpu.saveAndDisableInterrupts();
        defer cpu.restoreInterrupts(flags);
        home.lock.take();
        me.no_fault = true;
        const now = readWord(addr);
        me.no_fault = false;
        if (now == null) {
            // The page went away in between (unmapped, or given back with
            // `madvise`). Rare: start over, which faults it in or fails.
            home.lock.drop();
            if (attempts == 8) return error.Fault;
            continue;
        }
        if (now.? != expected) {
            home.lock.drop();
            return error.Again;
        }

        insert(home, &waiter);
        var timeout = timer.WakeTimer.init(me);
        // One tick more than asked for: the first tick may be about to
        // happen, and a wait must not end before its time.
        if (ticks) |n| timer.add(&timeout.timer, n + 1);
        var b = home;
        while (!waiter.woken and !timeout.hasFired() and !thread.interrupted()) {
            b.lock.drop();
            thread.block();
            b = lockOwn(&waiter);
        }
        if (ticks != null) timeout.finish();
        // Woken and out of time at once counts as woken: the waker counted
        // this thread among those it woke.
        const was_there = remove(b, &waiter);
        b.lock.drop();
        if (!was_there) return;
        return if (timeout.hasFired()) error.TimedOut else error.Interrupted;
    }
}

/// Wake up to `count` threads waiting on the word at `addr` in the
/// address space of `p` whose bit set has a bit in common with `bitset`,
/// longest waiter first. Returns how many were woken.
pub fn wake(p: *Process, addr: u64, count: u32, bitset: u32) u32 {
    const b = bucket(@intFromPtr(p), addr);
    const held = b.lock.acquire();
    defer b.lock.release(held);
    return wakeLocked(b, @intFromPtr(p), addr, count, bitset);
}

/// `wake` in the bucket `b`, whose lock is held.
fn wakeLocked(b: *Bucket, space: usize, addr: u64, count: u32, bitset: u32) u32 {
    var woken: u32 = 0;
    var link = &b.head;
    while (link.*) |w| {
        if (woken == count) break;
        if (w.space != space or w.addr != addr or w.bitset & bitset == 0) {
            link = &w.next;
            continue;
        }
        link.* = w.next;
        w.next = null;
        w.woken = true;
        thread.wake(w.thread); // under the lock: the thread is still in `wait`
        woken += 1;
    }
    return woken;
}

/// Wake up to `wake_count` threads waiting on `addr`, and move up to
/// `move_count` more of them to wait on `to` instead, without waking
/// them. If `expected` is given and the word at `addr` is not that value,
/// nothing is done (`error.Again`). Returns the number woken plus the
/// number moved.
pub fn requeue(p: *Process, addr: u64, wake_count: u32, move_count: u32, to: u64, expected: ?u32) WaitError!u32 {
    if (addr % 4 != 0 or to % 4 != 0) return error.Fault;
    const me = thread.current();
    const space = @intFromPtr(p);
    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        if (expected != null and readWord(addr) == null) return error.Fault;
        const from = bucket(space, addr);
        const dest = bucket(space, to);
        const flags = cpu.saveAndDisableInterrupts();
        defer cpu.restoreInterrupts(flags);
        // Both buckets, the lower address first, so that two requeues
        // between the same two never wait for each other.
        const first = if (@intFromPtr(from) <= @intFromPtr(dest)) from else dest;
        const second = if (first == from) dest else from;
        first.lock.take();
        if (second != first) second.lock.takeNested(.condition_nested);
        defer {
            if (second != first) second.lock.dropNested(.condition_nested);
            first.lock.drop();
        }
        if (expected) |want| {
            me.no_fault = true;
            const now = readWord(addr);
            me.no_fault = false;
            if (now == null) {
                if (attempts == 8) return error.Fault;
                continue; // releases the locks
            }
            if (now.? != want) return error.Again;
        }
        const woken = wakeLocked(from, space, addr, wake_count, ANY);
        var moved: u32 = 0;
        var link = &from.head;
        while (link.*) |w| {
            if (moved == move_count) break;
            if (w.space != space or w.addr != addr) {
                link = &w.next;
                continue;
            }
            link.* = w.next;
            w.addr = to;
            insert(dest, w);
            moved += 1;
        }
        return woken + moved;
    }
}

/// Number of threads waiting on any futex of the address space of `p`.
/// For tests.
pub fn waiting(p: *const Process) usize {
    var n: usize = 0;
    for (&table) |*b| {
        const held = b.lock.acquire();
        defer b.lock.release(held);
        var w = b.head;
        while (w) |waiter| : (w = waiter.next) {
            if (waiter.space == @intFromPtr(p)) n += 1;
        }
    }
    return n;
}

/// Nanoseconds since boot, for timeouts and the clock calls.
pub fn monotonicNanos() u64 {
    return @import("clock.zig").nanos();
}

/// Timer ticks that cover `ns` nanoseconds, rounded up.
pub fn nanosToTicks(ns: u64) u64 {
    return (ns + timer.NS_PER_TICK - 1) / timer.NS_PER_TICK;
}
