//! `/test/getchar`: wait for one key and exit with its character code. The
//! kernel test starts several of these and feeds them keys, to check that
//! each waiting reader gets one key, in the order the readers arrived.

const lib = @import("lib");

pub const panic = lib.panic;

/// Program entry point.
export fn _start() callconv(.c) noreturn {
    lib.exit(lib.getChar());
}
