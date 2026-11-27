//! `/test/fork`: new processes as Linux makes them. `fork` gives a child
//! with a copy of the memory and the same open files; `wait4` collects it
//! with its status, by process ID or any, waiting or not; a child that a
//! signal ended is reported as such; `vfork` holds the parent until the
//! child is gone; `clone` without `CLONE_THREAD` with a stack of its own;
//! the descendant limit. Exits with 0, or with the number of the first
//! failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn wait4(pid: i64, status: *i32, options: u64) u64 {
    return lib.syscall6(Sys.wait4, @bitCast(pid), @intFromPtr(status), options, 0, 0, 0);
}

fn exited(status: i32) ?u8 {
    return if (status & 0x7F == 0) @intCast((status >> 8) & 0xFF) else null;
}

fn signaled(status: i32) ?u8 {
    const sig = status & 0x7F;
    return if (sig != 0 and sig != 0x7F) @intCast(sig) else null;
}

var shared: u64 = 1;
var stack: [16 * 1024]u8 align(16) = undefined;

pub fn main() noreturn {
    const me = lib.syscall(Sys.getpid, 0, 0, 0);
    var status: i32 = 0;
    expect(wait4(-1, &status, 0) == lib.err(.CHILD), 1); // no children yet

    // --- fork: a copy of the memory; the parent's stays as it was.
    var pfd: [2]i32 = undefined;
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&pfd), 0, 0) == 0, 2);
    shared = 42;
    const child = lib.syscall(Sys.fork, 0, 0, 0);
    if (child == 0) {
        // In the child: its own copy, the same pipe.
        if (shared != 42) lib.exit(100);
        shared = 7;
        if (lib.syscall(Sys.getppid, 0, 0, 0) != me) lib.exit(101);
        if (lib.syscall(Sys.getpid, 0, 0, 0) == me) lib.exit(102);
        _ = lib.syscall(Sys.write, @intCast(pfd[1]), @intFromPtr("hi"), 2);
        lib.exit(23);
    }
    expect(!lib.isError(child) and child != me, 3);
    var buf: [4]u8 = undefined;
    expect(lib.read(@intCast(pfd[0]), &buf) == 2 and buf[0] == 'h', 4); // through the shared pipe
    expect(wait4(@intCast(child), &status, 0) == child and exited(status) == 23, 5);
    expect(shared == 42, 6); // what the child wrote was its own
    expect(wait4(@intCast(child), &status, 0) == lib.err(.CHILD), 7); // collected once

    // --- One open file, one offset: what the child reads, the parent does
    // not read again.
    const motd = lib.open("/etc/motd");
    expect(!lib.isError(motd), 22);
    const reader = lib.syscall(Sys.fork, 0, 0, 0);
    if (reader == 0) {
        var three: [3]u8 = undefined;
        lib.exit(if (lib.read(motd, &three) == 3 and three[0] == 'W') 0 else 1);
    }
    expect(wait4(@intCast(reader), &status, 0) == reader and exited(status) == 0, 23);
    var rest: [4]u8 = undefined;
    expect(lib.read(motd, &rest) == 4 and std.mem.eql(u8, &rest, "come"), 24);
    expect(lib.syscall(Sys.lseek, motd, 0, 1) == 7, 25);
    _ = lib.close(motd);

    // --- WNOHANG, and "any child".
    const slow = lib.syscall(Sys.fork, 0, 0, 0);
    if (slow == 0) {
        _ = lib.read(@intCast(pfd[0]), &buf); // until the parent writes
        lib.exit(5);
    }
    expect(wait4(-1, &status, abi.WNOHANG) == 0, 8); // there, not ended
    _ = lib.syscall(Sys.write, @intCast(pfd[1]), @intFromPtr("go"), 1);
    expect(wait4(-1, &status, 0) == slow and exited(status) == 5, 9);

    // --- A child a signal ends; one the kernel kills for a fault.
    const victim = lib.syscall(Sys.fork, 0, 0, 0);
    if (victim == 0) {
        _ = lib.read(@intCast(pfd[0]), &buf); // waits for ever
        lib.exit(1);
    }
    expect(lib.syscall(Sys.kill, victim, 15, 0) == 0, 10); // SIGTERM
    expect(wait4(@intCast(victim), &status, 0) == victim and signaled(status) == 15, 11);
    const crash = lib.syscall(Sys.fork, 0, 0, 0);
    if (crash == 0) {
        @as(*volatile u8, @ptrFromInt(0x10)).* = 1;
        lib.exit(1);
    }
    expect(wait4(@intCast(crash), &status, 0) == crash and signaled(status) == 11, 12); // SIGSEGV

    // --- vfork: the parent goes on only once the child is gone.
    shared = 0;
    const vchild = lib.syscall(Sys.vfork, 0, 0, 0);
    if (vchild == 0) {
        // (Its own copy of memory here, unlike Linux: only the end shows.)
        for (0..20) |_| lib.yield();
        _ = lib.syscall(Sys.exit, 9, 0, 0);
        unreachable;
    }
    // Ended already: collected without waiting.
    expect(wait4(@intCast(vchild), &status, abi.WNOHANG) == vchild and exited(status) == 9, 13);

    // --- clone without CLONE_THREAD, on a stack of its own, with a signal
    // of choice on exit (ignored by default: SIGCHLD and SIGURG are).
    const top = @intFromPtr(&stack) + stack.len;
    // (In assembly: the child starts on the empty stack, so it must not
    // return from anything; it ends with status 4 at once.)
    const cloned = asm volatile (
        \\ mov $56, %%eax
        \\ syscall
        \\ test %%rax, %%rax
        \\ jnz 1f
        \\ mov $60, %%eax
        \\ mov $4, %%edi
        \\ syscall
        \\ ud2
        \\1:
        : [ret] "={rax}" (-> u64),
        : [flags] "{rdi}" (@as(u64, 23)), // SIGURG when it ends
          [stack] "{rsi}" (top),
          [ptid] "{rdx}" (@as(u64, 0)),
          [ctid] "{r10}" (@as(u64, 0)),
          [tls] "{r8}" (@as(u64, 0)),
        : .{ .rcx = true, .r11 = true, .memory = true });
    expect(!lib.isError(cloned), 14);
    expect(wait4(@intCast(cloned), &status, 0) == cloned and exited(status) == 4, 15);

    // --- What is refused.
    expect(lib.syscall6(Sys.clone, 0x400, 0, 0, 0, 0, 0) == lib.err(.INVAL), 16); // CLONE_FILES: not between processes
    expect(wait4(-1, &status, 0x100) == lib.err(.INVAL), 17);
    expect(lib.syscall6(Sys.wait4, @bitCast(@as(i64, -1)), 8, 0, 0, 0, 0) == lib.err(.CHILD), 18); // no child: before any write

    // --- Many children at once, collected in any order.
    var pids: [6]u64 = undefined;
    for (&pids, 0..) |*pid, i| {
        pid.* = lib.syscall(Sys.fork, 0, 0, 0);
        if (pid.* == 0) lib.exit(@intCast(30 + i));
        expect(!lib.isError(pid.*), 19);
    }
    var seen: u64 = 0;
    for (pids) |_| {
        const got = wait4(-1, &status, 0);
        for (pids, 0..) |pid, i| {
            if (pid == got and exited(status) == @as(u8, @intCast(30 + i))) seen |= @as(u64, 1) << @intCast(i);
        }
    }
    expect(seen == 0x3F, 20);
    expect(wait4(-1, &status, 0) == lib.err(.CHILD), 21);

    // --- An orphan: a child that ends before its own child goes to this
    // process (there is no init in the kernel's tests), which collects it.
    var opfd: [2]i32 = undefined;
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&opfd), 0, 0) == 0, 26);
    const middle = lib.syscall(Sys.fork, 0, 0, 0);
    if (middle == 0) {
        const grandchild = lib.syscall(Sys.fork, 0, 0, 0);
        if (grandchild == 0) {
            _ = lib.close(@intCast(opfd[1]));
            var b: [1]u8 = undefined;
            _ = lib.read(@intCast(opfd[0]), &b); // until the grandparent says
            // Adopted by now: its parent is the grandparent.
            lib.exit(if (lib.syscall(Sys.getppid, 0, 0, 0) == me) 60 else 61);
        }
        lib.exit(if (lib.isError(grandchild)) 1 else 0);
    }
    expect(wait4(@intCast(middle), &status, 0) == middle and exited(status) == 0, 27);
    _ = lib.syscall(Sys.write, @intCast(opfd[1]), @intFromPtr("x"), 1);
    _ = lib.close(@intCast(opfd[1]));
    _ = lib.close(@intCast(opfd[0]));
    expect(wait4(-1, &status, 0) != lib.err(.CHILD) and exited(status) == 60, 28); // the orphan, collected here

    // --- Process groups and sessions. Started by the kernel, this program
    // leads a session and a group of its own.
    expect(lib.syscall(Sys.getpgrp, 0, 0, 0) == me and lib.syscall(Sys.getpgid, 0, 0, 0) == me, 30);
    expect(lib.syscall(Sys.getsid, 0, 0, 0) == me, 31);
    expect(lib.syscall(Sys.setsid, 0, 0, 0) == lib.err(.PERM), 32); // leads a group already
    expect(lib.syscall(Sys.setpgid, 0, 0, 0) == lib.err(.PERM), 33); // a session leader stays where it is
    // A child moved into a group of its own, and ended through it.
    const g = lib.syscall(Sys.fork, 0, 0, 0);
    if (g == 0) {
        _ = lib.read(@intCast(pfd[0]), &buf); // waits for ever
        lib.exit(1);
    }
    expect(lib.syscall(Sys.getpgid, g, 0, 0) == me, 34); // inherited
    expect(lib.syscall(Sys.setpgid, g, 0, 0) == 0 and lib.syscall(Sys.getpgid, g, 0, 0) == g, 35);
    expect(lib.syscall(Sys.getsid, g, 0, 0) == me, 36); // the same session
    expect(lib.syscall(Sys.setpgid, g, 99999, 0) == lib.err(.PERM), 37); // no such group
    expect(lib.syscall(Sys.setpgid, 99999, 0, 0) == lib.err(.SRCH), 38); // not a child
    expect(wait4(0, &status, abi.WNOHANG) == lib.err(.CHILD), 39); // none in this group now
    expect(lib.syscall(Sys.kill, @bitCast(-@as(i64, @intCast(g))), 15, 0) == 0, 40);
    expect(wait4(-@as(i64, @intCast(g)), &status, 0) == g and signaled(status) == 15, 41);
    expect(lib.syscall(Sys.kill, @bitCast(-@as(i64, @intCast(g))), 15, 0) == lib.err(.SRCH), 42); // the group is gone
    // A child that starts a session of its own.
    const s1 = lib.syscall(Sys.fork, 0, 0, 0);
    if (s1 == 0) {
        const mine = lib.syscall(Sys.getpid, 0, 0, 0);
        if (lib.syscall(Sys.setsid, 0, 0, 0) != mine) lib.exit(50);
        if (lib.syscall(Sys.getsid, 0, 0, 0) != mine or lib.syscall(Sys.getpgrp, 0, 0, 0) != mine) lib.exit(51);
        lib.exit(52);
    }
    expect(wait4(@intCast(s1), &status, 0) == s1 and exited(status) == 52, 43);
    // The terminal's foreground group: this program's, as nobody set one.
    var fg: i32 = 0;
    expect(lib.syscall(Sys.ioctl, 0, 0x540F, @intFromPtr(&fg)) == 0 and fg == @as(i32, @intCast(me)), 44); // TIOCGPGRP

    _ = lib.close(@intCast(pfd[0]));
    _ = lib.close(@intCast(pfd[1]));
    lib.exit(0);
}
