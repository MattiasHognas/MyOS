//! The vDSO: functions a program calls without entering the kernel,
//! mapped into every process and announced in its auxiliary vector
//! (`AT_SYSINFO_EHDR`), as Linux does. glibc looks them up by name and
//! version (`LINUX_2.6`) and calls them for `clock_gettime`,
//! `gettimeofday` and `time`; Go's runtime parses this image itself.
//!
//! They read the clock from the page just below the image (`vvar`), which
//! the kernel writes (`kernel/vdso.zig`) and programs can only read: the
//! TSC's base and rate, as the kernel's own clock (`kernel/clock.zig`)
//! converts it. Where the TSC cannot be used, or for a clock this does not
//! know, they make the system call instead.
//!
//! Built position independent, without a C library, into one segment
//! (`vdso.lds`), and embedded in the kernel.

/// The page the kernel writes, laid out as `kernel/vdso.zig`'s `VVar`.
const VVar = extern struct {
    /// Odd while the kernel changes what follows.
    seq: u32,
    /// 1 if the TSC is the clock (else: make the system call).
    tsc: u32,
    tsc_base: u64,
    ns_base: u64,
    mult: u64,
    shift: u32,
    _pad: u32,
    /// The wall clock minus the monotonic clock, in nanoseconds.
    realtime_offset: i64,
    /// How `getcpu` reads the CPU's number: 1 `RDPID`, 2 `RDTSCP` (both
    /// give `TSC_AUX`, which the kernel sets to it), 0 the system call.
    getcpu: u32,
    _pad2: u32,
};

const Timespec = extern struct { sec: i64, nsec: i64 };
const Timeval = extern struct { sec: i64, usec: i64 };

/// The start of this image, which the linker knows: the page below it is
/// the kernel's.
extern const __ehdr_start: u8;

inline fn vvar() *const volatile VVar {
    return @ptrFromInt(@intFromPtr(&__ehdr_start) - 4096);
}

inline fn rdtscOrdered() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("lfence; rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        :
        : .{ .memory = true });
    return @as(u64, hi) << 32 | lo;
}

inline fn syscall2(n: u64, a: u64, b: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a),
          [b] "{rsi}" (b),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

/// The monotonic clock in nanoseconds, and the wall clock's offset from
/// it; null where the TSC is not the clock.
fn read() ?struct { mono: u64, offset: i64 } {
    const v = vvar();
    while (true) {
        const seq = v.seq;
        if (seq & 1 != 0) continue; // being changed: look again
        if (v.tsc == 0) return null;
        const base_tsc = v.tsc_base;
        const base_ns = v.ns_base;
        const mult = v.mult;
        const shift: u7 = @intCast(v.shift);
        const offset = v.realtime_offset;
        const now = rdtscOrdered();
        if (v.seq != seq) continue;
        const delta = now -% base_tsc;
        // (delta * mult) >> shift, the product's two halves shifted by
        // hand (a 128-bit shift by a variable would need a helper this
        // image does not have).
        const product = @as(u128, delta) * mult;
        const lo: u64 = @truncate(product);
        const hi: u64 = @truncate(product >> 64);
        const s6: u6 = @truncate(shift);
        const scaled = if (shift == 0) lo else if (shift >= 64) hi >> @truncate(shift - 64) else (lo >> s6) | (hi << @truncate(64 - @as(u7, s6)));
        const ns = base_ns + scaled;
        return .{ .mono = ns, .offset = offset };
    }
}

const CLOCK_REALTIME = 0;
const CLOCK_MONOTONIC = 1;
const CLOCK_MONOTONIC_RAW = 4;
const CLOCK_REALTIME_COARSE = 5;
const CLOCK_MONOTONIC_COARSE = 6;
const CLOCK_BOOTTIME = 7;
const SYS_gettimeofday = 96;
const SYS_time = 201;
const SYS_clock_gettime = 228;

export fn __vdso_clock_gettime(clock: i32, ts: *Timespec) callconv(.c) i32 {
    const wall = switch (clock) {
        CLOCK_REALTIME, CLOCK_REALTIME_COARSE => true,
        CLOCK_MONOTONIC, CLOCK_MONOTONIC_RAW, CLOCK_MONOTONIC_COARSE, CLOCK_BOOTTIME => false,
        else => return @bitCast(@as(u32, @truncate(syscall2(SYS_clock_gettime, @bitCast(@as(i64, clock)), @intFromPtr(ts))))),
    };
    const t = read() orelse return @bitCast(@as(u32, @truncate(syscall2(SYS_clock_gettime, @bitCast(@as(i64, clock)), @intFromPtr(ts)))));
    const ns: i64 = @as(i64, @bitCast(t.mono)) + (if (wall) t.offset else 0);
    ts.* = .{ .sec = @divFloor(ns, 1_000_000_000), .nsec = @mod(ns, 1_000_000_000) };
    return 0;
}

export fn __vdso_gettimeofday(tv: ?*Timeval, tz: ?*anyopaque) callconv(.c) i32 {
    if (tz != null) return @bitCast(@as(u32, @truncate(syscall2(SYS_gettimeofday, @intFromPtr(tv), @intFromPtr(tz)))));
    const out = tv orelse return 0;
    const t = read() orelse return @bitCast(@as(u32, @truncate(syscall2(SYS_gettimeofday, @intFromPtr(tv), 0))));
    const ns: i64 = @as(i64, @bitCast(t.mono)) + t.offset;
    out.* = .{ .sec = @divFloor(ns, 1_000_000_000), .usec = @divFloor(@mod(ns, 1_000_000_000), 1000) };
    return 0;
}

export fn __vdso_time(t: ?*i64) callconv(.c) i64 {
    const now = read() orelse return @bitCast(syscall2(SYS_time, @intFromPtr(t), 0));
    const sec = @divFloor(@as(i64, @bitCast(now.mono)) + now.offset, 1_000_000_000);
    if (t) |p| p.* = sec;
    return sec;
}

const SYS_getcpu = 309;

/// The CPU the caller runs on, and its NUMA node (0), as Linux's vDSO
/// gives them: from `TSC_AUX` (the CPU's number in its low 12 bits, the
/// node above), without entering the kernel where the CPU can read it.
export fn __vdso_getcpu(cpu: ?*u32, node: ?*u32, unused: ?*anyopaque) callconv(.c) i32 {
    _ = unused;
    const aux: u64 = switch (vvar().getcpu) {
        1 => asm volatile ("rdpid %[aux]"
            : [aux] "=r" (-> u64),
        ),
        2 => blk: {
            var ecx: u32 = undefined;
            asm volatile ("rdtscp"
                : [ecx] "={ecx}" (ecx),
                :
                : .{ .rax = true, .rdx = true });
            break :blk ecx;
        },
        else => return @bitCast(@as(u32, @truncate(syscall2(SYS_getcpu, @intFromPtr(cpu), @intFromPtr(node))))),
    };
    if (cpu) |c| c.* = @truncate(aux & 0xFFF);
    if (node) |n| n.* = @truncate(aux >> 12);
    return 0;
}

// The names without the prefix, as Linux's vDSO has them too.
comptime {
    @export(&__vdso_getcpu, .{ .name = "getcpu", .linkage = .weak });
    @export(&__vdso_clock_gettime, .{ .name = "clock_gettime", .linkage = .weak });
    @export(&__vdso_gettimeofday, .{ .name = "gettimeofday", .linkage = .weak });
    @export(&__vdso_time, .{ .name = "time", .linkage = .weak });
}
