//! `/test/fuzz`: make thousands of syscalls with random numbers and
//! arguments. The kernel must survive every one of them, must not kill this
//! process (no argument can make a syscall fault), and must leak nothing
//! (the kernel test compares free memory before and after).
//!
//! The sequence comes from a fixed seed, so a failure repeats exactly. Half
//! the calls use implemented numbers, so the argument checks behind them are
//! reached; arguments are drawn from values that matter: valid and invalid
//! pointers, addresses at the edges of user space, small descriptors, huge
//! lengths.
//!
//! Left out on purpose: `exit` and `exit_group` (the run would end early),
//! the calls that unmap or reprotect memory (the program would take its
//! own code or stack away), closing or replacing the standard descriptors,
//! making pipes, waiting in `poll`, and `myos_getchar`
//! (it would wait for a key forever). Console writes of readable memory are
//! steered to a block of text, to keep the serial log printable.
//!
//! Exits with 0 after the last call; the kernel test fails on anything else.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const Sys = lib.Sys;

const ITERATIONS = 20_000;
const SEED: u64 = 0x4D79_4F53_2D66_757A; // "MyOS-fuz"

const UNMAPPED: u64 = 0x1000_0000;
/// First byte above the stack, which is at a random address: found at start.
var STACK_TOP: u64 = 0;
const PAGE = 4096;

const implemented = [_]u64{
    Sys.read,        Sys.write,           Sys.open,              Sys.close,        Sys.sched_yield,   Sys.gettid,       Sys.myos_run,
    Sys.arch_prctl,  Sys.set_tid_address, Sys.writev,            Sys.ioctl,        Sys.poll,          Sys.rt_sigaction, Sys.rt_sigprocmask,
    Sys.sigaltstack, Sys.mmap,            Sys.brk,               Sys.futex,        Sys.clock_gettime, Sys.fstat,        Sys.lseek,
    Sys.pread64,     Sys.openat,          Sys.fcntl,             Sys.getpid,       Sys.kill,          Sys.tgkill,       Sys.uname,
    Sys.prlimit64,   Sys.getrandom,       Sys.sched_getaffinity, Sys.gettimeofday,
};
/// Paths a call may be given. Never this program or the shell: one would
/// recurse, the other waits for the keyboard.
const paths = [_][*:0]const u8{ "/etc/motd", "/bin/hello", "/test/entry_regs", "/does/not/exist", "" };
/// What console writes of valid memory print.
const line = "fuzz fuzz fuzz fuzz fuzz fuzz fuzz fuzz fuzz fuzz fuzz fuzz\n";
const text: *const [16 * line.len]u8 = blk: {
    var t: [16 * line.len]u8 = undefined;
    for (0..16) |i| @memcpy(t[i * line.len ..][0..line.len], line);
    const final = t;
    break :blk &final;
};

/// Scratch memory the kernel may read from and write to.
var buf: [3 * PAGE]u8 align(PAGE) = undefined;

/// xorshift64*: a small deterministic generator.
fn next(state: *u64) u64 {
    state.* ^= state.* >> 12;
    state.* ^= state.* << 25;
    state.* ^= state.* >> 27;
    return state.* *% 0x2545F4914F6CDD1D;
}

/// A random syscall number.
fn pickNumber(rng: *u64) u64 {
    const r = next(rng);
    return switch (r % 4) {
        0, 1 => implemented[(r >> 8) % implemented.len],
        2 => (r >> 8) % 512,
        else => next(rng),
    };
}

/// A random argument. `readable` is set if it may point at memory the
/// kernel can read.
fn pickArg(rng: *u64, readable: *bool) u64 {
    const r = next(rng);
    const v = r >> 8;
    readable.* = false;
    switch (r % 10) {
        0 => return 0,
        1 => return v % 32, // a descriptor, a flag, a short length
        2 => {
            readable.* = true;
            return @intFromPtr(&buf) + v % buf.len;
        },
        3 => {
            readable.* = true;
            return @intFromPtr(paths[v % paths.len]);
        },
        4 => return UNMAPPED + v % (2 * PAGE),
        5 => return 0xFFFF_8000_0000_0000 | v, // kernel half
        6 => return ~@as(u64, 0) - v % 16,
        7 => return next(rng),
        8 => return v % 70_000, // a length that crosses pages
        else => return STACK_TOP - v % 9, // the last mapped bytes, and past them
    }
}

/// Program entry point.
pub fn main() noreturn {
    // The frame pointer of the entry function is in the stack's last page.
    STACK_TOP = std.mem.alignForward(u64, @frameAddress(), PAGE);
    var rng: u64 = SEED;
    var args: [6]u64 = undefined;
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const nr = pickNumber(&rng);
        var second_readable = false;
        for (&args, 0..) |*a, n| {
            var readable = false;
            a.* = pickArg(&rng, &readable);
            if (n == 1) second_readable = readable;
        }
        if (nr == Sys.exit or nr == Sys.exit_group or nr == Sys.myos_getchar) continue;
        // Calls with which a program takes its own memory away or changes
        // what it may do with it are a program's right, and its end.
        if (nr == Sys.munmap or nr == Sys.mprotect or nr == Sys.madvise or nr == Sys.mremap) continue;
        if (nr == Sys.mmap) args[3] &= ~@as(u64, lib.abi.MAP.FIXED | lib.abi.MAP.FIXED_NOREPLACE);
        if (nr == Sys.brk and args[0] != 0) args[0] = 0; // only ask where the heap ends
        if (nr == Sys.poll) args[2] = 0; // do not wait
        // Nor in a futex or a sleep; and a new thread started with random
        // registers would be this program's end, as would a signal to itself.
        if (nr == Sys.nanosleep or nr == Sys.clock_nanosleep or nr == Sys.clone) continue;
        if (nr == Sys.futex) args[1] = (args[1] & ~@as(u64, 0x7F)) | lib.abi.FUTEX.WAKE;
        if (nr == Sys.kill or nr == Sys.tkill) args[1] = 0;
        if (nr == Sys.tgkill) args[2] = 0;
        // The standard descriptors stay what they are: the last line of
        // this program goes to one. And nothing reads a pipe made here,
        // so a read from one would wait for ever.
        if (nr == Sys.close and args[0] <= 2) continue;
        if ((nr == Sys.dup2 or nr == Sys.dup3) and args[1] <= 2) continue;
        if (nr == Sys.pipe or nr == Sys.pipe2) continue;
        if (nr == Sys.write and args[0] <= 2 and (second_readable or args[1] >= STACK_TOP - 8)) {
            const off = next(&rng) % (text.len - 64);
            args[1] = @intFromPtr(text) + off;
            args[2] %= 64;
        }
        _ = lib.syscall6(nr, args[0], args[1], args[2], args[3], args[4], args[5]);
    }
    lib.write("\nfuzz done\n");
    lib.exit(0);
}
