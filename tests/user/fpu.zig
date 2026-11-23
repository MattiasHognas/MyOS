//! `/test/fpu`: check that the x87, SSE and AVX registers survive thread
//! switches. The kernel test runs two copies at once. Each fills every
//! register with values derived from its thread ID, gives up the CPU (by
//! `sched_yield`, or by spinning until the timer preempts it) so the other
//! copy runs and overwrites them all, and then expects its own values back.
//!
//! Exits with 0 if every round matches, 1 for a mismatch in a round that
//! yields, 2 for one in a round that spins.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;

const regs = @import("fpu_regs.zig");

/// Rounds that switch threads with `sched_yield`.
const YIELD_ROUNDS = 300;
/// Rounds that spin, to be preempted by the timer.
const SPIN_ROUNDS = 24;
/// Loop iterations per spinning round.
const SPINS = 3_000_000;

/// xorshift64*: a small deterministic generator.
fn next(state: *u64) u64 {
    state.* ^= state.* >> 12;
    state.* ^= state.* << 25;
    state.* ^= state.* >> 27;
    return state.* *% 0x2545F4914F6CDD1D;
}

/// Fill `s` with a new register state.
fn fill(s: *regs.State, rng: *u64) void {
    for (&s.vec) |*v| {
        for (std.mem.bytesAsSlice(u64, v)) |*w| w.* = next(rng);
    }
    // A normal 80-bit number: integer bit set, exponent neither 0 nor all ones.
    const mantissa = next(rng) | (1 << 63);
    const exponent: u16 = @intCast(1 + next(rng) % 0x7FFE);
    std.mem.writeInt(u64, s.st0[0..8], mantissa, .little);
    std.mem.writeInt(u16, s.st0[8..10], exponent, .little);
    // All exceptions masked; rounding and precision control vary.
    const r = next(rng);
    s.fcw = 0x003F | @as(u16, @intCast(r & 3)) << 10 | @as(u16, @intCast(r >> 2 & 3)) << 8;
    s.mxcsr = 0x1F80 | @as(u32, @intCast(r >> 4 & 3)) << 13;
}

/// True if `out` holds what was loaded from `in`.
fn same(a: *const regs.State, b: *const regs.State, avx: bool) bool {
    const width: usize = if (avx) 32 else 16;
    for (&a.vec, &b.vec) |*x, *y| {
        if (!std.mem.eql(u8, x[0..width], y[0..width])) return false;
    }
    return std.mem.eql(u8, &a.st0, &b.st0) and a.fcw == b.fcw and a.mxcsr == b.mxcsr;
}

var in: regs.State = undefined;
var out: regs.State = undefined;

/// Program entry point.
export fn _start() callconv(.c) noreturn {
    const avx = regs.avxUsable();
    var rng: u64 = 0x9E3779B97F4A7C15 *% (lib.gettid() + 1);

    for (0..YIELD_ROUNDS) |round| {
        fill(&in, &rng);
        regs.fpu_roundtrip(&in, &out, 0, 1 + round % 3, @intFromBool(avx));
        if (!same(&in, &out, avx)) lib.exit(1);
    }
    for (0..SPIN_ROUNDS) |_| {
        fill(&in, &rng);
        regs.fpu_roundtrip(&in, &out, SPINS, 0, @intFromBool(avx));
        if (!same(&in, &out, avx)) lib.exit(2);
    }
    lib.exit(0);
}
