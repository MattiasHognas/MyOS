//! A sampling profiler, in kernels built to be benchmarked (`-Dbench`):
//! every timer tick, each CPU notes where it was interrupted, and
//! `/proc/profile` lists the kernel functions the samples fell in, most
//! first. What it says is where the kernel spends its time, which the
//! counters of `stats.zig` cannot (they say which calls are slow, not
//! why).
//!
//! Samples go into a ring per CPU (`RING` of them, the oldest overwritten),
//! made when the CPU comes up; a sample in user mode is counted as
//! `[user]`, one in the idle loop under its function's name. At the tick's
//! rate (`timer.HZ`) a benchmark run of a few minutes gives some ten
//! thousand samples a CPU.

const std = @import("std");
const build_options = @import("build_options");

const cpu = @import("../arch/x86_64/cpu.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const heap = @import("heap.zig");
const backtrace = @import("debug/backtrace.zig");

pub const enabled = build_options.profile;

/// Samples kept per CPU.
pub const RING = 16384;

const Ring = struct {
    next: u64 = 0,
    rips: [RING]u64 = @splat(0),
};

/// Make the running CPU's ring. Without memory for it, the CPU is not sampled.
pub fn initCpu() void {
    if (!enabled) return;
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const c = percpu.currentIfReady() orelse return;
    if (c.profile_ring != null) return;
    const r = heap.allocator.create(Ring) catch return;
    r.* = .{};
    c.profile_ring = r;
}

/// The timer interrupted this CPU at `rip`, in user mode if `user`. From
/// the interrupt handler.
pub fn sample(rip: u64, user: bool) void {
    if (!enabled) return;
    const c = percpu.currentIfReady() orelse return;
    const r: *Ring = @ptrCast(@alignCast(c.profile_ring orelse return));
    r.rips[r.next % RING] = if (user) 0 else rip;
    r.next += 1;
}

/// The text of `/proc/profile`: the functions with the most samples, with
/// their counts and share, all CPUs together.
pub fn report(allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (!enabled) {
        try out.appendSlice(allocator, "# not sampled: a kernel built with -Dbench samples\n");
        return out.toOwnedSlice(allocator);
    }
    // Every sample as the name of its function, then counted by sorting
    // (a name is at one address per function).
    const Name = struct { ptr: usize, len: usize };
    var names: std.ArrayList(Name) = .empty;
    defer names.deinit(allocator);
    for (0..percpu.count()) |cpu_index| {
        const r: *const Ring = @ptrCast(@alignCast(percpu.get(cpu_index).profile_ring orelse continue));
        const n = @min(r.next, RING);
        for (r.rips[0..n]) |rip| {
            const name: []const u8 = if (rip == 0) "[user]" else if (backtrace.symbolize(rip)) |sym| sym.name else "[unknown]";
            try names.append(allocator, .{ .ptr = @intFromPtr(name.ptr), .len = name.len });
        }
    }
    const total = names.items.len;
    std.mem.sort(Name, names.items, {}, struct {
        fn less(_: void, a: Name, b: Name) bool {
            return a.ptr < b.ptr;
        }
    }.less);
    const Entry = struct { name: Name, count: usize };
    var counted: std.ArrayList(Entry) = .empty;
    defer counted.deinit(allocator);
    var i: usize = 0;
    while (i < names.items.len) {
        var j = i;
        while (j < names.items.len and names.items[j].ptr == names.items[i].ptr) j += 1;
        try counted.append(allocator, .{ .name = names.items[i], .count = j - i });
        i = j;
    }
    std.mem.sort(Entry, counted.items, {}, struct {
        fn more(_: void, a: Entry, b: Entry) bool {
            return a.count > b.count;
        }
    }.more);
    try out.print(allocator, "# samples {d}\n# count percent function\n", .{total});
    for (counted.items[0..@min(counted.items.len, 60)]) |e| {
        const name = @as([*]const u8, @ptrFromInt(e.name.ptr))[0..e.name.len];
        try out.print(allocator, "{d} {d:.1} {s}\n", .{ e.count, @as(f64, @floatFromInt(e.count * 100)) / @as(f64, @floatFromInt(@max(total, 1))), name });
    }
    return out.toOwnedSlice(allocator);
}
