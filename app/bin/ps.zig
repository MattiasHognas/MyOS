//! `ps`: every process, from `/proc`: its ID, its parent's, its state
//! (R running or ready, S waiting, Z ended and not collected) and its
//! command line.

const std = @import("std");
const u = @import("util");

fn readAll(path: [*:0]const u8, buf: []u8) ?[]u8 {
    const fd = u.open(path, u.O.RDONLY, 0);
    if (u.isErr(fd)) return null;
    defer u.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = u.read(fd, buf[len..]);
        if (u.isErr(n) or n == 0) break;
        len += n;
    }
    return buf[0..len];
}

pub fn main() u8 {
    var out: u.Out = .{ .fd = 1 };
    out.write("  PID  PPID S CMD\n");
    const fd = u.open("/proc", u.O.RDONLY | u.O.DIRECTORY, 0);
    if (u.isErr(fd)) {
        u.complain("ps", "/proc", fd);
        return 1;
    }
    defer u.close(fd);
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = u.sys3(.getdents64, fd, @intFromPtr(&buf), buf.len);
        if (u.isErr(n) or n == 0) break;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            const pid = std.fmt.parseInt(u64, name, 10) catch continue;
            var path: [64:0]u8 = undefined;
            var stat_buf: [512]u8 = undefined;
            var cmd_buf: [256]u8 = undefined;
            const stat = readAll(u.bufZ(&path, "/proc/{d}/stat", .{pid}) catch continue, &stat_buf) orelse continue;
            // "pid (comm) S ppid ...": the fields after the closing parenthesis.
            const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse continue;
            var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
            const state = fields.next() orelse "?";
            const ppid = fields.next() orelse "?";
            const cmd: []u8 = readAll(u.bufZ(&path, "/proc/{d}/cmdline", .{pid}) catch continue, &cmd_buf) orelse cmd_buf[0..0];
            // NULs between the arguments become spaces.
            for (cmd) |*c| {
                if (c.* == 0) c.* = ' ';
            }
            const comm = stat[std.mem.indexOfScalar(u8, stat, '(').? + 1 .. close];
            const line = std.mem.trimEnd(u8, cmd, " ");
            out.print("{d:>5} {s:>5} {s} {s}\n", .{ pid, ppid, state, if (line.len > 0) line else comm });
        }
    }
    out.flush();
    return 0;
}
