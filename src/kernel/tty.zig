//! The terminal: what descriptors 0, 1 and 2 are open on.
//!
//! Keys come from the keyboard and the serial port (`input`, from their
//! interrupt handlers), go through the line discipline (`tty_core.zig`:
//! line editing, echo, Ctrl+C and Ctrl+D) and wait for a program's `read`.
//! What is to be shown for them goes to the console. Ctrl+C ends the
//! foreground program (`process.setForeground`) by sending it `SIGINT`,
//! unless it handles or ignores that.
//!
//! One terminal, as there is one console. Readers are served in the order
//! they asked, as the keyboard used to serve them: each stands in a line
//! (a record on its own stack), and the one at the front takes the next
//! piece of input.

const std = @import("std");
const readiness = @import("readiness.zig");

const abi = @import("abi");
const proc = @import("process.zig");
const SpinLock = @import("sync/spinlock.zig").SpinLock;
const thread = @import("thread.zig");
const tty_core = @import("tty_core.zig");
const WaitQueue = @import("sync/wait_queue.zig").WaitQueue;

/// Interrupt handlers take it, so it is a spinlock; what is shown is
/// printed after it is released.
var lock: SpinLock = .{ .rank = .condition };
var core: tty_core.Tty = .{};
var readers: WaitQueue = .{};

const Reader = struct { next: ?*Reader = null };
var first_reader: ?*Reader = null;
var last_reader: ?*Reader = null;

/// Where what is shown goes: the console's printer (set by `init`; the
/// host has none).
var show: ?*const fn ([]const u8) void = null;

/// The exit status of a program ended by Ctrl+C: 128 + `SIGINT`, as a
/// shell reports one killed by that signal.
pub const INTERRUPTED = 128 + 2;

/// Wake the threads waiting to read, and the pollers: what there is to
/// read may have changed. With the lock.
fn wakeReaders() void {
    _ = readers.wakeAll();
    version +%= 1;
    readiness.changed();
}

/// Moves on whenever what there is to read may have changed: for
/// edge-triggered `epoll`. Under the lock.
var version: u64 = 0;

/// `version`, for `epoll`.
pub fn changeCount() u64 {
    const held = lock.acquire();
    defer lock.release(held);
    return version;
}

pub fn init(printer: *const fn ([]const u8) void) void {
    show = printer;
}

/// A key has been typed. From an interrupt handler or a thread, with no
/// lock held.
pub fn input(c: u8) void {
    var echo_buf: [64]u8 = undefined;
    var echo: std.ArrayListUnmanaged(u8) = .initBuffer(&echo_buf);
    const action = blk: {
        const held = lock.acquire();
        defer lock.release(held);
        const action = core.input(c, &echo);
        if (action != .none) wakeReaders();
        break :blk action;
    };
    if (echo.items.len != 0) if (show) |f| f(echo.items);
    if (action == .interrupt) _ = proc.terminateForeground(INTERRUPTED);
}

/// Type `text` as if it came from the keyboard, all of it before any
/// reader looks: for tests. Ctrl+C in it acts once, at the end.
pub fn inject(text: []const u8) void {
    var echo_buf: [512]u8 = undefined;
    var echo: std.ArrayListUnmanaged(u8) = .initBuffer(&echo_buf);
    var interrupt = false;
    {
        const held = lock.acquire();
        defer lock.release(held);
        for (text) |c| {
            // What is shown is dropped once the buffer is nearly full.
            if (echo.capacity - echo.items.len < 64) echo.clearRetainingCapacity();
            if (core.input(c, &echo) == .interrupt) interrupt = true;
        }
        wakeReaders();
    }
    if (echo.items.len != 0) if (show) |f| f(echo.items);
    if (interrupt) _ = proc.terminateForeground(INTERRUPTED);
}

fn leaveLine(me: *Reader) void {
    var link = &first_reader;
    var prev: ?*Reader = null;
    while (link.*) |r| : ({
        prev = r;
        link = &r.next;
    }) {
        if (r != me) continue;
        link.* = me.next;
        if (last_reader == me) last_reader = prev;
        return;
    }
}

pub const ReadResult = union(enum) {
    /// Bytes read; 0 is the end of input (Ctrl+D on an empty line).
    bytes: usize,
    /// Nothing there and the reader would not wait.
    again,
    /// The calling thread's process is ending.
    killed,
};

/// What a program's `read` of the terminal gets: in the usual mode one
/// line at most, once Enter (or Ctrl+D) has been typed; each key at once
/// with line editing off. Waits unless `nonblock`. Into a kernel buffer:
/// the caller copies it to the program.
pub fn read(buf: []u8, nonblock: bool) ReadResult {
    if (buf.len == 0) return .{ .bytes = 0 };
    const held = lock.acquire();
    defer lock.release(held);
    var me: Reader = .{};
    if (last_reader) |last| last.next = &me else first_reader = &me;
    last_reader = &me;
    defer leaveLine(&me);
    while (true) {
        if (first_reader == &me) {
            if (core.read(buf)) |n| {
                // The next reader's input may be there already.
                if (core.readable()) wakeReaders();
                return .{ .bytes = n };
            }
            if (nonblock) return .again;
        }
        if (!readers.waitKillable(&lock)) {
            wakeReaders(); // whoever is first now
            return .killed;
        }
    }
}

/// Whether a `read` would return without waiting (`poll`).
pub fn readable() bool {
    const held = lock.acquire();
    defer lock.release(held);
    return core.readable();
}

/// Bytes waiting to be read (`FIONREAD`).
pub fn available() usize {
    const held = lock.acquire();
    defer lock.release(held);
    return core.available();
}

/// Threads waiting in `read`: for tests.
pub fn waitingReaders() usize {
    const held = lock.acquire();
    defer lock.release(held);
    return readers.waiting();
}

/// The settings as `struct termios` (`TCGETS`).
pub fn getAttributes() abi.Termios {
    const s = blk: {
        const held = lock.acquire();
        defer lock.release(held);
        break :blk core.settings;
    };
    var t: abi.Termios = .{};
    t.iflag = if (s.cr_to_nl) @as(u32, abi.TERMIOS.ICRNL) else 0;
    t.oflag = abi.TERMIOS.OPOST | abi.TERMIOS.ONLCR; // the console turns "\n" into "\r\n"
    t.cflag = abi.TERMIOS.B38400 | abi.TERMIOS.CS8 | abi.TERMIOS.CREAD;
    t.lflag = (if (s.canonical) @as(u32, abi.TERMIOS.ICANON) else 0) |
        (if (s.echo) @as(u32, abi.TERMIOS.ECHO | abi.TERMIOS.ECHOE | abi.TERMIOS.ECHOK) else 0) |
        (if (s.signals) @as(u32, abi.TERMIOS.ISIG) else 0);
    t.cc[abi.TERMIOS.VINTR] = 0x03;
    t.cc[abi.TERMIOS.VERASE] = 0x7F;
    t.cc[abi.TERMIOS.VKILL] = 0x15;
    t.cc[abi.TERMIOS.VEOF] = 0x04;
    t.cc[abi.TERMIOS.VMIN] = 1;
    return t;
}

/// Take the settings from `struct termios` (`TCSETS` and its variants).
/// What this terminal does not offer (other control characters, `VMIN`
/// and `VTIME` other than one character and no timeout, output
/// processing) is ignored, as a terminal ignores what its hardware
/// cannot do. With `flush`, typed input not yet read is thrown away.
pub fn setAttributes(t: abi.Termios, flush: bool) void {
    const held = lock.acquire();
    defer lock.release(held);
    if (flush) core.flush();
    core.configure(.{
        .canonical = t.lflag & abi.TERMIOS.ICANON != 0,
        .echo = t.lflag & abi.TERMIOS.ECHO != 0,
        .signals = t.lflag & abi.TERMIOS.ISIG != 0,
        .cr_to_nl = t.iflag & abi.TERMIOS.ICRNL != 0,
    });
    wakeReaders(); // a change of mode can make input readable
}

/// Throw away typed input not yet read (`TCFLSH`).
pub fn flushInput() void {
    const held = lock.acquire();
    defer lock.release(held);
    core.flush();
}

/// Back to the usual settings, keeping what has been typed: when the
/// shell takes the terminal back from a program that changed them.
pub fn restoreSettings() void {
    const held = lock.acquire();
    defer lock.release(held);
    core.configure(.{});
    wakeReaders();
}

/// Back to the usual settings with nothing waiting: for tests.
pub fn reset() void {
    const held = lock.acquire();
    defer lock.release(held);
    core = .{};
}

/// The size of the console in characters (`TIOCGWINSZ`). A fixed 80 by
/// 25 until the console says what it has.
pub fn windowSize() abi.WinSize {
    return .{ .rows = 25, .cols = 80 };
}
