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

/// Map `len` bytes of zeroed memory with the permissions `prot`
/// (`abi.PROT`), at `addr` if given and free, or with `abi.MAP.FIXED` in
/// `flags` exactly there. Private and anonymous are added to `flags`.
/// Returns the address, or an error. The memory is not there until it is
/// touched, so a large mapping costs nothing until it is used.
pub fn mmap(addr: u64, len: u64, prot: u64, flags: u64) u64 {
    return syscall6(Sys.mmap, addr, len, prot, flags | abi.MAP.PRIVATE | abi.MAP.ANONYMOUS, ~@as(u64, 0), 0);
}

/// Unmap `len` bytes at `addr`. Returns 0, or an error.
pub fn munmap(addr: u64, len: u64) u64 {
    return syscall(Sys.munmap, addr, len, 0);
}

/// Change the permissions of `len` bytes at `addr`. Returns 0, or an error.
pub fn mprotect(addr: u64, len: u64, prot: u64) u64 {
    return syscall(Sys.mprotect, addr, len, prot);
}

/// Move the end of the heap to `addr` (0: just ask) and return where it is.
pub fn brk(addr: u64) u64 {
    return syscall(Sys.brk, addr, 0, 0);
}

/// Pages from the kernel, for the allocator.
const MappedPages = struct {
    pub fn map(len: usize) ?[*]u8 {
        const addr = mmap(0, len, abi.PROT.READ | abi.PROT.WRITE, 0);
        return if (isError(addr)) null else @ptrFromInt(addr);
    }

    pub fn unmap(ptr: [*]u8, len: usize) void {
        _ = munmap(@intFromPtr(ptr), len);
    }
};

var heap_state: @import("alloc.zig").Allocator(MappedPages) = .{};

/// The program's heap: a `std.mem.Allocator` on top of `mmap`
/// (`alloc.zig`), for the standard library's containers and for
/// `allocator.alloc`/`create`/`free`. For one thread; a program with
/// threads puts a lock around its use.
pub const allocator: std.mem.Allocator = heap_state.allocator();

/// Give the CPU to another ready thread.
pub fn yield() void {
    _ = syscall(Sys.sched_yield, 0, 0, 0);
}

/// The calling thread's ID.
pub fn gettid() u64 {
    return syscall(Sys.gettid, 0, 0, 0);
}

/// Read the terminal's settings into `t`, or set them from it. Returns 0,
/// or an error (`ENOTTY` for a descriptor that is no terminal).
pub fn tcgetattr(fd: u64, t: *abi.Termios) u64 {
    return syscall(Sys.ioctl, fd, abi.TIOC.TCGETS, @intFromPtr(t));
}

pub fn tcsetattr(fd: u64, t: *const abi.Termios) u64 {
    return syscall(Sys.ioctl, fd, abi.TIOC.TCSETS, @intFromPtr(t));
}

/// Wait for one key and return it: the terminal without line editing and
/// echo for the time it takes. Null at the end of input or on an error.
pub fn readKey() ?u8 {
    var saved: abi.Termios = undefined;
    if (tcgetattr(0, &saved) != 0) return null;
    var raw = saved;
    raw.lflag &= ~@as(u32, abi.TERMIOS.ICANON | abi.TERMIOS.ECHO);
    _ = tcsetattr(0, &raw);
    defer _ = tcsetattr(0, &saved);
    var c: [1]u8 = undefined;
    return if (read(0, &c) == 1) c[0] else null;
}

/// Start the program at `path` and wait for it to exit. Returns its exit
/// status (0-255; 255 if a signal ended it, a fault included), or an error
/// if it couldn't be started: of `fork`, or of `execve` in the child.
pub fn run(path: [*:0]const u8) u64 {
    return runArgs(path, null, null);
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
///
/// `fork`, `execve` in the child and `wait4` in the parent, as a C
/// library's `posix_spawn` does it: an `execve` that fails writes its
/// error to a pipe that closes itself on a successful one.
pub fn runArgs(path: [*:0]const u8, arg_list: ?[*]const ?[*:0]const u8, env_list: ?[*]const ?[*:0]const u8) u64 {
    var pfd: [2]i32 = undefined;
    const piped = syscall(Sys.pipe2, @intFromPtr(&pfd), abi.O.CLOEXEC, 0);
    if (isError(piped)) return piped;
    const pid = syscall(Sys.fork, 0, 0, 0);
    if (isError(pid)) {
        _ = close(@intCast(pfd[0]));
        _ = close(@intCast(pfd[1]));
        return pid;
    }
    if (pid == 0) {
        const only = [_:null]?[*:0]const u8{path};
        const none = [_:null]?[*:0]const u8{};
        const argv_ptr: usize = if (arg_list) |a| @intFromPtr(a) else @intFromPtr(&only);
        const envp_ptr: usize = if (env_list) |e| @intFromPtr(e) else @intFromPtr(&none);
        const rc = syscall(Sys.execve, @intFromPtr(path), argv_ptr, envp_ptr);
        _ = syscall(Sys.write, @intCast(pfd[1]), @intFromPtr(&rc), @sizeOf(u64));
        _ = syscall(Sys.exit_group, 127, 0, 0);
        unreachable;
    }
    _ = close(@intCast(pfd[1]));
    var failure: u64 = 0;
    const n = read(@intCast(pfd[0]), std.mem.asBytes(&failure));
    _ = close(@intCast(pfd[0]));
    var status: u32 = 0;
    while (true) {
        const rc = syscall6(Sys.wait4, pid, @intFromPtr(&status), 0, 0, 0, 0);
        if (!isError(rc) or rc != err(.INTR)) break;
    }
    if (n == @sizeOf(u64)) return failure; // `execve` said why it could not
    if (status & 0x7F != 0) return 255; // a signal ended it
    return (status >> 8) & 0xFF;
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
