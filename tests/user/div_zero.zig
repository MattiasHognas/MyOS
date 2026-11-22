//! `/test/div_zero`: divide by zero in ring 3. The CPU raises a divide error
//! and the kernel must kill this process (exit code 255). The `div` is
//! written in assembly so no compiler safety check gets in first. Exits with
//! 0 if the instruction somehow succeeds.

const lib = @import("lib");

pub const panic = lib.panic;

/// Program entry point.
export fn _start() callconv(.c) noreturn {
    asm volatile (
        \\ xor %%edx, %%edx
        \\ xor %%ecx, %%ecx
        \\ div %%rcx
        ::: .{ .rax = true, .rcx = true, .rdx = true });
    lib.exit(0);
}
