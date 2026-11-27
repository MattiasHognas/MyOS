//! The terminal's line discipline: what happens to typed characters
//! between the keyboard and a program's `read`.
//!
//! In the usual mode (canonical, with echo) a line is put together here:
//! characters are shown as they are typed, backspace takes the last one
//! back, Ctrl+U the whole line, and only Enter hands the line to the
//! reader, who never sees the corrections. Ctrl+D ends input: on an empty
//! line the reader gets end of file, otherwise what has been typed so far
//! without a newline. Ctrl+C throws the line away and asks for the
//! foreground program to be interrupted.
//!
//! A program that wants every key as it is typed turns that off (`ICANON`,
//! `ECHO`, `ISIG` in `Settings`, set through `termios`): then each
//! character goes to the reader at once and nothing is shown.
//!
//! This is the state machine alone: no locks, no waiting, no hardware, so
//! it is tested on the host. `tty.zig` puts it between the input drivers,
//! the console and the readers.

const std = @import("std");

/// Longest line that can be edited (Linux: 4095). More than that is not
/// taken until Enter or a correction makes room.
pub const LINE_MAX = 1024;
/// Characters that can wait to be read.
pub const READY_MAX = 4096;

pub const Settings = struct {
    /// Lines are edited here and handed over whole.
    canonical: bool = true,
    /// Typed characters are shown.
    echo: bool = true,
    /// Ctrl+C, Ctrl+\ and Ctrl+Z send the foreground program `SIGINT`,
    /// `SIGQUIT` and `SIGTSTP` (`ISIG`).
    signals: bool = true,
    /// Carriage return is taken as newline (`ICRNL`): what Enter sends on
    /// a serial line.
    cr_to_nl: bool = true,
};

/// What `input` asks its caller to do besides showing `echo`.
pub const Action = enum {
    none,
    /// Something can be read now: wake the readers.
    readable,
    /// Ctrl+C: interrupt the foreground program. (Readers are woken too:
    /// nothing is readable, but one of them may be about to die.)
    interrupt,
    /// Ctrl+\: `SIGQUIT` to the foreground program.
    quit,
    /// Ctrl+Z: stop the foreground program (`SIGTSTP`).
    suspend_,
};

/// One waiting item: a character, or one of the two marks that end a
/// canonical read without being characters.
const Item = packed struct(u16) {
    char: u8,
    /// Ends a read; if it is the first thing read, the read returns 0
    /// (end of file).
    eof: bool = false,
    /// Ends a read (a line given up with Ctrl+D before Enter).
    flush: bool = false,
    _: u6 = 0,
};

pub const Tty = struct {
    settings: Settings = .{},
    /// The line being typed, in canonical mode.
    line: [LINE_MAX]u8 = undefined,
    line_len: usize = 0,
    /// What readers can take, oldest first: a ring.
    ready: [READY_MAX]Item = undefined,
    ready_head: usize = 0,
    ready_len: usize = 0,
    /// Canonical reads that can be made without waiting: newlines and
    /// marks in `ready`.
    lines: usize = 0,

    fn push(self: *Tty, item: Item) bool {
        if (self.ready_len == READY_MAX) return false;
        self.ready[(self.ready_head + self.ready_len) % READY_MAX] = item;
        self.ready_len += 1;
        return true;
    }

    /// Room for the line and a mark behind it?
    fn lineFits(self: *const Tty) bool {
        return READY_MAX - self.ready_len > self.line_len;
    }

    /// Move the line being typed to the readers, followed by `end`.
    fn commit(self: *Tty, end: Item) void {
        for (self.line[0..self.line_len]) |c| _ = self.push(.{ .char = c });
        _ = self.push(end);
        self.line_len = 0;
        self.lines += 1;
    }

    /// A character has been typed. What is to be shown for it is appended
    /// to `echo` (which must have room for `ECHO_MAX` bytes more).
    pub fn input(self: *Tty, typed: u8, echo: *std.ArrayListUnmanaged(u8)) Action {
        const s = self.settings;
        const c = if (typed == '\r' and s.cr_to_nl) '\n' else typed;

        if (s.signals and (c == 0x03 or c == 0x1C or c == 0x1A)) { // Ctrl+C, Ctrl+\, Ctrl+Z
            self.line_len = 0;
            if (s.echo) echo.appendSliceAssumeCapacity(switch (c) {
                0x03 => "^C\n",
                0x1C => "^\\\n",
                else => "^Z\n",
            });
            return switch (c) {
                0x03 => .interrupt,
                0x1C => .quit,
                else => .suspend_,
            };
        }
        if (!s.canonical) {
            if (!self.push(.{ .char = c })) return .none; // nobody reads: dropped
            if (s.echo) echo.appendAssumeCapacity(c);
            return .readable;
        }
        switch (c) {
            '\n' => {
                if (!self.lineFits()) return .none; // no room: Enter again later
                if (s.echo) echo.appendAssumeCapacity('\n');
                self.line[self.line_len] = '\n'; // (one byte is kept free for it)
                self.line_len += 1;
                // The newline is the line's last character and ends the read.
                for (self.line[0..self.line_len]) |ch| _ = self.push(.{ .char = ch });
                self.line_len = 0;
                self.lines += 1;
                return .readable;
            },
            0x04 => { // Ctrl+D
                if (!self.lineFits()) return .none;
                self.commit(if (self.line_len == 0) .{ .char = 0, .eof = true } else .{ .char = 0, .flush = true });
                return .readable;
            },
            0x08, 0x7F => { // backspace, delete
                if (self.line_len == 0) return .none;
                self.line_len -= 1;
                if (s.echo) echo.appendSliceAssumeCapacity("\x08 \x08");
                return .none;
            },
            0x15 => { // Ctrl+U: the whole line
                if (s.echo) {
                    // As many as fit the caller's buffer at once; a line
                    // longer than that keeps its tail on the screen.
                    const erase = @min(self.line_len, (echo.capacity - echo.items.len) / 3);
                    for (0..erase) |_| echo.appendSliceAssumeCapacity("\x08 \x08");
                }
                self.line_len = 0;
                return .none;
            },
            else => {
                // Printable characters and tab; other control characters
                // have no meaning here and are not taken.
                if (c < ' ' and c != '\t') return .none;
                if (self.line_len >= LINE_MAX - 1) return .none; // full: only corrections and Enter
                self.line[self.line_len] = c;
                self.line_len += 1;
                if (s.echo) echo.appendAssumeCapacity(c);
                return .none;
            },
        }
    }

    /// Most bytes one `input` adds to `echo`, the erasing of a whole line
    /// apart (which takes what room there is).
    pub const ECHO_MAX = 3;

    /// Whether a `read` would return without waiting.
    pub fn readable(self: *const Tty) bool {
        return if (self.settings.canonical) self.lines != 0 else self.ready_len != 0;
    }

    /// Characters waiting to be read (`FIONREAD`).
    pub fn available(self: *const Tty) usize {
        return self.ready_len - @min(self.ready_len, self.marks());
    }

    fn marks(self: *const Tty) usize {
        var n: usize = 0;
        for (0..self.ready_len) |i| {
            const item = self.ready[(self.ready_head + i) % READY_MAX];
            if (item.eof or item.flush) n += 1;
        }
        return n;
    }

    /// Take what a `read` of up to `buf.len` bytes gets, or null if it
    /// would have to wait. In canonical mode that is one line at most,
    /// with its newline; 0 is end of file (Ctrl+D on an empty line). A
    /// line longer than `buf` is given in pieces.
    pub fn read(self: *Tty, buf: []u8) ?usize {
        if (!self.readable()) return null;
        var n: usize = 0;
        while (self.ready_len != 0) {
            const item = self.ready[self.ready_head];
            if (item.eof or item.flush) {
                // An end-of-file mark ends a read that has characters
                // already without being used up: the next read sees it.
                if (item.eof and n != 0) break;
                self.ready_head = (self.ready_head + 1) % READY_MAX;
                self.ready_len -= 1;
                if (self.settings.canonical) self.lines -= 1;
                break;
            }
            if (n == buf.len) break;
            buf[n] = item.char;
            n += 1;
            self.ready_head = (self.ready_head + 1) % READY_MAX;
            self.ready_len -= 1;
            if (self.settings.canonical and item.char == '\n') {
                self.lines -= 1;
                break;
            }
        }
        return n;
    }

    /// Change the settings. Going from edited lines to single keys hands
    /// over what has been typed so far; what waits to be read stays.
    pub fn configure(self: *Tty, new: Settings) void {
        if (self.settings.canonical and !new.canonical) {
            for (self.line[0..self.line_len]) |c| _ = self.push(.{ .char = c });
            self.line_len = 0;
        }
        if (!self.settings.canonical and new.canonical) {
            // What is there counts as lines again: one for each newline
            // and mark.
            var count: usize = 0;
            for (0..self.ready_len) |i| {
                const item = self.ready[(self.ready_head + i) % READY_MAX];
                if (item.eof or item.flush or item.char == '\n') count += 1;
            }
            self.lines = count;
        }
        self.settings = new;
    }

    /// Throw away everything typed and not yet read (`TCFLSH`).
    pub fn flush(self: *Tty) void {
        self.line_len = 0;
        self.ready_len = 0;
        self.ready_head = 0;
        self.lines = 0;
    }
};
