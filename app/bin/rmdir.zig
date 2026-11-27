//! `rmdir dir...`: remove empty directories.

const std = @import("std");
const u = @import("util");

pub fn main(init: std.process.Init.Minimal) u8 {
    const args = init.args.vector;
    if (args.len < 2) {
        u.print(2, "rmdir: missing operand\n", .{});
        return 1;
    }
    var status: u8 = 0;
    for (args[1..]) |a| {
        const rc = u.sys3(.unlinkat, u.AT_FDCWD, @intFromPtr(a), 0x200); // AT_REMOVEDIR
        if (u.isErr(rc)) {
            u.print(2, "rmdir: failed to remove '{s}': {s}\n", .{ u.span(a), u.message(u.errnoOf(rc)) });
            status = 1;
        }
    }
    return status;
}
