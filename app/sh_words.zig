//! How the shell splits a line into words and operators (`app/bin/sh.zig`).
//!
//! Operators: `|`, `;`, `&&`, `||`, `<`, `>`, `>>`, `2>`, `2>>`, `2>&1`,
//! where no quote hides them; `#` at the start of a word begins a comment.
//! Inside single quotes every character stands for itself; inside double
//! quotes a backslash keeps `"`, `\` and `$`, and `$` still expands;
//! outside quotes a backslash keeps the next character. `$?` is the last
//! status, `$NAME` and `${NAME}` a variable (empty if it is not set), and
//! a `$` before anything else is itself. Quoted and unquoted parts next to
//! each other make one word, and `''` is an empty one. No globbing.
//!
//! No dependencies but `std`: tested on the host.

const std = @import("std");

pub const Op = enum { pipe, semicolon, and_and, or_or, background, in, out, append, err_out, err_append, err_to_out };
pub const Token = union(enum) { word: [:0]const u8, op: Op };

pub const Error = error{
    /// A quote that is never closed, `${` without `}`, or a backslash at
    /// the very end.
    Unterminated,
    /// The words do not fit.
    TooLong,
    /// More words and operators than there is room for.
    TooMany,
};

/// What `$` expands to.
pub const Context = struct {
    status: u8,
    lookup: *const fn (name: []const u8) ?[]const u8,
};

/// The memory the words of the last line are in, and the tokens.
pub const Splitter = struct {
    store: [8192]u8 = undefined,
    tokens: [256]Token = undefined,
    used: usize = 0,

    /// Split `line`. The tokens and their words stay valid until the next
    /// call.
    pub fn split(self: *Splitter, line: []const u8, ctx: Context) Error![]const Token {
        self.used = 0;
        var n: usize = 0;
        var i: usize = 0;
        while (true) {
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
            if (i == line.len or line[i] == '#') break;
            if (n == self.tokens.len) return error.TooMany;
            if (operator(line[i..])) |o| {
                self.tokens[n] = .{ .op = o.op };
                n += 1;
                i += o.len;
                continue;
            }
            const start = self.used;
            while (i < line.len) {
                const c = line[i];
                if (c == ' ' or c == '\t' or c == '|' or c == ';' or c == '<' or c == '>' or c == '&') {
                    // `2>` and the like are operators only as a word of their own.
                    break;
                }
                if (c == '\'') {
                    const end = std.mem.indexOfScalarPos(u8, line, i + 1, '\'') orelse return error.Unterminated;
                    try self.put(line[i + 1 .. end]);
                    i = end + 1;
                } else if (c == '"') {
                    i += 1;
                    while (true) {
                        if (i == line.len) return error.Unterminated;
                        const d = line[i];
                        if (d == '"') break;
                        if (d == '\\' and i + 1 < line.len and (line[i + 1] == '"' or line[i + 1] == '\\' or line[i + 1] == '$')) {
                            try self.put(line[i + 1 .. i + 2]);
                            i += 2;
                        } else if (d == '$') {
                            i = try self.expand(line, i, ctx);
                        } else {
                            try self.put(line[i .. i + 1]);
                            i += 1;
                        }
                    }
                    i += 1;
                } else if (c == '\\') {
                    if (i + 1 == line.len) return error.Unterminated;
                    try self.put(line[i + 1 .. i + 2]);
                    i += 2;
                } else if (c == '$') {
                    i = try self.expand(line, i, ctx);
                } else {
                    try self.put(line[i .. i + 1]);
                    i += 1;
                }
            }
            if (self.used == self.store.len) return error.TooLong;
            self.store[self.used] = 0;
            self.tokens[n] = .{ .word = self.store[start..self.used :0] };
            self.used += 1;
            n += 1;
        }
        return self.tokens[0..n];
    }

    fn put(self: *Splitter, bytes: []const u8) Error!void {
        if (bytes.len >= self.store.len - self.used) return error.TooLong;
        @memcpy(self.store[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }

    /// `$?`, `$NAME` or `${NAME}` at `line[i]`: put what it stands for, and
    /// return where the line goes on.
    fn expand(self: *Splitter, line: []const u8, i: usize, ctx: Context) Error!usize {
        if (i + 1 < line.len and line[i + 1] == '?') {
            var buf: [4]u8 = undefined;
            try self.put(std.fmt.bufPrint(&buf, "{d}", .{ctx.status}) catch unreachable);
            return i + 2;
        }
        var j = i + 1;
        var braced = false;
        if (j < line.len and line[j] == '{') {
            braced = true;
            j += 1;
        }
        const name_start = j;
        while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '_')) j += 1;
        if (j == name_start) {
            if (braced) return error.Unterminated;
            try self.put("$");
            return i + 1;
        }
        const name = line[name_start..j];
        if (braced) {
            if (j == line.len or line[j] != '}') return error.Unterminated;
            j += 1;
        }
        try self.put(ctx.lookup(name) orelse "");
        return j;
    }
};

/// The operator `rest` starts with, longest first.
fn operator(rest: []const u8) ?struct { op: Op, len: usize } {
    const ops = [_]struct { []const u8, Op }{
        .{ "2>&1", .err_to_out }, .{ "2>>", .err_append }, .{ "2>", .err_out }, .{ ">>", .append },
        .{ "&&", .and_and },      .{ "||", .or_or },       .{ "|", .pipe },     .{ ";", .semicolon },
        .{ "&", .background },    .{ "<", .in },           .{ ">", .out },
    };
    for (ops) |o| {
        if (std.mem.startsWith(u8, rest, o[0])) return .{ .op = o[1], .len = o[0].len };
    }
    return null;
}
