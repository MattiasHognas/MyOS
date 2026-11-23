//! `/test/kernel_read`: read kernel memory from ring 3. The page is mapped but
//! not user-accessible, so the CPU faults and the kernel must kill this process
//! (exit code 255). Exits with 0 if the read somehow succeeds.

const lib = @import("lib");
pub const panic = lib.panic;

/// Program entry point.
export fn _start() callconv(.c) noreturn {
    const kernel_text: *const volatile u64 = @ptrFromInt(0xFFFF_FFFF_8000_0000);
    _ = kernel_text.*;
    lib.exit(0);
}
