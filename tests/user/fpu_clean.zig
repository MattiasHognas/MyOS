//! `/test/fpu_clean`: check that a new process starts with clean x87, SSE
//! and AVX state: the values Linux gives a new program, and nothing of the
//! program that ran before (the kernel test runs `/test/fpu` first, which
//! leaves every register full).
//!
//! The first instruction saves the x87 and SSE state with `fxsave`, before
//! any compiler-generated code can touch a register.
//!
//! Exit status: 0 clean; 1 x87 control/status/tag words; 2 MXCSR; 3 x87
//! registers; 4 XMM registers; 5 upper halves of the YMM registers.

const std = @import("std");
const lib = @import("lib");
const regs = @import("fpu_regs.zig");

pub const panic = lib.panic;

/// The 512-byte FXSAVE image taken at entry.
export var fx_area: [512]u8 align(64) = undefined;

/// Program entry point. On entry RSP is 8 below a 16-byte boundary, as
/// after a call, so the `call` below would misalign it: hence the `sub`.
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ fxsave64 fx_area(%%rip)
        \\ sub $8, %%rsp
        \\ call fpuCleanMain
        \\ ud2
    );
}

var state: regs.State = undefined;

/// Inspect the saved image; see the exit statuses above.
export fn fpuCleanMain() callconv(.c) noreturn {
    const fx = &fx_area;
    const fcw = std.mem.readInt(u16, fx[0..2], .little);
    const fsw = std.mem.readInt(u16, fx[2..4], .little);
    const ftw = fx[4]; // abridged tag word: 0 = every register empty
    if (fcw != 0x037F or fsw != 0 or ftw != 0) lib.exit(1);
    if (std.mem.readInt(u32, fx[24..28], .little) != 0x1F80) lib.exit(2);
    if (!std.mem.allEqual(u8, fx[32..160], 0)) lib.exit(3);
    if (!std.mem.allEqual(u8, fx[160..416], 0)) lib.exit(4);

    // SSE code leaves the upper halves of the YMM registers alone, so they
    // still hold what the kernel loaded.
    if (regs.avxUsable()) {
        regs.storeVec(&state, true);
        for (&state.vec) |*v| {
            if (!std.mem.allEqual(u8, v[16..32], 0)) lib.exit(5);
        }
    }
    lib.exit(0);
}
