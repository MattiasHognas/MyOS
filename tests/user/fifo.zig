//! `/test/fifo`: FIFOs (named pipes) as Linux has them. `mknod` with
//! `S_IFIFO` makes one in `/tmp`, `stat` says what it is; opening one end
//! waits for the other (or, without waiting, succeeds for a reader and
//! fails with `ENXIO` for a writer nobody reads); what is written is read
//! at the other end, and end of file comes when the writers are gone; a
//! signal ends a wait; `unlink` takes the name away. Exits with 0, or
//! with the number of the first failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

const AT_FDCWD: u64 = @bitCast(@as(i64, -100));
const S_IFIFO = 0o010000;
const S_IFCHR = 0o020000;
const O_RDONLY = 0;
const O_WRONLY = 1;
const O_RDWR = 2;
const O_NONBLOCK = 0o4000;
const SIGUSR1 = 10;
const SA_RESTORER = 0x0400_0000;

comptime {
    asm (
        \\.section .text
        \\.global fifo_restorer
        \\fifo_restorer:
        \\  mov $15, %eax
        \\  syscall
        \\  ud2
    );
}
extern fn fifo_restorer() callconv(.c) void;
fn onSignal(_: i32) callconv(.c) void {}

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn mknod(path: [*:0]const u8, mode: u64) u64 {
    return lib.syscall6(Sys.mknodat, AT_FDCWD, @intFromPtr(path), mode, 0, 0, 0);
}

fn open(path: [*:0]const u8, flags: u64) u64 {
    return lib.syscall(Sys.open, @intFromPtr(path), flags, 0);
}

fn sleepMs(ms: u64) void {
    var t: abi.TimeSpec = .{ .sec = 0, .nsec = @intCast(ms * 1_000_000) };
    _ = lib.syscall(Sys.nanosleep, @intFromPtr(&t), 0, 0);
}

fn wait(pid: u64) i32 {
    var status: i32 = -1;
    _ = lib.syscall6(Sys.wait4, pid, @intFromPtr(&status), 0, 0, 0, 0);
    return status;
}

/// A name of its own, so that two copies of the test do not meet.
var path_buf: [32:0]u8 = undefined;

pub fn main() noreturn {
    const pid = lib.syscall(Sys.getpid, 0, 0, 0);
    const name = std.fmt.bufPrint(path_buf[0 .. path_buf.len - 1], "/tmp/fifo-{d}", .{pid}) catch unreachable;
    path_buf[name.len] = 0;
    const path: [*:0]const u8 = @ptrCast(&path_buf);

    // --- Making one.
    expect(mknod(path, S_IFIFO | 0o644) == 0, 1);
    expect(mknod(path, S_IFIFO | 0o644) == lib.err(.EXIST), 2);
    expect(mknod("/etc/fifo", S_IFIFO | 0o644) == lib.err(.ROFS), 3);
    expect(mknod("/tmp/fifo-dev", S_IFCHR | 0o644) == lib.err(.PERM), 4);
    var st: abi.Stat = .{};
    expect(lib.syscall6(Sys.newfstatat, AT_FDCWD, @intFromPtr(path), @intFromPtr(&st), 0, 0, 0) == 0, 5);
    expect(st.mode & 0o170000 == S_IFIFO, 6);
    expect(open(path, O_RDWR) == lib.err(.INVAL), 7);

    // --- Without waiting: a writer alone is refused, a reader alone is not.
    expect(open(path, O_WRONLY | O_NONBLOCK) == lib.err(.NXIO), 8);
    const r = open(path, O_RDONLY | O_NONBLOCK);
    expect(!lib.isError(r), 9);
    const w = open(path, O_WRONLY | O_NONBLOCK);
    expect(!lib.isError(w), 10);
    var buf: [8]u8 = undefined;
    expect(lib.syscall(Sys.read, r, @intFromPtr(&buf), buf.len) == lib.err(.AGAIN), 11); // empty, a writer there
    expect(lib.syscall(Sys.write, w, @intFromPtr("abc"), 3) == 3, 12);
    expect(lib.syscall(Sys.read, r, @intFromPtr(&buf), buf.len) == 3 and std.mem.eql(u8, buf[0..3], "abc"), 13);
    expect(lib.syscall(Sys.fstat, r, @intFromPtr(&st), 0) == 0 and st.mode & 0o170000 == S_IFIFO, 14);
    _ = lib.syscall(Sys.close, w, 0, 0);
    expect(lib.syscall(Sys.read, r, @intFromPtr(&buf), buf.len) == 0, 15); // the writers gone: the end
    _ = lib.syscall(Sys.close, r, 0, 0);

    // --- A writer waits for a reader: the child opens first.
    const writer = lib.syscall(Sys.fork, 0, 0, 0);
    if (writer == 0) {
        const fd = open(path, O_WRONLY);
        if (lib.isError(fd)) lib.exit(40);
        _ = lib.syscall(Sys.write, fd, @intFromPtr("hi"), 2);
        lib.exit(0);
    }
    sleepMs(20);
    const r2 = open(path, O_RDONLY);
    expect(!lib.isError(r2), 16);
    var got: usize = 0;
    while (got < 2) {
        const n = lib.syscall(Sys.read, r2, @intFromPtr(&buf[got]), 2 - got);
        if (lib.isError(n) or n == 0) break;
        got += n;
    }
    expect(got == 2 and std.mem.eql(u8, buf[0..2], "hi"), 17);
    expect(wait(writer) == 0, 18);
    _ = lib.syscall(Sys.close, r2, 0, 0);

    // --- A reader waits for a writer: the parent opens first.
    const late = lib.syscall(Sys.fork, 0, 0, 0);
    if (late == 0) {
        sleepMs(20);
        const fd = open(path, O_WRONLY);
        if (lib.isError(fd)) lib.exit(41);
        _ = lib.syscall(Sys.write, fd, @intFromPtr("ok"), 2);
        lib.exit(0);
    }
    const r3 = open(path, O_RDONLY);
    expect(!lib.isError(r3), 19);
    got = 0;
    while (got < 2) {
        const n = lib.syscall(Sys.read, r3, @intFromPtr(&buf[got]), 2 - got);
        if (lib.isError(n) or n == 0) break;
        got += n;
    }
    expect(got == 2 and std.mem.eql(u8, buf[0..2], "ok"), 20);
    expect(wait(late) == 0, 21);
    _ = lib.syscall(Sys.close, r3, 0, 0);

    // --- A signal ends a wait for the other end.
    const act = abi.SigAction{ .handler = @intFromPtr(&onSignal), .flags = SA_RESTORER, .restorer = @intFromPtr(&fifo_restorer), .mask = 0 };
    expect(lib.syscall6(Sys.rt_sigaction, SIGUSR1, @intFromPtr(&act), 0, abi.SIGSET_SIZE, 0, 0) == 0, 22);
    const poker = lib.syscall(Sys.fork, 0, 0, 0);
    if (poker == 0) {
        sleepMs(20);
        _ = lib.syscall(Sys.kill, pid, SIGUSR1, 0);
        lib.exit(0);
    }
    expect(open(path, O_RDONLY) == lib.err(.INTR), 23);
    expect(wait(poker) == 0, 24);
    // (The kernel test checks that no FIFO is left in its table now.)
    // Nobody waits or holds an end now: a writer alone is refused again.
    expect(open(path, O_WRONLY | O_NONBLOCK) == lib.err(.NXIO), 25);

    // --- A process killed while it waits to open leaves nothing behind
    // (the .NET runtime's debugger thread waits so for a debugger, until
    // the program ends). Last: nothing after it would tidy up for it.
    const sleeper = lib.syscall(Sys.fork, 0, 0, 0);
    if (sleeper == 0) {
        _ = open(path, O_RDONLY); // no writer comes
        lib.exit(42);
    }
    sleepMs(20);
    _ = lib.syscall(Sys.kill, sleeper, 9, 0);
    expect(wait(sleeper) & 0x7F == 9, 28);

    // --- Gone with its name.
    expect(lib.syscall(Sys.unlink, @intFromPtr(path), 0, 0) == 0, 26);
    expect(open(path, O_RDONLY | O_NONBLOCK) == lib.err(.NOENT), 27);
    lib.exit(0);
}
