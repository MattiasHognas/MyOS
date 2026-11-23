//! `/test/preempt`: make long syscalls while another copy of this program
//! does the same, so the timer preempts each of them in the middle of a
//! syscall. Every call goes through `checked.call`, which notices a register
//! that came back wrong, and the data read must be the same every time.
//!
//! Exits with 0 if every check passes, otherwise with the number of the
//! first failing check.

const lib = @import("lib");
const checked = @import("checked.zig");

pub const panic = lib.panic;

const Sys = lib.Sys;

/// Bytes to read in total before the program is done.
const TARGET_BYTES = 3 * 1024 * 1024;

var buf: [64 * 1024]u8 = undefined;

/// Stop with exit status `code`.
fn fail(code: u64) noreturn {
    lib.exit(code);
}

/// Read `/bin/hello` to the end in large reads and return a checksum of it
/// and its size.
fn readAll(total: *u64) u64 {
    const fd = checked.call3(Sys.open, @intFromPtr("/bin/hello"), 0, 0, .{ .flags = 0x4C5 }) orelse fail(1);
    if (lib.isError(fd)) fail(2);
    var sum: u64 = 0xcbf29ce484222325;
    while (true) {
        const n = checked.call3(Sys.read, fd, @intFromPtr(&buf), buf.len, .{ .flags = 0x891 }) orelse fail(3);
        if (lib.isError(n) or n > buf.len) fail(4);
        if (n == 0) break;
        for (buf[0..n]) |b| sum = (sum ^ b) *% 0x100000001b3;
        total.* += n;
    }
    if (checked.call3(Sys.close, fd, 0, 0, .{}) != 0) fail(5);
    return sum;
}

/// Program entry point.
export fn _start() callconv(.c) noreturn {
    var total: u64 = 0;
    const first = readAll(&total);
    if (total == 0) fail(6);
    while (total < TARGET_BYTES) {
        if (readAll(&total) != first) fail(7);
    }
    lib.exit(0);
}
