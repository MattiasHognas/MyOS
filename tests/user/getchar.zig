//! `/test/getchar`: wait for one key and exit with its character code. The
//! kernel test starts several of these and feeds them keys, to check that
//! each waiting reader gets one key, in the order the readers arrived.

const lib = @import("lib");

pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}

/// Program entry point.
pub fn main() noreturn {
    lib.exit(lib.getChar());
}
