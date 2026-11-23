//! Minimal user-space runtime for MyOS programs: syscall wrappers, `print`
//! and a panic handler.
//!
//! The syscall ABI is Linux's for x86-64 (`docs/syscalls.md`); the numbers
//! and error values come from the same file the kernel uses (`abi`, which is
//! `src/abi/linux.zig`). A failing call returns a negated error number: test
//! with `isError`, compare with `err(.NOENT)`.

const std = @import("std");
pub const abi = @import("abi");

pub const Sys = abi.Sys;
pub const E = abi.E;
pub const err = abi.err;
pub const isError = abi.isError;
pub const errno = abi.errno;

/// Invoke syscall `n` with six arguments and return the result from RAX.
/// The kernel preserves every register except RAX, RCX and R11.
pub fn syscall6(n: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [n] "{rax}" (n),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
          [a5] "{r8}" (a5),
          [a6] "{r9}" (a6),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

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

/// Write `s` to the console (descriptor 1).
pub fn write(s: []const u8) void {
    _ = syscall(Sys.write, abi.STDOUT, @intFromPtr(s.ptr), s.len);
}

/// Terminate the program with exit status `code` (0-255). Never returns.
pub fn exit(code: u64) noreturn {
    _ = syscall(Sys.exit, code, 0, 0);
    unreachable;
}

/// Open the file at `path` for reading. Returns a file descriptor, or an error.
pub fn open(path: [*:0]const u8) u64 {
    return syscall(Sys.open, @intFromPtr(path), abi.O.RDONLY, 0);
}

/// Read up to `buf.len` bytes from `fd` into `buf`. Returns the number of
/// bytes read, 0 at end of file, or an error.
pub fn read(fd: u64, buf: []u8) u64 {
    return syscall(Sys.read, fd, @intFromPtr(buf.ptr), buf.len);
}

/// Close file descriptor `fd`. Returns 0, or an error.
pub fn close(fd: u64) u64 {
    return syscall(Sys.close, fd, 0, 0);
}

/// Give the CPU to another ready thread.
pub fn yield() void {
    _ = syscall(Sys.sched_yield, 0, 0, 0);
}

/// The calling thread's ID.
pub fn gettid() u64 {
    return syscall(Sys.gettid, 0, 0, 0);
}

/// Block until a key is pressed and return its character.
pub fn getChar() u8 {
    return @truncate(syscall(Sys.myos_getchar, 0, 0, 0));
}

/// Start the program at `path` and wait for it to exit. Returns its exit
/// status (0-255; 255 if the kernel killed it), or an error if it couldn't
/// be started.
pub fn run(path: [*:0]const u8) u64 {
    return syscall(Sys.myos_run, @intFromPtr(path), 0, 0);
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
