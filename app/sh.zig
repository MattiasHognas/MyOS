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

/// Read one line from the terminal into `buf` and return it without its
/// newline. The terminal does the editing: echo, backspace, Ctrl+U, and
/// Ctrl+C, which throws the line away. At the end of input (Ctrl+D on an
/// empty line) the shell goes on: there is nothing yet that would start
/// another one.
fn readLine(buf: []u8) []u8 {
    var len: usize = 0;
    while (len < buf.len) {
        const n = lib.read(0, buf[len..]);
        if (lib.isError(n)) return buf[0..0]; // interrupted, say: an empty line
        if (n == 0) {
            if (len == 0) lib.write("\n");
            return buf[0..len];
        }
        len += n;
        if (buf[len - 1] == '\n') return buf[0 .. len - 1];
    }
    // Longer than the buffer: the rest of the line is dropped.
    var rest: [64]u8 = undefined;
    while (true) {
        const n = lib.read(0, &rest);
        if (lib.isError(n) or n == 0 or rest[n - 1] == '\n') break;
    }
    return buf[0..len];
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
