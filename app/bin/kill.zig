//! `kill [-signal] pid...`: send a signal (TERM unless one is given, by
//! number or name) to processes; a negative ID is a process group.

const std = @import("std");
const u = @import("util");

const names = [_]struct { []const u8, u32 }{
    .{ "HUP", 1 },   .{ "INT", 2 },   .{ "QUIT", 3 },  .{ "KILL", 9 },  .{ "USR1", 10 },
    .{ "USR2", 12 }, .{ "PIPE", 13 }, .{ "ALRM", 14 }, .{ "TERM", 15 }, .{ "CHLD", 17 },
    .{ "CONT", 18 }, .{ "STOP", 19 }, .{ "TSTP", 20 },
};

fn signalNumber(s: []const u8) ?u32 {
    if (std.fmt.parseInt(u32, s, 10)) |n| return n else |_| {}
    const name = if (std.mem.startsWith(u8, s, "SIG")) s[3..] else s;
    for (names) |n| if (u.eql(n[0], name)) return n[1];
    return null;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const args = init.args.vector;
    var sig: u32 = 15;
    var first: usize = 1;
    if (args.len > 1) {
        const a = u.span(args[1]);
        if (a.len > 1 and a[0] == '-' and !std.ascii.isDigit(a[1]) or (a.len > 1 and a[0] == '-' and args.len > 2)) {
            sig = signalNumber(a[1..]) orelse {
                u.print(2, "kill: {s}: invalid signal specification\n", .{a[1..]});
                return 1;
            };
            first = 2;
        }
    }
    if (args.len <= first) {
        u.print(2, "kill: usage: kill [-signal] pid...\n", .{});
        return 1;
    }
    var status: u8 = 0;
    for (args[first..]) |a| {
        const pid = std.fmt.parseInt(i32, u.span(a), 10) catch {
            u.print(2, "kill: {s}: arguments must be process IDs\n", .{u.span(a)});
            status = 1;
            continue;
        };
        const rc = u.sys2(.kill, @bitCast(@as(isize, pid)), sig);
        if (u.isErr(rc)) {
            u.print(2, "kill: ({d}) - {s}\n", .{ pid, u.message(u.errnoOf(rc)) });
            status = 1;
        }
    }
    return status;
}
