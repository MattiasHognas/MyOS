//! `/test/write_text`: write to this program's own code. The ELF loader maps
//! code read-only, so the CPU faults and the kernel must kill this process
//! (exit code 255). Exits with 0 if the write somehow succeeds.

const lib = @import("lib");
pub const panic = lib.panic;

/// Program entry point.
export fn _start() callconv(.c) noreturn {
    const code: *volatile u8 = @ptrFromInt(@intFromPtr(&_start));
    code.* = 0xCC;
    lib.exit(0);
}
