//! `/test/tmp`: a filesystem that can be written, at `/tmp`: files made,
//! written, cut short, renamed and removed; directories; a program copied
//! there and run; and the read-only filesystem beside it, which still
//! refuses all of that.
//!
//! Everything it makes is under a directory named after its process, and
//! is removed again: the kernel test checks that nothing is left. Exits
//! with 0, or with the number of the first failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;
const O = abi.O;
const S = abi.S;

const CWD: u64 = @bitCast(@as(i64, abi.AT_FDCWD));

fn expect(ok: bool, check: u64) void {
    if (!ok) lib.exit(check);
}

fn open(path: [*:0]const u8, flags: u64) u64 {
    return lib.syscall(Sys.open, @intFromPtr(path), flags, 0o644);
}

fn write(fd: u64, data: []const u8) u64 {
    return lib.syscall(Sys.write, fd, @intFromPtr(data.ptr), data.len);
}

fn stat(path: [*:0]const u8) ?abi.Stat {
    var st: abi.Stat = undefined;
    return if (lib.syscall(Sys.stat, @intFromPtr(path), @intFromPtr(&st), 0) == 0) st else null;
}

fn call1(nr: u64, path: [*:0]const u8) u64 {
    return lib.syscall(nr, @intFromPtr(path), 0o755, 0);
}

fn rename(old: [*:0]const u8, new: [*:0]const u8) u64 {
    return lib.syscall(Sys.rename, @intFromPtr(old), @intFromPtr(new), 0);
}

var buf: [4096]u8 = undefined;

/// The whole of the file at `path`, as far as `buf` holds it.
fn contents(path: [*:0]const u8) []const u8 {
    const fd = open(path, O.RDONLY);
    if (lib.isError(fd)) return "<cannot open>";
    defer _ = lib.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = lib.read(fd, buf[len..]);
        if (lib.isError(n) or n == 0) break;
        len += n;
    }
    return buf[0..len];
}

fn put(path: [*:0]const u8, text: []const u8) void {
    const fd = open(path, O.WRONLY | O.CREAT | O.TRUNC);
    if (lib.isError(fd) or write(fd, text) != text.len) lib.exit(250);
    _ = lib.close(fd);
}

var list_buf: [512]u8 = undefined;
var dents: [1024]u8 align(8) = undefined;

/// The names in the directory at `path` without "." and "..", in the
/// order of the bytes of their names, joined with spaces.
fn listing(path: [*:0]const u8) []const u8 {
    const fd = open(path, O.RDONLY | O.DIRECTORY);
    if (lib.isError(fd)) return "<cannot open>";
    defer _ = lib.close(fd);
    var found: [16][]const u8 = undefined;
    var count: usize = 0;
    var names: [512]u8 = undefined;
    var names_len: usize = 0;
    while (true) {
        const n = lib.syscall(Sys.getdents64, fd, @intFromPtr(&dents), dents.len);
        if (lib.isError(n) or n == 0) break;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, dents[at + 16 ..][0..2], .little);
            const name = std.mem.sliceTo(dents[at + 19 .. at + reclen], 0);
            at += reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            @memcpy(names[names_len..][0..name.len], name);
            found[count] = names[names_len..][0..name.len];
            names_len += name.len;
            count += 1;
        }
    }
    std.mem.sort([]const u8, found[0..count], {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    var len: usize = 0;
    for (found[0..count], 0..) |name, i| {
        if (i != 0) {
            list_buf[len] = ' ';
            len += 1;
        }
        @memcpy(list_buf[len..][0..name.len], name);
        len += name.len;
    }
    return list_buf[0..len];
}

pub fn main() noreturn {
    // --- /tmp is there, a directory, and can be written; the rest cannot.
    expect(stat("/tmp").?.mode & S.IFMT == S.IFDIR, 1);
    expect(lib.syscall(Sys.access, @intFromPtr("/tmp"), abi.ACCESS.W_OK, 0) == 0, 2);
    expect(open("/etc/new", O.WRONLY | O.CREAT) == lib.err(.ROFS), 3);
    expect(open("/etc/motd", O.WRONLY) == lib.err(.ROFS) and open("/etc/motd", O.RDWR) == lib.err(.ROFS), 4);
    expect(call1(Sys.mkdir, "/etc/dir") == lib.err(.ROFS) and call1(Sys.unlink, "/etc/motd") == lib.err(.ROFS), 5);
    expect(rename("/etc/motd", "/etc/other") == lib.err(.ROFS), 6);
    expect(lib.syscall(Sys.truncate, @intFromPtr("/etc/motd"), 0, 0) == lib.err(.ROFS), 7);
    expect(std.mem.eql(u8, contents("/etc/motd"), "Welcome to MyOS!\n"), 8); // and is as it was

    // Everything else happens in a directory of this process's own.
    var dir_buf: [32]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "/tmp/t{d}\x00", .{lib.syscall(Sys.getpid, 0, 0, 0)}) catch unreachable;
    const dir_z: [*:0]const u8 = @ptrCast(dir.ptr);
    expect(call1(Sys.mkdir, dir_z) == 0, 10);
    expect(call1(Sys.mkdir, dir_z) == lib.err(.EXIST), 11);
    expect(lib.syscall(Sys.chdir, @intFromPtr(dir_z), 0, 0) == 0, 12);
    expect(std.mem.eql(u8, listing("."), ""), 13);

    // --- A file: made, written, read back.
    expect(open("note", O.RDONLY) == lib.err(.NOENT), 20);
    const fd = open("note", O.WRONLY | O.CREAT | O.EXCL);
    expect(!lib.isError(fd), 21);
    expect(open("note", O.WRONLY | O.CREAT | O.EXCL) == lib.err(.EXIST), 22);
    expect(write(fd, "hello, ") == 7 and write(fd, "file") == 4, 23);
    expect(lib.read(fd, buf[0..4]) == lib.err(.BADF), 24); // open for writing only
    expect(lib.syscall(Sys.fcntl, fd, 3, 0) == O.WRONLY, 25);
    var st: abi.Stat = undefined;
    expect(lib.syscall(Sys.fstat, fd, @intFromPtr(&st), 0) == 0 and st.size == 11 and st.mode == S.IFREG | 0o644, 26);
    expect(lib.close(fd) == 0, 27);
    expect(std.mem.eql(u8, contents("note"), "hello, file"), 28);
    expect(stat("note").?.size == 11 and std.mem.eql(u8, listing("."), "note"), 29);
    const ro = open("note", O.RDONLY);
    expect(write(ro, "x") == lib.err(.BADF) and lib.syscall(Sys.ftruncate, ro, 0, 0) == lib.err(.INVAL), 30);
    expect(lib.syscall6(Sys.mmap, 0, 4096, abi.PROT.READ, abi.MAP.PRIVATE, ro, 0) == lib.err(.NODEV), 31); // cannot be mapped
    _ = lib.close(ro);

    // Offsets: in the middle, past the end (the gap is zeroes), at a place
    // of the caller's choosing, always at the end.
    const rw = open("note", O.RDWR);
    expect(lib.syscall(Sys.lseek, rw, 7, abi.SEEK.SET) == 7 and write(rw, "FILE") == 4, 35);
    expect(lib.syscall(Sys.lseek, rw, 3, abi.SEEK.END) == 14 and write(rw, "!") == 1, 36);
    expect(std.mem.eql(u8, contents("note"), "hello, FILE\x00\x00\x00!"), 37);
    expect(lib.syscall6(Sys.pwrite64, rw, @intFromPtr("J"), 1, 0, 0, 0) == 1, 38);
    expect(lib.syscall(Sys.lseek, rw, 0, abi.SEEK.CUR) == 15, 39); // pwrite leaves the offset alone
    const ap = open("note", O.WRONLY | O.APPEND);
    expect(write(ap, "++") == 2 and lib.syscall(Sys.lseek, ap, 0, abi.SEEK.SET) == 0 and write(ap, "++") == 2, 40);
    expect(lib.syscall(Sys.fcntl, ap, 3, 0) == O.WRONLY | O.APPEND, 41);
    _ = lib.close(ap);
    expect(std.mem.eql(u8, contents("note"), "Jello, FILE\x00\x00\x00!++++"), 42);
    // Cut short, grown with zeroes, emptied on opening.
    expect(lib.syscall(Sys.ftruncate, rw, 5, 0) == 0 and std.mem.eql(u8, contents("note"), "Jello"), 43);
    expect(lib.syscall(Sys.ftruncate, rw, 8, 0) == 0 and std.mem.eql(u8, contents("note"), "Jello\x00\x00\x00"), 44);
    expect(lib.syscall(Sys.truncate, @intFromPtr("note"), 2, 0) == 0 and stat("note").?.size == 2, 45);
    expect(lib.syscall(Sys.ftruncate, rw, ~@as(u64, 0), 0) == lib.err(.INVAL), 46);
    expect(lib.syscall(Sys.ftruncate, rw, 1 << 40, 0) == lib.err(.FBIG), 47);
    expect(lib.syscall(Sys.fsync, rw, 0, 0) == 0 and lib.syscall(Sys.fchmod, rw, 0o600, 0) == 0, 48);
    _ = lib.close(rw);
    put("note", "new");
    expect(std.mem.eql(u8, contents("note"), "new"), 49);

    // readv: one read into several buffers, short where the file ends.
    put("vec", "abcdefghij");
    const vfd = open("vec", O.RDONLY);
    var part1: [3]u8 = undefined;
    var part2: [4]u8 = undefined;
    var part3: [8]u8 = undefined;
    const iov = [_]abi.IoVec{
        .{ .base = @intFromPtr(&part1), .len = part1.len },
        .{ .base = 0, .len = 0 }, // an empty one is skipped
        .{ .base = @intFromPtr(&part2), .len = part2.len },
        .{ .base = @intFromPtr(&part3), .len = part3.len },
    };
    expect(lib.syscall(Sys.readv, vfd, @intFromPtr(&iov), iov.len) == 10, 55);
    expect(std.mem.eql(u8, &part1, "abc") and std.mem.eql(u8, &part2, "defg") and std.mem.eql(u8, part3[0..3], "hij"), 56);
    expect(lib.syscall(Sys.readv, vfd, @intFromPtr(&iov), iov.len) == 0, 57); // at the end
    expect(lib.syscall(Sys.readv, vfd, 8, 1) == lib.err(.FAULT) and lib.syscall(Sys.readv, 99, @intFromPtr(&iov), 1) == lib.err(.BADF), 58);
    expect(lib.syscall(Sys.readv, vfd, @intFromPtr(&iov), 5000) == lib.err(.INVAL), 59);
    _ = lib.close(vfd);
    expect(call1(Sys.unlink, "vec") == 0, 64);

    // --- A megabyte, in pieces that do not match the blocks it is kept in.
    const big = open("big", O.RDWR | O.CREAT);
    var piece: [1000]u8 = undefined;
    var total: usize = 0;
    while (total < 1 << 20) {
        for (&piece, 0..) |*b, i| b.* = @truncate((total + i) *% 31 >> 3);
        expect(write(big, &piece) == piece.len, 50);
        total += piece.len;
    }
    expect(lib.syscall(Sys.lseek, big, 0, abi.SEEK.SET) == 0, 51);
    var at: usize = 0;
    while (at < total) {
        const n = lib.read(big, piece[0..777]);
        expect(n == @min(777, total - at), 52);
        for (piece[0..n], 0..) |b, i| expect(b == @as(u8, @truncate((at + i) *% 31 >> 3)), 53);
        at += n;
    }
    expect(lib.read(big, &piece) == 0, 54);
    _ = lib.close(big);

    // --- A removed file lives on for whoever has it open.
    const held = open("big", O.RDONLY);
    expect(call1(Sys.unlink, "big") == 0 and call1(Sys.unlink, "big") == lib.err(.NOENT), 60);
    expect(stat("big") == null and std.mem.eql(u8, listing("."), "note"), 61);
    expect(lib.syscall6(Sys.pread64, held, @intFromPtr(&piece), 4, 1 << 19, 0, 0) == 4, 62);
    expect(piece[0] == @as(u8, @truncate((1 << 19) *% 31 >> 3)), 63);
    _ = lib.close(held);

    // --- Directories.
    expect(call1(Sys.mkdir, "sub") == 0 and call1(Sys.mkdir, "sub/deeper") == 0, 70);
    expect(call1(Sys.mkdir, "no/such/place") == lib.err(.NOENT) and call1(Sys.mkdir, "note/inside") == lib.err(.NOTDIR), 71);
    put("sub/a", "A");
    put("sub/deeper/b", "B");
    expect(std.mem.eql(u8, listing("."), "note sub") and std.mem.eql(u8, listing("sub"), "a deeper"), 72);
    expect(std.mem.eql(u8, contents("sub/../sub/./deeper/b"), "B"), 73);
    expect(call1(Sys.rmdir, "sub") == lib.err(.NOTEMPTY) and call1(Sys.rmdir, "note") == lib.err(.NOTDIR), 74);
    expect(call1(Sys.unlink, "sub") == lib.err(.ISDIR) and call1(Sys.rmdir, "nothing") == lib.err(.NOENT), 75);
    expect(open("sub", O.WRONLY) == lib.err(.ISDIR) and open("sub/new/", O.WRONLY | O.CREAT) == lib.err(.ISDIR), 76);
    // In a directory by its descriptor.
    const sub = open("sub", O.RDONLY | O.DIRECTORY);
    const made = lib.syscall6(Sys.openat, sub, @intFromPtr("c"), O.WRONLY | O.CREAT, 0o644, 0, 0);
    expect(!lib.isError(made) and write(made, "C") == 1 and lib.close(made) == 0, 77);
    expect(lib.syscall(Sys.mkdirat, sub, @intFromPtr("d"), 0o755) == 0, 78);
    expect(lib.syscall(Sys.unlinkat, sub, @intFromPtr("d"), abi.AT_REMOVEDIR) == 0, 79);
    expect(lib.syscall(Sys.unlinkat, sub, @intFromPtr("c"), 0) == 0 and lib.syscall(Sys.unlinkat, sub, @intFromPtr("a"), 8) == lib.err(.INVAL), 80);
    _ = lib.close(sub);

    // --- Renaming.
    expect(rename("note", "letter") == 0 and stat("note") == null and std.mem.eql(u8, contents("letter"), "new"), 85);
    put("other", "old contents");
    expect(rename("letter", "other") == 0 and std.mem.eql(u8, contents("other"), "new"), 86); // replaced
    expect(rename("sub", "moved") == 0 and std.mem.eql(u8, contents("moved/deeper/b"), "B") and stat("sub") == null, 87);
    expect(rename("other", "moved/deeper/other") == 0 and std.mem.eql(u8, listing("moved/deeper"), "b other"), 88);
    expect(rename("nothing", "x") == lib.err(.NOENT) and rename("moved", "moved/deeper/again") == lib.err(.INVAL), 89);
    put("plain", "a file");
    expect(rename("moved", "plain") == lib.err(.NOTDIR) and rename("plain", "moved") == lib.err(.ISDIR), 90); // not one kind onto the other
    expect(rename("moved", "moved/deeper/b") == lib.err(.INVAL) and call1(Sys.unlink, "plain") == 0, 96);
    expect(rename("moved/a", "/etc/a") == lib.err(.XDEV) and rename("/etc/motd", "motd") == lib.err(.XDEV), 91); // not between filesystems
    expect(lib.syscall6(Sys.renameat2, CWD, @intFromPtr("moved/a"), CWD, @intFromPtr("moved/z"), 1, 0) == lib.err(.INVAL), 92); // no flags
    // The mount point itself stays what and where it is.
    expect(call1(Sys.rmdir, "/tmp") == lib.err(.BUSY) and call1(Sys.unlink, "/tmp") == lib.err(.ISDIR), 93);
    expect(rename("/tmp", "/tmp2") == lib.err(.BUSY) and call1(Sys.mkdir, "/tmp") == lib.err(.EXIST), 94);
    // A FIFO can be made here (`/test/fifo` uses one), and removed again.
    expect(lib.syscall6(Sys.mknodat, CWD, @intFromPtr("fifo"), S.IFIFO | 0o600, 0, 0, 0) == 0 and call1(Sys.unlink, "fifo") == 0, 95);

    // --- A program copied here runs from here.
    const src = open("/bin/hello", O.RDONLY);
    const dst = open("hello", O.WRONLY | O.CREAT);
    while (true) {
        const n = lib.read(src, &buf);
        expect(!lib.isError(n), 100);
        if (n == 0) break;
        expect(write(dst, buf[0..n]) == n, 101);
    }
    _ = lib.close(src);
    _ = lib.close(dst);
    expect(stat("hello").?.size == stat("/bin/hello").?.size, 102);
    expect(lib.run("hello") == 0 and lib.run("./hello") == 0, 103);
    put("hello", "not a program any more");
    expect(lib.run("hello") == lib.err(.NOEXEC), 104);

    // --- Links: symbolic ones, followed; hard ones, the same file twice.
    put("target", "linked");
    expect(lib.syscall(Sys.symlink, @intFromPtr("target"), @intFromPtr("soft"), 0) == 0, 120);
    expect(std.mem.eql(u8, contents("soft"), "linked"), 121); // followed
    var lbuf: [32]u8 = undefined;
    expect(lib.syscall(Sys.readlink, @intFromPtr("soft"), @intFromPtr(&lbuf), lbuf.len) == 6 and std.mem.eql(u8, lbuf[0..6], "target"), 122);
    {
        var lst: abi.Stat = .{};
        expect(lib.syscall6(Sys.newfstatat, CWD, @intFromPtr("soft"), @intFromPtr(&lst), abi.AT_SYMLINK_NOFOLLOW, 0, 0) == 0 and lst.mode & S.IFMT == S.IFLNK, 123);
    }
    expect(lib.syscall(Sys.symlink, @intFromPtr("x"), @intFromPtr("soft"), 0) == lib.err(.EXIST), 124);
    expect(lib.syscall(Sys.symlink, @intFromPtr("nowhere"), @intFromPtr("dangling"), 0) == 0, 125); // need not exist
    expect(open("dangling", O.RDONLY) == lib.err(.NOENT), 126);
    expect(lib.syscall(Sys.symlink, @intFromPtr("x"), @intFromPtr("/etc/x"), 0) == lib.err(.ROFS), 127);
    expect(lib.syscall(Sys.link, @intFromPtr("target"), @intFromPtr("hard"), 0) == 0, 128);
    const a = stat("target").?;
    const b = stat("hard").?;
    expect(a.ino == b.ino and a.nlink == 2 and b.nlink == 2, 129);
    put("hard", "changed"); // through one name, seen through the other
    expect(std.mem.eql(u8, contents("target"), "changed"), 130);
    expect(call1(Sys.unlink, "target") == 0 and stat("hard").?.nlink == 1 and std.mem.eql(u8, contents("hard"), "changed"), 131);
    expect(lib.syscall(Sys.link, @intFromPtr("."), @intFromPtr("dirlink"), 0) == lib.err(.PERM), 132); // no directory
    expect(lib.syscall(Sys.link, @intFromPtr("/etc/motd"), @intFromPtr("motd"), 0) == lib.err(.XDEV), 133);
    expect(call1(Sys.unlink, "soft") == 0 and call1(Sys.unlink, "dangling") == 0 and call1(Sys.unlink, "hard") == 0, 134);

    // --- Times: set by writing, by utimensat and futimens.
    {
        put("timed", "x");
        const t0 = stat("timed").?;
        expect(t0.mtime.sec > 1_700_000_000, 135); // the wall clock, not 1970
        const times = [2]abi.TimeSpec{ .{ .sec = 1000, .nsec = 5 }, .{ .sec = 2000, .nsec = 7 } };
        expect(lib.syscall6(Sys.utimensat, CWD, @intFromPtr("timed"), @intFromPtr(&times), 0, 0, 0) == 0, 136);
        const t1 = stat("timed").?;
        expect(t1.atime.sec == 1000 and t1.atime.nsec == 5 and t1.mtime.sec == 2000 and t1.mtime.nsec == 7, 137);
        // UTIME_OMIT keeps one, UTIME_NOW sets it to now.
        const some = [2]abi.TimeSpec{ .{ .sec = 0, .nsec = abi.UTIME_OMIT }, .{ .sec = 0, .nsec = abi.UTIME_NOW } };
        expect(lib.syscall6(Sys.utimensat, CWD, @intFromPtr("timed"), @intFromPtr(&some), 0, 0, 0) == 0, 138);
        const t2 = stat("timed").?;
        expect(t2.atime.sec == 1000 and t2.mtime.sec > 1_700_000_000, 139);
        // futimens: the descriptor's file, all of it now.
        const tfd = open("timed", O.RDWR);
        expect(lib.syscall6(Sys.utimensat, tfd, 0, 0, 0, 0, 0) == 0 and stat("timed").?.atime.sec > 1_700_000_000, 140);
        _ = lib.syscall(Sys.close, tfd, 0, 0);
        const bad = [2]abi.TimeSpec{ .{ .sec = 0, .nsec = 2_000_000_000 }, .{ .sec = 0, .nsec = 0 } };
        expect(lib.syscall6(Sys.utimensat, CWD, @intFromPtr("timed"), @intFromPtr(&bad), 0, 0, 0) == lib.err(.INVAL), 141);
        expect(lib.syscall6(Sys.utimensat, CWD, @intFromPtr("/etc/motd"), 0, 0, 0, 0) == lib.err(.ROFS), 142);
        expect(stat("/etc/motd").?.mtime.sec > 1_700_000_000, 143); // the image's: when the system started
        expect(call1(Sys.unlink, "timed") == 0, 144);
    }

    // --- fallocate, posix_fadvise, sendfile, copy_file_range.
    {
        put("src", "0123456789");
        const sfd = open("src", O.RDWR);
        expect(lib.syscall6(Sys.fallocate, sfd, 0, 0, 20, 0, 0) == 0 and stat("src").?.size == 20, 150); // longer
        expect(lib.syscall6(Sys.fallocate, sfd, 1, 0, 100, 0, 0) == 0 and stat("src").?.size == 20, 151); // KEEP_SIZE
        expect(lib.syscall6(Sys.fallocate, sfd, 3, 0, 4, 0, 0) == lib.err(.OPNOTSUPP), 152); // punch a hole
        expect(lib.syscall6(Sys.fallocate, sfd, 0, 0, 0, 0, 0) == lib.err(.INVAL), 153);
        _ = lib.syscall(Sys.ftruncate, sfd, 10, 0);
        expect(lib.syscall6(Sys.fadvise64, sfd, 0, 0, 2, 0, 0) == 0 and lib.syscall6(Sys.fadvise64, sfd, 0, 0, 9, 0, 0) == lib.err(.INVAL), 154);
        // sendfile into a pipe, from an offset given (the file's stays).
        var p: [2]i32 = undefined;
        expect(lib.syscall(Sys.pipe2, @intFromPtr(&p), 0, 0) == 0, 155);
        var off: u64 = 3;
        expect(lib.syscall6(Sys.sendfile, @intCast(p[1]), sfd, @intFromPtr(&off), 4, 0, 0) == 4 and off == 7, 156);
        var got: [8]u8 = undefined;
        expect(lib.read(@intCast(p[0]), &got) == 4 and std.mem.eql(u8, got[0..4], "3456"), 157);
        expect(lib.syscall6(Sys.sendfile, sfd, @intCast(p[0]), 0, 4, 0, 0) == lib.err(.INVAL), 158); // from a pipe
        _ = lib.syscall(Sys.close, @intCast(p[0]), 0, 0);
        _ = lib.syscall(Sys.close, @intCast(p[1]), 0, 0);
        // copy_file_range: between two files, from offsets that move.
        const dfd = open("dst", O.RDWR | O.CREAT);
        var in_off: u64 = 5;
        expect(lib.syscall6(Sys.copy_file_range, sfd, @intFromPtr(&in_off), dfd, 0, 5, 0) == 5 and in_off == 10, 159);
        expect(std.mem.eql(u8, contents("dst"), "56789"), 160);
        expect(lib.syscall6(Sys.copy_file_range, sfd, 0, dfd, 0, 5, 1) == lib.err(.INVAL), 161); // flags
        _ = lib.syscall(Sys.close, sfd, 0, 0);
        _ = lib.syscall(Sys.close, dfd, 0, 0);
        expect(call1(Sys.unlink, "src") == 0 and call1(Sys.unlink, "dst") == 0, 162);
    }

    // --- And away with all of it.
    expect(call1(Sys.unlink, "hello") == 0 and call1(Sys.unlink, "moved/a") == 0, 110);
    expect(call1(Sys.unlink, "moved/deeper/b") == 0 and call1(Sys.unlink, "moved/deeper/other") == 0, 111);
    expect(call1(Sys.rmdir, "moved/deeper") == 0 and call1(Sys.rmdir, "moved") == 0, 112);
    expect(std.mem.eql(u8, listing("."), ""), 113);
    // The directory a process is in can be removed under it; it is then nowhere.
    expect(call1(Sys.rmdir, dir_z) == 0 and stat(dir_z) == null, 114);
    expect(open("again", O.WRONLY | O.CREAT) == lib.err(.NOENT) and stat(".") == null, 115);
    expect(lib.syscall(Sys.chdir, @intFromPtr("/"), 0, 0) == 0, 116);

    lib.exit(0);
}
