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
    // Every number MyOS has a name for is the one Zig's standard library
    // has under that name (its table is generated from Linux's).
    var compared: usize = 0;
    inline for (comptime std.meta.declarations(abi.Sys)) |name| {
        const value = @field(abi.Sys, name);
        if (@TypeOf(value) == comptime_int or @TypeOf(value) == u64 or @TypeOf(value) == usize) {
            if (@hasField(std.os.linux.SYS, name)) {
                const want = @backingInt(@field(std.os.linux.SYS, name));
                if (want != value) {
                    std.debug.print("Sys.{s} is {d}, Linux's is {d}\n", .{ name, value, want });
                    return error.TestUnexpectedResult;
                }
                compared += 1;
            }
        }
    }
    try std.testing.expect(compared >= 129); // all of them, at the time of writing
}

test "private syscall numbers are clear of Linux's and of the x32 bit" {
    try std.testing.expect(abi.Sys.PRIVATE_BASE > 100_000);
    try std.testing.expect(abi.Sys.PRIVATE_BASE + 0x1000 < 0x4000_0000);
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

/// `@sizeOf(T)` and the offsets of its fields, against Linux's x86-64
/// layout (from the kernel's `include/uapi` headers): a field in the
/// wrong place reads as garbage in a program built for Linux.
fn expectLayout(comptime T: type, size: usize, offsets: anytype) !void {
    try std.testing.expectEqual(size, @sizeOf(T));
    inline for (offsets) |o| {
        if (@offsetOf(T, o[0]) != o[1]) {
            std.debug.print("{s}.{s} is at {d}, Linux has it at {d}\n", .{ @typeName(T), o[0], @offsetOf(T, o[0]), o[1] });
            return error.TestUnexpectedResult;
        }
    }
}

test "struct layouts are Linux's x86-64 ones" {
    try expectLayout(abi.IoVec, 16, .{ .{ "base", 0 }, .{ "len", 8 } });
    // The kernel's `struct sigaction` (not the C library's).
    try expectLayout(abi.SigAction, 32, .{ .{ "handler", 0 }, .{ "flags", 8 }, .{ "restorer", 16 }, .{ "mask", 24 } });
    try expectLayout(abi.SigStack, 24, .{ .{ "sp", 0 }, .{ "flags", 8 }, .{ "size", 16 } });
    try expectLayout(abi.PollFd, 8, .{ .{ "fd", 0 }, .{ "events", 4 }, .{ "revents", 6 } });
    try expectLayout(abi.TimeSpec, 16, .{ .{ "sec", 0 }, .{ "nsec", 8 } });
    try expectLayout(abi.Stat, 144, .{
        .{ "dev", 0 },    .{ "ino", 8 },      .{ "nlink", 16 },  .{ "mode", 24 },
        .{ "uid", 28 },   .{ "gid", 32 },     .{ "rdev", 40 },   .{ "size", 48 },
        .{ "blksize", 56 }, .{ "blocks", 64 }, .{ "atime", 72 }, .{ "mtime", 88 },
        .{ "ctime", 104 },
    });
    try expectLayout(abi.UtsName, 390, .{ .{ "sysname", 0 }, .{ "nodename", 65 }, .{ "release", 130 }, .{ "version", 195 }, .{ "machine", 260 }, .{ "domainname", 325 } });
    try expectLayout(abi.RLimit, 16, .{ .{ "cur", 0 }, .{ "max", 8 } });
    try expectLayout(abi.SysInfo, 112, .{
        .{ "uptime", 0 },     .{ "loads", 8 },     .{ "totalram", 32 }, .{ "freeram", 40 },
        .{ "sharedram", 48 }, .{ "bufferram", 56 }, .{ "totalswap", 64 }, .{ "freeswap", 72 },
        .{ "procs", 80 },     .{ "totalhigh", 88 }, .{ "freehigh", 96 }, .{ "mem_unit", 104 },
    });
    try expectLayout(abi.StatFs, 120, .{
        .{ "type", 0 },   .{ "bsize", 8 }, .{ "blocks", 16 },  .{ "bfree", 24 },  .{ "bavail", 32 },
        .{ "files", 40 }, .{ "ffree", 48 }, .{ "fsid", 56 },   .{ "namelen", 64 }, .{ "frsize", 72 },
        .{ "flags", 80 }, .{ "spare", 88 },
    });
    // `clone_args` as first published (CLONE_ARGS_SIZE_VER0).
    try expectLayout(abi.CloneArgs, 64, .{
        .{ "flags", 0 },       .{ "pidfd", 8 }, .{ "child_tid", 16 },  .{ "parent_tid", 24 },
        .{ "exit_signal", 32 }, .{ "stack", 40 }, .{ "stack_size", 48 }, .{ "tls", 56 },
    });
    // The kernel's `struct termios` of TCGETS (the C library's is larger).
    try expectLayout(abi.Termios, 36, .{ .{ "iflag", 0 }, .{ "oflag", 4 }, .{ "cflag", 8 }, .{ "lflag", 12 }, .{ "line", 16 }, .{ "cc", 17 } });
    try expectLayout(abi.WinSize, 8, .{ .{ "rows", 0 }, .{ "cols", 2 }, .{ "xpixel", 4 }, .{ "ypixel", 6 } });
    // Packed on x86-64 (`__EPOLL_PACKED`).
    try expectLayout(abi.EpollEvent, 12, .{ .{ "events", 0 }, .{ "data", 4 } });
    try expectLayout(abi.SignalfdSiginfo, 128, .{
        .{ "signo", 0 }, .{ "errno", 4 },   .{ "code", 8 },     .{ "pid", 12 },   .{ "uid", 16 },
        .{ "fd", 20 },   .{ "tid", 24 },    .{ "band", 28 },    .{ "overrun", 32 }, .{ "trapno", 36 },
        .{ "status", 40 }, .{ "int", 44 },  .{ "ptr", 48 },     .{ "utime", 56 }, .{ "stime", 64 },
        .{ "addr", 72 }, .{ "addr_lsb", 80 }, .{ "syscall", 84 }, .{ "call_addr", 88 }, .{ "arch", 96 },
    });
    try expectLayout(abi.StatxTimestamp, 16, .{ .{ "sec", 0 }, .{ "nsec", 8 } });
    try expectLayout(abi.Statx, 256, .{
        .{ "mask", 0 },        .{ "blksize", 4 },    .{ "attributes", 8 },       .{ "nlink", 16 },
        .{ "uid", 20 },        .{ "gid", 24 },       .{ "mode", 28 },            .{ "ino", 32 },
        .{ "size", 40 },       .{ "blocks", 48 },    .{ "attributes_mask", 56 }, .{ "atime", 64 },
        .{ "btime", 80 },      .{ "ctime", 96 },     .{ "mtime", 112 },          .{ "rdev_major", 128 },
        .{ "rdev_minor", 132 }, .{ "dev_major", 136 }, .{ "dev_minor", 140 },
    });
}
