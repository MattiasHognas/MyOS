//! `/test/epoll`: `eventfd` and `epoll`, as a runtime's event loop uses
//! them: a counter another thread signals through, a pipe, waiting on
//! both with a timeout. Exits with 0, or with the number of the first
//! failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;
const EPOLL = abi.EPOLL;

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn write8(fd: u64, v: u64) u64 {
    return lib.syscall(Sys.write, fd, @intFromPtr(&v), 8);
}

fn read8(fd: u64) ?u64 {
    var v: u64 = 0;
    return if (lib.syscall(Sys.read, fd, @intFromPtr(&v), 8) == 8) v else null;
}

fn ctl(ep: u64, op: u64, fd: u64, mask: u32, data: u64) u64 {
    const ev: abi.EpollEvent = .{ .events = mask, .data = data };
    return lib.syscall6(Sys.epoll_ctl, ep, op, fd, @intFromPtr(&ev), 0, 0);
}

var events: [8]abi.EpollEvent = undefined;

fn wait(ep: u64, timeout_ms: i64) u64 {
    return lib.syscall6(Sys.epoll_wait, ep, @intFromPtr(&events), events.len, @bitCast(timeout_ms), 0, 0);
}

fn nowMs() u64 {
    var ts: abi.TimeSpec = undefined;
    _ = lib.syscall(Sys.clock_gettime, abi.CLOCK.MONOTONIC, @intFromPtr(&ts), 0);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

// A thread that signals the eventfd after a while.
comptime {
    asm (
        \\.section .text
        \\.global clone_raw
        \\.type clone_raw, @function
        \\clone_raw:
        \\  mov %rcx, %r10
        \\  mov $56, %eax
        \\  syscall
        \\  test %rax, %rax
        \\  jnz 1f
        \\  pop %rdi
        \\  pop %rax
        \\  call *%rax
        \\  mov %eax, %edi
        \\  mov $60, %eax
        \\  syscall
        \\  ud2
        \\1:
        \\  ret
    );
}
extern fn clone_raw(flags: u64, stack: u64, ptid: u64, ctid: u64, tls: u64) callconv(.c) u64;
var thread_tid: std.atomic.Value(u32) = .init(0);
var thread_tls: [4]u64 = .{ 0, 0, 0, 0 };

fn signaller(fd: usize) callconv(.c) u32 {
    const ts: abi.TimeSpec = .{ .sec = 0, .nsec = 30_000_000 };
    _ = lib.syscall(Sys.nanosleep, @intFromPtr(&ts), 0, 0);
    _ = write8(fd, 5);
    return 0;
}

pub fn main() noreturn {
    // --- eventfd: a counter.
    const efd = lib.syscall(Sys.eventfd2, 3, abi.EFD.NONBLOCK, 0);
    expect(!lib.isError(efd), 1);
    expect(read8(efd) == 3, 2); // all of it
    expect(lib.syscall(Sys.read, efd, @intFromPtr(&events), 8) == lib.err(.AGAIN), 3); // empty, and does not wait
    expect(write8(efd, 2) == 8 and write8(efd, 3) == 8 and read8(efd) == 5, 4); // writes add up
    expect(lib.syscall(Sys.read, efd, @intFromPtr(&events), 4) == lib.err(.INVAL), 5); // 8 bytes or nothing
    expect(write8(efd, std.math.maxInt(u64)) == lib.err(.INVAL), 6);
    const sem = lib.syscall(Sys.eventfd2, 2, abi.EFD.SEMAPHORE | abi.EFD.NONBLOCK, 0);
    expect(read8(sem) == 1 and read8(sem) == 1 and read8(sem) == null, 7); // one at a time
    expect(lib.syscall(Sys.eventfd2, 0, 0x40, 0) == lib.err(.INVAL), 8);

    // --- epoll over an eventfd and a pipe.
    const ep = lib.syscall(Sys.epoll_create1, EPOLL.CLOEXEC, 0, 0);
    expect(!lib.isError(ep), 10);
    var pfd: [2]i32 = undefined;
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&pfd), 0, 0) == 0, 11);
    const rd: u64 = @intCast(pfd[0]);
    const wr: u64 = @intCast(pfd[1]);
    expect(ctl(ep, EPOLL.CTL_ADD, efd, EPOLL.IN | EPOLL.ET, 100) == 0, 12);
    expect(ctl(ep, EPOLL.CTL_ADD, rd, EPOLL.IN, 200) == 0, 13);
    expect(ctl(ep, EPOLL.CTL_ADD, rd, EPOLL.IN, 200) == lib.err(.EXIST), 14);
    expect(ctl(ep, EPOLL.CTL_MOD, 99, EPOLL.IN, 0) == lib.err(.BADF), 15);
    expect(ctl(ep, EPOLL.CTL_DEL, wr, 0, 0) == lib.err(.NOENT), 16);
    expect(ctl(ep, EPOLL.CTL_ADD, ep, EPOLL.IN, 0) == lib.err(.INVAL), 17); // itself
    const file = lib.open("/etc/motd");
    expect(ctl(ep, EPOLL.CTL_ADD, file, EPOLL.IN, 0) == lib.err(.PERM), 18); // always ready: refused, as on Linux
    expect(ctl(efd, EPOLL.CTL_ADD, rd, EPOLL.IN, 0) == lib.err(.INVAL), 19); // not an epoll instance

    // Nothing ready: a timeout of 0 says so at once, one of 30 ms waits it out.
    expect(wait(ep, 0) == 0, 20);
    const before = nowMs();
    expect(wait(ep, 30) == 0, 21);
    expect(nowMs() - before >= 25, 22);
    // Ready: what and with what data.
    expect(lib.syscall(Sys.write, wr, @intFromPtr("hi"), 2) == 2, 23);
    expect(wait(ep, -1) == 1 and events[0].events == EPOLL.IN and events[0].data == 200, 24);
    _ = write8(efd, 1);
    const both = wait(ep, -1);
    expect(both == 2, 25);
    expect(events[0].data + events[1].data == 300, 26);
    // At most as many as asked for.
    expect(lib.syscall6(Sys.epoll_wait, ep, @intFromPtr(&events), 1, 0, 0, 0) == 1, 27);
    expect(lib.syscall6(Sys.epoll_wait, ep, @intFromPtr(&events), 0, 0, 0, 0) == lib.err(.INVAL), 28);
    expect(lib.syscall6(Sys.epoll_wait, ep, 8, 4, 0, 0, 0) == lib.err(.FAULT), 29);
    _ = read8(efd);
    var buf: [4]u8 = undefined;
    _ = lib.read(rd, &buf);
    expect(wait(ep, 0) == 0, 30);

    // Another thread signals while this one waits for ever.
    const stack = lib.mmap(0, 64 * 1024, abi.PROT.READ | abi.PROT.WRITE, abi.MAP.STACK);
    const top: [*]u64 = @ptrFromInt(stack + 64 * 1024);
    (top - 1)[0] = @intFromPtr(&signaller);
    (top - 2)[0] = efd;
    const flags = 0x100 | 0x200 | 0x400 | 0x800 | 0x10000 | 0x80000 | 0x100000 | 0x200000;
    expect(!lib.isError(clone_raw(flags, @intFromPtr(top - 2), @intFromPtr(&thread_tid), @intFromPtr(&thread_tid), @intFromPtr(&thread_tls))), 31);
    expect(wait(ep, -1) == 1 and events[0].data == 100, 32);
    expect(read8(efd) == 5, 33);
    while (thread_tid.load(.acquire) != 0) _ = lib.syscall6(Sys.futex, @intFromPtr(&thread_tid), abi.FUTEX.WAIT, thread_tid.load(.acquire), 0, 0, 0);

    // One-shot: reported once, until changed again.
    expect(ctl(ep, EPOLL.CTL_MOD, rd, EPOLL.IN | EPOLL.ONESHOT, 7) == 0, 40);
    _ = lib.syscall(Sys.write, wr, @intFromPtr("x"), 1);
    expect(wait(ep, 0) == 1 and events[0].data == 7, 41);
    expect(wait(ep, 0) == 0, 42);
    expect(ctl(ep, EPOLL.CTL_MOD, rd, EPOLL.IN, 8) == 0 and wait(ep, 0) == 1 and events[0].data == 8, 43);
    // A closed descriptor is no longer reported; and a hang-up is.
    expect(ctl(ep, EPOLL.CTL_DEL, rd, 0, 0) == 0 and wait(ep, 0) == 0, 44);
    expect(ctl(ep, EPOLL.CTL_ADD, rd, EPOLL.IN, 9) == 0, 45);
    _ = lib.read(rd, &buf);
    _ = lib.close(wr);
    expect(wait(ep, 0) == 1 and events[0].events & EPOLL.HUP != 0, 46);
    _ = lib.close(rd);
    expect(wait(ep, 0) == 0, 47);

    // Edge-triggered: reported once while it stays ready, again after a
    // new change. (`efd` was added with EPOLLET.)
    _ = write8(efd, 1);
    expect(wait(ep, 0) == 1 and events[0].data == 100, 60);
    expect(wait(ep, 0) == 0, 61); // still readable, nothing new
    _ = write8(efd, 1);
    expect(wait(ep, 0) == 1 and events[0].data == 100, 62); // something new
    expect(read8(efd) == 2, 63);
    // Level-triggered stays reported while ready.
    var p2: [2]i32 = undefined;
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&p2), 0, 0) == 0, 64);
    expect(ctl(ep, EPOLL.CTL_ADD, @intCast(p2[0]), EPOLL.IN, 300) == 0, 65);
    _ = lib.syscall(Sys.write, @intCast(p2[1]), @intFromPtr("y"), 1);
    expect(wait(ep, 0) == 1 and wait(ep, 0) == 1 and events[0].data == 300, 66);
    // The watch is on the open file: closing the descriptor ends it, and a
    // new file under the same number is not watched.
    const old_fd: u64 = @intCast(p2[0]);
    _ = lib.close(old_fd);
    var p3: [2]i32 = undefined;
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&p3), 0, 0) == 0 and @as(u64, @intCast(p3[0])) == old_fd, 67);
    _ = lib.syscall(Sys.write, @intCast(p3[1]), @intFromPtr("z"), 1);
    expect(wait(ep, 0) == 0, 68);
    expect(ctl(ep, EPOLL.CTL_DEL, old_fd, 0, 0) == lib.err(.NOENT), 69); // the watch is gone
    for ([_]i32{ p2[1], p3[0], p3[1] }) |fd| _ = lib.close(@intCast(fd));

    // `poll` waiting for ever on a pipe that another thread writes to: the
    // pipe wakes it.
    var p4: [2]i32 = undefined;
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&p4), 0, 0) == 0, 70);
    (top - 1)[0] = @intFromPtr(&signaller);
    (top - 2)[0] = @intCast(p4[1]);
    expect(!lib.isError(clone_raw(flags, @intFromPtr(top - 2), @intFromPtr(&thread_tid), @intFromPtr(&thread_tid), @intFromPtr(&thread_tls))), 71);
    var pfds = [_]abi.PollFd{.{ .fd = p4[0], .events = abi.POLL.IN, .revents = 0 }};
    expect(lib.syscall(Sys.poll, @intFromPtr(&pfds), 1, @bitCast(@as(i64, -1))) == 1 and pfds[0].revents == abi.POLL.IN, 72);
    expect(read8(@intCast(p4[0])) == 5, 73);
    while (thread_tid.load(.acquire) != 0) _ = lib.syscall6(Sys.futex, @intFromPtr(&thread_tid), abi.FUTEX.WAIT, thread_tid.load(.acquire), 0, 0, 0);
    for (p4) |fd| _ = lib.close(@intCast(fd));

    for ([_]u64{ efd, sem, ep, file }) |fd| expect(lib.close(fd) == 0, 50);
    lib.exit(0);
}
