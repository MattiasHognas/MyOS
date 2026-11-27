//! The clocks programs read (`clock_gettime` and the like).
//!
//! **Monotonic time** comes from the TSC where the CPU's is invariant (it
//! runs at one rate whatever the CPU's speed and sleep states: CPUID
//! 0x80000007, EDX bit 8), calibrated against the HPET at boot, and from
//! the HPET otherwise. Reading the TSC is an instruction; reading the
//! HPET is a slow access to a device, and runtimes read the clock all the
//! time. Every CPU that comes up checks that its TSC agrees with the boot
//! CPU's (`checkCpu`); if one does not, every CPU goes back to the HPET.
//!
//! The conversion is `ns = base_ns + ((tsc - base_tsc) * mult) >> SHIFT`,
//! with `mult` fixed at calibration: no division when the clock is read.
//!
//! **Wall-clock time** is the RTC's date at boot (`rtc.zig`) plus the
//! monotonic time since; 2026-01-01 if the RTC says nothing usable.

const std = @import("std");

const cpu = @import("../arch/x86_64/cpu.zig");
const hpet = @import("../drivers/hpet.zig");
const rtc = @import("../drivers/rtc.zig");

const log = std.log.scoped(.clock);

const SHIFT = 32;

/// Where the TSC is used, and its calibration. Written once at boot,
/// before any other CPU runs, and `use_tsc` again only to turn it off.
var use_tsc = std.atomic.Value(bool).init(false);
var base_tsc: u64 = 0;
var base_ns: u64 = 0;
var mult: u64 = 0;
var tsc_hz: u64 = 0;

/// Nanoseconds from 1970 to the moment the monotonic clock read 0.
var wall_offset_ns: u64 = 0;
/// 2026-01-01, for a machine whose RTC says nothing usable.
const FALLBACK_EPOCH_SECONDS: u64 = 1_767_225_600;
const NS_PER_SEC: u64 = 1_000_000_000;

/// The TSC, read after everything before it (`lfence`, written as bytes:
/// the kernel is built without SSE2). A plain `rdtsc` may be done ahead
/// of earlier loads, and a time read after seeing another CPU's later one
/// would then come out earlier than it: Linux's `rdtsc_ordered`.
pub inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile (".byte 0x0f, 0xae, 0xe8\nrdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

/// Whether the CPU says its TSC is invariant.
fn invariantTsc() bool {
    if (cpu.cpuid(0x8000_0000, 0).eax < 0x8000_0007) return false;
    return cpu.cpuid(0x8000_0007, 0).edx & (1 << 8) != 0;
}

/// Calibrate the TSC against the HPET (over 50 ms), and read the RTC.
/// Once, on the boot CPU, after `hpet.init`.
pub fn init() void {
    if (invariantTsc()) {
        const t0 = rdtsc();
        const h0 = hpet.nanos();
        hpet.sleepNs(50_000_000);
        const t1 = rdtsc();
        const h1 = hpet.nanos();
        const ticks = t1 - t0;
        const ns = h1 - h0;
        if (ticks > 0 and ns > 0) {
            tsc_hz = @intCast(@as(u128, ticks) * NS_PER_SEC / ns);
            mult = @intCast((@as(u128, ns) << SHIFT) / ticks);
            base_tsc = t1;
            base_ns = h1;
            use_tsc.store(true, .release);
            log.info("TSC: invariant, {d} MHz, the monotonic clock", .{tsc_hz / 1_000_000});
        }
    } else log.info("TSC: not invariant; the monotonic clock is the HPET", .{});

    const now_ns = nanos();
    const secs = rtc.readUnixSeconds() orelse blk: {
        log.warn("RTC: no usable date; the wall clock starts at 2026-01-01", .{});
        break :blk FALLBACK_EPOCH_SECONDS;
    };
    wall_offset_ns = secs * NS_PER_SEC -| now_ns;
}

/// Nanoseconds since boot (more exactly: since the HPET started), on any
/// CPU, never less than a moment before on the same CPU.
pub fn nanos() u64 {
    if (use_tsc.load(.acquire)) {
        const d = rdtsc() -% base_tsc;
        return base_ns + @as(u64, @intCast((@as(u128, d) * mult) >> SHIFT));
    }
    return hpet.nanos();
}

/// Nanoseconds since 1970: the wall clock.
pub fn wallNanos() u64 {
    return wall_offset_ns + nanos();
}

/// Whether the monotonic clock is the TSC (for tests and the boot log).
pub fn usingTsc() bool {
    return use_tsc.load(.acquire);
}

/// The TSC's rate in Hz, 0 if it is not used.
pub fn tscHz() u64 {
    return if (usingTsc()) tsc_hz else 0;
}

/// On a CPU that has just come up, while the boot CPU waits for it: check
/// that its TSC runs with the boot CPU's (`boot_tsc` is what the boot CPU
/// read last, just before this CPU read its own; they must not be more
/// than a few microseconds apart, and never in the wrong order). If they
/// are not, the TSC is not used, here or anywhere.
pub fn checkCpu(boot_tsc: u64) void {
    if (!usingTsc()) return;
    const mine = rdtsc();
    const behind = mine < boot_tsc;
    const apart_ns = if (behind) 0 else @as(u64, @intCast(((@as(u128, mine - boot_tsc)) * mult) >> SHIFT));
    if (behind) disableTsc("a CPU's TSC is behind the boot CPU's");
    if (apart_ns > 5_000_000) disableTsc("a CPU's TSC is far ahead of the boot CPU's"); // 5 ms: far more than the handshake takes
}

/// Go back to the HPET, on every CPU, saying why. Only while CPUs come up,
/// before any program has read the clock.
pub fn disableTsc(why: []const u8) void {
    if (!use_tsc.swap(false, .acq_rel)) return;
    log.warn("TSC: {s}; the monotonic clock is the HPET", .{why});
}
