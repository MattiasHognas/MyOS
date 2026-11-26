//! `/test/terminal`: descriptor 0 as a terminal, with the kernel test
//! typing (it injects keys as the keyboard would, each time this program
//! waits). Exits with 0, or with the number of the first failing check.
//!
//! With the argument `wait` it only waits for a line, for ever: the
//! kernel test makes it the foreground program and types Ctrl+C.
//!
//! What the kernel test types, in order:
//!   "helo\x7f\x7flo wrld\x15hello, world\n"   one line, corrected twice
//!   "first\nsecond\n"                          two lines at once
//!   "partial\x04"                              Ctrl+D after some text
//!   "\x04"                                     Ctrl+D on an empty line
//!   "k"                                        a key without line editing

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

fn expect(ok: bool, check: u64) void {
    if (!ok) lib.exit(check);
}

fn eql(s: [*:0]const u8, want: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(s), want);
}

var buf: [256]u8 = undefined;

fn readLine() []const u8 {
    const n = lib.read(0, &buf);
    if (lib.isError(n)) lib.exit(200);
    return buf[0..n];
}

pub fn main() noreturn {
    const args = lib.argv();
    if (args.len > 1 and eql(args[1], "wait")) {
        _ = lib.read(0, &buf);
        lib.exit(1); // Ctrl+C should have ended it before a line came
    }

    // It is a terminal, with line editing and echo, and a size.
    var t: abi.Termios = undefined;
    expect(lib.tcgetattr(0, &t) == 0, 1);
    expect(t.lflag & abi.TERMIOS.ICANON != 0 and t.lflag & abi.TERMIOS.ECHO != 0 and t.lflag & abi.TERMIOS.ISIG != 0, 2);
    expect(t.cc[abi.TERMIOS.VEOF] == 4 and t.cc[abi.TERMIOS.VINTR] == 3, 3);
    expect(lib.tcgetattr(1, &t) == 0 and lib.tcgetattr(2, &t) == 0, 4); // all three are the terminal
    const file = lib.open("/etc/motd");
    expect(lib.tcgetattr(file, &t) == lib.err(.NOTTY), 5);
    _ = lib.close(file);
    expect(lib.syscall(Sys.ioctl, 0, 0x1234, 0) == lib.err(.INVAL), 6);
    expect(lib.syscall(Sys.ioctl, 0, abi.TIOC.TCGETS, 8) == lib.err(.FAULT), 7);

    // Nothing typed yet: poll says so, a read waits (the kernel test sees
    // it waiting and types).
    var pfd = [_]abi.PollFd{.{ .fd = 0, .events = abi.POLL.IN, .revents = 0 }};
    expect(lib.syscall(Sys.poll, @intFromPtr(&pfd), 1, 0) == 0, 10);

    // A line arrives whole, without the corrections.
    expect(std.mem.eql(u8, readLine(), "hello, world\n"), 11);
    // Two lines: one read each, and the second is there at once.
    expect(std.mem.eql(u8, readLine(), "first\n"), 12);
    pfd[0].revents = 0;
    expect(lib.syscall(Sys.poll, @intFromPtr(&pfd), 1, 0) == 1 and pfd[0].revents == abi.POLL.IN, 13);
    var avail: i32 = 0;
    expect(lib.syscall(Sys.ioctl, 0, abi.TIOC.FIONREAD, @intFromPtr(&avail)) == 0 and avail == 7, 14);
    expect(lib.read(0, buf[0..3]) == 3 and std.mem.eql(u8, buf[0..3], "sec"), 15); // a short read takes part of a line
    expect(std.mem.eql(u8, readLine(), "ond\n"), 16);
    // Ctrl+D: what was typed, without a newline; then the end of input.
    expect(std.mem.eql(u8, readLine(), "partial"), 17);
    expect(lib.read(0, &buf) == 0, 18);

    // Without line editing: one key, at once, not shown.
    var raw = t;
    expect(lib.tcgetattr(0, &raw) == 0, 20);
    raw.lflag &= ~@as(u32, abi.TERMIOS.ICANON | abi.TERMIOS.ECHO);
    expect(lib.tcsetattr(0, &raw) == 0, 21);
    var now: abi.Termios = undefined;
    expect(lib.tcgetattr(0, &now) == 0 and now.lflag & abi.TERMIOS.ICANON == 0, 22);
    expect(lib.read(0, buf[0..10]) == 1 and buf[0] == 'k', 23);
    // Non-blocking, with nothing there.
    expect(lib.syscall(Sys.fcntl, 0, 4, abi.O.NONBLOCK) == 0 and lib.read(0, &buf) == lib.err(.AGAIN), 24);
    expect(lib.syscall(Sys.fcntl, 0, 4, 0) == 0, 25);
    // Settings left changed: the kernel test checks they come back when
    // a program started by another ends (the shell's case).
    lib.exit(0);
}
