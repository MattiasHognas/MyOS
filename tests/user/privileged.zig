//! `/test/privileged`: execute `cli` in ring 3. The CPU raises a general
//! protection fault and the kernel must kill this process (exit code 255).
//! Exits with 0 if the instruction somehow succeeds.

const lib = @import("lib");
pub const panic = lib.panic;

/// Program entry point.
export fn _start() callconv(.c) noreturn {
    asm volatile ("cli");
    lib.exit(0);
}
