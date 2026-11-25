//! Host tests for the shell's command-line splitting (`app/cmdline.zig`).

const std = @import("std");
const cmdline = @import("cmdline");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

fn expectSplit(line: []const u8, want: []const []const u8) !void {
    var storage: [256]u8 = undefined;
    var argv: [16]?[*:0]const u8 = undefined;
    const n = try cmdline.split(line, &storage, &argv);
    try expectEqual(want.len, n);
    for (want, 0..) |w, i| try std.testing.expectEqualStrings(w, std.mem.span(argv[i].?));
    try expectEqual(null, argv[n]); // the list ends as `execve` wants it
}

test "words are separated by any number of spaces" {
    try expectSplit("hello", &.{"hello"});
    try expectSplit("  echo   one two  ", &.{ "echo", "one", "two" });
    try expectSplit("", &.{});
    try expectSplit("    ", &.{});
}

test "quotes keep spaces, and join with what is next to them" {
    try expectSplit("echo 'two words' \"three more words\"", &.{ "echo", "two words", "three more words" });
    try expectSplit("a\"b c\"d", &.{"ab cd"});
    try expectSplit("say 'it''s'", &.{ "say", "its" });
    try expectSplit("x '' \"\" y", &.{ "x", "", "", "y" });
    try expectSplit("'\"' \"'\"", &.{ "\"", "'" });
}

test "a backslash makes the next character literal, except in single quotes" {
    try expectSplit("a\\ b", &.{"a b"});
    try expectSplit("\\'x \\\"y \\\\", &.{ "'x", "\"y", "\\" });
    try expectSplit("\"a\\\"b\"", &.{"a\"b"});
    try expectSplit("'a\\b'", &.{"a\\b"});
}

test "what cannot be split is an error" {
    var storage: [8]u8 = undefined;
    var argv: [3]?[*:0]const u8 = undefined;
    var roomy: [64]u8 = undefined;
    try expectError(error.Unterminated, cmdline.split("echo 'open", &roomy, &argv));
    try expectError(error.Unterminated, cmdline.split("echo \"open", &roomy, &argv));
    try expectError(error.Unterminated, cmdline.split("echo \\", &roomy, &argv));
    try expectError(error.TooManyArguments, cmdline.split("a b c", &storage, &argv));
    try expectError(error.TooLong, cmdline.split("12345678", &storage, &argv));
    try expectError(error.TooLong, cmdline.split("1234 567", &storage, &argv));
    try expectEqual(2, try cmdline.split("1234 56", &storage, &argv)); // exactly fits, with the NULs
    try expectEqual(2, try cmdline.split("a b", &storage, &argv)); // and exactly as many as there is room for
    var none: [0]?[*:0]const u8 = .{};
    try expectError(error.TooManyArguments, cmdline.split("", &storage, &none));
}
