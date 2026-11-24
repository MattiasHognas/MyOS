//! The kernel's random-number generator.
//!
//! Stack-protector canaries and address randomization draw from it now;
//! `AT_RANDOM` and `getrandom` will. `bytes` and `int` never block and can
//! be called from any context once `init` has run.
//!
//! Where the randomness comes from, best first:
//!
//! 1. **RDSEED**: the CPU's hardware entropy source.
//! 2. **RDRAND**: the CPU's own generator, seeded from that source.
//! 3. **Timing**: the low bits of the time-stamp counter, read around
//!    operations whose duration varies (port I/O, and later interrupts).
//!    Weak on its own, and weaker still in an emulator.
//!
//! Everything found is mixed into one generator (`random_core.zig`), so
//! the result is at least as unpredictable as the best source. If the CPU has
//! neither instruction, the seed rests on timing alone: `init` says so in
//! the log, and `hardwareSeeded` returns false. On real hardware made
//! after 2012 that does not happen.
//!
//! The generator is reseeded from the hardware source every `RESEED_BYTES`
//! of output, and whenever `addEntropy` is given something new.

const std = @import("std");
const cpu = @import("../arch/x86_64/cpu.zig");
const core = @import("random_core.zig");
const SpinLock = @import("sync/spinlock.zig").SpinLock;
const log = std.log.scoped(.random);

/// Output after which fresh hardware entropy is mixed in.
const RESEED_BYTES = 1 << 20;
/// Hardware values taken per seed: 8 x 64 bits.
const HW_WORDS = 8;
/// Timing samples taken per seed.
const TIMING_SAMPLES = 256;

var lock: SpinLock = .{ .rank = .random };
var generator: core.Generator = .init(@splat(0));
var ready = false;
var has_rdseed = false;
var has_rdrand = false;

/// Where `collect` gathers its samples before mixing them in at once. Static:
/// 2 KiB is too much for a kernel stack frame. Guarded by `lock`, or by
/// running before there are threads.
var samples: [2 * HW_WORDS + TIMING_SAMPLES]u64 = undefined;

/// True once `init` has run.
pub fn isReady() bool {
    return ready;
}

/// True if the seed includes hardware random numbers (RDSEED or RDRAND).
pub fn hardwareSeeded() bool {
    return has_rdseed or has_rdrand;
}

/// One value from RDSEED (`seed`) or RDRAND, or null if the CPU had none
/// ready after a few tries. The instructions are written as bytes, since
/// the assembler would want a feature flag: `rdseed %rax` / `rdrand %rax`.
fn hardwareWord(seed: bool) ?u64 {
    for (0..16) |_| {
        var ok: u8 = undefined;
        const value = if (seed) asm volatile (
            \\ .byte 0x48, 0x0f, 0xc7, 0xf8
            \\ setc %[ok]
            : [value] "={rax}" (-> u64),
              [ok] "=r" (ok),
        ) else asm volatile (
            \\ .byte 0x48, 0x0f, 0xc7, 0xf0
            \\ setc %[ok]
            : [value] "={rax}" (-> u64),
              [ok] "=r" (ok),
        );
        if (ok != 0) return value;
        std.atomic.spinLoopHint();
    }
    return null;
}

/// The time-stamp counter.
fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

/// Mix everything available into `g`: hardware values if `use_hardware`
/// and the CPU has them, and always timing. Returns the number of
/// hardware words obtained. The caller holds `lock` (or runs before there
/// are threads).
fn collect(g: *core.Generator, use_hardware: bool) usize {
    var n: usize = 0;
    if (use_hardware) {
        for ([_]bool{ true, false }) |seed| {
            if (!(if (seed) has_rdseed else has_rdrand)) continue;
            for (0..HW_WORDS) |_| {
                samples[n] = hardwareWord(seed) orelse break;
                n += 1;
            }
        }
    }
    const words = n;
    // Port 0x80 is the POST diagnostic port: writing to it does nothing
    // but takes a bus cycle of uncertain length.
    for (0..TIMING_SAMPLES) |_| {
        cpu.outb(0x80, 0);
        samples[n] = rdtsc();
        n += 1;
    }
    g.mix(std.mem.sliceAsBytes(samples[0..n]));
    @memset(&samples, 0); // do not leave seed material lying around
    return words;
}

/// Seed the generator. Called once, early in boot; needs no memory
/// allocation and no interrupts.
pub fn init() void {
    const leaf1 = cpu.cpuid(1, 0);
    has_rdrand = leaf1.ecx & (1 << 30) != 0;
    has_rdseed = cpu.cpuid(0, 0).eax >= 7 and cpu.cpuid(7, 0).ebx & (1 << 18) != 0;

    const words = collect(&generator, true);
    ready = true;
    if (words > 0) {
        log.info("seeded from {s} ({d} hardware words) and timing", .{ if (has_rdseed) "RDSEED and RDRAND" else "RDRAND", words });
    } else {
        log.warn("no hardware random numbers (RDSEED, RDRAND): seeded from timing only, which is weak", .{});
    }
}

/// Mix `data` into the generator: anything an attacker could not fully
/// predict (interrupt timing, device data). Never harmful, whatever it is.
pub fn addEntropy(data: []const u8) void {
    const held = lock.acquire();
    defer lock.release(held);
    generator.mix(data);
    generator.mix(std.mem.asBytes(&rdtsc()));
}

/// Fill `buf` with random bytes.
pub fn bytes(buf: []u8) void {
    const held = lock.acquire();
    defer lock.release(held);
    if (!ready) @panic("random: used before init");
    if (generator.produced >= RESEED_BYTES) _ = collect(&generator, true);
    generator.fill(buf);
}

/// A random value of the unsigned integer type `T`.
pub fn int(comptime T: type) T {
    var buf: [@sizeOf(T)]u8 = undefined;
    bytes(&buf);
    return std.mem.readInt(T, &buf, .little);
}

/// A random value in `0..bound` (`bound` not included), without bias.
pub fn below(bound: u64) u64 {
    std.debug.assert(bound != 0);
    // Reject the values above the largest multiple of `bound`.
    const limit = std.math.maxInt(u64) - std.math.maxInt(u64) % bound;
    while (true) {
        const value = int(u64);
        if (value < limit) return value % bound;
    }
}

/// Scratch generator for `timingOnlyOutput`. Static: a generator's state is
/// too large for a kernel stack frame. Guarded by `lock`.
var timing_generator: core.Generator = .init(@splat(0));

/// For tests: 32 bytes from a generator fed by timing alone, as on a CPU
/// without RDSEED and RDRAND.
pub fn timingOnlyOutput() [core.SEED_LENGTH]u8 {
    const held = lock.acquire();
    defer lock.release(held);
    timing_generator = .init(@splat(0));
    _ = collect(&timing_generator, false);
    var out: [core.SEED_LENGTH]u8 = undefined;
    timing_generator.fill(&out);
    return out;
}
