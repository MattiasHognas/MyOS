//! `/test/write_text`: write to this program's own code. The ELF loader maps
//! code read-only, so the CPU faults and the kernel must kill this process
//! (exit code 255). Exits with 0 if the write somehow succeeds.

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}

/// Program entry point.
pub fn main() noreturn {
    const code: *volatile u8 = @ptrFromInt(@intFromPtr(&main));
    code.* = 0xCC;
    lib.exit(0);
}
