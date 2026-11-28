//! `/test/inotify`: being told of changes as Linux tells them. A watch on
//! a directory of `/tmp` hears a file made in it, written, closed after
//! writing, given new times, renamed (`IN_MOVED_FROM` and `IN_MOVED_TO`
//! with one cookie) and removed, each with the entry's name; a watch on a
//! file hears its own changes and, when it goes, `IN_DELETE_SELF` and
//! `IN_IGNORED`; `inotify_rm_watch` gives `IN_IGNORED`; reading waits,
//! or not; `poll` sees it readable; a buffer too small is `EINVAL`.
//! Exits with 0, or with the number of the first failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

const IN_MODIFY = 0x2;
const IN_ATTRIB = 0x4;
const IN_CLOSE_WRITE = 0x8;
const IN_MOVED_FROM = 0x40;
const IN_MOVED_TO = 0x80;
const IN_CREATE = 0x100;
const IN_DELETE = 0x200;
const IN_DELETE_SELF = 0x400;
const IN_IGNORED = 0x8000;
const IN_ISDIR = 0x4000_0000;
const IN_ONLYDIR = 0x0100_0000;
const IN_NONBLOCK = 0o4000;
const IN_CLOEXEC = 0o2000000;

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

const Ev = struct { wd: i32, mask: u32, cookie: u32, name: []const u8 };

var buf: [4096]u8 align(8) = undefined;
var evs: [32]Ev = undefined;

/// Read what is queued (without waiting) into `evs`.
fn drain(fd: u64) []Ev {
    const n = lib.syscall(Sys.read, fd, @intFromPtr(&buf), buf.len);
    if (lib.isError(n)) return evs[0..0];
    var i: usize = 0;
    var count: usize = 0;
    while (i < n and count < evs.len) {
        const len = std.mem.readInt(u32, buf[i + 12 ..][0..4], .little);
        const raw = buf[i + 16 ..][0..len];
        evs[count] = .{
            .wd = std.mem.readInt(i32, buf[i..][0..4], .little),
            .mask = std.mem.readInt(u32, buf[i + 4 ..][0..4], .little),
            .cookie = std.mem.readInt(u32, buf[i + 8 ..][0..4], .little),
            .name = std.mem.sliceTo(raw, 0),
        };
        count += 1;
        i += 16 + len;
    }
    return evs[0..count];
}

fn has(list: []const Ev, wd: i32, mask: u32, name: []const u8) ?Ev {
    for (list) |e| {
        if (e.wd == wd and e.mask == mask and std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

fn path1(nr: u64, p: [*:0]const u8) u64 {
    return lib.syscall(nr, @intFromPtr(p), 0, 0);
}

var dir_buf: [40]u8 = undefined;
var file_buf: [48]u8 = undefined;
var moved_buf: [48]u8 = undefined;

fn z(out: []u8, comptime fmt: []const u8, args: anytype) [*:0]const u8 {
    const t = std.fmt.bufPrint(out[0 .. out.len - 1], fmt, args) catch unreachable;
    out[t.len] = 0;
    return @ptrCast(out.ptr);
}

pub fn main() noreturn {
    const pid = lib.syscall(Sys.getpid, 0, 0, 0);
    const dir = z(&dir_buf, "/tmp/watched-{d}", .{pid});
    const file = z(&file_buf, "/tmp/watched-{d}/f", .{pid});
    const moved = z(&moved_buf, "/tmp/watched-{d}/g", .{pid});
    expect(lib.syscall(Sys.mkdir, @intFromPtr(dir), 0o755, 0) == 0, 1);

    expect(lib.syscall(Sys.inotify_init1, 0x1234, 0, 0) == lib.err(.INVAL), 2);
    const in = lib.syscall(Sys.inotify_init1, IN_NONBLOCK | IN_CLOEXEC, 0, 0);
    expect(!lib.isError(in), 3);
    expect(drain(in).len == 0 and lib.syscall(Sys.read, in, @intFromPtr(&buf), buf.len) == lib.err(.AGAIN), 4);
    const wd = lib.syscall(Sys.inotify_add_watch, in, @intFromPtr(dir), 0xFFF);
    expect(!lib.isError(wd) and wd > 0, 5);
    const w: i32 = @intCast(wd);
    expect(lib.syscall(Sys.inotify_add_watch, in, @intFromPtr(dir), 0xFFF) == wd, 6); // the same path, the same watch
    expect(lib.syscall(Sys.inotify_add_watch, in, @intFromPtr("/tmp/no-such"), 0xFFF) == lib.err(.NOENT), 7);
    expect(lib.syscall(Sys.inotify_add_watch, in, @intFromPtr("/etc/motd"), 0xFFF | IN_ONLYDIR) == lib.err(.NOTDIR), 8);
    expect(lib.syscall(Sys.inotify_add_watch, in, @intFromPtr(dir), 0) == lib.err(.INVAL), 9); // no event

    // --- A file made, written, closed.
    const fd = lib.syscall(Sys.open, @intFromPtr(file), abi.O.WRONLY | abi.O.CREAT, 0o644);
    expect(!lib.isError(fd), 10);
    // poll: readable now.
    var pfd = [1]abi.PollFd{.{ .fd = @intCast(in), .events = abi.POLL.IN, .revents = 0 }};
    expect(lib.syscall(Sys.poll, @intFromPtr(&pfd), 1, 0) == 1 and pfd[0].revents & abi.POLL.IN != 0, 11);
    _ = lib.syscall(Sys.write, fd, @intFromPtr("x"), 1);
    _ = lib.syscall(Sys.close, fd, 0, 0);
    var got = drain(in);
    expect(has(got, w, IN_CREATE, "f") != null, 12);
    expect(has(got, w, IN_MODIFY, "f") != null, 13);
    expect(has(got, w, IN_CLOSE_WRITE, "f") != null, 14);

    // --- A watch on the file itself, and new times.
    const fwd: i32 = @intCast(lib.syscall(Sys.inotify_add_watch, in, @intFromPtr(file), IN_ATTRIB | IN_DELETE_SELF | IN_MODIFY));
    expect(fwd > 0 and fwd != w, 15);
    expect(lib.syscall6(Sys.utimensat, @bitCast(@as(i64, abi.AT_FDCWD)), @intFromPtr(file), 0, 0, 0, 0) == 0, 16);
    got = drain(in);
    expect(has(got, w, IN_ATTRIB, "f") != null and has(got, fwd, IN_ATTRIB, "") != null, 17);

    // --- Renamed: two halves, one cookie.
    expect(lib.syscall(Sys.rename, @intFromPtr(file), @intFromPtr(moved), 0) == 0, 18);
    got = drain(in);
    const from = has(got, w, IN_MOVED_FROM, "f") orelse lib.exit(19);
    const to = has(got, w, IN_MOVED_TO, "g") orelse lib.exit(20);
    expect(from.cookie != 0 and from.cookie == to.cookie, 21);
    // (A watch is on a path: the file's has gone with its name.)
    expect(has(got, fwd, IN_IGNORED, "") != null, 22);

    // --- Removed, and a directory made and removed in it.
    expect(lib.syscall(Sys.mkdir, @intFromPtr(file), 0o755, 0) == 0, 23); // "f" again, as a directory
    expect(path1(Sys.rmdir, file) == 0, 24);
    expect(path1(Sys.unlink, moved) == 0, 25);
    got = drain(in);
    expect(has(got, w, IN_CREATE | IN_ISDIR, "f") != null and has(got, w, IN_DELETE | IN_ISDIR, "f") != null, 26);
    expect(has(got, w, IN_DELETE, "g") != null, 27);

    // --- rm_watch: IN_IGNORED; a buffer too small for one record.
    expect(lib.syscall(Sys.inotify_rm_watch, in, @intCast(w), 0) == 0, 28);
    expect(lib.syscall(Sys.inotify_rm_watch, in, @intCast(w), 0) == lib.err(.INVAL), 29);
    expect(lib.syscall(Sys.read, in, @intFromPtr(&buf), 8) == lib.err(.INVAL), 30);
    got = drain(in);
    expect(got.len == 1 and got[0].wd == w and got[0].mask == IN_IGNORED, 31);

    // --- A read that waits: a child makes the change.
    const blocking = lib.syscall(Sys.inotify_init1, 0, 0, 0);
    const bw: i32 = @intCast(lib.syscall(Sys.inotify_add_watch, blocking, @intFromPtr(dir), IN_CREATE));
    const child = lib.syscall(Sys.fork, 0, 0, 0);
    if (child == 0) {
        var t: abi.TimeSpec = .{ .sec = 0, .nsec = 20_000_000 };
        _ = lib.syscall(Sys.nanosleep, @intFromPtr(&t), 0, 0);
        const c = lib.syscall(Sys.open, @intFromPtr(file), abi.O.WRONLY | abi.O.CREAT, 0o644);
        _ = lib.syscall(Sys.close, c, 0, 0);
        lib.exit(0);
    }
    const n = lib.syscall(Sys.read, blocking, @intFromPtr(&buf), buf.len);
    expect(!lib.isError(n) and n >= 16 and std.mem.readInt(i32, buf[0..4], .little) == bw, 32);
    var status: i32 = 0;
    expect(lib.syscall6(Sys.wait4, child, @intFromPtr(&status), 0, 0, 0, 0) == child and status == 0, 33);

    _ = lib.syscall(Sys.close, blocking, 0, 0);
    _ = lib.syscall(Sys.close, in, 0, 0);
    _ = path1(Sys.unlink, file);
    expect(path1(Sys.rmdir, dir) == 0, 34);
    lib.exit(0);
}
