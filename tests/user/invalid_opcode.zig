//! `/test/invalid_opcode`: execute `ud2` in ring 3. The CPU raises an invalid
//! opcode exception and the kernel must kill this process (exit code 255).
//! Exits with 0 if execution somehow continues.

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}

/// Program entry point.
pub fn main() noreturn {
    asm volatile ("ud2");
    lib.exit(0);
}
