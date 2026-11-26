//! Extended CPU state: x87, SSE, AVX and AVX-512 registers.
//!
//! The kernel itself is built soft-float and never touches these registers,
//! so they always hold the state of the last user thread that ran, and they
//! only have to be saved and restored when the CPU moves from one user
//! thread to another (`switchState`, called by the scheduler). Kernel
//! threads have no saved state. Nothing is saved on interrupts or syscalls.
//!
//! `init` picks the mechanism once:
//!
//! - **XSAVE** where the CPU has it, with x87 and SSE state plus AVX and
//!   AVX-512 where supported. The save area's size comes from CPUID, as the
//!   processor defines the layout: 832 bytes with AVX, about 2.7 KiB with
//!   AVX-512.
//! - **FXSAVE** otherwise: x87 and SSE only, a fixed 512 bytes.
//!
//! AVX-512 is enabled because programs need it to start, not only to run
//! fast: a C library built for x86-64-v4 (as some distributions build
//! theirs) marks everything linked against it as needing such a CPU, and
//! its loader refuses to start that where the operating system has not
//! enabled AVX-512's state. Features beyond it (MPX, protection keys, AMX)
//! stay disabled in XCR0, so a program that checks before using them, as
//! it must, does not use them.
//!
//! A new thread starts from `initArea`: the reset state Linux gives a new
//! process (all registers zero, x87 control word 0x37F, MXCSR 0x1F80), so
//! nothing of the previous owner of the CPU is visible.
//!
//! The save and restore instructions are written as bytes: the kernel's
//! target has SSE switched off, and the assembler would refuse them.

const std = @import("std");

const cpu = @import("cpu.zig");

const log = std.log.scoped(.fpu);

/// How extended state is saved, chosen by `init`.
pub const Mode = enum { fxsave, xsave };

/// Alignment the save instructions require of their memory operand.
pub const AREA_ALIGN = 64;
/// Size of the FXSAVE area, which is also the legacy part of an XSAVE area.
pub const FXSAVE_SIZE = 512;
/// Largest area this kernel supports: legacy part, header, AVX state, and
/// AVX-512's three components (opmask, upper halves of ZMM0-15, ZMM16-31)
/// at the offsets the standard layout has for them, which leave room for
/// the MPX components before them.
pub const MAX_AREA_SIZE = 2688;
/// The area with AVX and nothing after it.
pub const AVX_AREA_SIZE = FXSAVE_SIZE + 64 + 256;

/// x87 control word after `fninit`: all exceptions masked, 64-bit precision.
pub const DEFAULT_FCW: u16 = 0x037F;
/// MXCSR reset value: all exceptions masked, round to nearest.
pub const DEFAULT_MXCSR: u32 = 0x1F80;

const XCR0_X87: u64 = 1 << 0;
const XCR0_SSE: u64 = 1 << 1;
const XCR0_AVX: u64 = 1 << 2;
/// AVX-512: the opmask registers, the upper 256 bits of ZMM0-15, ZMM16-31.
const XCR0_AVX512: u64 = (1 << 5) | (1 << 6) | (1 << 7);

const CR0_MP: u64 = 1 << 1;
const CR0_EM: u64 = 1 << 2;
const CR0_TS: u64 = 1 << 3;
const CR0_NE: u64 = 1 << 5;
const CR4_OSFXSR: u64 = 1 << 9;
const CR4_OSXMMEXCPT: u64 = 1 << 10;
const CR4_OSXSAVE: u64 = 1 << 18;

var mode: Mode = .fxsave;
var area_size: usize = FXSAVE_SIZE;
var xcr0: u64 = 0;

/// The mechanism in use.
pub fn currentMode() Mode {
    return mode;
}

/// Bytes a thread's save area takes with the features that are enabled.
pub fn areaSize() usize {
    return area_size;
}

/// True if AVX state is enabled (and so saved and restored).
pub fn avxEnabled() bool {
    return xcr0 & XCR0_AVX != 0;
}

/// True if AVX-512 state is enabled.
pub fn avx512Enabled() bool {
    return xcr0 & XCR0_AVX512 == XCR0_AVX512;
}

/// The feature mask loaded into XCR0, or 0 without XSAVE.
pub fn enabledFeatures() u64 {
    return xcr0;
}

/// Write extended control register 0, which selects the state components
/// XSAVE manages and the instruction sets user code may use.
fn writeXcr0(value: u64) void {
    asm volatile (".byte 0x0f, 0x01, 0xd1" // xsetbv
        :
        : [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
          [idx] "{ecx}" (@as(u32, 0)),
    );
}

/// Features and area size found by `detect`.
pub const Config = struct { mode: Mode, xcr0: u64, area_size: usize };

/// Decide what to enable from CPUID values: `leaf1_ecx` is CPUID.1:ECX,
/// `leaf_d_eax` is CPUID.(0xD,0):EAX (the XCR0 bits the CPU supports), or 0
/// when that leaf does not exist, and `leaf7_ebx` is CPUID.(7,0):EBX (bit
/// 16: AVX-512F), or 0. The area size for XSAVE is read from CPUID after
/// XCR0 is set, so `area_size` is only final for FXSAVE.
pub fn detect(leaf1_ecx: u32, leaf_d_eax: u32, leaf7_ebx: u32) Config {
    const has_xsave = leaf1_ecx & (1 << 26) != 0;
    const has_avx = leaf1_ecx & (1 << 28) != 0;
    if (!has_xsave or leaf_d_eax & 3 != 3) return .{ .mode = .fxsave, .xcr0 = 0, .area_size = FXSAVE_SIZE };
    var features = XCR0_X87 | XCR0_SSE;
    if (has_avx and leaf_d_eax & XCR0_AVX != 0) {
        features |= XCR0_AVX;
        // All three components or none: XCR0 refuses some of them alone.
        if (leaf7_ebx & (1 << 16) != 0 and leaf_d_eax & XCR0_AVX512 == XCR0_AVX512) features |= XCR0_AVX512;
    }
    return .{ .mode = .xsave, .xcr0 = features, .area_size = FXSAVE_SIZE + 64 };
}

/// Enable x87, SSE and (where supported) AVX for user code on the boot CPU
/// and choose how their state is saved. x86-64 guarantees FXSAVE and SSE2,
/// so there is nothing to fall back to below that. The other CPUs follow
/// with `initCpu`.
pub fn init() void {
    const leaf1 = cpu.cpuid(1, 0);
    const max_leaf = cpu.cpuid(0, 0).eax;
    const leaf_d_eax = if (max_leaf >= 0xD) cpu.cpuid(0xD, 0).eax else 0;
    const leaf7_ebx = if (max_leaf >= 7) cpu.cpuid(7, 0).ebx else 0;
    const config = detect(leaf1.ecx, leaf_d_eax, leaf7_ebx);
    mode = config.mode;
    xcr0 = config.xcr0;
    area_size = config.area_size;
    const size = enable();
    if (mode == .xsave) {
        if (size < FXSAVE_SIZE + 64 or size > MAX_AREA_SIZE) @panic("fpu: unexpected XSAVE area size");
        area_size = size;
    }
    switch (mode) {
        .xsave => log.info("extended state: XSAVE, {d} bytes, AVX {s}, AVX-512 {s}", .{
            area_size,
            if (avxEnabled()) "on" else "not supported",
            if (avx512Enabled()) "on" else "not supported",
        }),
        .fxsave => log.info("extended state: FXSAVE, {d} bytes (no XSAVE; AVX off)", .{area_size}),
    }
}

/// Enable on this CPU what `init` chose on the boot CPU. Must run on every
/// CPU before it enters ring 3. A thread's saved state has one layout, so a
/// CPU that would lay it out differently cannot be used: returns false then.
pub fn initCpu() bool {
    return enable() == area_size;
}

/// Set the control registers for the chosen mode and give the registers a
/// defined state. Returns the size of the save area on this CPU.
fn enable() usize {
    // No emulation, no lazy-switching traps, native x87 error reporting.
    cpu.writeCr0((cpu.readCr0() & ~(CR0_EM | CR0_TS)) | CR0_MP | CR0_NE);
    const cr4 = cpu.readCr4() | CR4_OSFXSR | CR4_OSXMMEXCPT;
    var size: usize = FXSAVE_SIZE;
    if (mode == .xsave) {
        cpu.writeCr4(cr4 | CR4_OSXSAVE);
        writeXcr0(xcr0);
        // EBX: the area size for the features now enabled in XCR0.
        size = cpu.cpuid(0xD, 0).ebx;
    } else cpu.writeCr4(cr4);
    asm volatile ("fninit");
    return size;
}

/// Read extended control register 0. Only with XSAVE enabled.
pub fn readXcr0() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile (".byte 0x0f, 0x01, 0xd0" // xgetbv
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [idx] "{ecx}" (@as(u32, 0)),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Fill `area` (at least `areaSize()` bytes) with the state a new thread
/// starts with. In XSAVE mode the zeroed header says "every component is in
/// its initial state", but MXCSR is loaded from the area regardless, so it
/// is always set.
pub fn initArea(area: []u8) void {
    @memset(area, 0);
    std.mem.writeInt(u16, area[0..2], DEFAULT_FCW, .little);
    std.mem.writeInt(u32, area[24..28], DEFAULT_MXCSR, .little);
}

/// Save the running thread's extended state to `area`.
fn save(area: [*]align(AREA_ALIGN) u8) void {
    switch (mode) {
        .xsave => asm volatile (".byte 0x48, 0x0f, 0xae, 0x27" // xsave64 (%rdi)
            :
            : [area] "{rdi}" (area),
              [lo] "{eax}" (@as(u32, 0xFFFF_FFFF)),
              [hi] "{edx}" (@as(u32, 0xFFFF_FFFF)),
            : .{ .memory = true }),
        .fxsave => asm volatile (".byte 0x48, 0x0f, 0xae, 0x07" // fxsave64 (%rdi)
            :
            : [area] "{rdi}" (area),
            : .{ .memory = true }),
    }
}

/// Save the extended state that is in the registers now to `area`, without
/// changing it: the copy a new thread starts with. Interrupts must be off.
pub fn saveCurrent(area: [*]align(AREA_ALIGN) u8) void {
    save(area);
}

/// Load extended state from `area`, replacing all of the CPU's.
fn restore(area: [*]align(AREA_ALIGN) const u8) void {
    switch (mode) {
        .xsave => asm volatile (".byte 0x48, 0x0f, 0xae, 0x2f" // xrstor64 (%rdi)
            :
            : [area] "{rdi}" (area),
              [lo] "{eax}" (@as(u32, 0xFFFF_FFFF)),
              [hi] "{edx}" (@as(u32, 0xFFFF_FFFF)),
            : .{ .memory = true }),
        .fxsave => asm volatile (".byte 0x48, 0x0f, 0xae, 0x0f" // fxrstor64 (%rdi)
            :
            : [area] "{rdi}" (area),
            : .{ .memory = true }),
    }
}

/// Move the CPU's extended state from one thread to another: save into
/// `prev` and load from `next`. Null means a kernel thread, which has no
/// state: nothing is saved for it, and the registers keep the last user
/// thread's values until the next user thread is loaded. Interrupts must be off.
pub fn switchState(prev: ?[*]align(AREA_ALIGN) u8, next: ?[*]align(AREA_ALIGN) const u8) void {
    if (prev) |area| save(area);
    if (next) |area| restore(area);
}
