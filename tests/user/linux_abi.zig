//! `/test/linux_abi`: check what a Linux program relies on before `main`
//! and in its first calls: the initial stack (arguments, environment,
//! auxiliary vector), the FS and GS base, and `writev`, `ioctl`,
//! `set_tid_address` and `exit_group`.
//!
//! The kernel test starts it with the arguments `abi`, `x y` and an empty
//! one, and the environment `A=1`; started with fewer arguments it skips
//! the checks of their contents. Two copies run at once, so each one's FS
//! and GS base must survive the other running.
//!
//! Exits with 0 through `exit_group`, or with the number of the first
//! failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const Sys = lib.Sys;
const abi = lib.abi;
const AT = abi.AT;

fn expect(ok: bool, check: u64) void {
    if (!ok) lib.exit(check);
}

fn eql(s: [*:0]const u8, want: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(s), want);
}

/// The 8 bytes at offset 0 from the FS (or GS) base.
fn readFs() u64 {
    return asm volatile ("mov %%fs:0, %[v]"
        : [v] "=r" (-> u64),
    );
}

fn readGs() u64 {
    return asm volatile ("mov %%gs:0, %[v]"
        : [v] "=r" (-> u64),
    );
}

var fs_block: [2]u64 = .{ 0, 0 };
var gs_block: [2]u64 = .{ 0, 0 };

pub fn main() noreturn {
    // The initial stack.
    const argv = lib.argv();
    const env = lib.environ();
    expect(argv.len >= 1, 1);
    if (argv.len == 3) {
        expect(eql(argv[0], "abi") and eql(argv[1], "x y") and eql(argv[2], ""), 2);
        expect(env.len == 1 and eql(env[0], "A=1"), 3);
        // In order of address, as on Linux, and the environment after them.
        expect(@intFromPtr(argv[0]) < @intFromPtr(argv[1]) and @intFromPtr(argv[2]) < @intFromPtr(env[0]), 4);
    }
    expect(lib.auxValue(AT.PAGESZ) == 4096, 5);
    expect(lib.auxValue(AT.CLKTCK) == 100, 6);
    expect(lib.auxValue(AT.BASE) == 0 and lib.auxValue(AT.UID) == 0 and lib.auxValue(AT.SECURE) == 0, 7);
    // The program headers: how many and how large, and, if this program's
    // are part of what was loaded (that is up to how it was linked), where
    // they are; then the loadable segments (type 1) can be read there.
    const phdr = lib.auxValue(AT.PHDR) orelse lib.exit(8);
    const phnum = lib.auxValue(AT.PHNUM) orelse lib.exit(8);
    expect(phnum >= 1 and phnum < 64 and lib.auxValue(AT.PHENT) == 56, 9);
    if (phdr != 0) {
        var loads: usize = 0;
        for (0..phnum) |i| {
            const ph: *align(1) const u32 = @ptrFromInt(phdr + i * 56);
            if (ph.* == 1) loads += 1;
        }
        expect(loads >= 1, 10);
    }
    // The entry point is in this program's code, near `main`.
    const entry = lib.auxValue(AT.ENTRY) orelse lib.exit(11);
    const here = @intFromPtr(&main);
    expect(entry != 0 and (if (entry > here) entry - here else here - entry) < 16 * 1024 * 1024, 11);
    // Sixteen random bytes, not all the same.
    const random: *const [16]u8 = @ptrFromInt(lib.auxValue(AT.RANDOM) orelse lib.exit(12));
    expect(!std.mem.allEqual(u8, random, random[0]), 12);
    const execfn: [*:0]const u8 = @ptrFromInt(lib.auxValue(AT.EXECFN) orelse lib.exit(13));
    expect(eql(execfn, "/test/linux_abi"), 13);
    const platform: [*:0]const u8 = @ptrFromInt(lib.auxValue(AT.PLATFORM) orelse lib.exit(14));
    expect(eql(platform, "x86_64"), 14);
    expect(lib.auxValue(33) == null, 15); // no vDSO

    // set_tid_address returns the thread's ID.
    const tid = lib.gettid();
    var tid_slot: u32 = 0;
    expect(lib.syscall(Sys.set_tid_address, @intFromPtr(&tid_slot), 0, 0) == tid, 20);

    // FS and GS base: set, read back, used by the CPU, and still there
    // after other programs have run.
    fs_block[0] = 0xF500_0000 + tid;
    gs_block[0] = 0x6500_0000 + tid;
    expect(lib.syscall(Sys.arch_prctl, abi.ARCH.SET_FS, @intFromPtr(&fs_block), 0) == 0, 21);
    expect(lib.syscall(Sys.arch_prctl, abi.ARCH.SET_GS, @intFromPtr(&gs_block), 0) == 0, 22);
    for (0..200) |_| {
        expect(readFs() == 0xF500_0000 + tid and readGs() == 0x6500_0000 + tid, 23);
        lib.yield();
    }
    var spin: usize = 0;
    while (spin < 30_000_000) : (spin += 1) { // long enough to be preempted
        if (spin % 1_000_000 == 0) expect(readFs() == 0xF500_0000 + tid and readGs() == 0x6500_0000 + tid, 24);
    }
    var got: u64 = 0;
    expect(lib.syscall(Sys.arch_prctl, abi.ARCH.GET_FS, @intFromPtr(&got), 0) == 0 and got == @intFromPtr(&fs_block), 25);
    expect(lib.syscall(Sys.arch_prctl, abi.ARCH.GET_GS, @intFromPtr(&got), 0) == 0 and got == @intFromPtr(&gs_block), 26);
    // A base outside user space is refused and changes nothing.
    for ([_]u64{ 0xFFFF_8000_0000_0000, 0xFFFF_FFFF_FFFF_F000, 0x0000_8000_0000_0000, 0x8000_0000_0000_0000 }) |bad| {
        expect(lib.syscall(Sys.arch_prctl, abi.ARCH.SET_FS, bad, 0) == lib.err(.PERM), 27);
        expect(lib.syscall(Sys.arch_prctl, abi.ARCH.SET_GS, bad, 0) == lib.err(.PERM), 28);
    }
    expect(readFs() == 0xF500_0000 + tid and readGs() == 0x6500_0000 + tid, 29);
    expect(lib.syscall(Sys.arch_prctl, 0x1234, 0, 0) == lib.err(.INVAL), 30);
    expect(lib.syscall(Sys.arch_prctl, abi.ARCH.GET_FS, 0xFFFF_8000_0000_0000, 0) == lib.err(.FAULT), 31);
    expect(lib.syscall(Sys.arch_prctl, abi.ARCH.GET_FS, 8, 0) == lib.err(.FAULT), 32);

    // ioctl: nothing is a terminal yet.
    expect(lib.syscall(Sys.ioctl, 1, 0x5413, 0) == lib.err(.NOTTY), 40);
    expect(lib.syscall(Sys.ioctl, 99, 0x5413, 0) == lib.err(.BADF), 41);

    // writev.
    const a = "linux_abi: ";
    const b = "writev works\n";
    const iov = [_]abi.IoVec{
        .{ .base = @intFromPtr(a), .len = a.len },
        .{ .base = 0, .len = 0 }, // an empty buffer may point anywhere
        .{ .base = @intFromPtr(b), .len = b.len },
    };
    expect(lib.syscall(Sys.writev, 1, @intFromPtr(&iov), iov.len) == a.len + b.len, 50);
    expect(lib.syscall(Sys.writev, 1, @intFromPtr(&iov), 0) == 0, 51);
    expect(lib.syscall(Sys.writev, 5, @intFromPtr(&iov), iov.len) == lib.err(.BADF), 52);
    expect(lib.syscall(Sys.writev, 1, @intFromPtr(&iov), abi.IOV_MAX + 1) == lib.err(.INVAL), 53);
    expect(lib.syscall(Sys.writev, 1, 8, 1) == lib.err(.FAULT), 54);
    // A first buffer that cannot be read: nothing written, EFAULT. A later
    // one: what came before it is written and counted.
    const bad_first = [_]abi.IoVec{.{ .base = 8, .len = 4 }};
    expect(lib.syscall(Sys.writev, 1, @intFromPtr(&bad_first), 1) == lib.err(.FAULT), 55);
    const bad_second = [_]abi.IoVec{ .{ .base = @intFromPtr(b), .len = b.len }, .{ .base = 8, .len = 4 } };
    expect(lib.syscall(Sys.writev, 1, @intFromPtr(&bad_second), 2) == b.len, 56);
    // Lengths that add up past what one call may move.
    const huge = [_]abi.IoVec{ .{ .base = @intFromPtr(a), .len = 1 << 62 }, .{ .base = @intFromPtr(a), .len = 1 << 62 }, .{ .base = @intFromPtr(a), .len = 1 << 63 } };
    expect(lib.syscall(Sys.writev, 1, @intFromPtr(&huge), 3) == lib.err(.INVAL), 57);

    _ = lib.syscall(Sys.exit_group, 0, 0, 0);
    lib.exit(99); // exit_group returned
}
