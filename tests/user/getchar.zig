//! `/test/getchar`: wait for one key and exit with its character code (0
//! at the end of input). The kernel test starts several of these and
//! feeds them keys, to check that each waiting reader gets one key, in the
//! order the readers arrived. It reads descriptor 0 with line editing off,
//! which the kernel test sets up beforehand: switching it here would race
//! with the other readers switching it back.

const lib = @import("lib");

pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}

/// Program entry point.
pub fn main() noreturn {
    var c: [1]u8 = undefined;
    lib.exit(if (lib.read(0, &c) == 1) c[0] else 0);
}
