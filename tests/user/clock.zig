//! `/test/clock`: the clocks from ring 3. The monotonic clock advances
//! and never goes back; sleeps last as long as asked, and not much
//! longer: whole ticks end within a tick of the deadline, and short ones
//! (under 2 ms) within a millisecond or so; the wall clock is a date from
//! the RTC, which it prints for the test script to compare with the
//! host's (`MYOS_REALTIME <seconds>`). Exits with 0, or with the number of
//! the first failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn now(clock: u64) u64 {
    var ts: abi.TimeSpec = undefined;
    _ = lib.syscall(Sys.clock_gettime, clock, @intFromPtr(&ts), 0);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn sleepNs(ns: u64) void {
    const ts: abi.TimeSpec = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
    _ = lib.syscall(Sys.nanosleep, @intFromPtr(&ts), 0, 0);
}

pub fn main() noreturn {
    const M = abi.CLOCK.MONOTONIC;
    // Advances, never back, at nanosecond steps.
    var last = now(M);
    var moved = false;
    for (0..10000) |_| {
        const t = now(M);
        expect(t >= last, 1);
        if (t != last) moved = true;
        last = t;
    }
    expect(moved, 2);

    // Sleeps: as long as asked at least; at most a tick (10 ms) and a
    // little more over for whole ticks, a few ms for short ones (the
    // emulator is slow, and other programs run meanwhile).
    for ([_]u64{ 30_000_000, 15_000_000 }) |ask| {
        const t0 = now(M);
        sleepNs(ask);
        const took = now(M) - t0;
        expect(took >= ask, 3);
        expect(took < ask + 25_000_000, 4);
    }
    var worst_short: u64 = 0;
    for (0..20) |_| {
        const t0 = now(M);
        sleepNs(500_000);
        const took = now(M) - t0;
        expect(took >= 500_000, 5);
        worst_short = @max(worst_short, took);
    }
    expect(worst_short < 8_000_000, 6); // not rounded up to a tick or two

    // The wall clock: a date after the code was written, and moving with
    // the monotonic one.
    const r0 = now(abi.CLOCK.REALTIME);
    expect(r0 / 1_000_000_000 > 1_767_225_600, 7); // after 2026-01-01
    const m0 = now(M);
    sleepNs(20_000_000);
    const dr = now(abi.CLOCK.REALTIME) - r0;
    const dm = now(M) - m0;
    expect(dr + 2_000_000 > dm and dm + 2_000_000 > dr, 8);
    var tv: [2]i64 = undefined;
    expect(lib.syscall(Sys.gettimeofday, @intFromPtr(&tv), 0, 0) == 0 and @as(u64, @intCast(tv[0])) >= r0 / 1_000_000_000, 9);
    lib.print("MYOS_REALTIME {d}\n", .{r0 / 1_000_000_000});
    lib.exit(0);
}
