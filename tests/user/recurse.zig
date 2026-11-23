//! `/test/recurse`: start this same program again and wait for it, so the
//! chain of processes grows until the kernel refuses to start another one,
//! because memory ran out or because a limit on descendants was reached.
//! Every parent is alive and waiting while its child runs.
//!
//! The process that is refused exits with 100 (`EAGAIN`: descendant limit),
//! 200 (`ENOMEM`) or 99 (anything else). Each parent passes its child's
//! status on with 1 added, up to 90, so the first process exits with the
//! reason plus the depth the chain reached: 105 is "limit reached, five
//! processes below the first".

const lib = @import("lib");
pub const panic = lib.panic;

/// Program entry point.
export fn _start() callconv(.c) noreturn {
    const status = lib.run("/test/recurse");
    if (status == lib.err(.AGAIN)) lib.exit(100);
    if (status == lib.err(.NOMEM)) lib.exit(200);
    if (lib.isError(status)) lib.exit(99);
    // A child that was killed (255) or failed some other way: pass it on.
    if (status < 100 or status == 255) lib.exit(status);
    lib.exit(if (status % 100 < 90) status + 1 else status);
}
