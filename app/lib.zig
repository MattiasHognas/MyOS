//! Minimal user-space runtime for MyOS programs: syscall wrappers, `print`
//! and a panic handler. Syscall numbers must match `src/kernel/syscall.zig`.

const std = @import("std");

/// Value returned by syscalls on failure (-1 as u64).
pub const ERR = std.math.maxInt(u64);

/// Invoke syscall `n` with up to three arguments and return the result from RAX.
pub fn syscall(n: u64, a1: u64, a2: u64, a3: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [n] "{rax}" (n),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

/// Write `s` (at most 4 KiB) to the console.
pub fn write(s: []const u8) void {
    _ = syscall(0, @intFromPtr(s.ptr), s.len, 0);
}

/// Terminate the program with exit code `code`. Never returns.
pub fn exit(code: u64) noreturn {
    _ = syscall(1, code, 0, 0);
    unreachable;
}

/// Open the file at `path` for reading. Returns a file descriptor, or `ERR`.
pub fn open(path: []const u8) u64 {
    return syscall(4, @intFromPtr(path.ptr), path.len, 0);
}

/// Read up to `buf.len` bytes from `fd` into `buf`. Returns the number of
/// bytes read, 0 at end of file, or `ERR`.
pub fn read(fd: u64, buf: []u8) u64 {
    return syscall(5, fd, @intFromPtr(buf.ptr), buf.len);
}

/// Close file descriptor `fd`.
pub fn close(fd: u64) void {
    _ = syscall(6, fd, 0, 0);
}

/// Give the CPU to another ready thread.
pub fn yield() void {
    _ = syscall(2, 0, 0, 0);
}

/// Block until a key is pressed and return its character.
pub fn getChar() u8 {
    return @truncate(syscall(7, 0, 0, 0));
}

/// Start the program at `path` and wait for it to exit. Returns its exit
/// code, or `ERR` if it couldn't be started.
pub fn run(path: []const u8) u64 {
    return syscall(8, @intFromPtr(path.ptr), path.len, 0);
}

/// Format `args` with `fmt` and write the result to the console. Output
/// longer than 256 bytes is replaced by `<print overflow>`.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    write(std.fmt.bufPrint(&buf, fmt, args) catch "<print overflow>\n");
}

/// Panic handler for user programs: print the message and exit with code 1.
pub const panic = std.debug.FullPanic(onPanic);

/// Implementation behind `panic`.
fn onPanic(msg: []const u8, _: ?usize) noreturn {
    print("panic: {s}\n", .{msg});
    exit(1);
}
