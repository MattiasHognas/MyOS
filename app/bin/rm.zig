//! `rm [-r] [-f] path...`: remove files; with `-r`, directories and what
//! is in them; with `-f`, no complaint about what is not there.

const std = @import("std");
const u = @import("util");

const AT_REMOVEDIR = 0x200;

var recursive = false;
var force = false;

fn remove(path: [*:0]const u8) bool {
    var st: u.Stat = undefined;
    const s = u.sys4(.newfstatat, u.AT_FDCWD, @intFromPtr(path), @intFromPtr(&st), 0x100); // AT_SYMLINK_NOFOLLOW
    if (u.isErr(s)) {
        if (force and u.errnoOf(s) == 2) return true;
        u.print(2, "rm: cannot remove '{s}': {s}\n", .{ u.span(path), u.message(u.errnoOf(s)) });
        return false;
    }
    if (u.isDir(st.mode)) {
        if (!recursive) {
            u.print(2, "rm: cannot remove '{s}': Is a directory\n", .{u.span(path)});
            return false;
        }
        if (!emptyDir(path)) return false;
        const rc = u.sys3(.unlinkat, u.AT_FDCWD, @intFromPtr(path), AT_REMOVEDIR);
        if (u.isErr(rc)) {
            u.print(2, "rm: cannot remove '{s}': {s}\n", .{ u.span(path), u.message(u.errnoOf(rc)) });
            return false;
        }
        return true;
    }
    const rc = u.sys3(.unlinkat, u.AT_FDCWD, @intFromPtr(path), 0);
    if (u.isErr(rc)) {
        u.print(2, "rm: cannot remove '{s}': {s}\n", .{ u.span(path), u.message(u.errnoOf(rc)) });
        return false;
    }
    return true;
}

/// Remove what is in the directory `path`, one entry at a time, listing
/// it again after each (the listing changes as entries go).
fn emptyDir(path: [*:0]const u8) bool {
    const fd = u.open(path, u.O.RDONLY | u.O.DIRECTORY, 0);
    if (u.isErr(fd)) {
        u.complain("rm", u.span(path), fd);
        return false;
    }
    defer u.close(fd);
    var ok = true;
    var buf: [2048]u8 align(8) = undefined;
    while (true) {
        _ = u.sys3(.lseek, fd, 0, 0);
        const n = u.sys3(.getdents64, fd, @intFromPtr(&buf), buf.len);
        if (u.isErr(n) or n == 0) break;
        var removed = false;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (u.eql(name, ".") or u.eql(name, "..")) continue;
            var full: [4096:0]u8 = undefined;
            const p = u.bufZ(&full, "{s}/{s}", .{ u.span(path), name }) catch return false;
            if (!remove(p)) {
                ok = false;
                continue;
            }
            removed = true;
        }
        if (!removed) break;
    }
    return ok;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const args = init.args.vector;
    var status: u8 = 0;
    var any = false;
    for (args[1..]) |a| {
        const s = u.span(a);
        if (s.len > 1 and s[0] == '-') {
            for (s[1..]) |c| switch (c) {
                'r', 'R' => recursive = true,
                'f' => force = true,
                else => {
                    u.print(2, "rm: invalid option -- '{c}'\n", .{c});
                    return 1;
                },
            };
            continue;
        }
        any = true;
        if (!remove(a)) status = 1;
    }
    if (!any and !force) {
        u.print(2, "rm: missing operand\n", .{});
        return 1;
    }
    return status;
}
