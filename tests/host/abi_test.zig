//! Host tests for the user/kernel ABI definitions (`src/abi/linux.zig`):
//! the values must be Linux's, and results must encode errors as Linux does.

const std = @import("std");

const abi = @import("abi");

test "syscall numbers are Linux's x86-64 numbers" {
    try std.testing.expectEqual(0, abi.Sys.read);
    try std.testing.expectEqual(1, abi.Sys.write);
    try std.testing.expectEqual(2, abi.Sys.open);
    try std.testing.expectEqual(3, abi.Sys.close);
    try std.testing.expectEqual(24, abi.Sys.sched_yield);
    try std.testing.expectEqual(60, abi.Sys.exit);
    try std.testing.expectEqual(186, abi.Sys.gettid);
    // The same numbers as the host's, when the host is x86-64 Linux.
    const builtin = @import("builtin");
    if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        const SYS = std.os.linux.SYS;
        try std.testing.expectEqual(@backingInt(SYS.read), abi.Sys.read);
        try std.testing.expectEqual(@backingInt(SYS.write), abi.Sys.write);
        try std.testing.expectEqual(@backingInt(SYS.open), abi.Sys.open);
        try std.testing.expectEqual(@backingInt(SYS.close), abi.Sys.close);
        try std.testing.expectEqual(@backingInt(SYS.sched_yield), abi.Sys.sched_yield);
        try std.testing.expectEqual(@backingInt(SYS.exit), abi.Sys.exit);
        try std.testing.expectEqual(@backingInt(SYS.gettid), abi.Sys.gettid);
    }
}

test "private syscall numbers are clear of Linux's and of the x32 bit" {
    try std.testing.expect(abi.Sys.PRIVATE_BASE > 100_000);
    try std.testing.expect(abi.Sys.myos_run < 0x4000_0000);
    try std.testing.expect(abi.Sys.myos_getchar != abi.Sys.myos_run);
}

test "error numbers are Linux's" {
    const E = std.os.linux.E;
    inline for (comptime std.meta.tags(abi.E)) |e| {
        try std.testing.expectEqual(@backingInt(@field(E, @tagName(e))), @backingInt(e));
    }
}

test "the errors MyOS returns" {
    try std.testing.expectEqual(11, @backingInt(abi.E.AGAIN));
    try std.testing.expectEqual(12, @backingInt(abi.E.NOMEM));
    try std.testing.expectEqual(24, @backingInt(abi.E.MFILE));
}

test "errors are returned as negative numbers" {
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFE), abi.err(.NOENT));
    try std.testing.expectEqual(@as(i64, -14), @as(i64, @bitCast(abi.err(.FAULT))));
    try std.testing.expectEqual(@as(i64, -38), @as(i64, @bitCast(abi.err(.NOSYS))));
}

test "isError and errno: only -4095..-1 are errors" {
    for (std.meta.tags(abi.E)) |e| {
        try std.testing.expect(abi.isError(abi.err(e)));
        try std.testing.expectEqual(@backingInt(e), abi.errno(abi.err(e)));
    }
    const minus = struct {
        fn of(n: i64) u64 {
            return @bitCast(-n);
        }
    }.of;
    try std.testing.expect(abi.isError(minus(1)));
    try std.testing.expect(abi.isError(minus(4095)));
    try std.testing.expectEqual(@as(u16, 4095), abi.errno(minus(4095)));
    // Large values are results (addresses in the upper half, say), not errors.
    try std.testing.expect(!abi.isError(minus(4096)));
    try std.testing.expect(!abi.isError(0));
    try std.testing.expect(!abi.isError(255));
    try std.testing.expect(!abi.isError(0x7FFF_FFFF_FFFF_FFFF));
    try std.testing.expectEqual(@as(u16, 0), abi.errno(0));
    try std.testing.expectEqual(@as(u16, 0), abi.errno(minus(4096)));
}

test "an exit status is 8 bits and never looks like an error" {
    try std.testing.expectEqual(@as(u64, 0), abi.exitStatus(0));
    try std.testing.expectEqual(@as(u64, 255), abi.exitStatus(255));
    try std.testing.expectEqual(@as(u64, 0), abi.exitStatus(256));
    try std.testing.expectEqual(@as(u64, 255), abi.exitStatus(~@as(u64, 0))); // exit(-1)
    try std.testing.expect(!abi.isError(abi.exitStatus(abi.err(.NOENT))));
}

test "open flags are Linux's" {
    const O = std.os.linux.O;
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return;
    try std.testing.expectEqual(@as(u32, @bitCast(O{ .ACCMODE = .WRONLY })), abi.O.WRONLY);
    try std.testing.expectEqual(@as(u32, @bitCast(O{ .ACCMODE = .RDWR })), abi.O.RDWR);
    try std.testing.expectEqual(@as(u32, @bitCast(O{ .CREAT = true })), abi.O.CREAT);
    try std.testing.expectEqual(@as(u32, @bitCast(O{ .TRUNC = true })), abi.O.TRUNC);
    try std.testing.expectEqual(@as(u32, @bitCast(O{ .APPEND = true })), abi.O.APPEND);
}
