//! `/test/bad_return`: exercise the syscall exit path with return states the
//! `syscall` instruction itself never produces. The kernel test installs a
//! syscall handler that alters the saved state for the three numbers below
//! (in the real kernel they are unknown, and this program exits with 90).
//!
//! 1. `VIA_IRET`: the handler sets RF, which `sysretq` cannot restore, so
//!    the kernel must return with `iretq`. Everything a syscall preserves
//!    must still come back.
//! 2. `BAD_FLAGS`: the handler asks for IOPL 3, NT, and interrupts off. The
//!    kernel must not grant any of them.
//! 3. `BAD_STATE`: the handler makes the state impossible to return to (a
//!    return address outside user space, or kernel selectors). The kernel
//!    must kill the process (exit status 255) rather than fault in ring 0.
//!
//! Exit status 255 is the pass; anything else is the failing step.

const lib = @import("lib");
const checked = @import("checked.zig");

pub const panic = lib.panic;

/// Test-only syscall numbers; must match `tests/kernel/helpers.zig`.
const VIA_IRET = lib.Sys.PRIVATE_BASE + 0x100;
const BAD_FLAGS = lib.Sys.PRIVATE_BASE + 0x101;
const BAD_STATE = lib.Sys.PRIVATE_BASE + 0x102;

/// Program entry point.
export fn _start() callconv(.c) noreturn {
    if (lib.syscall(VIA_IRET, 0, 0, 0) == lib.err(.NOSYS)) lib.exit(90);
    for ([_]u64{ 0, checked.FLAGS_MASK, 0x4C1 }) |flags| {
        if (checked.call3(VIA_IRET, 1, 2, 3, .{ .flags = flags, .misalign = 8 }) != 0x1234) lib.exit(1);
    }

    if (lib.syscall(BAD_FLAGS, 0, 0, 0) != 0x1234) lib.exit(2);
    const flags = asm volatile (
        \\ pushfq
        \\ pop %[f]
        : [f] "=r" (-> u64),
    );
    // IF on, IOPL 0, NT clear.
    if (flags & 0x200 == 0 or flags & 0x3000 != 0 or flags & 0x4000 != 0) lib.exit(3);

    _ = lib.syscall(BAD_STATE, 0, 0, 0);
    lib.exit(4); // the kernel returned to us
}
