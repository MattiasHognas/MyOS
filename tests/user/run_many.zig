//! `/test/run_many`: start a small program eight times, one after the
//! other, and exit with the number of times it ran successfully. With a
//! limit of one descendant this only works if a child that has exited no
//! longer counts.

const lib = @import("lib");
pub const panic = lib.panic;

/// Program entry point.
export fn _start() callconv(.c) noreturn {
    var ran: u64 = 0;
    for (0..8) |_| {
        if (lib.run("/test/entry_regs") == 0) ran += 1;
    }
    lib.exit(ran);
}
