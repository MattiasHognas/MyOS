//! `echo [-n] [word...]`: the words, separated by spaces, and a newline
//! unless `-n` is first.

const std = @import("std");
const u = @import("util");

pub fn main(init: std.process.Init.Minimal) u8 {
    const args = init.args.vector;
    var first: usize = 1;
    var newline = true;
    if (args.len > 1 and u.eql(u.span(args[1]), "-n")) {
        newline = false;
        first = 2;
    }
    var out: u.Out = .{ .fd = 1 };
    for (args[@min(first, args.len)..], 0..) |a, i| {
        if (i > 0) out.write(" ");
        out.write(u.span(a));
    }
    if (newline) out.write("\n");
    out.flush();
    return 0;
}
