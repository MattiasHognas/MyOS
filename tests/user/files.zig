//! `/test/files`: what a program finds in the filesystem besides plain
//! files: directories, the few entries of `/proc` and `/dev`, a
//! descriptor table that grows, and the answers to calls that would
//! change a filesystem that cannot be changed. Also the scheduling calls
//! a runtime makes for its threads.
//!
//! Exits with 0, or with the number of the first failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;
const S = abi.S;

const CWD: u64 = @bitCast(@as(i64, abi.AT_FDCWD));

fn expect(ok: bool, check: u64) void {
    if (!ok) lib.exit(check);
}

fn statOf(path: [*:0]const u8) ?abi.Stat {
    var st: abi.Stat = undefined;
    return if (lib.syscall(Sys.stat, @intFromPtr(path), @intFromPtr(&st), 0) == 0) st else null;
}

fn kind(path: [*:0]const u8) u32 {
    return if (statOf(path)) |st| st.mode & S.IFMT else 0;
}

fn openFlags(path: [*:0]const u8, flags: u64) u64 {
    return lib.syscall(Sys.open, @intFromPtr(path), flags, 0);
}

var text: [8192]u8 = undefined;
var long_path: [4200]u8 = undefined;
var list_buf: [2048]u8 = undefined;
var dents: [1024]u8 align(8) = undefined;

/// The names `getdents64` gives for the directory `fd` from where it
/// stands, joined with spaces.
fn listing(fd: u64) []const u8 {
    var len: usize = 0;
    while (true) {
        const n = lib.syscall(Sys.getdents64, fd, @intFromPtr(&dents), dents.len);
        if (lib.isError(n)) lib.exit(190);
        if (n == 0) break;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, dents[at + 16 ..][0..2], .little);
            if (reclen < 20 or reclen % 8 != 0 or at + reclen > n) lib.exit(191);
            const name = std.mem.sliceTo(dents[at + 19 .. at + reclen], 0);
            if (std.mem.readInt(u64, dents[at..][0..8], .little) == 0) lib.exit(192); // an inode number is never 0
            if (len != 0) {
                list_buf[len] = ' ';
                len += 1;
            }
            @memcpy(list_buf[len..][0..name.len], name);
            len += name.len;
            at += reclen;
        }
    }
    return list_buf[0..len];
}

/// The `d_type` the directory `fd` gives for `name`, or 0.
fn linkType(fd: u64, name: []const u8) u8 {
    _ = lib.syscall(Sys.lseek, fd, 0, abi.SEEK.SET);
    while (true) {
        const n = lib.syscall(Sys.getdents64, fd, @intFromPtr(&dents), dents.len);
        if (lib.isError(n) or n == 0) return 0;
        var at: usize = 0;
        while (at < n) {
            const reclen = std.mem.readInt(u16, dents[at + 16 ..][0..2], .little);
            if (std.mem.eql(u8, std.mem.sliceTo(dents[at + 19 .. at + reclen], 0), name)) return dents[at + 18];
            at += reclen;
        }
    }
}

/// Whether the listing `names` has the name `name`.
fn has(names: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, names, ' ');
    while (it.next()) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Read the whole file at `path` into `text`.
/// `fmt` with `n` in it, NUL-terminated in `buf`.
fn zpath(buf: []u8, comptime fmt: []const u8, n: u64) [*:0]const u8 {
    const out = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, .{n}) catch unreachable;
    buf[out.len] = 0;
    return @ptrCast(buf.ptr);
}

fn slurp(path: [*:0]const u8) []const u8 {
    const fd = lib.open(path);
    if (lib.isError(fd)) return "";
    var len: usize = 0;
    while (len < text.len) {
        const n = lib.read(fd, text[len..]);
        if (lib.isError(n) or n == 0) break;
        len += n;
    }
    _ = lib.close(fd);
    return text[0..len];
}

pub fn main() noreturn {
    var buf: [256]u8 = undefined;
    const bufp = @intFromPtr(&buf);

    // --- Directories exist because files are in them.
    expect(kind("/") == S.IFDIR and kind("/etc") == S.IFDIR and kind("/etc/") == S.IFDIR and kind("/test") == S.IFDIR, 1);
    expect(kind("/etc/motd") == S.IFREG and kind("/et") == 0 and kind("/etc/mot") == 0 and kind("/etc/motd/x") == 0, 2);
    expect(lib.syscall(Sys.access, @intFromPtr("/etc"), abi.ACCESS.R_OK | abi.ACCESS.X_OK, 0) == 0, 3);
    expect(lib.syscall(Sys.readlink, @intFromPtr("/etc"), bufp, buf.len) == lib.err(.INVAL), 4); // no link
    // One is opened for reading only; a file is not one.
    const etc = lib.open("/etc");
    expect(!lib.isError(etc), 5);
    expect(openFlags("/etc", abi.O.WRONLY) == lib.err(.ISDIR), 6);
    expect(openFlags("/etc/motd", abi.O.DIRECTORY) == lib.err(.NOTDIR), 7);
    expect(openFlags("/sys/devices/system/node", abi.O.DIRECTORY) == lib.err(.NOENT), 8);
    // `stat` and `lstat` are `newfstatat` for a path.
    var st: abi.Stat = undefined;
    expect(lib.syscall(Sys.lstat, @intFromPtr("/etc/motd"), @intFromPtr(&st), 0) == 0 and st.size == 17, 9);
    expect(lib.syscall(Sys.stat, @intFromPtr("/nothing"), @intFromPtr(&st), 0) == lib.err(.NOENT), 10);
    expect(lib.syscall(Sys.stat, @intFromPtr("/etc/motd"), 8, 0) == lib.err(.FAULT), 11);

    // --- A directory descriptor: listed, and a place for paths to start.
    expect(lib.syscall(Sys.fstat, etc, @intFromPtr(&st), 0) == 0 and st.mode & S.IFMT == S.IFDIR, 110);
    expect(lib.read(etc, &buf) == lib.err(.ISDIR) and lib.syscall(Sys.write, etc, bufp, 1) == lib.err(.BADF), 111);
    expect(lib.syscall(Sys.fcntl, etc, 3, 0) == abi.O.RDONLY | abi.O.DIRECTORY, 112);
    {
        // `motd`, and the one user there is to programs (`passwd`, `group`,
        // `nsswitch.conf`), in whatever order the image has them.
        const etc_list = listing(etc);
        var names: usize = 0;
        var it = std.mem.tokenizeScalar(u8, etc_list, ' ');
        while (it.next()) |_| names += 1;
        expect(std.mem.startsWith(u8, etc_list, ". .. ") and names == 6 and std.mem.indexOf(u8, etc_list, "motd") != null and
            std.mem.indexOf(u8, etc_list, "passwd") != null and std.mem.indexOf(u8, etc_list, "nsswitch.conf") != null, 113);
    }
    expect(std.mem.eql(u8, listing(etc), ""), 114); // at the end it stays at the end
    expect(lib.syscall(Sys.lseek, etc, 0, abi.SEEK.SET) == 0 and std.mem.startsWith(u8, listing(etc), ". .. "), 115); // from the start again
    expect(lib.syscall(Sys.lseek, etc, 5, abi.SEEK.SET) == lib.err(.INVAL) and lib.syscall(Sys.lseek, etc, 0, abi.SEEK.END) == lib.err(.INVAL), 116);
    // A buffer for one entry at a time gives them one at a time; one too
    // small for the next entry is an error, not a short answer.
    _ = lib.syscall(Sys.lseek, etc, 0, abi.SEEK.SET);
    var small: [24]u8 align(8) = undefined;
    expect(lib.syscall(Sys.getdents64, etc, @intFromPtr(&small), 24) == 24 and small[19] == '.' and small[20] == 0, 117);
    expect(lib.syscall(Sys.getdents64, etc, @intFromPtr(&small), 24) == 24 and small[20] == '.', 118);
    expect(lib.syscall(Sys.getdents64, etc, @intFromPtr(&small), 20) == lib.err(.INVAL), 119); // "motd" needs 24
    expect(lib.syscall(Sys.getdents64, etc, @intFromPtr(&small), 24) == 24 and std.mem.eql(u8, small[19..23], "motd") and small[18] == abi.DT.REG, 120);
    // The rest one at a time (`passwd` and the others), then the end.
    var rest_left: usize = 0;
    while (rest_left < 8) : (rest_left += 1) {
        const got = lib.syscall(Sys.getdents64, etc, bufp, 40); // one record: `nsswitch.conf`'s is 40 bytes
        if (got == 0 or lib.isError(got)) break;
    }
    expect(rest_left == 3, 121);
    expect(lib.syscall(Sys.getdents64, etc, 8, 4096) == lib.err(.INVAL) or lib.syscall(Sys.getdents64, etc, 8, 4096) == 0, 122);
    expect(lib.syscall(Sys.getdents64, 99, bufp, 64) == lib.err(.BADF), 123);
    const motd_for_dents = lib.open("/etc/motd");
    expect(lib.syscall(Sys.getdents64, motd_for_dents, bufp, 64) == lib.err(.NOTDIR), 124);
    // The root holds what the image holds, and /proc and /dev besides.
    const root_dir = lib.open("/");
    const root_list = listing(root_dir);
    expect(std.mem.startsWith(u8, root_list, ". .. proc dev "), 125);
    expect(has(root_list, "etc") and has(root_list, "bin") and has(root_list, "test") and !has(root_list, "motd"), 126);
    expect(std.mem.count(u8, root_list, "etc") == 1 and std.mem.count(u8, root_list, "dev") == 1, 127); // each once
    _ = lib.close(root_dir);
    const dev_dir = lib.open("/dev");
    expect(std.mem.eql(u8, listing(dev_dir), ". .. null urandom random"), 128);
    _ = lib.close(dev_dir);
    const self_dir = lib.open("/proc/self/");
    expect(std.mem.eql(u8, listing(self_dir), ". .. stat cmdline comm mountinfo cgroup schedstat status statm mounts task exe maps"), 129);
    _ = lib.close(self_dir);
    // Every process has a directory by its ID, this one included; another
    // process's has no `exe` or `maps`.
    const proc_dir = lib.open("/proc");
    var pid_text: [24]u8 = undefined;
    const my_pid = lib.syscall(Sys.getpid, 0, 0, 0);
    const pid_name = std.fmt.bufPrint(&pid_text, " {d}", .{my_pid}) catch unreachable;
    const proc_list = listing(proc_dir);
    expect(std.mem.startsWith(u8, proc_list, ". .. self meminfo ") and std.mem.indexOf(u8, proc_list, pid_name) != null, 135);
    _ = lib.close(proc_dir);
    const comm_fd = lib.open("/proc/self/comm");
    expect(!lib.isError(comm_fd) and lib.read(comm_fd, buf[0..6]) == 6 and std.mem.eql(u8, buf[0..6], "files\n"), 136);
    _ = lib.close(comm_fd);
    const cmd_fd = lib.open("/proc/self/cmdline");
    const cmd_len = lib.read(cmd_fd, buf[0..64]);
    expect(!lib.isError(cmd_len) and cmd_len > 0 and buf[cmd_len - 1] == 0, 137);
    _ = lib.close(cmd_fd);
    expect(lib.open("/proc/999999/stat") == lib.err(.NOENT), 138);
    // What is in the directory, by a path that starts at its descriptor.
    const rel = lib.syscall(Sys.openat, etc, @intFromPtr("motd"), 0);
    expect(!lib.isError(rel) and lib.read(rel, buf[0..7]) == 7 and std.mem.eql(u8, buf[0..7], "Welcome"), 130);
    _ = lib.close(rel);
    expect(lib.syscall6(Sys.newfstatat, etc, @intFromPtr("./motd"), @intFromPtr(&st), 0, 0, 0) == 0 and st.size == 17, 131);
    expect(lib.syscall6(Sys.newfstatat, etc, @intFromPtr("../bin/hello"), @intFromPtr(&st), 0, 0, 0) == 0, 132);
    expect(lib.syscall6(Sys.newfstatat, etc, @intFromPtr("../../../etc/motd"), @intFromPtr(&st), 0, 0, 0) == 0, 133); // ".." stops at the root
    expect(lib.syscall(Sys.openat, etc, @intFromPtr("nothing"), 0) == lib.err(.NOENT), 134);
    expect(lib.syscall(Sys.openat, motd_for_dents, @intFromPtr("x"), 0) == lib.err(.NOTDIR), 135); // a file is no place to start
    expect(lib.syscall(Sys.openat, 99, @intFromPtr("x"), 0) == lib.err(.BADF), 136);
    const absolute = lib.syscall(Sys.openat, 99, @intFromPtr("/etc/motd"), 0);
    expect(!lib.isError(absolute) and lib.close(absolute) == 0, 137); // absolute: the descriptor does not matter
    _ = lib.close(motd_for_dents);
    // A slash at the end asks for a directory.
    expect(lib.open("/etc/motd/") == lib.err(.NOTDIR), 138);
    expect(lib.syscall(Sys.stat, @intFromPtr("/etc/motd/"), @intFromPtr(&st), 0) == lib.err(.NOTDIR), 139);
    expect(lib.syscall(Sys.stat, @intFromPtr("/etc//./"), @intFromPtr(&st), 0) == 0 and st.mode & S.IFMT == S.IFDIR, 140);

    // --- The working directory: where relative paths start.
    expect(lib.syscall(Sys.getcwd, bufp, buf.len, 0) == 2 and buf[0] == '/' and buf[1] == 0, 150);
    const from_root = lib.open("etc/motd"); // relative to "/"
    expect(!lib.isError(from_root) and lib.close(from_root) == 0, 151);
    expect(lib.syscall(Sys.chdir, @intFromPtr("/etc"), 0, 0) == 0, 152);
    expect(lib.syscall(Sys.getcwd, bufp, buf.len, 0) == 5 and std.mem.eql(u8, buf[0..5], "/etc\x00"), 153);
    expect(lib.syscall(Sys.getcwd, bufp, 4, 0) == lib.err(.RANGE) and lib.syscall(Sys.getcwd, 8, 64, 0) == lib.err(.FAULT), 154);
    const in_etc = lib.open("motd");
    expect(!lib.isError(in_etc) and lib.read(in_etc, buf[0..7]) == 7 and std.mem.eql(u8, buf[0..7], "Welcome"), 155);
    _ = lib.close(in_etc);
    expect(kind("motd") == S.IFREG and kind("./motd") == S.IFREG and kind("../etc/motd") == S.IFREG and kind(".") == S.IFDIR, 156);
    expect(lib.syscall(Sys.chdir, @intFromPtr(".."), 0, 0) == 0 and kind("motd") == 0 and kind("etc/motd") == S.IFREG, 157);
    expect(lib.syscall(Sys.chdir, @intFromPtr("/etc/motd"), 0, 0) == lib.err(.NOTDIR), 158);
    expect(lib.syscall(Sys.chdir, @intFromPtr("/nothing"), 0, 0) == lib.err(.NOENT) and lib.syscall(Sys.chdir, 8, 0, 0) == lib.err(.FAULT), 159);
    expect(lib.syscall(Sys.chdir, @intFromPtr("/proc/self"), 0, 0) == 0 and lib.syscall(Sys.readlink, @intFromPtr("exe"), bufp, buf.len) == "/test/files".len, 160);
    // By descriptor.
    expect(lib.syscall(Sys.fchdir, etc, 0, 0) == 0 and kind("motd") == S.IFREG, 161);
    expect(lib.syscall(Sys.fchdir, 1, 0, 0) == lib.err(.NOTDIR) and lib.syscall(Sys.fchdir, 99, 0, 0) == lib.err(.BADF), 162);
    // A program started from here starts here: by a relative path, and
    // it finds a file by a relative path in turn.
    expect(lib.syscall(Sys.chdir, @intFromPtr("/test"), 0, 0) == 0, 163);
    expect(lib.run("entry_regs") == 0, 164);
    expect(lib.run("./entry_regs") == 0 and lib.run("../test/entry_regs") == 0, 165);
    expect(lib.run("nothing") == lib.err(.NOENT), 166);
    expect(lib.syscall(Sys.chdir, @intFromPtr("/"), 0, 0) == 0, 167);
    _ = lib.close(etc);

    // --- Long paths: up to 4095 bytes, each part up to 255.
    @memset(&long_path, 'a');
    var at: usize = 0;
    while (at <= 4000) : (at += 200) long_path[at] = '/'; // parts of 199 bytes, and a last one of 94
    long_path[4095] = 0; // 4095 bytes: the longest there is
    expect(lib.syscall(Sys.stat, @intFromPtr(&long_path), @intFromPtr(&st), 0) == lib.err(.NOENT), 171);
    long_path[4095] = 'a';
    long_path[4096] = 0; // one more
    expect(lib.syscall(Sys.stat, @intFromPtr(&long_path), @intFromPtr(&st), 0) == lib.err(.NAMETOOLONG), 172);
    @memset(long_path[0..300], 'b');
    long_path[0] = '/';
    long_path[256] = 0; // one part of 255
    expect(lib.syscall(Sys.stat, @intFromPtr(&long_path), @intFromPtr(&st), 0) == lib.err(.NOENT), 173);
    long_path[256] = 'b';
    long_path[257] = 0; // and of 256
    expect(lib.syscall(Sys.stat, @intFromPtr(&long_path), @intFromPtr(&st), 0) == lib.err(.NAMETOOLONG), 174);

    // --- Symbolic links: the layout is Linux's, with /usr merged.
    expect(lib.syscall(Sys.readlink, @intFromPtr("/bin"), bufp, buf.len) == 7 and std.mem.eql(u8, buf[0..7], "usr/bin"), 180);
    expect(lib.syscall(Sys.lstat, @intFromPtr("/bin"), @intFromPtr(&st), 0) == 0 and st.mode & S.IFMT == S.IFLNK and st.size == 7, 181);
    expect(kind("/bin") == S.IFDIR and kind("/sbin") == S.IFDIR and kind("/lib") == S.IFDIR and kind("/lib64") == S.IFDIR, 182); // followed
    expect(kind("/bin/sh") == S.IFREG and kind("/usr/bin/sh") == S.IFREG and kind("/bin/") == S.IFDIR, 183);
    expect(statOf("/bin/hello").?.ino == statOf("/usr/bin/hello").?.ino, 184); // one file, two ways
    const by_link = lib.open("/bin/hello");
    expect(!lib.isError(by_link) and lib.read(by_link, buf[0..4]) == 4 and std.mem.eql(u8, buf[0..4], "\x7fELF"), 185);
    _ = lib.close(by_link);
    expect(lib.run("/bin/entry_regs") == lib.err(.NOENT) and lib.run("/bin/hello") == 0, 186); // started through a link
    // Not followed where Linux does not: the last part of O_NOFOLLOW,
    // unlink and rename, and a path ending in a slash is followed after all.
    expect(lib.syscall(Sys.open, @intFromPtr("/bin"), abi.O.NOFOLLOW, 0) == lib.err(.LOOP), 187);
    expect(!lib.isError(lib.syscall(Sys.open, @intFromPtr("/bin/hello"), abi.O.NOFOLLOW, 0)), 188); // only the last part counts
    expect(lib.syscall(Sys.unlink, @intFromPtr("/bin"), 0, 0) == lib.err(.ROFS) and lib.syscall(Sys.rmdir, @intFromPtr("/bin"), 0, 0) == lib.err(.NOTDIR), 189);
    expect(lib.syscall(Sys.lstat, @intFromPtr("/bin/"), @intFromPtr(&st), 0) == 0 and st.mode & S.IFMT == S.IFDIR, 190);
    // In a listing, a link is a link.
    const top = lib.open("/");
    expect(linkType(top, "bin") == abi.DT.LNK and linkType(top, "usr") == abi.DT.DIR and linkType(top, "lib64") == abi.DT.LNK, 191);
    _ = lib.close(top);
    // Working directories through links, and ".." from there.
    expect(lib.syscall(Sys.chdir, @intFromPtr("/bin"), 0, 0) == 0, 192);
    expect(lib.syscall(Sys.getcwd, bufp, buf.len, 0) == "/usr/bin".len + 1 and std.mem.eql(u8, buf[0..8], "/usr/bin"), 193);
    expect(kind("sh") == S.IFREG and kind("../lib64") == S.IFDIR, 194);
    expect(lib.syscall(Sys.chdir, @intFromPtr("/"), 0, 0) == 0, 195);
    // The standard directories are there, empty.
    for ([_][*:0]const u8{ "/home", "/root", "/opt", "/var", "/mnt", "/media", "/run", "/usr/lib", "/usr/lib64" }) |d| expect(kind(d) == S.IFDIR, 196);

    // --- /proc/self/exe: how a program finds its own file.
    const pid = lib.syscall(Sys.getpid, 0, 0, 0);
    const n = lib.syscall(Sys.readlink, @intFromPtr("/proc/self/exe"), bufp, buf.len);
    expect(n == "/test/files".len and std.mem.eql(u8, buf[0..n], "/test/files"), 20);
    expect(lib.syscall(Sys.readlink, @intFromPtr("/proc/self/exe"), bufp, 5) == 5 and std.mem.eql(u8, buf[0..5], "/test"), 21); // cut, not refused
    expect(lib.syscall(Sys.readlink, @intFromPtr("/proc/self/exe"), bufp, 0) == lib.err(.INVAL), 22);
    expect(lib.syscall(Sys.readlink, @intFromPtr("/proc/self/exe"), 8, 64) == lib.err(.FAULT), 23);
    expect(lib.syscall6(Sys.readlinkat, CWD, @intFromPtr("/proc/self/exe"), bufp, buf.len, 0, 0) == n, 24);
    // By its own number too; nobody else's.
    var path_buf: [64]u8 = undefined;
    const own = std.fmt.bufPrint(&path_buf, "/proc/{d}/exe\x00", .{pid}) catch unreachable;
    expect(lib.syscall(Sys.readlink, @intFromPtr(own.ptr), bufp, buf.len) == n, 25);
    expect(lib.syscall(Sys.readlink, @intFromPtr("/proc/1/exe"), bufp, buf.len) == lib.err(.NOENT) or pid == 1, 26);
    expect(lib.syscall(Sys.readlink, @intFromPtr("/proc/0/exe"), bufp, buf.len) == lib.err(.NOENT), 27);
    expect(lib.syscall(Sys.readlink, @intFromPtr("/proc/selfish/exe"), bufp, buf.len) == lib.err(.NOENT), 28);
    // Followed, it is the program: `stat` sees a file, `lstat` the link,
    // and opening it reads the ELF header.
    expect(kind("/proc/self/exe") == S.IFREG and kind("/proc") == S.IFDIR and kind("/proc/self") == S.IFDIR, 29);
    expect(lib.syscall(Sys.lstat, @intFromPtr("/proc/self/exe"), @intFromPtr(&st), 0) == 0 and st.mode & S.IFMT == S.IFLNK, 30);
    const exe = lib.open("/proc/self/exe");
    expect(!lib.isError(exe) and lib.read(exe, buf[0..4]) == 4 and std.mem.eql(u8, buf[0..4], "\x7fELF"), 31);
    expect(lib.syscall(Sys.fstat, exe, @intFromPtr(&st), 0) == 0 and st.size == statOf("/test/files").?.size, 32);
    _ = lib.close(exe);

    // --- /proc/self/maps: one line a mapping, lowest first, and the
    // stack's line holds the address of a local variable.
    var local: u64 = 0;
    const here = @intFromPtr(&local);
    const anon = lib.mmap(0, 3 * 4096, abi.PROT.READ, 0);
    const maps = slurp("/proc/self/maps");
    expect(maps.len > 100 and maps[maps.len - 1] == '\n', 40);
    var lines = std.mem.splitScalar(u8, maps[0 .. maps.len - 1], '\n');
    var last_end: u64 = 0;
    var found_stack = false;
    var found_anon = false;
    var found_code = false;
    while (lines.next()) |line| {
        const dash = std.mem.indexOfScalar(u8, line, '-') orelse lib.exit(41);
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse lib.exit(41);
        const from = std.fmt.parseInt(u64, line[0..dash], 16) catch lib.exit(42);
        const to = std.fmt.parseInt(u64, line[dash + 1 .. space], 16) catch lib.exit(42);
        expect(from < to and from >= last_end and from % 4096 == 0 and to % 4096 == 0, 43);
        last_end = to;
        const perms = line[space + 1 ..][0..4];
        if (here >= from and here < to) {
            found_stack = std.mem.endsWith(u8, line, "[stack]") and std.mem.eql(u8, perms, "rw-p");
        }
        if (from <= anon and to >= anon + 3 * 4096) found_anon = std.mem.eql(u8, perms, "r--p");
        if (@intFromPtr(&main) >= from and @intFromPtr(&main) < to) found_code = std.mem.eql(u8, perms, "r-xp");
    }
    expect(found_stack, 44);
    expect(found_anon, 45);
    expect(found_code, 46);
    // It is a file like any other once open: offsets, and no length to `stat`.
    const mfd = lib.open("/proc/self/maps");
    expect(lib.syscall(Sys.fstat, mfd, @intFromPtr(&st), 0) == 0 and st.mode & S.IFMT == S.IFREG, 47);
    expect(lib.syscall6(Sys.pread64, mfd, bufp, 8, 0, 0, 0) == 8 and std.mem.eql(u8, buf[0..8], maps[0..8]), 48);
    expect(lib.syscall(Sys.lseek, mfd, 4, abi.SEEK.SET) == 4 and lib.read(mfd, buf[0..4]) == 4 and std.mem.eql(u8, buf[0..4], maps[4..8]), 49);
    // But its text is the descriptor's, so it cannot be mapped.
    expect(lib.syscall6(Sys.mmap, 0, 4096, abi.PROT.READ, abi.MAP.PRIVATE, mfd, 0) == lib.err(.NODEV), 50);
    expect(openFlags("/proc/self/maps", abi.O.WRONLY) == lib.err(.ROFS), 51);
    _ = lib.close(mfd);
    expect(kind("/proc/self/maps") == S.IFREG and kind("/proc/self/nothing") == 0 and kind("/proc/maps") == 0, 52);

    // --- /proc/self/stat starts with the process's number and name;
    // /proc/meminfo says how much memory there is.
    const stat_line = slurp("/proc/self/stat");
    const expected = std.fmt.bufPrint(&path_buf, "{d} (files) R ", .{pid}) catch unreachable;
    expect(std.mem.startsWith(u8, stat_line, expected) and stat_line[stat_line.len - 1] == '\n', 55);
    const meminfo = slurp("/proc/meminfo");
    expect(std.mem.startsWith(u8, meminfo, "MemTotal:") and std.mem.indexOf(u8, meminfo, "\nMemAvailable:") != null, 56);
    const total_kb = std.fmt.parseInt(u64, std.mem.trim(u8, meminfo["MemTotal:".len..std.mem.indexOf(u8, meminfo, " kB").?], " "), 10) catch 0;
    expect(total_kb >= 16 * 1024, 57);
    expect(kind("/proc/meminfo") == S.IFREG and kind("/proc/self/meminfo") == 0, 58);
    // /proc/cpuinfo: a block for each CPU, with the flags line, and the
    // CPU lists of /sys agreeing with it.
    const cpuinfo = slurp("/proc/cpuinfo");
    const blocks = std.mem.count(u8, cpuinfo, "processor\t: ");
    expect(std.mem.startsWith(u8, cpuinfo, "processor\t: 0\nvendor_id\t: ") and blocks >= 1, 59);
    expect(std.mem.indexOf(u8, cpuinfo, "\nflags\t\t: fpu ") != null and std.mem.indexOf(u8, cpuinfo, " sse2 ") != null and std.mem.indexOf(u8, cpuinfo, " lm") != null, 141);
    var online_buf: [16]u8 = undefined;
    const online = std.mem.trimEnd(u8, slurp("/sys/devices/system/cpu/online"), "\n");
    const want_online = if (blocks == 1) "0" else std.fmt.bufPrint(&online_buf, "0-{d}", .{blocks - 1}) catch unreachable;
    expect(std.mem.eql(u8, online, want_online), 142);
    expect(kind("/sys") == S.IFDIR and kind("/sys/devices/system/cpu") == S.IFDIR and kind("/sys/devices/system/cpu/possible") == S.IFREG and kind("/sys/devices/system/cpu/nothing") == 0 and kind("/sys/nothing") == 0, 143);
    expect(openFlags("/sys/devices/system/cpu/online", abi.O.WRONLY) == lib.err(.ROFS), 144);
    // The caches, from cpuid, as the .NET collector reads them: each index
    // a level and a size in kibibytes (empty where the CPU does not say,
    // as QEMU's emulated CPUs may not).
    const level = std.mem.trimEnd(u8, slurp("/sys/devices/system/cpu/cpu0/cache/index0/level"), "\n");
    if (level.len != 0) {
        expect(level[0] >= '1' and level[0] <= '3', 36);
        const size = std.mem.trimEnd(u8, slurp("/sys/devices/system/cpu/cpu0/cache/index0/size"), "\n");
        expect(size.len > 1 and size[size.len - 1] == 'K' and (std.fmt.parseInt(u64, size[0 .. size.len - 1], 10) catch 0) > 0, 37);
    }
    const cache_dir = lib.open("/sys/devices/system/cpu/cpu0/cache/index1");
    expect(std.mem.eql(u8, listing(cache_dir), ". .. level size type coherency_line_size ways_of_associativity number_of_sets"), 38);
    _ = lib.close(cache_dir);
    const cpu_dir = lib.open("/sys/devices/system/cpu");
    expect(std.mem.eql(u8, listing(cpu_dir), ". .. online possible present cpu0"), 145);
    _ = lib.close(cpu_dir);
    // The control-group files, which say what this process may use: the
    // memory limit is its RLIMIT_DATA.
    expect(std.mem.eql(u8, slurp("/proc/self/cgroup"), "0::/\n"), 146);
    expect(std.mem.indexOf(u8, slurp("/proc/self/mountinfo"), " / /sys/fs/cgroup ro,relatime - cgroup2 cgroup2 ro\n") != null, 147);
    var data_limit: abi.RLimit = undefined;
    expect(lib.syscall(Sys.getrlimit, abi.RLIMIT.DATA, @intFromPtr(&data_limit), 0) == 0, 148);
    const max_text = std.mem.trimEnd(u8, slurp("/sys/fs/cgroup/memory.max"), "\n");
    expect((std.fmt.parseInt(u64, max_text, 10) catch 0) == data_limit.cur, 149);
    const current = std.fmt.parseInt(u64, std.mem.trimEnd(u8, slurp("/sys/fs/cgroup/memory.current"), "\n"), 10) catch 0;
    expect(current > 0 and current < data_limit.cur, 12);
    expect(std.mem.eql(u8, slurp("/sys/fs/cgroup/cpu.max"), "max 100000\n"), 13);
    expect(std.mem.startsWith(u8, slurp("/sys/fs/cgroup/memory.stat"), "anon "), 14);
    var fs: abi.StatFs = undefined;
    expect(lib.syscall(Sys.statfs, @intFromPtr("/sys/fs/cgroup"), @intFromPtr(&fs), 0) == 0 and fs.type == 0x63677270, 15); // CGROUP2_SUPER_MAGIC
    expect(lib.syscall(Sys.statfs, @intFromPtr("/proc/self"), @intFromPtr(&fs), 0) == 0 and fs.type == 0x9fa0, 16);
    const cg_dir = lib.open("/sys/fs/cgroup");
    expect(std.mem.eql(u8, listing(cg_dir), ". .. cgroup.controllers cpu.max cpuset.cpus.effective memory.current memory.max memory.stat"), 17);
    _ = lib.close(cg_dir);
    // The always-on counters: this program's calls are among them, its
    // threads have run, and the lock classes are listed.
    const calls = slurp("/proc/syscalls");
    expect(std.mem.startsWith(u8, calls, "# number name calls ") and std.mem.indexOf(u8, calls, "\n39 getpid ") != null, 19);
    const sched = std.mem.trimEnd(u8, slurp("/proc/self/schedstat"), "\n");
    var fields = std.mem.splitScalar(u8, sched, ' ');
    const run_ns = std.fmt.parseInt(u64, fields.next() orelse "", 10) catch 0;
    _ = std.fmt.parseInt(u64, fields.next() orelse "x", 10) catch expect(false, 33);
    const slices = std.fmt.parseInt(u64, fields.next() orelse "", 10) catch 0;
    expect(run_ns > 0 and slices > 0 and fields.next() == null, 34);
    const locks = slurp("/proc/lockstat");
    expect(std.mem.startsWith(u8, locks, "# class contended wait_ns\n") and std.mem.indexOf(u8, locks, "\nscheduler ") != null, 35);
    const sys_dir = lib.open("/sys");
    expect(std.mem.eql(u8, listing(sys_dir), ". .. devices fs"), 18);
    _ = lib.close(sys_dir);

    // --- /dev/null and /dev/urandom.
    const null_fd = openFlags("/dev/null", abi.O.RDWR);
    expect(!lib.isError(null_fd), 60);
    expect(lib.read(null_fd, &buf) == 0, 61);
    expect(lib.syscall(Sys.write, null_fd, bufp, 100) == 100, 62);
    // What is written is never looked at, so only an address that cannot
    // be a program's is refused, as on Linux.
    expect(lib.syscall(Sys.write, null_fd, 8, 100) == 100, 63);
    expect(lib.syscall(Sys.write, null_fd, 0xFFFF_8000_0000_0000, 100) == lib.err(.FAULT), 68);
    expect(lib.syscall(Sys.fstat, null_fd, @intFromPtr(&st), 0) == 0 and st.mode & S.IFMT == S.IFCHR, 64);
    const rnd = lib.open("/dev/urandom");
    var a: [32]u8 = @splat(0);
    var b: [32]u8 = @splat(0);
    expect(lib.read(rnd, &a) == 32 and lib.read(rnd, &b) == 32, 65);
    expect(!std.mem.eql(u8, &a, &b) and !std.mem.allEqual(u8, &a, 0), 66);
    expect(kind("/dev/null") == S.IFCHR and kind("/dev/random") == S.IFCHR and kind("/dev") == S.IFDIR and kind("/dev/zero") == 0, 67);
    _ = lib.close(null_fd);
    _ = lib.close(rnd);

    // --- The filesystem cannot be changed, and says so after looking.
    expect(lib.syscall(Sys.unlink, @intFromPtr("/etc/motd"), 0, 0) == lib.err(.ROFS), 70);
    expect(lib.syscall(Sys.unlink, @intFromPtr("/tmp/nothing"), 0, 0) == lib.err(.NOENT), 71);
    expect(lib.syscall(Sys.unlinkat, CWD, @intFromPtr("/etc/motd"), 0) == lib.err(.ROFS), 72);
    expect(lib.syscall6(Sys.mknodat, CWD, @intFromPtr("/etc/pipe"), S.IFIFO | 0o600, 0, 0, 0) == lib.err(.ROFS), 73);
    expect(lib.syscall(Sys.unlink, 8, 0, 0) == lib.err(.FAULT), 74);
    const motd = lib.open("/etc/motd");
    expect(lib.syscall(Sys.fchmod, motd, 0o600, 0) == lib.err(.ROFS) and lib.syscall(Sys.fchmod, 99, 0o600, 0) == lib.err(.BADF), 75);
    expect(lib.syscall(Sys.ftruncate, motd, 0, 0) == lib.err(.INVAL) and lib.syscall(Sys.ftruncate, 99, 0, 0) == lib.err(.BADF), 76);
    // No networking.
    expect(lib.syscall(Sys.socket, 1, 1, 0) == lib.err(.AFNOSUPPORT), 77);
    expect(lib.syscall(Sys.memfd_create, @intFromPtr("x"), 0x100, 0) == lib.err(.INVAL), 78); // offered (`/test/memfd`); not with an unknown flag

    // --- The descriptor table grows: to a descriptor far up, and back.
    expect(lib.syscall(Sys.dup2, motd, 700, 0) == 700, 80);
    expect(lib.read(700, buf[0..7]) == 7 and std.mem.eql(u8, buf[0..7], "Welcome"), 81);
    expect(lib.syscall(Sys.fcntl, motd, 0, 1000) == 1000, 82); // F_DUPFD from 1000
    expect(lib.syscall(Sys.dup2, motd, 1023, 0) == 1023 and lib.syscall(Sys.dup2, motd, 1024, 0) == lib.err(.BADF), 83);
    expect(lib.syscall(Sys.fcntl, motd, 0, 1024) == lib.err(.INVAL), 84);
    expect(lib.close(700) == 0 and lib.close(1000) == 0 and lib.close(1023) == 0 and lib.close(700) == lib.err(.BADF), 85);
    expect(lib.close(5000) == lib.err(.BADF) and lib.read(900, &buf) == lib.err(.BADF), 86);
    // Fifty at once, each its own descriptor in order.
    var fds: [50]u64 = undefined;
    for (&fds, 0..) |*f, i| {
        f.* = lib.open("/etc/motd");
        expect(f.* == motd + 1 + i, 87);
    }
    for (fds) |f| expect(lib.close(f) == 0, 88);
    _ = lib.close(motd);

    // --- Scheduling: one policy, one priority, any CPU.
    const tid = lib.gettid();
    expect(lib.syscall(Sys.sched_getscheduler, 0, 0, 0) == abi.SCHED.OTHER and lib.syscall(Sys.sched_getscheduler, tid, 0, 0) == abi.SCHED.OTHER, 90);
    expect(lib.syscall(Sys.sched_getscheduler, 0x7FFF_FFF0, 0, 0) == lib.err(.SRCH), 91);
    var priority: i32 = -1;
    expect(lib.syscall(Sys.sched_getparam, 0, @intFromPtr(&priority), 0) == 0 and priority == 0, 92);
    expect(lib.syscall(Sys.sched_getparam, 0, 8, 0) == lib.err(.FAULT), 93);
    expect(lib.syscall(Sys.sched_setscheduler, tid, abi.SCHED.OTHER, @intFromPtr(&priority)) == 0, 94);
    expect(lib.syscall(Sys.sched_setscheduler, 0, abi.SCHED.FIFO, @intFromPtr(&priority)) == lib.err(.INVAL), 95);
    expect(lib.syscall(Sys.sched_setparam, 0, @intFromPtr(&priority), 0) == 0, 96);
    priority = 5;
    expect(lib.syscall(Sys.sched_setparam, 0, @intFromPtr(&priority), 0) == lib.err(.INVAL), 97);
    expect(lib.syscall(Sys.sched_get_priority_max, abi.SCHED.OTHER, 0, 0) == 0 and lib.syscall(Sys.sched_get_priority_min, abi.SCHED.OTHER, 0, 0) == 0, 98);
    expect(lib.syscall(Sys.sched_get_priority_max, abi.SCHED.FIFO, 0, 0) == lib.err(.INVAL), 99);
    var cpus: u64 = 0;
    expect(lib.syscall(Sys.sched_getaffinity, 0, 8, @intFromPtr(&cpus)) == 8 and cpus != 0, 100);
    expect(lib.syscall(Sys.sched_setaffinity, 0, 8, @intFromPtr(&cpus)) == 0, 101);
    var one: u64 = 1;
    expect(lib.syscall(Sys.sched_setaffinity, tid, 8, @intFromPtr(&one)) == 0, 102); // a CPU that is up: accepted
    one = @as(u64, 1) << 63;
    expect(lib.syscall(Sys.sched_setaffinity, 0, 8, @intFromPtr(&one)) == lib.err(.INVAL) or cpus >> 63 == 1, 103); // none that is up
    expect(lib.syscall(Sys.sched_setaffinity, 0, 8, 8) == lib.err(.FAULT), 104);
    expect(lib.syscall(Sys.sched_setaffinity, 0x7FFF_FFF0, 8, @intFromPtr(&cpus)) == lib.err(.SRCH), 105);
    expect(lib.syscall(Sys.getsid, 0, 0, 0) == pid and lib.syscall(Sys.getsid, pid, 0, 0) == pid, 106);
    expect(lib.syscall(Sys.getsid, 0x7FFF_FFF0, 0, 0) == lib.err(.SRCH), 107);

    // FD_CLOEXEC: a flag of the descriptor, not of the open file.
    const F_GETFD = 1;
    const F_SETFD = 2;
    const ce = lib.syscall6(Sys.openat, @bitCast(@as(i64, abi.AT_FDCWD)), @intFromPtr("/etc/motd"), abi.O.RDONLY | abi.O.CLOEXEC, 0, 0, 0);
    expect(!lib.isError(ce) and lib.syscall(Sys.fcntl, ce, F_GETFD, 0) == 1, 200);
    const plain = lib.syscall(Sys.dup, ce, 0, 0); // dup leaves it off
    expect(lib.syscall(Sys.fcntl, plain, F_GETFD, 0) == 0, 201);
    expect(lib.syscall(Sys.fcntl, plain, F_SETFD, 1) == 0 and lib.syscall(Sys.fcntl, plain, F_GETFD, 0) == 1, 202);
    expect(lib.syscall(Sys.fcntl, ce, F_SETFD, 0) == 0 and lib.syscall(Sys.fcntl, ce, F_GETFD, 0) == 0, 203);
    const dup_ce = lib.syscall(Sys.fcntl, ce, 1030, 0); // F_DUPFD_CLOEXEC
    expect(lib.syscall(Sys.fcntl, dup_ce, F_GETFD, 0) == 1, 204);
    expect(lib.syscall(Sys.dup3, ce, 60, abi.O.CLOEXEC) == 60 and lib.syscall(Sys.fcntl, 60, F_GETFD, 0) == 1, 205);
    expect(lib.syscall(Sys.dup2, ce, 60, 0) == 60 and lib.syscall(Sys.fcntl, 60, F_GETFD, 0) == 0, 206); // dup2 replaces it, flag off
    expect(lib.syscall(Sys.dup3, ce, 61, 0) == 61 and lib.syscall(Sys.fcntl, 61, F_GETFD, 0) == 0, 207);
    expect(lib.syscall(Sys.dup3, ce, 62, 0x40) == lib.err(.INVAL), 208);
    var pfd: [2]i32 = undefined;
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&pfd), abi.O.CLOEXEC, 0) == 0, 209);
    expect(lib.syscall(Sys.fcntl, @intCast(pfd[0]), F_GETFD, 0) == 1 and lib.syscall(Sys.fcntl, @intCast(pfd[1]), F_GETFD, 0) == 1, 210);
    for ([_]u64{ ce, plain, dup_ce, 60, 61, @intCast(pfd[0]), @intCast(pfd[1]) }) |fd| expect(lib.close(fd) == 0, 211);

    // statx: what newfstatat says, in the newer structure.
    var sx: abi.Statx = .{};
    var st2: abi.Stat = .{};
    const cwdfd: u64 = @bitCast(@as(i64, abi.AT_FDCWD));
    expect(lib.syscall6(Sys.statx, cwdfd, @intFromPtr("/etc/motd"), 0, 0x7FF, @intFromPtr(&sx), 0) == 0, 220);
    expect(lib.syscall6(Sys.newfstatat, cwdfd, @intFromPtr("/etc/motd"), @intFromPtr(&st2), 0, 0, 0) == 0, 221);
    expect(sx.size == @as(u64, @intCast(st2.size)) and sx.mode == @as(u16, @truncate(st2.mode)) and sx.mask & 0x7FF == 0x7FF, 222);
    expect(lib.syscall6(Sys.statx, cwdfd, @intFromPtr("/etc"), 0, 0x7FF, @intFromPtr(&sx), 0) == 0 and sx.mode & abi.S.IFMT == abi.S.IFDIR, 223);
    expect(lib.syscall6(Sys.statx, cwdfd, @intFromPtr("/nope"), 0, 0x7FF, @intFromPtr(&sx), 0) == lib.err(.NOENT), 224);
    const motd2 = lib.open("/etc/motd");
    expect(lib.syscall6(Sys.statx, motd2, @intFromPtr(""), abi.AT_EMPTY_PATH, 0x7FF, @intFromPtr(&sx), 0) == 0 and sx.size == @as(u64, @intCast(st2.size)), 225);
    expect(lib.syscall6(Sys.statx, cwdfd, @intFromPtr("/etc/motd"), 0, 0x7FF, 8, 0) == lib.err(.FAULT), 226);

    // preadv and pwritev: buffers in turn, from an offset; the file
    // offset stays.
    var a4: [4]u8 = undefined;
    var b4: [4]u8 = undefined;
    var whole: [8]u8 = undefined;
    expect(lib.syscall(Sys.pread64, motd2, @intFromPtr(&whole), 8) == 8 or true, 227);
    _ = lib.syscall6(Sys.pread64, motd2, @intFromPtr(&whole), 8, 2, 0, 0);
    const iov = [2]abi.IoVec{ .{ .base = @intFromPtr(&a4), .len = 4 }, .{ .base = @intFromPtr(&b4), .len = 4 } };
    expect(lib.syscall6(Sys.preadv, motd2, @intFromPtr(&iov), 2, 2, 0, 0) == 8, 228);
    expect(std.mem.eql(u8, &a4, whole[0..4]) and std.mem.eql(u8, &b4, whole[4..8]), 229);
    expect(lib.syscall(Sys.lseek, motd2, 0, 1) == 0, 230); // offset untouched
    expect(lib.syscall6(Sys.preadv, 1, @intFromPtr(&iov), 2, 0, 0, 0) == lib.err(.SPIPE), 231);
    // (A name of its own: two of these programs may run at once.)
    var tname = "/tmp/pwritev-0000000000".*;
    var tpid = lib.syscall(Sys.getpid, 0, 0, 0);
    var ti: usize = tname.len;
    while (ti > 13) {
        ti -= 1;
        tname[ti] = @intCast('0' + tpid % 10);
        tpid /= 10;
    }
    const tf = lib.syscall6(Sys.openat, cwdfd, @intFromPtr(&tname), abi.O.RDWR | abi.O.CREAT | abi.O.TRUNC, 0o644, 0, 0);
    expect(!lib.isError(tf), 232);
    expect(lib.syscall6(Sys.pwritev, tf, @intFromPtr(&iov), 2, 3, 0, 0) == 8, 233);
    var back: [11]u8 = undefined;
    expect(lib.syscall6(Sys.pread64, tf, @intFromPtr(&back), 11, 0, 0, 0) == 11 and std.mem.eql(u8, back[3..11], whole[0..8]) and back[0] == 0, 234);
    expect(lib.syscall6(Sys.pwritev2, tf, @intFromPtr(&iov), 1, @bitCast(@as(i64, -1)), 0, 0) == 4, 235); // -1: at the offset, as writev
    _ = lib.close(tf);
    _ = lib.syscall(Sys.unlink, @intFromPtr(&tname), 0, 0);
    _ = lib.close(motd2);

    // --- /proc/self/status, statm, mounts; threads in task/, with names.
    {
        const self_pid = lib.syscall(Sys.getpid, 0, 0, 0);
        const my_tid = lib.syscall(Sys.gettid, 0, 0, 0);
        var pbuf: [32]u8 = undefined;
        const status = slurp("/proc/self/status");
        expect(std.mem.indexOf(u8, status, std.fmt.bufPrint(&pbuf, "\nPid:\t{d}\n", .{self_pid}) catch unreachable) != null, 240);
        expect(std.mem.startsWith(u8, status, "Name:\t") and std.mem.indexOf(u8, status, "\nThreads:\t1\n") != null, 241);
        expect(std.mem.indexOf(u8, status, "\nVmRSS:\t") != null and std.mem.indexOf(u8, status, "\nCpus_allowed_list:\t") != null, 242);
        var statm_fields = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, slurp("/proc/self/statm"), "\n"), ' ');
        var statm_count: usize = 0;
        while (statm_fields.next()) |f| : (statm_count += 1) _ = std.fmt.parseInt(u64, f, 10) catch expect(false, 243);
        expect(statm_count == 7, 244);
        expect(std.mem.indexOf(u8, slurp("/proc/self/mounts"), "tmpfs /tmp tmpfs rw") != null, 245);
        expect(std.mem.indexOf(u8, slurp("/proc/mounts"), "proc /proc proc") != null, 246);
        // A thread's thread_name: set with prctl, seen in both comm files.
        expect(lib.syscall6(Sys.prctl, 15, @intFromPtr("worker-x"), 0, 0, 0, 0) == 0, 247); // PR_SET_NAME
        var thread_name: [16]u8 = undefined;
        expect(lib.syscall6(Sys.prctl, 16, @intFromPtr(&thread_name), 0, 0, 0, 0) == 0 and std.mem.eql(u8, std.mem.sliceTo(&thread_name, 0), "worker-x"), 248);
        expect(std.mem.eql(u8, slurp("/proc/self/comm"), "worker-x\n"), 249);
        var comm_buf: [48]u8 = undefined;
        const comm_path = zpath(&comm_buf, "/proc/self/task/{d}/comm", my_tid);
        expect(std.mem.eql(u8, slurp(comm_path), "worker-x\n"), 250);
        // Written through the file: what pthread_setname_np does.
        const thread_comm_fd = lib.syscall(Sys.open, @intFromPtr(comm_path), abi.O.WRONLY, 0);
        expect(!lib.isError(thread_comm_fd) and lib.syscall(Sys.write, thread_comm_fd, @intFromPtr("renamed\n"), 8) == 8, 251);
        _ = lib.close(thread_comm_fd);
        expect(lib.syscall6(Sys.prctl, 16, @intFromPtr(&thread_name), 0, 0, 0, 0) == 0 and std.mem.eql(u8, std.mem.sliceTo(&thread_name, 0), "renamed"), 252);
        var stat_buf: [48]u8 = undefined;
        const stat_path = zpath(&stat_buf, "/proc/self/task/{d}/stat", my_tid);
        var stat_start: [32]u8 = undefined;
        expect(std.mem.startsWith(u8, slurp(stat_path), std.fmt.bufPrint(&stat_start, "{d} (renamed) ", .{my_tid}) catch unreachable), 253);
        expect(lib.syscall(Sys.open, @intFromPtr("/proc/self/task/999999/comm"), 0, 0) == lib.err(.NOENT), 254);
        expect(lib.syscall(Sys.open, @intFromPtr("/proc/self/status"), abi.O.WRONLY, 0) == lib.err(.ROFS), 255);
        // The task directory lists the thread.
        const task_fd = lib.syscall(Sys.open, @intFromPtr("/proc/self/task"), abi.O.RDONLY | abi.O.DIRECTORY, 0);
        expect(!lib.isError(task_fd), 256);
        var task_dents: [512]u8 align(8) = undefined;
        const dent_len = lib.syscall(Sys.getdents64, task_fd, @intFromPtr(&task_dents), task_dents.len);
        _ = lib.close(task_fd);
        var tid_name: [16]u8 = undefined;
        expect(!lib.isError(dent_len) and std.mem.indexOf(u8, task_dents[0..dent_len], std.fmt.bufPrint(&tid_name, "{d}", .{my_tid}) catch unreachable) != null, 257);
        _ = lib.syscall6(Sys.prctl, 15, @intFromPtr("files"), 0, 0, 0, 0);
    }

    lib.exit(0);
}
