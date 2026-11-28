//! `/test/rseq`: restartable sequences as Linux has them. Registering an
//! area writes the CPU's number into it (and keeps it current), the same
//! registration twice is busy, taking it back needs the signature; a
//! signal that comes while the thread is inside its critical section sends
//! it to the section's abort address; a forked child keeps the
//! registration. Exits with 0, or with the number of the first failing
//! check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

const SIG = 0x5305_3053;
const SIGUSR1 = 10;
const SIGKILL = 9;
const SA_RESTORER = 0x0400_0000;
const FLAG_UNREGISTER = 1;

/// `struct rseq`, as registered.
const Area = extern struct {
    cpu_id_start: u32 = 0,
    cpu_id: u32 = 0xFFFF_FFFF,
    rseq_cs: u64 = 0,
    flags: u32 = 0,
    _pad: [3]u32 = @splat(0),
};

/// `struct rseq_cs`.
const Section = extern struct { version: u32 = 0, flags: u32 = 0, start_ip: u64 = 0, post_commit_offset: u64 = 0, abort_ip: u64 = 0 };

var area: Area align(32) = .{};
var other: Area align(32) = .{};
var section: Section align(32) = .{};
var signals: u32 = 0;

// `rseq_spin(&area.rseq_cs, &section)`: describe a critical section that
// spins for ever, enter it, and return 1 from its abort address, the
// only way out. And the restorer handlers return to.
comptime {
    asm (
        \\.section .text
        \\.global rseq_spin
        \\rseq_spin:
        \\  lea rseq_start(%rip), %rax
        \\  mov %rax, 8(%rsi)
        \\  lea rseq_end(%rip), %rcx
        \\  sub %rax, %rcx
        \\  mov %rcx, 16(%rsi)
        \\  lea rseq_abort(%rip), %rax
        \\  mov %rax, 24(%rsi)
        \\  mov %rsi, (%rdi)
        \\rseq_start:
        \\  jmp rseq_start
        \\rseq_end:
        \\  xor %eax, %eax
        \\  ret
        \\  .long 0x53053053
        \\rseq_abort:
        \\  mov $1, %eax
        \\  ret
        \\.global rseq_restorer
        \\rseq_restorer:
        \\  mov $15, %eax
        \\  syscall
        \\  ud2
    );
}
extern fn rseq_spin(cs_slot: *u64, cs: *Section) callconv(.c) u64;
extern fn rseq_restorer() callconv(.c) void;

fn onSignal(_: i32) callconv(.c) void {
    signals += 1;
}

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn rseq(a: u64, len: u64, flags: u64, sig: u64) u64 {
    return lib.syscall6(Sys.rseq, a, len, flags, sig, 0, 0);
}

fn getcpu() u32 {
    var c: u32 = 0;
    _ = lib.syscall(Sys.getcpu, @intFromPtr(&c), 0, 0);
    return c;
}

/// The area says the CPU `getcpu` says (asked until the thread stays put
/// between the two).
fn cpuAgrees(a: *volatile Area) bool {
    for (0..100) |_| {
        const before = getcpu();
        const seen = a.cpu_id;
        const start = a.cpu_id_start;
        if (before == getcpu() and seen == before and start == before) return true;
        _ = lib.syscall(Sys.sched_yield, 0, 0, 0);
    }
    return false;
}

pub fn main() noreturn {
    const me = lib.syscall(Sys.getpid, 0, 0, 0);

    // --- Registering: the CPU goes in at once and stays current.
    expect(rseq(@intFromPtr(&area) + 4, 32, 0, SIG) == lib.err(.INVAL), 1); // not aligned
    expect(rseq(@intFromPtr(&area), 16, 0, SIG) == lib.err(.INVAL), 2); // too short
    expect(rseq(@intFromPtr(&area), 32, 2, SIG) == lib.err(.INVAL), 3); // unknown flag
    expect(rseq(@intFromPtr(&area), 32, 0, SIG) == 0, 4);
    expect(cpuAgrees(&area), 5);
    for (0..20) |_| _ = lib.syscall(Sys.sched_yield, 0, 0, 0);
    expect(cpuAgrees(&area), 6);
    expect(rseq(@intFromPtr(&area), 32, 0, SIG) == lib.err(.BUSY), 7); // the same again
    expect(rseq(@intFromPtr(&other), 32, 0, SIG) == lib.err(.INVAL), 8); // another one
    expect(rseq(@intFromPtr(&area), 32, FLAG_UNREGISTER, SIG + 1) == lib.err(.PERM), 9); // wrong signature

    // --- A forked child keeps the registration, in its copy of the area.
    // A value no CPU has goes into the copy; the child's first time on a
    // CPU writes the real one.
    @as(*volatile u32, &area.cpu_id).* = 0xFFFF_FFF0;
    @as(*volatile u32, &area.cpu_id_start).* = 0xFFFF_FFF0;
    const child = lib.syscall(Sys.fork, 0, 0, 0);
    if (child == 0) lib.exit(if (cpuAgrees(&area)) 0 else 40);
    var status: i32 = 0;
    expect(lib.syscall6(Sys.wait4, child, @intFromPtr(&status), 0, 0, 0, 0) == child and status == 0, 10);

    // --- A signal inside the critical section: the thread leaves it at
    // its abort address. A child sends the signal; if the section were
    // not aborted it would spin for ever, so the child ends it after a
    // while and the check fails instead of hanging.
    const act = abi.SigAction{ .handler = @intFromPtr(&onSignal), .flags = SA_RESTORER, .restorer = @intFromPtr(&rseq_restorer), .mask = 0 };
    expect(lib.syscall6(Sys.rt_sigaction, SIGUSR1, @intFromPtr(&act), 0, abi.SIGSET_SIZE, 0, 0) == 0, 11);
    const sender = lib.syscall(Sys.fork, 0, 0, 0);
    if (sender == 0) {
        var t: abi.TimeSpec = .{ .sec = 0, .nsec = 30_000_000 };
        _ = lib.syscall(Sys.nanosleep, @intFromPtr(&t), 0, 0);
        _ = lib.syscall(Sys.kill, @intCast(me), SIGUSR1, 0);
        t = .{ .sec = 3, .nsec = 0 };
        _ = lib.syscall(Sys.nanosleep, @intFromPtr(&t), 0, 0);
        _ = lib.syscall(Sys.kill, @intCast(me), SIGKILL, 0); // it never left the section
        lib.exit(0);
    }
    // Being switched out and in again aborts the section too (the fork
    // just now may do it), as on Linux: it is entered again until the
    // signal has come. Every way out is the abort address.
    var aborts: usize = 0;
    while (@atomicLoad(u32, &signals, .acquire) == 0) {
        expect(rseq_spin(&area.rseq_cs, &section) == 1, 12);
        aborts += 1;
    }
    expect(signals == 1 and aborts >= 1, 13);
    expect(area.rseq_cs == 0, 14); // cleared by the kernel
    _ = lib.syscall(Sys.kill, @intCast(sender), SIGKILL, 0);
    _ = lib.syscall6(Sys.wait4, sender, @intFromPtr(&status), 0, 0, 0, 0);

    // --- Taken back: the area says so, and can be registered again.
    expect(rseq(@intFromPtr(&area), 32, FLAG_UNREGISTER, SIG) == 0, 15);
    expect(area.cpu_id == 0xFFFF_FFFF, 16);
    expect(rseq(@intFromPtr(&area), 32, FLAG_UNREGISTER, SIG) == lib.err(.INVAL), 17); // nothing registered
    expect(rseq(@intFromPtr(&other), 32, 0, SIG) == 0, 18);
    expect(cpuAgrees(&other), 19);
    lib.exit(0);
}
