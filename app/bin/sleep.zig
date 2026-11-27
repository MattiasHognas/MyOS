//! `sleep seconds`: wait that long (a whole or a decimal number).

const std = @import("std");
const u = @import("util");

pub fn main(init: std.process.Init.Minimal) u8 {
    const args = init.args.vector;
    if (args.len != 2) {
        u.print(2, "sleep: missing operand\n", .{});
        return 1;
    }
    const secs = std.fmt.parseFloat(f64, u.span(args[1])) catch {
        u.print(2, "sleep: invalid time interval '{s}'\n", .{u.span(args[1])});
        return 1;
    };
    if (secs < 0) return 1;
    const whole: u64 = @intFromFloat(@floor(secs));
    const ts = std.os.linux.timespec{ .sec = @intCast(whole), .nsec = @intFromFloat((secs - @floor(secs)) * 1e9) };
    while (true) {
        const rc = u.sys2(.nanosleep, @intFromPtr(&ts), 0);
        if (!u.isErr(rc) or u.errnoOf(rc) != 4) break;
    }
    return 0;
}
