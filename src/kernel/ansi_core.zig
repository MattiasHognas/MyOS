//! The escape sequences of a VT100 terminal the console understands, read
//! one byte at a time: `ESC [`, numbers separated by `;`, and a final
//! letter. Anything else that starts with `ESC` is read to its end and
//! dropped, so it never shows up as text. No kernel dependencies: tested
//! on the host.

/// What the console is to do with a byte.
pub const Action = union(enum) {
    /// Draw it: it is not part of a sequence.
    print,
    /// It is part of a sequence that is not complete, or means nothing here.
    swallow,
    /// It completes a sequence that asks for this.
    command: Command,
};

pub const Command = union(enum) {
    /// `ESC[<row>;<col>H` (counted from 1 in the sequence, from 0 here).
    cursor_to: struct { row: usize, col: usize },
    cursor_up: usize,
    cursor_down: usize,
    cursor_right: usize,
    cursor_left: usize,
    /// `ESC[2J`: the whole screen; `ESC[J`: from the cursor to the end.
    erase_screen,
    erase_below,
    /// `ESC[K`: from the cursor to the end of the line; `ESC[2K`: all of it.
    erase_line_right,
    erase_line,
};

pub const Parser = struct {
    state: enum { text, escape, csi } = .text,
    params: [4]usize = .{ 0, 0, 0, 0 },
    count: usize = 0,
    /// A digit has been read for the current parameter.
    digits: bool = false,

    pub fn feed(self: *Parser, c: u8) Action {
        switch (self.state) {
            .text => {
                if (c != 0x1B) return .print;
                self.state = .escape;
                return .swallow;
            },
            .escape => {
                if (c == '[') {
                    self.state = .csi;
                    self.params = .{ 0, 0, 0, 0 };
                    self.count = 0;
                    self.digits = false;
                } else {
                    self.state = .text; // a two-byte sequence: dropped
                }
                return .swallow;
            },
            .csi => {
                if (c >= '0' and c <= '9') {
                    if (self.count < self.params.len) self.params[self.count] = self.params[self.count] *| 10 +| (c - '0');
                    self.digits = true;
                    return .swallow;
                }
                if (c == ';') {
                    self.count += 1;
                    self.digits = false;
                    return .swallow;
                }
                if (c == '?' or c == ' ' or c == '>') return .swallow; // private markers
                if (c < 0x40 or c > 0x7E) return .swallow; // not a final byte yet
                self.state = .text;
                const n = self.count + @intFromBool(self.digits);
                const first = if (n > 0) self.params[0] else 0;
                const one = if (first == 0) 1 else first; // a missing or 0 count is 1
                return switch (c) {
                    'H', 'f' => .{ .command = .{ .cursor_to = .{
                        .row = (if (n > 0 and self.params[0] > 0) self.params[0] else 1) - 1,
                        .col = (if (n > 1 and self.params[1] > 0) self.params[1] else 1) - 1,
                    } } },
                    'A' => .{ .command = .{ .cursor_up = one } },
                    'B' => .{ .command = .{ .cursor_down = one } },
                    'C' => .{ .command = .{ .cursor_right = one } },
                    'D' => .{ .command = .{ .cursor_left = one } },
                    'J' => .{ .command = if (first == 2 or first == 3) .erase_screen else .erase_below },
                    'K' => .{ .command = if (first == 2) .erase_line else .erase_line_right },
                    else => .swallow, // colours (m) and the rest
                };
            },
        }
    }
};
