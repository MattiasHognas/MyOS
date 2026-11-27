//! Counters that are always on: what the kernel spends its time on,
//! cheap enough never to turn off (an `rdtsc` and a few additions to the
//! running CPU's own memory each), so that a slow path is found by
//! looking, not guessing.
//!
//!   /proc/syscalls   per system call, machine-wide: calls, total time,
//!                    and how long they took, in powers of two
//!   /proc/lockstat   per lock class (`lock_order.Rank`): acquisitions that
//!                    had to wait, and how long they waited
//!   /proc/<pid>/schedstat  as Linux's: time running, time ready but not
//!                    running, and time slices, summed over its threads
//!
//! Each CPU counts into its own table (`PerCpu.syscall_stats`, made when
//! it comes up; `PerCpu.lock_contended`), with interrupts off
//! for the few instructions of an update, so no two CPUs write one line
//! and nothing is lost when a thread moves. Reading adds the CPUs up; a
//! read while counting goes on may be a count behind.
//!
//! Times are TSC cycles, shown in nanoseconds (`clock.tscHz`); without an
//! invariant TSC they are shown as cycles.

const std = @import("std");

const abi = @import("abi");
const cpu = @import("../arch/x86_64/cpu.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const heap = @import("heap.zig");
const clock = @import("clock.zig");
const lock_order = @import("sync/lock_order.zig");

/// System-call numbers counted: Linux's x86-64 calls are all below.
pub const SYSCALLS = 512;
/// Latency classes: below 2^(BUCKET0+1) cycles, then each a power of two
/// more, the last one everything above.
pub const BUCKETS = 16;
const BUCKET0 = 6;

pub const SyscallStat = struct {
    count: u64 = 0,
    cycles: u64 = 0,
    buckets: [BUCKETS]u32 = @splat(0),
};

pub const SyscallTable = [SYSCALLS]SyscallStat;

pub inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

fn bucketOf(cycles: u64) usize {
    const log = if (cycles == 0) 0 else 63 - @clz(cycles);
    return @min(BUCKETS - 1, log -| BUCKET0);
}

/// Make the running CPU's table of system calls: when it comes up, so
/// that its memory is there from the start, not taken in the middle of
/// some program's call. Without memory for it, the CPU counts nothing.
pub fn initCpu() void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const c = percpu.currentIfReady() orelse return;
    if (c.syscall_stats != null) return;
    const t = heap.allocator.create(SyscallTable) catch return;
    t.* = @splat(.{});
    c.syscall_stats = t;
}

/// A system call `number` took `cycles`: count it on this CPU.
pub fn syscall(number: u64, cycles: u64) void {
    if (number >= SYSCALLS) return;
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const c = percpu.currentIfReady() orelse return;
    const table: *SyscallTable = @ptrCast(@alignCast(c.syscall_stats orelse return));
    const s = &table[@intCast(number)];
    s.count += 1;
    s.cycles += cycles;
    s.buckets[bucketOf(cycles)] += 1;
}

/// A lock of `rank` was taken after waiting `cycles` for it. Interrupts
/// are off (the lock is being taken).
pub fn contended(rank: lock_order.Rank, cycles: u64) void {
    const c = percpu.currentIfReady() orelse return;
    const i = @backingInt(rank);
    c.lock_contended[i] +%= 1;
    c.lock_wait_cycles[i] +%= cycles;
}

/// Cycles as nanoseconds, if the TSC's rate is known.
pub fn toNs(cycles: u64) u64 {
    const hz = clock.tscHz();
    if (hz == 0) return cycles;
    return @intCast(@as(u128, cycles) * std.time.ns_per_s / hz);
}

/// The name Linux gives system call `n`, where MyOS knows it.
fn syscallName(n: usize) ?[]const u8 {
    const names = comptime blk: {
        @setEvalBranchQuota(100_000);
        var table: [SYSCALLS]?[]const u8 = @splat(null);
        for (std.meta.declarations(abi.Sys)) |d| {
            const v = @field(abi.Sys, d);
            if (@TypeOf(v) != comptime_int or v < 0 or v >= SYSCALLS) continue;
            if (table[v] == null) table[v] = d;
        }
        break :blk table;
    };
    return names[n];
}

/// The text of `/proc/syscalls`: a line for each call made since boot,
/// with its total and average time in nanoseconds and the count in each
/// latency class (the first below 128 cycles, each next one twice as
/// long), all CPUs added up.
pub fn syscallReport(allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# number name calls total_ns avg_ns buckets(<128 cycles, then x2 each)\n");
    const sums = try allocator.create(SyscallTable);
    defer allocator.destroy(sums);
    sums.* = @splat(.{});
    for (0..percpu.count()) |i| {
        const table: *const SyscallTable = @ptrCast(@alignCast(percpu.get(i).syscall_stats orelse continue));
        for (table, sums) |s, *sum| {
            sum.count += s.count;
            sum.cycles += s.cycles;
            for (s.buckets, &sum.buckets) |b, *sb| sb.* += b;
        }
    }
    for (sums, 0..) |s, n| {
        if (s.count == 0) continue;
        try out.print(allocator, "{d} {s} {d} {d} {d}", .{ n, syscallName(n) orelse "?", s.count, toNs(s.cycles), toNs(s.cycles / s.count) });
        for (s.buckets) |b| try out.print(allocator, " {d}", .{b});
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// The text of `/proc/lockstat`: for each lock class that had to wait,
/// how often and for how long in all, all CPUs added up.
pub fn lockReport(allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# class contended wait_ns\n");
    inline for (comptime std.enums.values(lock_order.Rank)) |rank| {
        var n: u64 = 0;
        var cycles: u64 = 0;
        for (0..percpu.count()) |i| {
            const c = percpu.get(i);
            n += c.lock_contended[@backingInt(rank)];
            cycles += c.lock_wait_cycles[@backingInt(rank)];
        }
        try out.print(allocator, "{s} {d} {d}\n", .{ @tagName(rank), n, toNs(cycles) });
    }
    return out.toOwnedSlice(allocator);
}
