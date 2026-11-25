//! `/test/kernel_read`: read kernel memory from ring 3. The page is mapped but
//! not user-accessible, so the CPU faults and the kernel must kill this process
//! (exit code 255). Exits with 0 if the read somehow succeeds.
//!
//! The address is in the kernel's direct map of physical memory (1 MiB into
//! it), which is at a fixed place; the kernel image itself is loaded at a
//! random address.

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}

/// Program entry point.
pub fn main() noreturn {
    const kernel_memory: *const volatile u64 = @ptrFromInt(0xFFFF_8000_0010_0000);
    _ = kernel_memory.*;
    lib.exit(0);
}
