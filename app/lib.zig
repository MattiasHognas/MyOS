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

// --- Startup ---------------------------------------------------------------
//
// A program starts the way a Linux program does: the stack pointer is on a
// 16-byte boundary and points at `argc`, followed by the argument pointers,
// NULL, the environment pointers, NULL, and the auxiliary vector
// (`docs/syscalls.md`). `_start` below notes where that is and calls the
// program's `pub fn main() noreturn`. For that to be linked in, the program
// names this file at compile time: `comptime { _ = lib; }`. A program that
// must control its very first instructions defines `pub export fn _start`
// itself instead.

const root = @import("root");

/// True if the program brings its own `_start` (which must be `pub`).
const own_start = @hasDecl(root, "_start");

comptime {
    if (!own_start) {
        @export(&start, .{ .name = "_start" });
        @export(&startMain, .{ .name = "myosStart" });
    }
}

fn start() callconv(.naked) noreturn {
    asm volatile (
        \\ mov %%rsp, %%rdi
        \\ call myosStart
        \\ ud2
    );
}

/// The initial stack pointer, for `argv`, `environ` and `auxValue`.
var initial_stack: [*]const usize = undefined;

fn startMain(sp: [*]const usize) callconv(.c) noreturn {
    initial_stack = sp;
    root.main();
}

/// Tell the runtime where the initial stack is. Only for a program with
/// its own `_start`, which passes the stack pointer it was entered with.
pub fn setInitialStack(sp: [*]const usize) void {
    initial_stack = sp;
}

/// The program's arguments; the first is the name it was started under.
pub fn argv() []const [*:0]const u8 {
    const argc = initial_stack[0];
    const first: [*]const [*:0]const u8 = @ptrCast(initial_stack + 1);
    return first[0..argc];
}

/// The program's environment: strings of the form `NAME=value`.
pub fn environ() []const [*:0]const u8 {
    const first: [*]const ?[*:0]const u8 = @ptrCast(initial_stack + 1 + initial_stack[0] + 1);
    var n: usize = 0;
    while (first[n] != null) n += 1;
    return @ptrCast(first[0..n]);
}

/// The environment as the NULL-terminated array the program was started
/// with, to hand on to a program it starts.
pub fn environPointers() [*]const ?[*:0]const u8 {
    return @ptrCast(initial_stack + 1 + initial_stack[0] + 1);
}

/// The value the kernel gave for key `key` (`abi.AT`) in the auxiliary
/// vector, or null if it gave none.
pub fn auxValue(key: usize) ?usize {
    var at = initial_stack + 1 + initial_stack[0] + 1 + environ().len + 1;
    while (at[0] != abi.AT.NULL) : (at += 2) {
        if (at[0] == key) return at[1];
    }
    return null;
}

/// Start the program at `path` with the arguments `arg_list` and the
/// environment `env_list` (each a NULL-terminated array of strings, or null)
/// and wait for it to exit. Returns as `run` does.
pub fn runArgs(path: [*:0]const u8, arg_list: ?[*]const ?[*:0]const u8, env_list: ?[*]const ?[*:0]const u8) u64 {
    return syscall(Sys.myos_run, @intFromPtr(path), @intFromPtr(arg_list), @intFromPtr(env_list));
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
