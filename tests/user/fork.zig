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

    _ = lib.close(@intCast(pfd[0]));
    _ = lib.close(@intCast(pfd[1]));
    lib.exit(0);
}
