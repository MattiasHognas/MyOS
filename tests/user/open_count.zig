//! `/test/open_count`: open a file again and again until the kernel
//! refuses, and exit with the number of descriptors obtained. The refusal
//! must be `EMFILE`; anything else exits with 200. With a limit of 16 the
//! answer is 13 (the three standard streams are open already); after a
//! hundred it stops and exits with 201.
//!
//! With the argument `all` it does not stop at a hundred, and exits with 0
//! if the kernel refused exactly at descriptor 1024, Linux's default
//! limit and this kernel's too, with 1 otherwise.

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}

/// Program entry point.
pub fn main() noreturn {
    if (lib.argv().len > 1) {
        var last: u64 = 0;
        while (true) {
            const fd = lib.open("/etc/motd");
            if (fd == lib.err(.MFILE)) lib.exit(if (last == 1023) 0 else 1);
            if (lib.isError(fd) or fd != last + 1 and last != 0) lib.exit(200);
            last = fd;
        }
    }
    var count: u64 = 0;
    while (count < 100) : (count += 1) {
        const fd = lib.open("/etc/motd");
        if (fd == lib.err(.MFILE)) lib.exit(count);
        if (lib.isError(fd)) lib.exit(200);
    }
    lib.exit(201); // no limit at all
}
