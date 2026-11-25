//! `/bin/hello`: print a greeting and the contents of `/etc/motd`.

const lib = @import("lib.zig");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}

/// Program entry point. Exits with 0 on success, or 1 if `/etc/motd` can't be opened.
pub fn main() noreturn {
    lib.write("Hello from /bin/hello!\n");
    const fd = lib.open("/etc/motd");
    if (lib.isError(fd)) {
        lib.write("cannot open /etc/motd\n");
        lib.exit(1);
    }
    var buf: [256]u8 = undefined;
    const n = lib.read(fd, &buf);
    if (!lib.isError(n)) lib.write(buf[0..n]);
    _ = lib.close(fd);
    lib.exit(0);
}
