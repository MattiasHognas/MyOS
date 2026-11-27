//! `pwd`: the working directory.

const std = @import("std");
const u = @import("util");

pub fn main() u8 {
    var buf: [4096]u8 = undefined;
    const n = u.sys2(.getcwd, @intFromPtr(&buf), buf.len);
    if (u.isErr(n)) {
        u.complain("pwd", ".", n);
        return 1;
    }
    const path = std.mem.sliceTo(&buf, 0);
    u.print(1, "{s}\n", .{path});
    return 0;
}
