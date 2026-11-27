//! `/test/sigqueue`: real-time signals and taking signals without a
//! handler. Each real-time signal sent is delivered, in order, with the
//! value `rt_sigqueueinfo` gave it; a standard signal sent twice while
//! pending is one. `rt_sigtimedwait` takes them, waits for one, or gives
//! up after its timeout; a `signalfd` is read for them and is readable to
//! `poll` and `epoll` while one is pending. A program may not pretend to
//! be the kernel to another process, and the queue has a limit. Exits
//! with 0, or with the number of the first failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

const SIGUSR1 = 10;
const SIGUSR2 = 12;
const RT1 = 33; // SIGRTMIN + 1 as a C library numbers it with two kept for itself
const RT2 = 34;
const RT3 = 35;
const RT4 = 36;
const SI_USER = 0;
const SI_QUEUE = -1;
const SA_SIGINFO = 0x4;
const SA_RESTORER = 0x0400_0000;

/// `siginfo_t` as a signal with a value carries it.
const SigInfo = extern struct {
    signo: i32 = 0,
    errno: i32 = 0,
    code: i32 = 0,
    _pad: i32 = 0,
    pid: u32 = 0,
    uid: u32 = 0,
    value: u64 = 0,
    _rest: [96]u8 = @splat(0),
};

comptime {
    asm (
        \\.section .text
        \\.global sq_restorer
        \\sq_restorer:
        \\  mov $15, %eax
        \\  syscall
        \\  ud2
    );
}
extern fn sq_restorer() callconv(.c) void;

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn bit(sig: u6) u64 {
    return @as(u64, 1) << (sig - 1);
}

fn block(mask: u64) void {
    _ = lib.syscall6(Sys.rt_sigprocmask, abi.SIG.BLOCK, @intFromPtr(&mask), 0, abi.SIGSET_SIZE, 0, 0);
}

fn unblock(mask: u64) void {
    _ = lib.syscall6(Sys.rt_sigprocmask, abi.SIG.UNBLOCK, @intFromPtr(&mask), 0, abi.SIGSET_SIZE, 0, 0);
}

fn queue(pid: u64, sig: u64, code: i32, value: u64) u64 {
    const info: SigInfo = .{ .signo = @intCast(sig), .code = code, .pid = @intCast(lib.syscall(Sys.getpid, 0, 0, 0)), .value = value };
    return lib.syscall(Sys.rt_sigqueueinfo, pid, sig, @intFromPtr(&info));
}

/// `rt_sigtimedwait` for `set`, without waiting (`timeout_ms` 0), for ever
/// (null), or that long.
fn timedWait(set: u64, info: *SigInfo, timeout_ms: ?u64) u64 {
    if (timeout_ms) |ms| {
        const ts: abi.TimeSpec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
        return lib.syscall6(Sys.rt_sigtimedwait, @intFromPtr(&set), @intFromPtr(info), @intFromPtr(&ts), abi.SIGSET_SIZE, 0, 0);
    }
    return lib.syscall6(Sys.rt_sigtimedwait, @intFromPtr(&set), @intFromPtr(info), 0, abi.SIGSET_SIZE, 0, 0);
}

fn nowMs() u64 {
    var ts: abi.TimeSpec = undefined;
    _ = lib.syscall(Sys.clock_gettime, abi.CLOCK.MONOTONIC, @intFromPtr(&ts), 0);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn sleepMs(ms: u64) void {
    const ts: abi.TimeSpec = .{ .sec = 0, .nsec = @intCast(ms * 1_000_000) };
    _ = lib.syscall(Sys.nanosleep, @intFromPtr(&ts), 0, 0);
}

fn wait4(pid: u64, status: *i32) u64 {
    return lib.syscall6(Sys.wait4, pid, @intFromPtr(status), 0, 0, 0, 0);
}

var seen: [8]u64 = undefined;
var seen_count: usize = 0;
fn onRt(_: i32, info: *const SigInfo, _: *anyopaque) callconv(.c) void {
    if (seen_count < seen.len) seen[seen_count] = info.value;
    seen_count += 1;
}

pub fn main() noreturn {
    const me = lib.syscall(Sys.getpid, 0, 0, 0);
    var info: SigInfo = .{};

    // --- Three of one real-time signal, each with its value, and two of a
    // standard one: rt_sigtimedwait takes the three in order, the two once.
    block(bit(RT1) | bit(SIGUSR1));
    expect(queue(me, RT1, SI_QUEUE, 1) == 0 and queue(me, RT1, SI_QUEUE, 2) == 0 and queue(me, RT1, SI_QUEUE, 3) == 0, 1);
    expect(lib.syscall(Sys.kill, me, SIGUSR1, 0) == 0 and lib.syscall(Sys.kill, me, SIGUSR1, 0) == 0, 2);
    var pending: u64 = 0;
    expect(lib.syscall(Sys.rt_sigpending, @intFromPtr(&pending), abi.SIGSET_SIZE, 0) == 0 and pending & (bit(RT1) | bit(SIGUSR1)) == bit(RT1) | bit(SIGUSR1), 3);
    for ([_]u64{ 1, 2, 3 }) |v| {
        expect(timedWait(bit(RT1), &info, 0) == RT1, 4);
        expect(info.signo == RT1 and info.code == SI_QUEUE and info.pid == me and info.value == v, 5);
    }
    expect(timedWait(bit(RT1), &info, 0) == lib.err(.AGAIN), 6); // all taken
    expect(timedWait(bit(SIGUSR1), &info, 0) == SIGUSR1 and info.code == SI_USER and info.pid == me, 7); // from kill
    expect(timedWait(bit(SIGUSR1), &info, 0) == lib.err(.AGAIN), 8); // the second was the same one
    expect(lib.syscall(Sys.rt_sigpending, @intFromPtr(&pending), abi.SIGSET_SIZE, 0) == 0 and pending & (bit(RT1) | bit(SIGUSR1)) == 0, 9);

    // --- A timeout ends the wait.
    const before = nowMs();
    expect(timedWait(bit(RT1), &info, 30) == lib.err(.AGAIN) and nowMs() - before >= 25, 10);
    // Bad arguments.
    const set: u64 = bit(RT1);
    const bad_ts: abi.TimeSpec = .{ .sec = 0, .nsec = 2_000_000_000 };
    expect(lib.syscall6(Sys.rt_sigtimedwait, @intFromPtr(&set), 0, @intFromPtr(&bad_ts), abi.SIGSET_SIZE, 0, 0) == lib.err(.INVAL), 11);
    expect(lib.syscall6(Sys.rt_sigtimedwait, @intFromPtr(&set), 0, 0, 4, 0, 0) == lib.err(.INVAL), 12);
    expect(lib.syscall(Sys.rt_sigqueueinfo, me, 99, @intFromPtr(&info)) == lib.err(.INVAL), 13);
    expect(queue(99999, RT1, SI_QUEUE, 0) == lib.err(.SRCH), 14);

    // --- A handler gets each one, in order, with its value.
    const act = abi.SigAction{ .handler = @intFromPtr(&onRt), .flags = SA_SIGINFO | SA_RESTORER, .restorer = @intFromPtr(&sq_restorer), .mask = 0 };
    expect(lib.syscall6(Sys.rt_sigaction, RT2, @intFromPtr(&act), 0, abi.SIGSET_SIZE, 0, 0) == 0, 20);
    block(bit(RT2));
    expect(queue(me, RT2, SI_QUEUE, 7) == 0 and queue(me, RT2, SI_QUEUE, 8) == 0, 21);
    const to_thread: SigInfo = .{ .signo = RT2, .code = SI_QUEUE, .value = 9 };
    expect(lib.syscall6(Sys.rt_tgsigqueueinfo, me, me, RT2, @intFromPtr(&to_thread), 0, 0) == 0, 22); // to the thread
    expect(seen_count == 0, 23);
    unblock(bit(RT2));
    expect(seen_count == 3 and seen[0] == 9 and seen[1] == 7 and seen[2] == 8, 24); // the thread's own first

    // --- Another process: a value reaches it; pretending to be the
    // kernel (si_code 0 or more) does not.
    const child = lib.syscall(Sys.fork, 0, 0, 0);
    if (child == 0) {
        block(bit(RT3));
        var got: SigInfo = .{};
        if (timedWait(bit(RT3), &got, null) != RT3) lib.exit(1);
        lib.exit(@intCast(got.value));
    }
    expect(queue(child, RT3, SI_USER, 1) == lib.err(.PERM), 30);
    // The child may not have blocked it yet: then the default (the end
    // of the process) would take it. Give it time.
    sleepMs(20);
    expect(queue(child, RT3, SI_QUEUE, 42) == 0, 31);
    var status: i32 = 0;
    expect(wait4(child, &status) == child and status == 42 << 8, 32);

    // --- A signalfd.
    block(bit(RT4) | bit(SIGUSR2));
    const mask: u64 = bit(RT4) | bit(SIGUSR2);
    const sfd = lib.syscall6(Sys.signalfd4, @bitCast(@as(i64, -1)), @intFromPtr(&mask), abi.SIGSET_SIZE, abi.SFD.NONBLOCK, 0, 0);
    expect(!lib.isError(sfd), 40);
    var recs: [3]abi.SignalfdSiginfo = undefined;
    expect(lib.read(sfd, std.mem.sliceAsBytes(&recs)) == lib.err(.AGAIN), 41);
    expect(lib.read(sfd, std.mem.sliceAsBytes(&recs)[0..64]) == lib.err(.INVAL), 42); // less than a record
    expect(queue(me, RT4, SI_QUEUE, 5) == 0 and lib.syscall(Sys.kill, me, SIGUSR2, 0) == 0, 43);
    var pfd = [_]abi.PollFd{.{ .fd = @intCast(sfd), .events = abi.POLL.IN, .revents = 0 }};
    expect(lib.syscall(Sys.poll, @intFromPtr(&pfd), 1, 0) == 1 and pfd[0].revents == abi.POLL.IN, 44);
    expect(lib.read(sfd, std.mem.sliceAsBytes(&recs)) == 2 * @sizeOf(abi.SignalfdSiginfo), 45);
    expect(recs[0].signo == SIGUSR2 and recs[0].code == SI_USER and recs[0].pid == me, 46); // the lowest first
    expect(recs[1].signo == RT4 and recs[1].code == SI_QUEUE and recs[1].int == 5 and recs[1].ptr == 5, 47);
    expect(lib.read(sfd, std.mem.sliceAsBytes(&recs)) == lib.err(.AGAIN), 48);
    expect(lib.syscall(Sys.poll, @intFromPtr(&pfd), 1, 0) == 0, 49);
    // epoll sees it too.
    const ep = lib.syscall(Sys.epoll_create1, 0, 0, 0);
    const ev: abi.EpollEvent = .{ .events = abi.EPOLL.IN, .data = 77 };
    expect(lib.syscall6(Sys.epoll_ctl, ep, abi.EPOLL.CTL_ADD, sfd, @intFromPtr(&ev), 0, 0) == 0, 50);
    var evs: [2]abi.EpollEvent = undefined;
    expect(lib.syscall6(Sys.epoll_wait, ep, @intFromPtr(&evs), 2, 0, 0, 0) == 0, 51);
    expect(queue(me, RT4, SI_QUEUE, 6) == 0, 52);
    expect(lib.syscall6(Sys.epoll_wait, ep, @intFromPtr(&evs), 2, 0, 0, 0) == 1 and evs[0].data == 77, 53);
    _ = lib.read(sfd, std.mem.sliceAsBytes(&recs));
    // A new set for the same descriptor; and one that is no signalfd.
    const only_usr2: u64 = bit(SIGUSR2);
    expect(lib.syscall6(Sys.signalfd4, sfd, @intFromPtr(&only_usr2), abi.SIGSET_SIZE, 0, 0, 0) == sfd, 54);
    expect(queue(me, RT4, SI_QUEUE, 1) == 0, 55);
    expect(lib.read(sfd, std.mem.sliceAsBytes(&recs)) == lib.err(.AGAIN), 56); // RT4 is not in the set now
    expect(timedWait(bit(RT4), &info, 0) == RT4, 57);
    expect(lib.syscall6(Sys.signalfd4, ep, @intFromPtr(&mask), abi.SIGSET_SIZE, 0, 0, 0) == lib.err(.INVAL), 58);
    expect(lib.syscall6(Sys.signalfd4, @bitCast(@as(i64, -1)), @intFromPtr(&mask), 4, 0, 0, 0) == lib.err(.INVAL), 59);
    // A blocking read waits until a signal comes, here from a child.
    expect(lib.syscall6(Sys.signalfd4, sfd, @intFromPtr(&mask), abi.SIGSET_SIZE, 0, 0, 0) == sfd, 60);
    const wfd = lib.syscall6(Sys.signalfd4, @bitCast(@as(i64, -1)), @intFromPtr(&mask), abi.SIGSET_SIZE, 0, 0, 0); // without O_NONBLOCK
    const sender = lib.syscall(Sys.fork, 0, 0, 0);
    if (sender == 0) {
        sleepMs(20);
        lib.exit(if (queue(lib.syscall(Sys.getppid, 0, 0, 0), RT4, SI_QUEUE, 11) == 0) 0 else 1);
    }
    expect(lib.read(wfd, std.mem.sliceAsBytes(&recs)) == @sizeOf(abi.SignalfdSiginfo) and recs[0].signo == RT4 and recs[0].int == 11 and recs[0].pid == sender, 61);
    expect(wait4(sender, &status) == sender and status == 0, 62);
    for ([_]u64{ sfd, wfd, ep }) |fd| _ = lib.close(fd);

    // --- The queue has a limit: RLIMIT_SIGPENDING, lowered in a child.
    const limited = lib.syscall(Sys.fork, 0, 0, 0);
    if (limited == 0) {
        const lim: abi.RLimit = .{ .cur = 4, .max = 4 };
        if (lib.syscall(Sys.setrlimit, abi.RLIMIT.SIGPENDING, @intFromPtr(&lim), 0) != 0) lib.exit(1);
        const self = lib.syscall(Sys.getpid, 0, 0, 0);
        for (0..4) |_| if (queue(self, RT1, SI_QUEUE, 0) != 0) lib.exit(2);
        if (queue(self, RT1, SI_QUEUE, 0) != lib.err(.AGAIN)) lib.exit(3);
        if (lib.syscall(Sys.kill, self, RT1, 0) != lib.err(.AGAIN)) lib.exit(4); // kill of a real-time signal too
        // Taking one makes room.
        var got: SigInfo = .{};
        if (timedWait(bit(RT1), &got, 0) != RT1 or queue(self, RT1, SI_QUEUE, 0) != 0) lib.exit(5);
        lib.exit(0); // what is queued goes with the process
    }
    expect(wait4(limited, &status) == limited and status == 0, 70);
    lib.exit(0);
}
