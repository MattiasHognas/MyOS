//! Host tests for how the shell splits a line (`app/sh_words.zig`).

const std = @import("std");
const w = @import("sh_words");

fn lookup(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "HOME")) return "/root";
    if (std.mem.eql(u8, name, "EMPTY")) return "";
    return null;
}

var sp: w.Splitter = .{};

fn split(line: []const u8) w.Error![]const w.Token {
    return sp.split(line, .{ .status = 7, .lookup = lookup });
}

fn expectWords(line: []const u8, want: []const []const u8) !void {
    const toks = try split(line);
    try std.testing.expectEqual(want.len, toks.len);
    for (toks, want) |t, s| try std.testing.expectEqualStrings(s, t.word);
}

test "words split on spaces and tabs" {
    try expectWords("ls  -l\t/bin", &.{ "ls", "-l", "/bin" });
    try expectWords("   ", &.{});
    try expectWords("echo # a comment", &.{"echo"});
}

test "quotes and backslashes" {
    try expectWords("echo 'a b' \"c d\" e\\ f", &.{ "echo", "a b", "c d", "e f" });
    try expectWords("a\"b c\"d ''", &.{ "ab cd", "" });
    try expectWords("'|' \"&&\" \\;", &.{ "|", "&&", ";" });
    try expectWords("\"a \\\" \\\\ \\$\"", &.{"a \" \\ $"});
    try std.testing.expectError(error.Unterminated, split("echo 'open"));
    try std.testing.expectError(error.Unterminated, split("echo \"open"));
    try std.testing.expectError(error.Unterminated, split("echo end\\"));
}

test "dollar: status, variables, braces, and a dollar alone" {
    try expectWords("echo $? $HOME ${HOME}x $NOPE. $EMPTY end", &.{ "echo", "7", "/root", "/rootx", ".", "", "end" });
    try expectWords("echo '$HOME' \"$HOME\" $ a$", &.{ "echo", "$HOME", "/root", "$", "a$" });
    try std.testing.expectError(error.Unterminated, split("echo ${HOME"));
}

test "operators, with and without spaces around them" {
    const toks = try split("a|b && c||d; e < in > out >> app 2> err 2>> err2 2>&1 & f&");
    const ops = [_]w.Op{ .pipe, .and_and, .or_or, .semicolon, .in, .out, .append, .err_out, .err_append, .err_to_out, .background, .background };
    var seen: usize = 0;
    for (toks) |t| switch (t) {
        .op => |o| {
            try std.testing.expectEqual(ops[seen], o);
            seen += 1;
        },
        .word => {},
    };
    try std.testing.expectEqual(ops.len, seen);
    const piped = try split("a|b");
    try std.testing.expectEqual(3, piped.len);
    try std.testing.expectEqualStrings("a", piped[0].word);
    try std.testing.expectEqual(w.Op.pipe, piped[1].op);
}

test "limits" {
    var long: [9000]u8 = undefined;
    @memset(&long, 'x');
    try std.testing.expectError(error.TooLong, split(&long));
    var many: [600]u8 = undefined;
    for (0..300) |i| {
        many[2 * i] = 'a';
        many[2 * i + 1] = ' ';
    }
    try std.testing.expectError(error.TooMany, split(&many));
}
