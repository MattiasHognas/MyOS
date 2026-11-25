//! `/bin/sh`: a tiny shell. Runs the first word of each line as `/bin/<name>`
//! (or as a path if it contains a slash) with the rest as its arguments
//! (`cmdline.zig` says how a line is split) and its own environment, and
//! waits for it; `exit` leaves the shell.

const std = @import("std");

const cmdline = @import("cmdline.zig");
const lib = @import("lib.zig");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}

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
pub fn main() noreturn {
    lib.write("MyOS shell. Type a program name and its arguments (e.g. hello), or exit.\n");
    var line: [128]u8 = undefined;
    var words: [192]u8 = undefined;
    var argv: [17]?[*:0]const u8 = undefined;
    var path: [160]u8 = undefined;

    while (true) {
        lib.write("$ ");
        const argc = cmdline.split(readLine(&line), &words, &argv) catch |e| {
            lib.print("sh: {s}\n", .{switch (e) {
                error.Unterminated => "a quote is not closed",
                error.TooManyArguments => "too many arguments",
                error.TooLong => "command too long",
            }});
            continue;
        };
        if (argc == 0) continue;
        const cmd = std.mem.span(argv[0].?);
        if (std.mem.eql(u8, cmd, "exit")) lib.exit(0);

        // "hello" -> "/bin/hello"; anything with a slash is used as-is
        // (the kernel wants a NUL-terminated path)
        const full = if (std.mem.indexOfScalar(u8, cmd, '/') != null)
            std.fmt.bufPrintSentinel(&path, "{s}", .{cmd}, 0) catch continue
        else
            std.fmt.bufPrintSentinel(&path, "/bin/{s}", .{cmd}, 0) catch continue;

        const code = lib.runArgs(full, &argv, lib.environPointers());
        if (code == lib.err(.NOENT)) {
            lib.print("sh: {s}: not found\n", .{cmd});
        } else if (lib.isError(code)) {
            lib.print("sh: {s}: cannot run (error {d})\n", .{ cmd, lib.errno(code) });
        } else if (code != 0) {
            lib.print("sh: {s} exited with code {d}\n", .{ cmd, code });
        }
    }
}
