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

/// Read the whole file at `path` into `text`.
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
    // One cannot be opened yet; a file is not one.
    expect(lib.open("/etc") == lib.err(.ACCES), 5);
    expect(openFlags("/etc", abi.O.WRONLY) == lib.err(.ISDIR), 6);
    expect(openFlags("/etc/motd", abi.O.DIRECTORY) == lib.err(.NOTDIR), 7);
    expect(openFlags("/sys/devices/system/node", abi.O.DIRECTORY) == lib.err(.NOENT), 8);
    // `stat` and `lstat` are `newfstatat` for a path.
    var st: abi.Stat = undefined;
    expect(lib.syscall(Sys.lstat, @intFromPtr("/etc/motd"), @intFromPtr(&st), 0) == 0 and st.size == 17, 9);
    expect(lib.syscall(Sys.stat, @intFromPtr("/nothing"), @intFromPtr(&st), 0) == lib.err(.NOENT), 10);
    expect(lib.syscall(Sys.stat, @intFromPtr("/etc/motd"), 8, 0) == lib.err(.FAULT), 11);

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
    expect(lib.syscall6(Sys.mknodat, CWD, @intFromPtr("/tmp/pipe"), S.IFIFO | 0o600, 0, 0, 0) == lib.err(.ROFS), 73);
    expect(lib.syscall(Sys.unlink, 8, 0, 0) == lib.err(.FAULT), 74);
    const motd = lib.open("/etc/motd");
    expect(lib.syscall(Sys.fchmod, motd, 0o600, 0) == lib.err(.ROFS) and lib.syscall(Sys.fchmod, 99, 0o600, 0) == lib.err(.BADF), 75);
    expect(lib.syscall(Sys.ftruncate, motd, 0, 0) == lib.err(.INVAL) and lib.syscall(Sys.ftruncate, 99, 0, 0) == lib.err(.BADF), 76);
    // No networking, no files in memory only.
    expect(lib.syscall(Sys.socket, 1, 1, 0) == lib.err(.AFNOSUPPORT), 77);
    expect(lib.syscall(Sys.memfd_create, @intFromPtr("x"), 0, 0) == lib.err(.NOSYS), 78);

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

    lib.exit(0);
}
