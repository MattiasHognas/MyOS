//! `/test/jobs`: stopping and continuing processes, as job control does.
//! `SIGSTOP` stops a child, which `wait4` reports with `WUNTRACED` and
//! `/proc` shows as `T`; signals sent to it meanwhile wait until `SIGCONT`
//! continues it (`WCONTINUED`), `SIGKILL` excepted; the parent gets
//! `SIGCHLD` for both. `SIGTSTP` stops a process without a handler and
//! runs the handler of one that has it; `SIGCONT` throws away a pending
//! stop signal. A process in the background that reads the terminal gets
//! `SIGTTIN` (or `EIO` if it ignores that), and one that takes the
//! terminal `SIGTTOU`. Exits with 0, or with the number of the first
//! failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

const SIGKILL = 9;
const SIGTERM = 15;
const SIGCHLD = 17;
const SIGCONT = 18;
const SIGSTOP = 19;
const SIGTSTP = 20;
const SIGTTIN = 21;
const SIGTTOU = 22;
const SA_RESTORER = 0x0400_0000;
const SA_NOCLDSTOP = 0x1;
const SIG_IGN = 1;
const TIOCSPGRP = 0x5410;

comptime {
    asm (
        \\.section .text
        \\.global jobs_restorer
        \\jobs_restorer:
        \\  mov $15, %eax
        \\  syscall
        \\  ud2
    );
}
extern fn jobs_restorer() callconv(.c) void;

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn wait4(pid: u64, status: *i32, options: u64) u64 {
    return lib.syscall6(Sys.wait4, pid, @intFromPtr(status), options, 0, 0, 0);
}

fn kill(pid: u64, sig: u64) void {
    expect(lib.syscall(Sys.kill, pid, sig, 0) == 0, 250);
}

fn sleepMs(ms: u64) void {
    const ts: abi.TimeSpec = .{ .sec = 0, .nsec = @intCast(ms * 1_000_000) };
    _ = lib.syscall(Sys.nanosleep, @intFromPtr(&ts), 0, 0);
}

fn sigaction(sig: u64, handler: u64, flags: u64) u64 {
    const act = abi.SigAction{ .handler = handler, .flags = flags | SA_RESTORER, .restorer = @intFromPtr(&jobs_restorer), .mask = 0 };
    return lib.syscall6(Sys.rt_sigaction, sig, @intFromPtr(&act), 0, abi.SIGSET_SIZE, 0, 0);
}

fn stopped(sig: u32) i32 {
    return @intCast((sig << 8) | 0x7f);
}

/// The state letter in `/proc/<pid>/stat`.
fn state(pid: u64) u8 {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/stat", .{pid}, 0) catch return 0;
    const fd = lib.open(path);
    if (lib.isError(fd)) return 0;
    defer _ = lib.close(fd);
    var buf: [128]u8 = undefined;
    const n = lib.read(fd, &buf);
    if (lib.isError(n)) return 0;
    const close_paren = std.mem.lastIndexOfScalar(u8, buf[0..n], ')') orelse return 0;
    return if (close_paren + 2 < n) buf[close_paren + 2] else 0;
}

var chld_count: std.atomic.Value(u32) = .init(0);
fn onChld(_: i32) callconv(.c) void {
    _ = chld_count.fetchAdd(1, .monotonic);
}

var tstp_count: std.atomic.Value(u32) = .init(0);
fn onTstp(_: i32) callconv(.c) void {
    _ = tstp_count.fetchAdd(1, .monotonic);
}

/// Bytes waiting in the non-blocking pipe `fd`, read and thrown away.
fn drain(fd: u64) usize {
    var total: usize = 0;
    var buf: [64]u8 = undefined;
    while (true) {
        const n = lib.read(fd, &buf);
        if (lib.isError(n) or n == 0) return total;
        total += n;
    }
}

/// A child that writes a byte to `fd` every 2 ms until it is ended.
fn ticker(fd: u64) noreturn {
    while (true) {
        _ = lib.syscall(Sys.write, fd, @intFromPtr("t"), 1);
        sleepMs(2);
    }
}

pub fn main() noreturn {
    var status: i32 = 0;
    expect(sigaction(SIGCHLD, @intFromPtr(&onChld), 0) == 0, 1);

    // --- SIGSTOP and SIGCONT: a child that keeps writing stops writing.
    var pfd: [2]i32 = undefined;
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&pfd), abi.O.NONBLOCK, 0) == 0, 2);
    const rd: u64 = @intCast(pfd[0]);
    const wr: u64 = @intCast(pfd[1]);
    const a = lib.syscall(Sys.fork, 0, 0, 0);
    if (a == 0) ticker(wr);
    expect(!lib.isError(a), 3);
    sleepMs(20);
    expect(drain(rd) > 0, 4); // it runs
    const chld_before = chld_count.load(.monotonic);
    kill(a, SIGSTOP);
    expect(wait4(a, &status, abi.WUNTRACED) == a and status == stopped(SIGSTOP), 5);
    expect(chld_count.load(.monotonic) > chld_before, 6); // told by SIGCHLD
    expect(state(a) == 'T', 7);
    expect(wait4(a, &status, abi.WUNTRACED | abi.WNOHANG) == 0, 8); // reported once
    sleepMs(20);
    _ = drain(rd); // what it wrote on its way to stopping
    sleepMs(40);
    expect(drain(rd) == 0, 9); // stopped: nothing new
    // A signal sent meanwhile waits: SIGTERM does not end it yet.
    kill(a, SIGTERM);
    sleepMs(20);
    expect(wait4(a, &status, abi.WNOHANG) == 0 and state(a) == 'T', 10);
    // SIGCONT continues it, and the SIGTERM then ends it.
    const chld_mid = chld_count.load(.monotonic);
    kill(a, SIGCONT);
    expect(wait4(a, &status, abi.WCONTINUED) == a and status == 0xffff, 11);
    expect(chld_count.load(.monotonic) > chld_mid, 12);
    expect(wait4(a, &status, 0) == a and status == SIGTERM, 13);

    // --- SIGKILL ends a stopped process.
    const b = lib.syscall(Sys.fork, 0, 0, 0);
    if (b == 0) ticker(wr);
    kill(b, SIGSTOP);
    expect(wait4(b, &status, abi.WUNTRACED) == b and status == stopped(SIGSTOP), 20);
    kill(b, SIGKILL);
    expect(wait4(b, &status, 0) == b and status == SIGKILL, 21);
    _ = drain(rd);

    // --- SIGTSTP stops a process that does not handle it; one that stops
    // itself is continued, and ends as it likes.
    const c = lib.syscall(Sys.fork, 0, 0, 0);
    if (c == 0) {
        _ = lib.syscall(Sys.kill, lib.syscall(Sys.getpid, 0, 0, 0), SIGTSTP, 0);
        lib.exit(5); // once continued
    }
    expect(wait4(c, &status, abi.WUNTRACED) == c and status == stopped(SIGTSTP), 30);
    kill(c, SIGCONT);
    expect(wait4(c, &status, 0) == c and status == 5 << 8, 31);

    // --- A handler for SIGTSTP runs instead.
    const d = lib.syscall(Sys.fork, 0, 0, 0);
    if (d == 0) {
        if (sigaction(SIGTSTP, @intFromPtr(&onTstp), 0) != 0) lib.exit(1);
        _ = lib.syscall(Sys.kill, lib.syscall(Sys.getpid, 0, 0, 0), SIGTSTP, 0);
        lib.exit(if (tstp_count.load(.monotonic) == 1) 0 else 2);
    }
    expect(wait4(d, &status, abi.WUNTRACED) == d and status == 0, 32);

    // --- SIGCONT throws away a pending stop signal: a child that blocks
    // SIGTSTP finds none pending after SIGCONT.
    // (Two pipes: one for "ready", one for "go".)
    var gfd: [2]i32 = undefined;
    var rfd: [2]i32 = undefined;
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&gfd), 0, 0) == 0 and lib.syscall(Sys.pipe2, @intFromPtr(&rfd), 0, 0) == 0, 40);
    const e = lib.syscall(Sys.fork, 0, 0, 0);
    if (e == 0) {
        const block: u64 = 1 << (SIGTSTP - 1);
        _ = lib.syscall6(Sys.rt_sigprocmask, 0, @intFromPtr(&block), 0, abi.SIGSET_SIZE, 0, 0); // SIG_BLOCK
        _ = lib.syscall(Sys.write, @intCast(rfd[1]), @intFromPtr("r"), 1);
        var go: [1]u8 = undefined;
        _ = lib.read(@intCast(gfd[0]), &go); // until the parent has sent both
        var pending: u64 = 0;
        _ = lib.syscall(Sys.rt_sigpending, @intFromPtr(&pending), abi.SIGSET_SIZE, 0);
        lib.exit(if (pending & block == 0) 0 else 3);
    }
    var ready: [1]u8 = undefined;
    expect(lib.read(@intCast(rfd[0]), &ready) == 1, 41);
    kill(e, SIGTSTP);
    kill(e, SIGCONT);
    _ = lib.syscall(Sys.write, @intCast(gfd[1]), @intFromPtr("g"), 1);
    expect(wait4(e, &status, 0) == e and status == 0, 42);
    for ([_]i32{ gfd[0], gfd[1], rfd[0], rfd[1] }) |fd| _ = lib.close(@intCast(fd));

    // --- SA_NOCLDSTOP: no SIGCHLD for a stop.
    expect(sigaction(SIGCHLD, @intFromPtr(&onChld), SA_NOCLDSTOP) == 0, 50);
    const f = lib.syscall(Sys.fork, 0, 0, 0);
    if (f == 0) ticker(wr);
    const chld_quiet = chld_count.load(.monotonic);
    kill(f, SIGSTOP);
    expect(wait4(f, &status, abi.WUNTRACED) == f and status == stopped(SIGSTOP), 51);
    expect(chld_count.load(.monotonic) == chld_quiet, 52);
    kill(f, SIGKILL);
    expect(wait4(f, &status, 0) == f and status == SIGKILL, 53);
    _ = drain(rd);

    // --- The terminal: this process's group has it, so a child in a group
    // of its own is in the background.
    const my_group: i32 = @intCast(lib.syscall(Sys.getpgid, 0, 0, 0));
    expect(lib.syscall(Sys.ioctl, 0, TIOCSPGRP, @intFromPtr(&my_group)) == 0, 60);
    // Reading it stops the child (SIGTTIN).
    const g = lib.syscall(Sys.fork, 0, 0, 0);
    if (g == 0) {
        _ = lib.syscall(Sys.setpgid, 0, 0, 0);
        var buf: [8]u8 = undefined;
        _ = lib.read(0, &buf);
        lib.exit(9);
    }
    expect(wait4(g, &status, abi.WUNTRACED) == g and status == stopped(SIGTTIN), 61);
    kill(g, SIGKILL);
    expect(wait4(g, &status, 0) == g and status == SIGKILL, 62);
    // One that ignores SIGTTIN is told EIO.
    const h = lib.syscall(Sys.fork, 0, 0, 0);
    if (h == 0) {
        _ = lib.syscall(Sys.setpgid, 0, 0, 0);
        if (sigaction(SIGTTIN, SIG_IGN, 0) != 0) lib.exit(1);
        var buf: [8]u8 = undefined;
        lib.exit(if (lib.read(0, &buf) == lib.err(.IO)) 0 else 2);
    }
    expect(wait4(h, &status, 0) == h and status == 0, 63);
    // Taking the terminal stops it (SIGTTOU) unless it ignores that.
    const i = lib.syscall(Sys.fork, 0, 0, 0);
    if (i == 0) {
        _ = lib.syscall(Sys.setpgid, 0, 0, 0);
        const own: i32 = @intCast(lib.syscall(Sys.getpid, 0, 0, 0));
        _ = lib.syscall(Sys.ioctl, 0, TIOCSPGRP, @intFromPtr(&own));
        lib.exit(9);
    }
    expect(wait4(i, &status, abi.WUNTRACED) == i and status == stopped(SIGTTOU), 64);
    kill(i, SIGKILL);
    expect(wait4(i, &status, 0) == i and status == SIGKILL, 65);
    const j = lib.syscall(Sys.fork, 0, 0, 0);
    if (j == 0) {
        _ = lib.syscall(Sys.setpgid, 0, 0, 0);
        if (sigaction(SIGTTOU, SIG_IGN, 0) != 0) lib.exit(1);
        // Gives it back to the parent's group: allowed, nothing sent.
        lib.exit(if (lib.syscall(Sys.ioctl, 0, TIOCSPGRP, @intFromPtr(&my_group)) == 0) 0 else 2);
    }
    expect(wait4(j, &status, 0) == j and status == 0, 66);

    _ = lib.close(rd);
    _ = lib.close(wr);
    lib.exit(0);
}
