//! `mkdir [-p] dir...`: make directories; with `-p`, the ones on the way
//! too, and no error for one that is there.

const std = @import("std");
const u = @import("util");

fn make(path: [*:0]const u8, parents: bool) usize {
    const rc = u.sys3(.mkdirat, u.AT_FDCWD, @intFromPtr(path), 0o755);
    if (!u.isErr(rc) or !parents) return rc;
    if (u.errnoOf(rc) == 17) return 0; // EEXIST
    if (u.errnoOf(rc) != 2) return rc; // ENOENT: the parent is missing
    var copy: [4096:0]u8 = undefined;
    const s = u.span(path);
    if (s.len >= copy.len) return rc;
    const cut = std.mem.lastIndexOfScalar(u8, std.mem.trimEnd(u8, s, "/"), '/') orelse return rc;
    if (cut == 0) return rc;
    @memcpy(copy[0..cut], s[0..cut]);
    copy[cut] = 0;
    const up = make(&copy, true);
    if (u.isErr(up)) return up;
    const again = u.sys3(.mkdirat, u.AT_FDCWD, @intFromPtr(path), 0o755);
    return if (u.isErr(again) and u.errnoOf(again) == 17) 0 else again;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const args = init.args.vector;
    var parents = false;
    var status: u8 = 0;
    var any = false;
    for (args[1..]) |a| {
        if (u.eql(u.span(a), "-p")) {
            parents = true;
            continue;
        }
        any = true;
        const rc = make(a, parents);
        if (u.isErr(rc)) {
            u.print(2, "mkdir: cannot create directory '{s}': {s}\n", .{ u.span(a), u.message(u.errnoOf(rc)) });
            status = 1;
        }
    }
    if (!any) {
        u.print(2, "mkdir: missing operand\n", .{});
        return 1;
    }
    return status;
}
