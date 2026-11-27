const std = @import("std");
const ansi = @import("ansi_core");

fn feedAll(p: *ansi.Parser, s: []const u8) ?ansi.Command {
    var last: ?ansi.Command = null;
    for (s, 0..) |c, i| {
        const a = p.feed(c);
        if (i + 1 < s.len) std.debug.assert(a != .print or c != 0x1B);
        switch (a) {
            .command => |cmd| last = cmd,
            else => {},
        }
    }
    return last;
}

test "plain text is printed" {
    var p: ansi.Parser = .{};
    for ("hello\n") |c| try std.testing.expect(p.feed(c) == .print);
}

test "clear and home, as clear(1) writes them" {
    var p: ansi.Parser = .{};
    try std.testing.expectEqual(ansi.Command{ .cursor_to = .{ .row = 0, .col = 0 } }, feedAll(&p, "\x1b[H").?);
    try std.testing.expectEqual(ansi.Command.erase_screen, feedAll(&p, "\x1b[2J").?);
    try std.testing.expectEqual(ansi.Command.erase_screen, feedAll(&p, "\x1b[3J").?);
    try std.testing.expectEqual(ansi.Command.erase_below, feedAll(&p, "\x1b[J").?);
    try std.testing.expect(p.feed('x') == .print);
}

test "cursor positions count from 1, and missing numbers are 1" {
    var p: ansi.Parser = .{};
    try std.testing.expectEqual(ansi.Command{ .cursor_to = .{ .row = 4, .col = 9 } }, feedAll(&p, "\x1b[5;10H").?);
    try std.testing.expectEqual(ansi.Command{ .cursor_to = .{ .row = 2, .col = 0 } }, feedAll(&p, "\x1b[3H").?);
    try std.testing.expectEqual(ansi.Command{ .cursor_up = 1 }, feedAll(&p, "\x1b[A").?);
    try std.testing.expectEqual(ansi.Command{ .cursor_left = 7 }, feedAll(&p, "\x1b[7D").?);
    try std.testing.expectEqual(ansi.Command.erase_line_right, feedAll(&p, "\x1b[K").?);
    try std.testing.expectEqual(ansi.Command.erase_line, feedAll(&p, "\x1b[2K").?);
}

test "what is not understood is swallowed, not printed" {
    var p: ansi.Parser = .{};
    for ("\x1b[1;31m") |c| try std.testing.expect(p.feed(c) == .swallow);
    for ("\x1b[?25l") |c| try std.testing.expect(p.feed(c) == .swallow);
    for ("\x1b7") |c| try std.testing.expect(p.feed(c) == .swallow);
    try std.testing.expect(p.feed('a') == .print);
    // Huge numbers saturate instead of overflowing.
    _ = feedAll(&p, "\x1b[99999999999999999999999999H");
    try std.testing.expect(p.feed('b') == .print);
}
