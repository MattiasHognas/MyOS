//! `ls [-a] [-l] [-F] [path...]`: the names in each directory, sorted, one
//! a line; a file's own name for a file. `-a` shows names starting with a
//! dot, `-l` the type and size, `-F` a `/` after directories. With more
//! than one path, each directory's list has its name above it.

const std = @import("std");
const u = @import("util");
const linux = std.os.linux;

var show_all = false;
var long = false;
var classify = false;

/// Names of one directory, in a fixed store (no allocator needed).
var store: [256 * 1024]u8 = undefined;
var names: [8192][]const u8 = undefined;

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn entryLine(out: *u.Out, dir: []const u8, name: []const u8) void {
    if (!long and !classify) {
        out.write(name);
        out.write("\n");
        return;
    }
    var full: [4096:0]u8 = undefined;
    const path = u.bufZ(&full, "{s}/{s}", .{ dir, name }) catch {
        out.print("{s}\n", .{name});
        return;
    };
    var st: u.Stat = undefined;
    const rc = u.sys4(.newfstatat, u.AT_FDCWD, @intFromPtr(path.ptr), @intFromPtr(&st), 0x100);
    const mode: u32 = if (u.isErr(rc)) 0 else st.mode;
    const kind: u8 = switch (mode & 0o170000) {
        0o040000 => 'd',
        0o120000 => 'l',
        0o020000 => 'c',
        0o010000 => 'p',
        else => '-',
    };
    const mark: []const u8 = if (classify and kind == 'd') "/" else if (classify and kind == 'l') "@" else "";
    if (long) {
        out.print("{c} {d:>9} {s}{s}", .{ kind, if (u.isErr(rc)) 0 else st.size, name, mark });
        if (kind == 'l') {
            var target: [4096]u8 = undefined;
            const n = u.sys4(.readlinkat, u.AT_FDCWD, @intFromPtr(path.ptr), @intFromPtr(&target), target.len);
            if (!u.isErr(n)) out.print(" -> {s}", .{target[0..n]});
        }
        out.write("\n");
    } else {
        out.print("{s}{s}\n", .{ name, mark });
    }
}

fn list(out: *u.Out, path: [*:0]const u8, header: bool) bool {
    var st: u.Stat = undefined;
    const s = u.stat(path, &st);
    if (u.isErr(s)) {
        u.print(2, "ls: cannot access '{s}': {s}\n", .{ u.span(path), u.message(u.errnoOf(s)) });
        return false;
    }
    if (!u.isDir(st.mode)) {
        const p = u.span(path);
        const base = if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[0..i] else ".";
        _ = base;
        if (long or classify) entryLine(out, ".", p) else out.print("{s}\n", .{p});
        return true;
    }
    const fd = u.open(path, u.O.RDONLY | u.O.DIRECTORY, 0);
    if (u.isErr(fd)) {
        u.print(2, "ls: cannot open directory '{s}': {s}\n", .{ u.span(path), u.message(u.errnoOf(fd)) });
        return false;
    }
    defer u.close(fd);
    var used: usize = 0;
    var count: usize = 0;
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = u.sys3(.getdents64, fd, @intFromPtr(&buf), buf.len);
        if (u.isErr(n)) {
            u.complain("ls", u.span(path), n);
            return false;
        }
        if (n == 0) break;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (name.len > 0 and name[0] == '.' and !show_all) continue;
            if (count == names.len or name.len > store.len - used) break;
            @memcpy(store[used..][0..name.len], name);
            names[count] = store[used..][0..name.len];
            used += name.len;
            count += 1;
        }
    }
    std.mem.sort([]const u8, names[0..count], {}, lessThan);
    if (header) out.print("{s}:\n", .{u.span(path)});
    for (names[0..count]) |name| entryLine(out, u.span(path), name);
    return true;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const args = init.args.vector;
    var paths: [64][*:0]const u8 = undefined;
    var n: usize = 0;
    for (args[1..]) |a| {
        const s = u.span(a);
        if (s.len > 1 and s[0] == '-') {
            for (s[1..]) |c| switch (c) {
                'a' => show_all = true,
                'l' => long = true,
                'F' => classify = true,
                '1' => {},
                else => {
                    u.print(2, "ls: invalid option -- '{c}'\n", .{c});
                    return 2;
                },
            };
            continue;
        }
        if (n < paths.len) {
            paths[n] = a;
            n += 1;
        }
    }
    if (n == 0) {
        paths[0] = ".";
        n = 1;
    }
    var out: u.Out = .{ .fd = 1 };
    var status: u8 = 0;
    for (paths[0..n], 0..) |p, i| {
        if (i > 0 and n > 1) out.write("\n");
        if (!list(&out, p, n > 1)) status = 2;
    }
    out.flush();
    return status;
}
