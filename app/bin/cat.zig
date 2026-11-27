//! `cat [file...]`: the files one after the other on standard output;
//! standard input for none, or for `-`.

const std = @import("std");
const u = @import("util");

var buf: [16384]u8 = undefined;

fn copy(fd: usize, name: []const u8) bool {
    while (true) {
        const n = u.read(fd, &buf);
        if (u.isErr(n)) {
            if (u.errnoOf(n) == 4) continue;
            u.complain("cat", name, n);
            return false;
        }
        if (n == 0) return true;
        if (!u.writeAll(1, buf[0..n])) return false;
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const args = init.args.vector;
    if (args.len < 2) return if (copy(0, "-")) 0 else 1;
    var status: u8 = 0;
    for (args[1..]) |a| {
        const name = u.span(a);
        if (u.eql(name, "-")) {
            if (!copy(0, "-")) status = 1;
            continue;
        }
        const fd = u.open(a, u.O.RDONLY, 0);
        if (u.isErr(fd)) {
            u.complain("cat", name, fd);
            status = 1;
            continue;
        }
        if (!copy(fd, name)) status = 1;
        u.close(fd);
    }
    return status;
}
