//! `/test/pipes`: file descriptors that are more than files: the standard
//! streams, duplicates, and pipes.
//!
//! Without arguments it runs the checks that must succeed and exits with
//! 0, or with the number of the first failing check. With `blocked` a
//! thread waits in a `read` from a pipe that nothing is ever written to,
//! and the main thread ends the process with status 9: the waiting thread
//! and the pipe must go with it.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;
const O = abi.O;
const POLL = abi.POLL;

const PIPE_SIZE = 4096;
const F_DUPFD = 0;
const F_GETFL = 3;
const F_SETFL = 4;

// clone_raw(flags: rdi, stack: rsi, ptid: rdx, ctid: rcx, tls: r8) -> tid.
// The new thread finds its argument and its function at the top of its
// stack, calls the function, and exits (itself only) with what it returns.
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

const ThreadFn = *const fn (usize) callconv(.c) u32;
const STACK_SIZE = 64 * 1024;
// CLONE_VM | FS | FILES | SIGHAND | THREAD | SETTLS | PARENT_SETTID | CHILD_CLEARTID
const THREAD_FLAGS = 0x100 | 0x200 | 0x400 | 0x800 | 0x10000 | 0x80000 | 0x100000 | 0x200000;

var thread_tid: std.atomic.Value(u32) = .init(0);
var thread_tls: [4]u64 = .{ 0, 0, 0, 0 };

fn start(func: ThreadFn, arg: usize) void {
    const stack = lib.mmap(0, STACK_SIZE, abi.PROT.READ | abi.PROT.WRITE, abi.MAP.STACK);
    if (lib.isError(stack)) lib.exit(90);
    const top: [*]u64 = @ptrFromInt(stack + STACK_SIZE);
    (top - 1)[0] = @intFromPtr(func);
    (top - 2)[0] = arg;
    const tid = clone_raw(THREAD_FLAGS, @intFromPtr(top - 2), @intFromPtr(&thread_tid), @intFromPtr(&thread_tid), @intFromPtr(&thread_tls));
    if (lib.isError(tid)) lib.exit(91);
}

fn join() void {
    while (true) {
        const tid = thread_tid.load(.acquire);
        if (tid == 0) break;
        _ = lib.syscall6(Sys.futex, @intFromPtr(&thread_tid), abi.FUTEX.WAIT, tid, 0, 0, 0);
    }
}

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn sleepMs(ms: u64) void {
    const ts: abi.TimeSpec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(ms % 1000 * 1_000_000) };
    _ = lib.syscall(Sys.nanosleep, @intFromPtr(&ts), 0, 0);
}

fn pipe(flags: u64) [2]i32 {
    var fds: [2]i32 = .{ -1, -1 };
    if (lib.syscall(Sys.pipe2, @intFromPtr(&fds), flags, 0) != 0) lib.exit(92);
    return fds;
}

fn fd(n: i32) u64 {
    return @intCast(n);
}

fn writeAll(to: u64, data: []const u8) u64 {
    return lib.syscall(Sys.write, to, @intFromPtr(data.ptr), data.len);
}

fn fstatMode(of: u64) u32 {
    var st: abi.Stat = undefined;
    if (lib.syscall(Sys.fstat, of, @intFromPtr(&st), 0) != 0) return 0;
    return st.mode & abi.S.IFMT;
}

fn poll(of: i32, events: i16, timeout_ms: u64) i16 {
    var entry: abi.PollFd = .{ .fd = of, .events = events, .revents = 0 };
    _ = lib.syscall(Sys.poll, @intFromPtr(&entry), 1, timeout_ms);
    return entry.revents;
}

var big: [3 * PIPE_SIZE]u8 = undefined;
var got: [3 * PIPE_SIZE]u8 = undefined;
var writer_fd: u64 = 0;
var written: std.atomic.Value(u64) = .init(0);

/// Write all of `big` to the pipe: three times what it holds, so this
/// waits for the reader twice.
fn writesBig(_: usize) callconv(.c) u32 {
    written.store(writeAll(writer_fd, &big), .release);
    _ = lib.close(writer_fd);
    return 0;
}

fn readsForEver(from: usize) callconv(.c) u32 {
    var b: [8]u8 = undefined;
    _ = lib.read(from, &b);
    return 0;
}

fn eql(s: [*:0]const u8, want: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(s), want);
}

pub fn main() noreturn {
    const args = lib.argv();
    if (args.len > 1 and eql(args[1], "blocked")) {
        const p = pipe(0);
        start(readsForEver, fd(p[0]));
        sleepMs(30); // it is asleep in the pipe by now
        _ = lib.syscall(Sys.exit_group, 9, 0, 0);
    }
    var buf: [64]u8 = undefined;

    // --- The standard streams are descriptors like any other: the console.
    expect(fstatMode(0) == abi.S.IFCHR and fstatMode(1) == abi.S.IFCHR and fstatMode(2) == abi.S.IFCHR, 1);
    expect(lib.syscall(Sys.fcntl, 1, F_GETFL, 0) == O.RDWR, 2);
    expect(lib.read(0, &buf) == lib.err(.BADF), 3); // no console input through read yet

    // --- dup gives the lowest free descriptor for the same open file.
    const file = lib.open("/etc/motd");
    expect(file == 3, 10);
    const twin = lib.syscall(Sys.dup, file, 0, 0);
    expect(twin == 4, 11);
    expect(lib.read(file, buf[0..8]) == 8, 12);
    expect(lib.read(twin, buf[8..11]) == 3, 13); // they share the offset
    expect(std.mem.eql(u8, buf[0..11], "Welcome to "), 14);
    expect(lib.close(file) == 0, 15);
    expect(lib.read(twin, buf[0..4]) == 4 and std.mem.eql(u8, buf[0..4], "MyOS"), 16); // still open through the twin
    expect(lib.syscall(Sys.dup, 99, 0, 0) == lib.err(.BADF), 17);
    expect(lib.syscall(Sys.dup, file, 0, 0) == lib.err(.BADF), 18); // closed

    // --- dup2 and dup3 choose the number and close what was there.
    expect(lib.syscall(Sys.dup2, twin, 9, 0) == 9, 20);
    expect(lib.syscall(Sys.dup2, twin, twin, 0) == twin, 21); // the same: nothing happens
    expect(lib.syscall(Sys.dup3, twin, twin, 0) == lib.err(.INVAL), 22);
    expect(lib.syscall(Sys.dup2, twin, 16, 0) == lib.err(.BADF), 23); // past the table
    expect(lib.syscall(Sys.dup2, 77, 5, 0) == lib.err(.BADF), 24);
    const other = lib.open("/bin/hello");
    expect(other == 3, 25);
    expect(lib.syscall(Sys.dup3, twin, other, 0) == other, 26); // replaces /bin/hello
    expect(lib.read(other, buf[0..1]) == 1 and buf[0] == '!', 27); // "Welcome to MyOS!": the shared offset
    expect(lib.syscall(Sys.fcntl, twin, F_DUPFD, 12) == 12, 28);
    expect(lib.syscall(Sys.fcntl, twin, F_DUPFD, 12) == 13, 29);
    expect(lib.syscall(Sys.fcntl, twin, F_DUPFD, 16) == lib.err(.INVAL), 30);
    for ([_]u64{ other, twin, 9, 12, 13 }) |n| expect(lib.close(n) == 0, 31);

    // --- A closed standard descriptor is free again, and the lowest.
    const saved = lib.syscall(Sys.dup, 0, 0, 0);
    expect(saved == 3, 35);
    expect(lib.close(0) == 0, 36);
    expect(lib.syscall(Sys.write, 0, @intFromPtr(&buf), 0) == lib.err(.BADF), 37);
    expect(lib.open("/etc/motd") == 0, 38);
    expect(lib.syscall(Sys.dup2, saved, 0, 0) == 0, 39); // and back
    expect(lib.close(saved) == 0 and fstatMode(0) == abi.S.IFCHR, 40);

    // --- A pipe: what goes in one end comes out of the other, in order.
    const p = pipe(0);
    expect(p[0] == 3 and p[1] == 4, 50);
    expect(fstatMode(fd(p[0])) == abi.S.IFIFO and fstatMode(fd(p[1])) == abi.S.IFIFO, 51);
    expect(lib.syscall(Sys.fcntl, fd(p[0]), F_GETFL, 0) == O.RDONLY, 52);
    expect(lib.syscall(Sys.fcntl, fd(p[1]), F_GETFL, 0) == O.WRONLY, 53);
    expect(poll(p[0], POLL.IN, 0) == 0 and poll(p[1], POLL.OUT, 0) == POLL.OUT, 54);
    expect(poll(p[0], POLL.IN, 20) == 0, 55); // waits out the 20 ms
    expect(writeAll(fd(p[1]), "hello ") == 6 and writeAll(fd(p[1]), "pipe") == 4, 56);
    expect(poll(p[0], POLL.IN, -%@as(u64, 1)) == POLL.IN, 57); // would wait for ever; it is ready
    expect(lib.read(fd(p[0]), buf[0..3]) == 3 and std.mem.eql(u8, buf[0..3], "hel"), 58);
    expect(lib.read(fd(p[0]), &buf) == 7 and std.mem.eql(u8, buf[0..7], "lo pipe"), 59); // what there is, not 64
    // The wrong end, a bad buffer, nothing at all.
    expect(writeAll(fd(p[0]), "x") == lib.err(.BADF) and lib.read(fd(p[1]), &buf) == lib.err(.BADF), 60);
    expect(lib.syscall(Sys.write, fd(p[1]), 8, 4) == lib.err(.FAULT), 61);
    expect(lib.syscall(Sys.read, fd(p[0]), 0xFFFF_8000_0000_0000, 4) == lib.err(.FAULT), 62);
    expect(writeAll(fd(p[1]), "") == 0 and lib.read(fd(p[0]), buf[0..0]) == 0, 63);
    expect(lib.syscall(Sys.lseek, fd(p[0]), 0, 0) == lib.err(.SPIPE), 64);

    // --- Non-blocking: an empty pipe and a full one say so instead of waiting.
    expect(lib.syscall(Sys.fcntl, fd(p[0]), F_SETFL, O.NONBLOCK) == 0, 70);
    expect(lib.syscall(Sys.fcntl, fd(p[0]), F_GETFL, 0) == O.RDONLY | O.NONBLOCK, 71);
    expect(lib.read(fd(p[0]), &buf) == lib.err(.AGAIN), 72);
    expect(lib.syscall(Sys.fcntl, fd(p[1]), F_SETFL, O.NONBLOCK) == 0, 73);
    for (&big, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    expect(writeAll(fd(p[1]), big[0 .. PIPE_SIZE - 10]) == PIPE_SIZE - 10, 74);
    expect(writeAll(fd(p[1]), big[0..11]) == lib.err(.AGAIN), 75); // one byte too many: none goes in
    expect(writeAll(fd(p[1]), big[0..10]) == 10, 76); // full, across the end of the buffer
    expect(poll(p[1], POLL.OUT, 0) == 0, 77);
    expect(writeAll(fd(p[1]), "x") == lib.err(.AGAIN), 78);
    var total: usize = lib.read(fd(p[0]), got[0..PIPE_SIZE]); // part of it, or all
    expect(total != 0 and total <= PIPE_SIZE, 79);
    while (total < PIPE_SIZE) {
        const n = lib.read(fd(p[0]), got[total..PIPE_SIZE]);
        expect(!lib.isError(n) and n != 0, 80);
        total += n;
    }
    expect(std.mem.eql(u8, got[0 .. PIPE_SIZE - 10], big[0 .. PIPE_SIZE - 10]) and std.mem.eql(u8, got[PIPE_SIZE - 10 .. PIPE_SIZE], big[0..10]), 81);

    // --- The other end closed: end of file for a reader, EPIPE for a writer.
    expect(writeAll(fd(p[1]), "last") == 4, 85);
    expect(lib.close(fd(p[1])) == 0, 86);
    expect(poll(p[0], POLL.IN, 0) == POLL.IN | POLL.HUP, 87);
    expect(lib.read(fd(p[0]), &buf) == 4, 88); // what was left
    expect(lib.read(fd(p[0]), &buf) == 0, 89); // then the end, not EAGAIN
    expect(poll(p[0], POLL.IN, 0) == POLL.HUP, 90);
    expect(lib.close(fd(p[0])) == 0, 91);
    const q = pipe(O.NONBLOCK | O.CLOEXEC);
    expect(lib.syscall(Sys.fcntl, fd(q[1]), F_GETFL, 0) == O.WRONLY | O.NONBLOCK, 92);
    expect(lib.close(fd(q[0])) == 0, 93);
    expect(poll(q[1], POLL.OUT, 0) == POLL.ERR, 94);
    expect(writeAll(fd(q[1]), "nobody") == lib.err(.PIPE), 95);
    expect(lib.close(fd(q[1])) == 0, 96);

    // --- A writer with more than the pipe holds waits for the reader; a
    // reader waits for the writer; closing the writing end ends it.
    const r = pipe(0);
    writer_fd = fd(r[1]);
    start(writesBig, 0);
    total = 0;
    while (true) {
        const n = lib.read(fd(r[0]), got[total..]);
        expect(!lib.isError(n), 100);
        if (n == 0) break; // the thread closed its end
        total += n;
        if (total == PIPE_SIZE) sleepMs(5); // let the writer find the pipe empty, too
    }
    join();
    expect(total == big.len and written.load(.acquire) == big.len, 101);
    expect(std.mem.eql(u8, &got, &big), 102);
    expect(lib.close(fd(r[0])) == 0, 103);

    // --- What is refused, and nothing stays open after a failure.
    expect(lib.syscall(Sys.pipe2, 8, 0, 0) == lib.err(.FAULT), 110);
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&buf), 1, 0) == lib.err(.INVAL), 111);
    expect(lib.syscall(Sys.pipe, 0xFFFF_8000_0000_0000, 0, 0) == lib.err(.FAULT), 112);
    var fds: [13]u64 = undefined;
    for (&fds, 3..) |*f, want| {
        f.* = lib.open("/etc/motd");
        expect(f.* == want, 113); // so the failed pipes left 3 and 4 free
    }
    var two: [2]i32 = .{ -5, -5 };
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&two), 0, 0) == lib.err(.MFILE), 114);
    expect(lib.close(15) == 0, 115);
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&two), 0, 0) == lib.err(.MFILE), 116); // room for one end only
    expect(two[0] == -5 and lib.open("/etc/motd") == 15, 117);
    expect(lib.syscall(Sys.dup, 3, 0, 0) == lib.err(.MFILE), 118);
    // Left open on purpose: the kernel closes them, and a pipe with them.
    _ = lib.close(14);
    _ = lib.close(15);
    _ = pipe(0);

    lib.exit(0);
}
