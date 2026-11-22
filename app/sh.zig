//! `/bin/sh`: a tiny shell. Runs each entered name as `/bin/<name>` (or as a
//! path if it contains a slash) and waits for it; `exit` leaves the shell.

const std = @import("std");
const lib = @import("lib.zig");

pub const panic = lib.panic;

/// Read one line from the keyboard into `buf`, echoing it and handling
/// backspace. Ctrl+C discards the line. Returns the line without the newline.
fn readLine(buf: []u8) []u8 {
    var len: usize = 0;
    while (true) {
        const c = lib.getChar();
        switch (c) {
            '\n' => {
                lib.write("\n");
                return buf[0..len];
            },
            0x08 => if (len > 0) {
                len -= 1;
                lib.write("\x08 \x08");
            },
            3 => { // Ctrl+C: drop the line
                lib.write("^C\n");
                return buf[0..0];
            },
            else => if (c >= ' ' and len < buf.len) {
                buf[len] = c;
                len += 1;
                lib.write(&.{c});
            },
        }
    }
}

/// Program entry point: the read-run loop.
export fn _start() callconv(.c) noreturn {
    lib.write("MyOS shell. Type a program name (e.g. hello), or exit.\n");
    var line: [128]u8 = undefined;
    var path: [160]u8 = undefined;

    while (true) {
        lib.write("$ ");
        const cmd = std.mem.trim(u8, readLine(&line), " ");
        if (cmd.len == 0) continue;
        if (std.mem.eql(u8, cmd, "exit")) lib.exit(0);

        // "hello" -> "/bin/hello"; anything with a slash is used as-is
        const full = if (std.mem.indexOfScalar(u8, cmd, '/') != null)
            cmd
        else
            std.fmt.bufPrint(&path, "/bin/{s}", .{cmd}) catch continue;

        const code = lib.run(full);
        if (code == lib.ERR) {
            lib.print("sh: {s}: not found\n", .{cmd});
        } else if (code != 0) {
            lib.print("sh: {s} exited with code {d}\n", .{ cmd, code });
        }
    }
}
