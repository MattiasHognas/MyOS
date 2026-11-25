//! `/test/syscall_abi`: check from ring 3 that a syscall gives back every
//! register the ABI promises (see `checked.zig`), for calls that succeed,
//! fail, block and switch threads, with every combination of the arithmetic
//! and direction flags and with odd stack alignments.
//!
//! Exits with 0 if every check passes, otherwise with the number of the
//! first failing check.

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const Sys = lib.Sys;
const err = lib.err;

const checked = @import("checked.zig");

var check_no: u64 = 0;

/// Record check number `check_no + 1`; exit with that number if `ok` is false.
fn expect(ok: bool) void {
    check_no += 1;
    if (!ok) lib.exit(check_no);
}

var buf: [64]u8 = undefined;

/// Program entry point: run the checks in order.
pub fn main() noreturn {
    const tid = lib.gettid();
    const path = "/etc/motd";

    // 1: every flag combination (7 flags, 128 patterns) through a trivial call.
    var ok = true;
    var bits: u64 = 0;
    while (bits < 128) : (bits += 1) {
        // Spread the 7 bits over CF, PF, AF, ZF, SF, DF, OF.
        const positions = [7]u6{ 0, 2, 4, 6, 7, 10, 11 };
        var flags: u64 = 0;
        for (positions, 0..) |pos, i| {
            if (bits >> @intCast(i) & 1 != 0) flags |= @as(u64, 1) << pos;
        }
        ok = ok and checked.call3(Sys.gettid, 1, 2, 3, .{ .flags = flags }) == tid;
    }
    expect(ok); // 1

    // The stack pointer is the program's business: the kernel must not care
    // whether it is aligned, and must not write below it.
    for ([_]u64{ 0, 8, 3, 1, 4096 + 5 }) |misalign| {
        expect(checked.call3(Sys.gettid, 0, 0, 0, .{ .misalign = misalign, .flags = 0x400 }) == tid); // 2-6
    }

    // Calls that fail keep the registers too.
    const all = checked.FLAGS_MASK;
    expect(checked.call3(999, 7, 8, 9, .{ .flags = all }) == err(.NOSYS)); // 7
    expect(checked.call3(Sys.write, 1, 0xFFFF_FFFF_8000_0000, 8, .{ .flags = all }) == err(.FAULT)); // 8
    expect(checked.call3(Sys.read, 77, @intFromPtr(&buf), buf.len, .{}) == err(.BADF)); // 9
    expect(checked.call3(Sys.open, @intFromPtr("/nope"), 0, 0, .{ .misalign = 8 }) == err(.NOENT)); // 10

    // Calls that do real work: file I/O, console output, a thread switch,
    // and a child process (the caller blocks while another program runs).
    const fd = checked.call3(Sys.open, @intFromPtr(path), 0, 0, .{ .flags = 0x401 }) orelse lib.exit(100);
    expect(fd == 3); // 11
    expect(checked.call3(Sys.read, fd, @intFromPtr(&buf), buf.len, .{ .flags = 0x8C4 }) == "Welcome to MyOS!\n".len); // 12
    expect(checked.call3(Sys.close, fd, 0, 0, .{ .flags = 0x11 }) == 0); // 13
    expect(checked.call3(Sys.write, 1, @intFromPtr("syscall_abi\n"), 12, .{ .flags = all, .misalign = 3 }) == 12); // 14
    expect(checked.call3(Sys.sched_yield, 0, 0, 0, .{ .flags = all }) == 0); // 15
    expect(checked.call3(Sys.myos_run, @intFromPtr("/test/entry_regs"), 0, 0, .{ .flags = 0x4D5 }) == 0); // 16

    lib.exit(0);
}
