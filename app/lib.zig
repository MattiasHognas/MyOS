const std = @import("std");

pub const ERR = std.math.maxInt(u64);

pub fn syscall(n: u64, a1: u64, a2: u64, a3: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [n] "{rax}" (n),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

pub fn write(s: []const u8) void {
    _ = syscall(0, @intFromPtr(s.ptr), s.len, 0);
}

pub fn exit(code: u64) noreturn {
    _ = syscall(1, code, 0, 0);
    unreachable;
}

pub fn open(path: []const u8) u64 {
    return syscall(4, @intFromPtr(path.ptr), path.len, 0);
}

pub fn read(fd: u64, buf: []u8) u64 {
    return syscall(5, fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn close(fd: u64) void {
    _ = syscall(6, fd, 0, 0);
}

pub fn getChar() u8 {
    return @truncate(syscall(7, 0, 0, 0));
}

/// Start a program and wait for it. Returns its exit code, or ERR if it couldn't start.
pub fn run(path: []const u8) u64 {
    return syscall(8, @intFromPtr(path.ptr), path.len, 0);
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    write(std.fmt.bufPrint(&buf, fmt, args) catch "<print overflow>\n");
}

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, _: ?usize) noreturn {
    print("panic: {s}\n", .{msg});
    exit(1);
}
