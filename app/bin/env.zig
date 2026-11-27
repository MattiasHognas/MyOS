//! `env`: the environment, a variable a line.

const std = @import("std");
const u = @import("util");

pub fn main(init: std.process.Init.Minimal) u8 {
    var out: u.Out = .{ .fd = 1 };
    for (init.environ.block.slice) |e| {
        out.write(u.span(e.?));
        out.write("\n");
    }
    out.flush();
    return 0;
}
