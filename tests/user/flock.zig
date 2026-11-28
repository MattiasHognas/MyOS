//! `/test/flock`: advisory locks on whole files. Two open files of one
//! file: shared locks go together, an exclusive one keeps out every other;
//! `LOCK_NB` says so at once, and without it the caller waits, here for
//! another process to unlock. A duplicate descriptor shares its open
//! file's lock; closing the last descriptor gives it up; changing its kind
//! works. Exits with 0, or with the number of the first failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;
const LOCK = abi.LOCK;

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn flock(fd: u64, op: u64) u64 {
    return lib.syscall(Sys.flock, fd, op, 0);
}

fn sleepMs(ms: u64) void {
    const ts: abi.TimeSpec = .{ .sec = 0, .nsec = @intCast(ms * 1_000_000) };
    _ = lib.syscall(Sys.nanosleep, @intFromPtr(&ts), 0, 0);
}

pub fn main() noreturn {
    // A file of its own in /tmp: two copies of this program run at once.
    var name_buf: [48]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&name_buf, "/tmp/flock-{d}", .{lib.syscall(Sys.getpid, 0, 0, 0)}, 0) catch unreachable;
    const a = lib.syscall(Sys.open, @intFromPtr(name.ptr), abi.O.RDWR | abi.O.CREAT, 0o644);
    const b = lib.open(name);
    expect(!lib.isError(a) and !lib.isError(b), 1);

    // Exclusive keeps out the other open file, shared and exclusive alike.
    expect(flock(a, LOCK.EX) == 0, 2);
    expect(flock(b, LOCK.EX | LOCK.NB) == lib.err(.AGAIN), 3);
    expect(flock(b, LOCK.SH | LOCK.NB) == lib.err(.AGAIN), 4);
    expect(flock(a, LOCK.EX) == 0, 5); // again: it has it
    // A duplicate is the same open file: it holds the lock too.
    const a2 = lib.syscall(Sys.dup, a, 0, 0);
    expect(flock(a2, LOCK.EX | LOCK.NB) == 0, 6);
    expect(flock(a, LOCK.UN) == 0, 7);
    // Shared locks go together; exclusive waits for them.
    expect(flock(b, LOCK.SH | LOCK.NB) == 0 and flock(a, LOCK.SH | LOCK.NB) == 0, 8);
    expect(flock(a, LOCK.EX | LOCK.NB) == lib.err(.AGAIN), 9); // b has a shared one
    // Closing b's descriptor gives up its lock.
    expect(lib.close(b) == 0, 10);
    expect(flock(a, LOCK.EX | LOCK.NB) == 0, 11); // from shared to exclusive
    // A lock on a file opened read-only, as .NET takes them.
    const motd = lib.open("/etc/motd");
    expect(flock(motd, LOCK.SH) == 0 and flock(motd, LOCK.UN) == 0, 12);
    _ = lib.close(motd);
    // Bad arguments.
    expect(flock(a, 0) == lib.err(.INVAL) and flock(a, LOCK.SH | LOCK.EX) == lib.err(.INVAL) and flock(a, LOCK.NB) == lib.err(.INVAL), 13);
    expect(flock(999, LOCK.SH) == lib.err(.BADF), 14);

    // Another process waits for the lock this one holds, and gets it when
    // it is given up.
    var pfd: [2]i32 = undefined;
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&pfd), 0, 0) == 0, 20);
    const child = lib.syscall(Sys.fork, 0, 0, 0);
    if (child == 0) {
        // Its own open file of the same file.
        const c = lib.open(name);
        if (flock(c, LOCK.EX | LOCK.NB) != lib.err(.AGAIN)) lib.exit(1);
        _ = lib.syscall(Sys.write, @intCast(pfd[1]), @intFromPtr("w"), 1); // about to wait
        if (flock(c, LOCK.EX) != 0) lib.exit(2);
        _ = lib.syscall(Sys.write, @intCast(pfd[1]), @intFromPtr("g"), 1); // got it
        lib.exit(0);
    }
    var ch: [1]u8 = undefined;
    expect(lib.read(@intCast(pfd[0]), &ch) == 1 and ch[0] == 'w', 21);
    sleepMs(30);
    // The child inherited a and a2, which share this lock; closing them all
    // here is what gives it up: the child's copies close as it ends.
    expect(flock(a, LOCK.UN) == 0, 22);
    expect(lib.read(@intCast(pfd[0]), &ch) == 1 and ch[0] == 'g', 23);
    var status: i32 = 0;
    expect(lib.syscall6(Sys.wait4, child, @intFromPtr(&status), 0, 0, 0, 0) == child and status == 0, 24);
    // Its lock went with its open file.
    expect(flock(a, LOCK.EX | LOCK.NB) == 0, 25);

    // --- Record locks (fcntl): byte ranges, per process or per open file.
    {
        const F_GETLK = 5;
        const F_SETLK = 6;
        const F_SETLKW = 7;
        const F_OFD_SETLK = 37;
        const RD = 0;
        const WR = 1;
        const UN = 2;
        const Flock = extern struct { type: i16, whence: i16 = 0, _pad: u32 = 0, start: i64, len: i64, pid: i32 = 0, _pad2: u32 = 0 };
        const op = struct {
            fn lk(fd: u64, cmd: u64, t: i16, start: i64, len: i64) u64 {
                var fl: Flock = .{ .type = t, .start = start, .len = len };
                return lib.syscall(Sys.fcntl, fd, cmd, @intFromPtr(&fl));
            }
            fn get(fd: u64, t: i16, start: i64, len: i64) Flock {
                var fl: Flock = .{ .type = t, .start = start, .len = len };
                _ = lib.syscall(Sys.fcntl, fd, F_GETLK, @intFromPtr(&fl));
                return fl;
            }
        };
        const me: i32 = @intCast(lib.syscall(Sys.getpid, 0, 0, 0));
        const f = lib.syscall(Sys.open, @intFromPtr(name.ptr), abi.O.RDWR, 0);
        expect(op.lk(f, F_SETLK, WR, 0, 10) == 0, 30);
        expect(op.get(f, WR, 0, 10).type == UN, 31); // its own locks are never in its way
        // Another process: told who is in its way, refused without waiting.
        const c1 = lib.syscall(Sys.fork, 0, 0, 0);
        if (c1 == 0) {
            const g = op.get(f, WR, 5, 1);
            if (g.type != WR or g.start != 0 or g.len != 10 or g.pid != me) lib.exit(50);
            if (op.lk(f, F_SETLK, RD, 5, 1) != lib.err(.AGAIN)) lib.exit(51);
            if (op.lk(f, F_SETLK, WR, 20, 0) != 0) lib.exit(52); // to the end: free
            lib.exit(0);
        }
        expect(lib.syscall6(Sys.wait4, c1, @intFromPtr(&status), 0, 0, 0, 0) == c1 and status == 0, 32);
        // Part of it given up: that part is free, the rest still held.
        expect(op.lk(f, F_SETLK, UN, 0, 5) == 0, 33);
        // Waiting (F_SETLKW) until it is given up.
        const c2 = lib.syscall(Sys.fork, 0, 0, 0);
        if (c2 == 0) {
            if (op.lk(f, F_SETLK, WR, 0, 5) != 0) lib.exit(53); // the part given up
            if (op.lk(f, F_SETLK, WR, 5, 1) != lib.err(.AGAIN)) lib.exit(54);
            if (op.lk(f, F_SETLKW, WR, 5, 1) != 0) lib.exit(55); // waits for the parent
            lib.exit(0);
        }
        sleepMs(30);
        expect(op.lk(f, F_SETLK, UN, 0, 0) == 0, 34);
        expect(lib.syscall6(Sys.wait4, c2, @intFromPtr(&status), 0, 0, 0, 0) == c2 and status == 0, 35);
        // Closing any descriptor of the file gives the process's locks up.
        expect(op.lk(f, F_SETLK, WR, 0, 1) == 0, 36);
        const other = lib.syscall(Sys.open, @intFromPtr(name.ptr), abi.O.RDONLY, 0);
        _ = lib.close(other);
        const c3 = lib.syscall(Sys.fork, 0, 0, 0);
        if (c3 == 0) lib.exit(if (op.get(f, WR, 0, 1).type == UN) 0 else 56);
        expect(lib.syscall6(Sys.wait4, c3, @intFromPtr(&status), 0, 0, 0, 0) == c3 and status == 0, 37);
        // OFD locks: two open files of one process are two owners.
        const x = lib.syscall(Sys.open, @intFromPtr(name.ptr), abi.O.RDWR, 0);
        const y = lib.syscall(Sys.open, @intFromPtr(name.ptr), abi.O.RDWR, 0);
        expect(op.lk(x, F_OFD_SETLK, WR, 0, 5) == 0, 38);
        expect(op.lk(y, F_OFD_SETLK, WR, 0, 5) == lib.err(.AGAIN), 39);
        _ = lib.close(x); // its locks go with it
        expect(op.lk(y, F_OFD_SETLK, WR, 0, 5) == 0, 40);
        // What is refused.
        expect(op.lk(f, F_SETLK, 9, 0, 1) == lib.err(.INVAL), 41);
        expect(op.lk(f, F_SETLK, WR, -5, 1) == lib.err(.INVAL), 42);
        // Ranges at the edges of what fits: refused, the kernel unharmed.
        expect(op.lk(f, F_SETLK, WR, std.math.maxInt(i64), 1) == lib.err(.OVERFLOW), 45);
        expect(op.lk(f, F_SETLK, WR, 0, std.math.minInt(i64)) == lib.err(.INVAL), 46);
        expect(op.lk(f, F_SETLK, WR, 10, -11) == lib.err(.INVAL), 47); // before 0
        expect(op.lk(f, F_SETLK, WR, 20, -10) == 0 and op.lk(f, F_SETLK, UN, 10, 10) == 0, 48); // [10, 20), clear of y's
        const ro = lib.open(name);
        expect(op.lk(ro, F_SETLK, WR, 0, 1) == lib.err(.BADF), 43); // a write lock on a file open for reading
        var p: [2]i32 = undefined;
        _ = lib.syscall(Sys.pipe2, @intFromPtr(&p), 0, 0);
        expect(op.lk(@intCast(p[0]), F_SETLK, RD, 0, 1) == lib.err(.INVAL), 44);
        for ([_]u64{ f, y, ro, @intCast(p[0]), @intCast(p[1]) }) |fd| _ = lib.close(fd);
    }

    for ([_]u64{ a, a2, @intCast(pfd[0]), @intCast(pfd[1]) }) |fd| _ = lib.close(fd);
    _ = lib.syscall(Sys.unlink, @intFromPtr(name.ptr), 0, 0);
    lib.exit(0);
}
