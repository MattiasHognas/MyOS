//! Host tests for the hardware-independent parts of extended-state handling
//! (`src/arch/x86_64/fpu.zig`): which mechanism and features are chosen from
//! CPUID, and what a new thread's save area contains.

const std = @import("std");

const fpu = @import("fpu");

const XSAVE: u32 = 1 << 26;
const AVX: u32 = 1 << 28;

test "no XSAVE: FXSAVE with a 512-byte area" {
    const c = fpu.detect(0, 0);
    try std.testing.expectEqual(fpu.Mode.fxsave, c.mode);
    try std.testing.expectEqual(@as(u64, 0), c.xcr0);
    try std.testing.expectEqual(@as(usize, 512), c.area_size);
}

test "AVX without XSAVE cannot be used" {
    const c = fpu.detect(AVX, 0x7);
    try std.testing.expectEqual(fpu.Mode.fxsave, c.mode);
    try std.testing.expectEqual(@as(u64, 0), c.xcr0);
}

test "XSAVE without AVX: x87 and SSE state only" {
    const c = fpu.detect(XSAVE, 0x3);
    try std.testing.expectEqual(fpu.Mode.xsave, c.mode);
    try std.testing.expectEqual(@as(u64, 0x3), c.xcr0);
}

test "XSAVE with AVX enables AVX state" {
    const c = fpu.detect(XSAVE | AVX, 0x7);
    try std.testing.expectEqual(fpu.Mode.xsave, c.mode);
    try std.testing.expectEqual(@as(u64, 0x7), c.xcr0);
}

test "AVX needs both the instruction set and the state component" {
    try std.testing.expectEqual(@as(u64, 0x3), fpu.detect(XSAVE | AVX, 0x3).xcr0);
    try std.testing.expectEqual(@as(u64, 0x3), fpu.detect(XSAVE, 0x7).xcr0);
}

test "features beyond AVX stay off" {
    // AVX-512 (bits 5-7), MPX (3-4), PKRU (9), AMX (17-18) all offered.
    const c = fpu.detect(XSAVE | AVX, 0x602FF);
    try std.testing.expectEqual(@as(u64, 0x7), c.xcr0);
}

test "XSAVE that cannot manage x87 and SSE state falls back to FXSAVE" {
    try std.testing.expectEqual(fpu.Mode.fxsave, fpu.detect(XSAVE | AVX, 0).mode);
    try std.testing.expectEqual(fpu.Mode.fxsave, fpu.detect(XSAVE | AVX, 0x1).mode);
}

test "a new thread's area is the reset state" {
    var area: [fpu.MAX_AREA_SIZE]u8 = @splat(0xAA); // whatever the last owner left
    fpu.initArea(&area);
    try std.testing.expectEqual(@as(u16, 0x037F), std.mem.readInt(u16, area[0..2], .little)); // FCW
    try std.testing.expectEqual(@as(u32, 0x1F80), std.mem.readInt(u32, area[24..28], .little)); // MXCSR
    // Everything else is zero: status and tag words, ST and XMM registers,
    // the XSAVE header (so every component is "initial") and the AVX state.
    try std.testing.expect(std.mem.allEqual(u8, area[2..24], 0));
    try std.testing.expect(std.mem.allEqual(u8, area[28..], 0));
}

test "the largest area fits the legacy part, the header and AVX" {
    try std.testing.expectEqual(@as(usize, 832), fpu.MAX_AREA_SIZE);
    try std.testing.expect(fpu.FXSAVE_SIZE % fpu.AREA_ALIGN == 0);
}
