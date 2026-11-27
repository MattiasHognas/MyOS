//! `/bin/sh`: MyOS's shell, an ordinary Linux program.
//!
//! A line is a list of pipelines separated by `;`, `&&` and `||`; a
//! pipeline is commands separated by `|`; a command is words and
//! redirections: `< file`, `> file`, `>> file`, `2> file`, `2>> file`,
//! `2>&1`. Words are quoted as in other shells: single quotes keep
//! everything, double quotes and a backslash keep spaces and operators;
//! outside single quotes `$?` is the last status and `$NAME` or `${NAME}`
//! a variable. No globbing. A pipeline that ends in `&` runs in the
//! background: the shell says its job number and process group and goes
//! on.
//!
//! Job control, when it reads the terminal: Ctrl+Z stops the pipeline in
//! the foreground, which becomes a job, as one started with `&` is;
//! `jobs` lists them, says which have ended before a prompt, `fg [%N]`
//! brings one back to the foreground and `bg [%N]` lets it go on in the
//! background. The shell itself ignores `SIGTSTP`, `SIGTTIN` and
//! `SIGTTOU`, as shells do; the programs it starts get the defaults.
//!
//! `cd`, `pwd`, `exit`, `export NAME=value`, `unset NAME`, `jobs`, `fg`
//! and `bg` are built in;
//! anything else is a program, found in `PATH` (`/usr/bin:/bin` if it is
//! not set) unless its name has a slash. Each pipeline runs in a process
//! group of its own, which gets the terminal while it runs, so Ctrl+C
//! interrupts it and not the shell.
//!
//! `sh -c "line"` runs one line; `sh file` runs the lines of a file;
//! without arguments the shell reads the terminal with a prompt (`$ `, or
//! `[status] $ ` after a command that failed) until `exit` or the end of
//! input.

const std = @import("std");
const u = @import("util");
const linux = std.os.linux;

const MAX_WORDS = 64;
const MAX_CMDS = 16;
const TIOCSPGRP = 0x5410;
const TCGETS = 0x5401;

// ---------------------------------------------------------------------------
// Variables: the environment, which `export` and `unset` change.

var env_store: [16384]u8 = undefined;
var env_used: usize = 0;
var env: [256:null]?[*:0]const u8 = @splat(null);
var env_len: usize = 0;

fn getVar(name: []const u8) ?[]const u8 {
    for (env[0..env_len]) |e| {
        const s = u.span(e.?);
        if (s.len > name.len and s[name.len] == '=' and std.mem.startsWith(u8, s, name)) return s[name.len + 1 ..];
    }
    return null;
}

fn unsetVar(name: []const u8) void {
    var i: usize = 0;
    while (i < env_len) {
        const s = u.span(env[i].?);
        if (s.len > name.len and s[name.len] == '=' and std.mem.startsWith(u8, s, name)) {
            env[i] = env[env_len - 1];
            env_len -= 1;
            env[env_len] = null;
        } else i += 1;
    }
}

/// Set `entry` (`NAME=value`); false if there is no room.
fn setVar(entry: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
    if (entry.len + 1 > env_store.len - env_used or env_len + 1 >= env.len) return false;
    unsetVar(entry[0..eq]);
    @memcpy(env_store[env_used..][0..entry.len], entry);
    env_store[env_used + entry.len] = 0;
    env[env_len] = @ptrCast(&env_store[env_used]);
    env_len += 1;
    env_used += entry.len + 1;
    return true;
}

// ---------------------------------------------------------------------------
// Words and operators (`sh_words.zig`, tested on the host).

const words_mod = @import("sh_words");
const Op = words_mod.Op;
const Token = words_mod.Token;
var words: words_mod.Splitter = .{};
var last_status: u8 = 0;

fn tokenize(line: []const u8) words_mod.Error![]const Token {
    return words.split(line, .{ .status = last_status, .lookup = getVar });
}

// ---------------------------------------------------------------------------
// Commands.

const Command = struct {
    argv: [MAX_WORDS + 1:null]?[*:0]const u8 = @splat(null),
    argc: usize = 0,
    in: ?[*:0]const u8 = null,
    out: ?[*:0]const u8 = null,
    append: bool = false,
    err: ?[*:0]const u8 = null,
    err_append: bool = false,
    err_to_out: bool = false,
};

fn say(comptime fmt: []const u8, args: anytype) void {
    u.print(2, "sh: " ++ fmt ++ "\n", args);
}

/// Parse the commands of one pipeline from `toks` into `cmds`; returns how
/// many, or null after saying what is wrong.
fn parsePipeline(toks: []const Token, cmds: []Command) ?usize {
    var n: usize = 0;
    var i: usize = 0;
    cmds[0] = .{};
    while (i < toks.len) : (i += 1) {
        const c = &cmds[n];
        switch (toks[i]) {
            .word => |w| {
                if (c.argc == MAX_WORDS) {
                    say("too many arguments", .{});
                    return null;
                }
                c.argv[c.argc] = w.ptr;
                c.argc += 1;
            },
            .op => |op| switch (op) {
                .pipe => {
                    if (c.argc == 0) {
                        say("syntax error near '|'", .{});
                        return null;
                    }
                    n += 1;
                    if (n == cmds.len) {
                        say("pipeline too long", .{});
                        return null;
                    }
                    cmds[n] = .{};
                },
                .err_to_out => c.err_to_out = true,
                .in, .out, .append, .err_out, .err_append => {
                    i += 1;
                    if (i == toks.len or toks[i] != .word) {
                        say("syntax error: a redirection needs a file", .{});
                        return null;
                    }
                    const f = toks[i].word.ptr;
                    switch (op) {
                        .in => c.in = f,
                        .out, .append => {
                            c.out = f;
                            c.append = op == .append;
                        },
                        else => {
                            c.err = f;
                            c.err_append = op == .err_append;
                        },
                    }
                },
                else => unreachable, // split off by the caller
            },
        }
    }
    if (cmds[n].argc == 0) {
        if (n == 0 and toks.len == 0) return 0;
        say("syntax error: a command is missing", .{});
        return null;
    }
    return n + 1;
}

// ---------------------------------------------------------------------------
// Running.

var interactive = false;
var shell_pgid: usize = 0;

/// Open `path` for a redirection onto descriptor `target`. In a child.
fn redirect(path: [*:0]const u8, flags: usize, target: usize) bool {
    const fd = u.open(path, flags, 0o644);
    if (u.isErr(fd)) {
        u.complain("sh", u.span(path), fd);
        return false;
    }
    if (fd != target) {
        _ = u.sys3(.dup3, fd, target, 0);
        u.close(fd);
    }
    return true;
}

fn applyRedirections(c: *const Command) bool {
    if (c.in) |f| if (!redirect(f, u.O.RDONLY, 0)) return false;
    if (c.out) |f| if (!redirect(f, u.O.WRONLY | u.O.CREAT | (if (c.append) @as(usize, u.O.APPEND) else u.O.TRUNC), 1)) return false;
    if (c.err) |f| if (!redirect(f, u.O.WRONLY | u.O.CREAT | (if (c.err_append) @as(usize, u.O.APPEND) else u.O.TRUNC), 2)) return false;
    if (c.err_to_out) _ = u.sys3(.dup3, 1, 2, 0);
    return true;
}

/// Run the program of `c` in this (child) process; never returns.
fn execute(c: *Command) noreturn {
    const name = u.span(c.argv[0].?);
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const rc = u.sys3(.execve, @intFromPtr(c.argv[0].?), @intFromPtr(&c.argv), @intFromPtr(&env));
        say("{s}: {s}", .{ name, u.message(u.errnoOf(rc)) });
        _ = u.sys1(.exit_group, if (u.errnoOf(rc) == 2) 127 else 126);
        unreachable;
    }
    const path = getVar("PATH") orelse "/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    var last_err: u16 = 2;
    while (it.next()) |dir| {
        var full: [4096:0]u8 = undefined;
        const p = u.bufZ(&full, "{s}/{s}", .{ if (dir.len == 0) "." else dir, name }) catch continue;
        const rc = u.sys3(.execve, @intFromPtr(p.ptr), @intFromPtr(&c.argv), @intFromPtr(&env));
        last_err = u.errnoOf(rc);
        if (last_err != 2) break; // there, but it would not run
    }
    if (last_err == 2) say("{s}: command not found", .{name}) else say("{s}: {s}", .{ name, u.message(last_err) });
    _ = u.sys1(.exit_group, if (last_err == 2) 127 else 126);
    unreachable;
}

/// What a status from `wait4` comes to, as `$?` has it; and a message
/// for a program a signal ended.
fn statusOf(raw: u32, name: []const u8) u8 {
    if (raw & 0xFF == 0x7F) return @intCast(128 + ((raw >> 8) & 0x7F)); // stopped
    const sig = raw & 0x7F;
    if (sig == 0) return @intCast((raw >> 8) & 0xFF);
    const what: []const u8 = switch (sig) {
        2 => "", // Ctrl+C: nothing to say, a new line
        13 => "", // a broken pipe is the end of a pipeline
        4 => "Illegal instruction",
        5 => "Trace/breakpoint trap",
        6 => "Aborted",
        7 => "Bus error",
        8 => "Floating point exception",
        9 => "Killed",
        11 => "Segmentation fault",
        15 => "Terminated",
        else => "Terminated by a signal",
    };
    if (sig == 2) _ = u.writeAll(2, "\n");
    if (what.len > 0) say("{s}: {s} (signal {d})", .{ name, what, sig });
    return @intCast(128 + sig);
}

// ---------------------------------------------------------------------------
// Jobs: pipelines stopped with Ctrl+Z, and those sent on with `bg`.

const MAX_JOBS = 8;

const Job = struct {
    pgid: usize = 0,
    /// The processes not collected yet, 0 for those that were.
    pids: [MAX_CMDS]usize = @splat(0),
    /// The command names, as `jobs` shows them.
    name_buf: [80]u8 = undefined,
    name_len: usize = 0,
    stopped: bool = false,
    /// The status of the pipeline's last command, once it has ended.
    status: u8 = 0,
    /// Where the last command is in `pids`.
    last: usize = 0,

    fn name(j: *const Job) []const u8 {
        return j.name_buf[0..j.name_len];
    }

    fn alive(j: *const Job) bool {
        for (j.pids) |pid| if (pid != 0) return true;
        return false;
    }
};

/// Jobs by number minus one; a slot with `pgid` 0 is free.
var jobs: [MAX_JOBS]Job = @splat(.{});

/// Wait for the processes of `j` that are left: until they have all ended
/// (the job is done) or one has stopped (it is a stopped job). With
/// `nohang`, only collect what has happened already. Returns the status
/// as `$?` has it.
fn waitJob(j: *Job, nohang: bool) u8 {
    var status: u8 = j.status;
    for (&j.pids, 0..) |*pid, i| {
        if (pid.* == 0) continue;
        var raw: u32 = 0;
        const options: usize = (if (interactive) @as(usize, linux.W.UNTRACED) else 0) | (if (nohang) @as(usize, linux.W.NOHANG) else 0);
        while (true) {
            const rc = u.sys4(.wait4, pid.*, @intFromPtr(&raw), options, 0);
            if (!u.isErr(rc) or u.errnoOf(rc) != 4) {
                if (rc == 0) break; // nohang, and nothing yet
                if (u.isErr(rc)) {
                    pid.* = 0; // not ours any more
                    break;
                }
                if (raw & 0xFF == 0x7F) {
                    j.stopped = true;
                    return statusOf(raw, j.name());
                }
                const s = statusOf(raw, j.name());
                if (i == j.last) status = s;
                pid.* = 0;
                break;
            }
        }
    }
    j.status = status;
    return status;
}

/// The number (1-based) of a free job slot; null if all are taken.
fn freeJob() ?usize {
    for (&jobs, 0..) |*j, i| if (j.pgid == 0) return i;
    return null;
}

/// The job `arg` names (`%N` or `N`), or the newest one without `arg`.
fn findJob(arg: ?[*:0]const u8) ?*Job {
    if (arg) |a| {
        var text = u.span(a);
        if (text.len > 0 and text[0] == '%') text = text[1..];
        const n = std.fmt.parseInt(usize, text, 10) catch return null;
        if (n == 0 or n > MAX_JOBS or jobs[n - 1].pgid == 0) return null;
        return &jobs[n - 1];
    }
    var i: usize = MAX_JOBS;
    while (i > 0) : (i -= 1) if (jobs[i - 1].pgid != 0) return &jobs[i - 1];
    return null;
}

fn jobNumber(j: *const Job) usize {
    return (@intFromPtr(j) - @intFromPtr(&jobs[0])) / @sizeOf(Job) + 1;
}

/// Collect jobs running in the background that have ended or stopped, and
/// say so: before each prompt.
fn reapJobs() void {
    for (&jobs) |*j| {
        if (j.pgid == 0 or j.stopped) continue;
        _ = waitJob(j, true);
        if (j.stopped) {
            u.print(2, "[{d}]+  Stopped                 {s}\n", .{ jobNumber(j), j.name() });
        } else if (!j.alive()) {
            u.print(2, "[{d}]+  Done                    {s}\n", .{ jobNumber(j), j.name() });
            j.* = .{};
        }
    }
}

/// Wait for the foreground job `j`: if it stops it stays a job, and the
/// shell says so; if it ends, its slot is freed. The terminal comes back
/// to the shell either way.
fn waitForeground(j: *Job) u8 {
    const status = waitJob(j, false);
    giveTerminal(shell_pgid);
    if (j.stopped) {
        u.print(2, "[{d}]+  Stopped                 {s}\n", .{ jobNumber(j), j.name() });
    } else {
        j.* = .{};
    }
    return status;
}

/// `jobs`, `fg` and `bg`.
fn jobBuiltin(which: []const u8, c: *Command) u8 {
    if (u.eql(which, "jobs")) {
        for (&jobs) |*j| {
            if (j.pgid == 0) continue;
            u.print(1, "[{d}]   {s}                 {s}\n", .{ jobNumber(j), if (j.stopped) "Stopped" else "Running", j.name() });
        }
        return 0;
    }
    const j = findJob(if (c.argc > 1) c.argv[1] else null) orelse {
        say("{s}: no such job", .{which});
        return 1;
    };
    if (u.eql(which, "fg")) {
        u.print(1, "{s}\n", .{j.name()});
        giveTerminal(j.pgid);
        j.stopped = false;
        _ = u.sys2(.kill, -%j.pgid, @intFromEnum(linux.SIG.CONT));
        return waitForeground(j);
    }
    // bg
    if (!j.stopped) {
        say("bg: job {d} is already running", .{jobNumber(j)});
        return 0;
    }
    j.stopped = false;
    _ = u.sys2(.kill, -%j.pgid, @intFromEnum(linux.SIG.CONT));
    u.print(1, "[{d}]+ {s} &\n", .{ jobNumber(j), j.name() });
    return 0;
}

/// Hand the terminal to the process group `pgid`.
fn giveTerminal(pgid: usize) void {
    if (!interactive) return;
    const g: i32 = @intCast(pgid);
    _ = u.sys3(.ioctl, 0, TIOCSPGRP, @intFromPtr(&g));
}

/// The built-in commands; null if `c` is none.
fn builtin(c: *Command) ?u8 {
    const name = u.span(c.argv[0].?);
    if (u.eql(name, "exit")) {
        const code: u8 = if (c.argc > 1) std.fmt.parseInt(u8, u.span(c.argv[1].?), 10) catch 2 else last_status;
        _ = u.sys1(.exit_group, code);
        unreachable;
    }
    if (u.eql(name, "cd")) {
        var home_store: [4096:0]u8 = undefined;
        const dir: [*:0]const u8 = if (c.argc > 1) c.argv[1].? else blk: {
            const home = getVar("HOME") orelse "/";
            const z = u.bufZ(&home_store, "{s}", .{home}) catch break :blk "/";
            break :blk z.ptr;
        };
        const rc = u.sys1(.chdir, @intFromPtr(dir));
        if (u.isErr(rc)) {
            say("cd: {s}: {s}", .{ u.span(dir), u.message(u.errnoOf(rc)) });
            return 1;
        }
        var buf: [4096]u8 = undefined;
        const n = u.sys2(.getcwd, @intFromPtr(&buf), buf.len);
        if (!u.isErr(n)) {
            var entry: [4100]u8 = undefined;
            _ = setVar(std.fmt.bufPrint(&entry, "PWD={s}", .{std.mem.sliceTo(&buf, 0)}) catch "");
        }
        return 0;
    }
    if (u.eql(name, "pwd")) {
        var buf: [4096]u8 = undefined;
        const n = u.sys2(.getcwd, @intFromPtr(&buf), buf.len);
        if (u.isErr(n)) return 1;
        u.print(1, "{s}\n", .{std.mem.sliceTo(&buf, 0)});
        return 0;
    }
    if (u.eql(name, "export")) {
        for (c.argv[1..c.argc]) |a| {
            const s = u.span(a.?);
            if (std.mem.indexOfScalar(u8, s, '=') == null) continue; // `export NAME`: it is exported already
            if (!setVar(s)) {
                say("export: no room for {s}", .{s});
                return 1;
            }
        }
        return 0;
    }
    if (u.eql(name, "unset")) {
        for (c.argv[1..c.argc]) |a| unsetVar(u.span(a.?));
        return 0;
    }
    if (u.eql(name, "jobs") or u.eql(name, "fg") or u.eql(name, "bg")) return jobBuiltin(name, c);
    return null;
}

/// Run a pipeline of `n` commands and return its status: the last one's;
/// 0 for one sent to the `background`.
fn runPipeline(cmds: []Command, background: bool) u8 {
    // A single built-in runs in the shell itself, with its redirections
    // undone afterwards (in the foreground even after `&`).
    if (cmds.len == 1 and isBuiltin(u.span(cmds[0].argv[0].?))) {
        const saved = [3]usize{ u.sys3(.fcntl, 0, 1030, 10), u.sys3(.fcntl, 1, 1030, 10), u.sys3(.fcntl, 2, 1030, 10) };
        const status = if (applyRedirections(&cmds[0])) builtin(&cmds[0]).? else 1;
        for (saved, 0..) |fd, i| {
            if (u.isErr(fd)) continue;
            _ = u.sys3(.dup3, fd, i, 0);
            u.close(fd);
        }
        return status;
    }
    var pids: [MAX_CMDS]usize = undefined;
    var started: usize = 0;
    var pgid: usize = 0;
    var prev_read: ?usize = null;
    for (cmds, 0..) |*c, i| {
        var pfd: [2]i32 = .{ -1, -1 };
        const last = i + 1 == cmds.len;
        if (!last) {
            const rc = u.sys2(.pipe2, @intFromPtr(&pfd), u.O.CLOEXEC);
            if (u.isErr(rc)) {
                say("pipe: {s}", .{u.message(u.errnoOf(rc))});
                break;
            }
        }
        const pid = u.sys0(.fork);
        if (u.isErr(pid)) {
            say("fork: {s}", .{u.message(u.errnoOf(pid))});
            if (!last) {
                u.close(@intCast(pfd[0]));
                u.close(@intCast(pfd[1]));
            }
            break;
        }
        if (pid == 0) {
            // The child: into the pipeline's group, onto its pipes.
            _ = u.sys2(.setpgid, 0, pgid);
            if (prev_read) |r| _ = u.sys3(.dup3, r, 0, 0);
            if (!last) _ = u.sys3(.dup3, @intCast(pfd[1]), 1, 0);
            // A program that ends its own group's foreground must not take
            // the handler the shell has for Ctrl+C: back to the default.
            // The stop signals the shell ignores, too.
            const dfl = linux.Sigaction{ .handler = .{ .handler = linux.SIG.DFL }, .mask = std.mem.zeroes(linux.sigset_t), .flags = 0 };
            for ([_]linux.SIG{ .INT, .TSTP, .TTIN, .TTOU }) |sig| _ = linux.sigaction(sig, &dfl, null);
            if (!applyRedirections(c)) _ = u.sys1(.exit_group, 1);
            if (builtin(c)) |status| _ = u.sys1(.exit_group, status);
            execute(c);
        }
        if (pgid == 0) pgid = pid;
        _ = u.sys2(.setpgid, pid, pgid); // in the parent too: whichever runs first
        if (i == 0 and !background) giveTerminal(pgid);
        pids[started] = pid;
        started += 1;
        if (prev_read) |r| u.close(r);
        prev_read = null;
        if (!last) {
            u.close(@intCast(pfd[1]));
            prev_read = @intCast(pfd[0]);
        }
    }
    if (prev_read) |r| u.close(r);
    if (started == 0) {
        if (!background) giveTerminal(shell_pgid);
        return 1;
    }
    // A job, while it runs: it stays one if it is stopped.
    const slot = freeJob() orelse MAX_JOBS - 1; // all taken: the last is reused
    const j = &jobs[slot];
    j.* = .{ .pgid = pgid, .status = 1, .last = started - 1 };
    @memcpy(j.pids[0..started], pids[0..started]);
    var name_w: std.Io.Writer = .fixed(&j.name_buf);
    for (cmds[0..started], 0..) |*c, i| {
        if (i > 0) name_w.writeAll(" | ") catch {};
        for (c.argv[0..c.argc], 0..) |a, k| {
            if (k > 0) name_w.writeAll(" ") catch {};
            name_w.writeAll(u.span(a.?)) catch {};
        }
    }
    j.name_len = name_w.end;
    if (background) {
        if (interactive) u.print(2, "[{d}] {d}\n", .{ jobNumber(j), pgid });
        return 0;
    }
    return waitForeground(j);
}

fn isBuiltin(name: []const u8) bool {
    for ([_][]const u8{ "exit", "cd", "pwd", "export", "unset", "jobs", "fg", "bg" }) |b| if (u.eql(name, b)) return true;
    return false;
}

/// Run one line: its pipelines, with `;`, `&&` and `||` between them.
fn runLine(line: []const u8) void {
    const toks = tokenize(line) catch |e| {
        say("{s}", .{switch (e) {
            error.Unterminated => "a quote is not closed",
            error.TooLong => "line too long",
            error.TooMany => "too many words",
        }});
        last_status = 2;
        return;
    };
    var start: usize = 0;
    var skip = false;
    var i: usize = 0;
    while (i <= toks.len) : (i += 1) {
        const sep: ?Op = if (i == toks.len) null else switch (toks[i]) {
            .op => |op| if (op == .semicolon or op == .and_and or op == .or_or or op == .background) op else null,
            .word => null,
        };
        if (i < toks.len and sep == null) continue;
        const part = toks[start..i];
        start = i + 1;
        if (!skip and part.len > 0) {
            var cmds: [MAX_CMDS]Command = undefined;
            if (parsePipeline(part, &cmds)) |n| {
                if (n > 0) last_status = runPipeline(cmds[0..n], sep == .background);
            } else last_status = 2;
        }
        // `&&` goes on after success, `||` after failure; `;` always.
        skip = if (sep) |s| switch (s) {
            .and_and => last_status != 0,
            .or_or => last_status == 0,
            else => false,
        } else false;
    }
}

fn onInterrupt(_: linux.SIG) callconv(.c) void {}

var line_buf: [4096]u8 = undefined;

/// Read one line from `fd` (without its newline); null at the end.
fn readLine(fd: usize) ?[]const u8 {
    var len: usize = 0;
    while (len < line_buf.len) {
        const n = u.read(fd, line_buf[len .. len + 1]);
        if (u.isErr(n)) {
            if (u.errnoOf(n) == 4) { // Ctrl+C at the prompt: a fresh one
                _ = u.writeAll(1, "\n");
                return "";
            }
            return null;
        }
        if (n == 0) return if (len > 0) line_buf[0..len] else null;
        if (line_buf[len] == '\n') return line_buf[0..len];
        len += 1;
    }
    return line_buf[0..len];
}

pub fn main(init: std.process.Init.Minimal) u8 {
    for (init.environ.block.slice) |e| _ = setVar(u.span(e.?));
    const args = init.args.vector;
    shell_pgid = u.sys1(.getpgid, 0);

    if (args.len >= 3 and u.eql(u.span(args[1]), "-c")) {
        runLine(u.span(args[2]));
        return last_status;
    }
    if (args.len >= 2) {
        const fd = u.open(args[1], u.O.RDONLY | u.O.CLOEXEC, 0);
        if (u.isErr(fd)) {
            say("{s}: {s}", .{ u.span(args[1]), u.message(u.errnoOf(fd)) });
            return 127;
        }
        while (readLine(fd)) |line| runLine(line);
        return last_status;
    }

    var termios: [64]u8 = undefined;
    interactive = !u.isErr(u.sys3(.ioctl, 0, TCGETS, @intFromPtr(&termios)));
    if (interactive) {
        // Ctrl+C at the prompt only gives a fresh one: a handler, which
        // the programs it starts do not inherit.
        const act = linux.Sigaction{ .handler = .{ .handler = onInterrupt }, .mask = std.mem.zeroes(linux.sigset_t), .flags = 0 };
        _ = linux.sigaction(.INT, &act, null);
        // Job control: the shell is never stopped itself.
        const ign = linux.Sigaction{ .handler = .{ .handler = linux.SIG.IGN }, .mask = std.mem.zeroes(linux.sigset_t), .flags = 0 };
        for ([_]linux.SIG{ .TSTP, .TTIN, .TTOU }) |sig| _ = linux.sigaction(sig, &ign, null);
        giveTerminal(shell_pgid);
    }
    while (true) {
        if (interactive) {
            reapJobs();
            if (last_status == 0) _ = u.writeAll(1, "$ ") else u.print(1, "[{d}] $ ", .{last_status});
        }
        const line = readLine(0) orelse break;
        runLine(line);
    }
    if (interactive) _ = u.writeAll(1, "exit\n");
    return last_status;
}
