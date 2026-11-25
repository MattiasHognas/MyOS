//! `/test/open_count`: open a file again and again until the kernel
//! refuses, and exit with the number of descriptors obtained. The refusal
//! must be `EMFILE`; anything else exits with 200. With the default limits
//! the answer is 13 (16 descriptors less the three standard streams).

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}

/// Program entry point.
pub fn main() noreturn {
    var count: u64 = 0;
    while (count < 100) : (count += 1) {
        const fd = lib.open("/etc/motd");
        if (fd == lib.err(.MFILE)) lib.exit(count);
        if (lib.isError(fd)) lib.exit(200);
    }
    lib.exit(201); // no limit at all
}
