//! `/test/umip`: execute `sgdt` in ring 3. With UMIP on, the CPU raises a
//! general protection fault and the kernel must kill this process (exit code
//! 255). Exits with 0 if the instruction succeeds, which would reveal the
//! address of the kernel's GDT.

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}

/// Program entry point.
pub fn main() noreturn {
    var gdtr: [10]u8 = undefined;
    asm volatile ("sgdt (%[p])"
        :
        : [p] "r" (&gdtr),
        : .{ .memory = true });
    lib.exit(0);
}
