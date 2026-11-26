//! Host tests for the signal frame (`src/kernel/signal_frame.zig`).

const std = @import("std");
const sf = @import("signal_frame");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

const no_alt: sf.Stack = .{ .flags = 2 }; // SS_DISABLE

test "signal frame: below the red zone, aligned as after a call" {
    const sp: u64 = 0x7fff_0000_1234;
    const p = try sf.place(sp, false, no_alt, 832 + 4);
    try expect(!p.on_alt_stack);
    try expect(p.fpstate + 832 + 4 <= sp - sf.RED_ZONE); // the red zone is left alone
    try expectEqual(0, p.fpstate % 64);
    try expect(p.frame + @sizeOf(sf.Frame) <= p.fpstate); // the frame below the FP state
    try expectEqual(8, p.frame % 16); // RSP + 8 is a multiple of 16
    // Whatever the stack pointer was: same rules.
    var s: u64 = 0x7fff_0000_0000;
    while (s < 0x7fff_0000_0100) : (s += 1) {
        const q = try sf.place(s, false, no_alt, 512);
        try expectEqual(8, q.frame % 16);
        try expectEqual(0, q.fpstate % 64);
        try expect(q.fpstate + 512 <= s - sf.RED_ZONE);
    }
}

test "signal frame: the alternate stack, when asked for and not in use" {
    const alt: sf.Stack = .{ .sp = 0x1000_0000, .size = 0x4000, .flags = 0 };
    const p = try sf.place(0x7fff_0000_0000, true, alt, 832 + 4);
    try expect(p.on_alt_stack);
    try expect(p.frame >= alt.sp and p.fpstate + 832 + 4 <= alt.sp + alt.size);
    try expectEqual(8, p.frame % 16);
    // Not asked for: the thread's own stack.
    try expect(!(try sf.place(0x7fff_0000_0000, false, alt, 512)).on_alt_stack);
    // Already on it (a signal in a handler running there): further down it.
    const nested = try sf.place(p.frame, true, alt, 832 + 4);
    try expect(nested.on_alt_stack and nested.frame < p.frame and nested.fpstate + 836 <= p.frame - sf.RED_ZONE);
    // Disabled: as if there were none.
    var off = alt;
    off.flags = 2;
    try expect(!(try sf.place(0x7fff_0000_0000, true, off, 512)).on_alt_stack);
    // Too small for a frame: refused, nothing written below it.
    const tiny: sf.Stack = .{ .sp = 0x1000_0000, .size = 256, .flags = 0 };
    try testing.expectError(error.NoRoom, sf.place(0x7fff_0000_0000, true, tiny, 512));
    // Stack pointers at the edges of the address space.
    try testing.expectError(error.NoRoom, sf.place(64, false, no_alt, 512));
    const top: sf.Stack = .{ .sp = ~@as(u64, 0) - 10, .size = 100, .flags = 0 };
    try testing.expectError(error.NoRoom, sf.place(0x7fff_0000_0000, true, top, 512));
}

test "signal frame: XSAVE marks for the handler and for rt_sigreturn" {
    var area: [832 + 4]u8 align(64) = @splat(0xAA);
    sf.markXsave(&area, 832, 0x7);
    try expect(sf.hasXsaveMarks(&area, 832));
    try expectEqual(sf.FP_XSTATE_MAGIC1, std.mem.readInt(u32, area[464..468], .little));
    try expectEqual(836, std.mem.readInt(u32, area[468..472], .little)); // extended_size
    try expectEqual(0x7, std.mem.readInt(u64, area[472..480], .little)); // xfeatures
    try expectEqual(sf.FP_XSTATE_MAGIC2, std.mem.readInt(u32, area[832..836], .little));
    // A program that overwrote them, or an area of another size: only the
    // FXSAVE part counts.
    area[832] ^= 1;
    try expect(!sf.hasXsaveMarks(&area, 832));
    try expect(!sf.hasXsaveMarks(area[0..600], 832));
}

test "signal frame: an FP image from a program cannot fault in the kernel" {
    var area: [832]u8 align(64) = @splat(0xFF);
    sf.sanitizeFp(&area, true, 0x7, 0xFFBF);
    try expectEqual(0xFFBF, std.mem.readInt(u32, area[24..28], .little)); // MXCSR: no reserved bits
    try expectEqual(0x7, std.mem.readInt(u64, area[512..520], .little)); // XSTATE_BV within XCR0
    try expect(std.mem.allEqual(u8, area[520..576], 0)); // XCOMP_BV and the reserved header bytes
    try expect(std.mem.allEqual(u8, area[576..], 0xFF)); // the registers themselves are the program's
    // FXSAVE form: only MXCSR.
    var legacy: [512]u8 align(16) = @splat(0xFF);
    sf.sanitizeFp(&legacy, false, 0, 0xFFFF);
    try expectEqual(0xFFFF, std.mem.readInt(u32, legacy[24..28], .little));
}

test "signal frame: siginfo for faults and for signals from programs" {
    const fault = sf.SigInfo.fromFault(11, 1, 0xdead_beef);
    try expectEqual(11, fault.signo);
    try expectEqual(1, fault.code);
    try expectEqual(0xdead_beef, std.mem.readInt(u64, fault.fields[0..8], .little)); // si_addr at byte 16
    const sent = sf.SigInfo.fromProcess(2, -6, 42, 0);
    try expectEqual(42, std.mem.readInt(u32, sent.fields[0..4], .little)); // si_pid
}
