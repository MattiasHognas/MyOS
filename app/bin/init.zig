//! `/sbin/init`: the first program, which the kernel starts and which
//! starts everything else. It runs the shell on the terminal, starts it
//! again whenever it ends, and collects the exit status of every orphan
//! the kernel hands it, so none stays a zombie.
//!
//! `init --restarts N` (for tests) starts the shell again only N times,
//! and then ends with the last shell's status.

const std = @import("std");
const u = @import("util");

const env = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", "HOME=/root", "TERM=vt100" };

fn startShell() usize {
    while (true) {
        const pid = u.sys0(.fork);
        if (u.isErr(pid)) {
            u.print(2, "init: cannot start the shell: {s}\n", .{u.message(u.errnoOf(pid))});
            pause(1);
            continue;
        }
        if (pid == 0) {
            // A process group of its own, which the shell gives the
            // terminal to.
            _ = u.sys2(.setpgid, 0, 0);
            _ = u.sys1(.chdir, @intFromPtr("/root"));
            const argv = [_:null]?[*:0]const u8{"-sh"};
            const rc = u.sys3(.execve, @intFromPtr("/bin/sh"), @intFromPtr(&argv), @intFromPtr(&env));
            u.print(2, "init: /bin/sh: {s}\n", .{u.message(u.errnoOf(rc))});
            _ = u.sys1(.exit_group, 127);
        }
        _ = u.sys2(.setpgid, pid, pid);
        return pid;
    }
}

fn pause(seconds: u64) void {
    const ts = std.os.linux.timespec{ .sec = @intCast(seconds), .nsec = 0 };
    _ = u.sys2(.nanosleep, @intFromPtr(&ts), 0);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const args = init.args.vector;
    var restarts_left: ?u64 = null;
    if (args.len == 3 and u.eql(u.span(args[1]), "--restarts")) restarts_left = std.fmt.parseInt(u64, u.span(args[2]), 10) catch null;
    var shell = startShell();
    var quick_ends: u32 = 0;
    var started = now();
    while (true) {
        var raw: u32 = 0;
        const pid = u.sys4(.wait4, @bitCast(@as(isize, -1)), @intFromPtr(&raw), 0, 0);
        if (u.isErr(pid)) {
            if (u.errnoOf(pid) == 10) shell = startShell(); // no children at all: should not happen
            continue;
        }
        if (pid != shell) continue; // an orphan, collected
        const by_signal = raw & 0x7F != 0;
        const value = if (by_signal) raw & 0x7F else (raw >> 8) & 0xFF;
        if (restarts_left) |*left| {
            if (left.* == 0) {
                u.print(1, "init: the shell ended (status {d}); done\n", .{value});
                return if (by_signal) 128 else @intCast(value);
            }
            left.* -= 1;
        }
        u.print(1, "init: the shell ended ({s} {d}); starting a new one\n", .{ if (by_signal) "signal" else "status", value });
        // One that cannot even start is not restarted in a tight loop.
        quick_ends = if (now() - started < 2) quick_ends + 1 else 0;
        if (quick_ends >= 3) pause(2);
        shell = startShell();
        started = now();
    }
}

fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = u.sys2(.clock_gettime, 1, @intFromPtr(&ts));
    return @intCast(ts.sec);
}
