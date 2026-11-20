const lib = @import("lib.zig");

pub const panic = lib.panic;

export fn _start() callconv(.c) noreturn {
    lib.write("Hello from /bin/hello!\n");
    const fd = lib.open("/etc/motd");
    if (fd == lib.ERR) {
        lib.write("cannot open /etc/motd\n");
        lib.exit(1);
    }
    var buf: [256]u8 = undefined;
    const n = lib.read(fd, &buf);
    if (n != lib.ERR) lib.write(buf[0..n]);
    lib.close(fd);
    lib.exit(0);
}
