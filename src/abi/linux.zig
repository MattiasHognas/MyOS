//! The user/kernel ABI: syscall numbers, error numbers and flags.
//!
//! MyOS's native syscall ABI is Linux's x86-64 ABI, so everything here has
//! Linux's values, except the private syscalls at `PRIVATE_BASE`. The kernel
//! and the user-space runtime (`app/lib.zig`, as the module `abi`) both
//! import this file, so the two cannot drift apart. It has no dependencies
//! and is tested on the host. `docs/syscalls.md` describes the calls.

/// Syscall numbers, passed in RAX.
pub const Sys = struct {
    /// `read(fd, buf, count) -> bytes read`; 0 at end of file.
    pub const read = 0;
    /// `write(fd, buf, count) -> bytes written`. Descriptors 1 and 2 are the console.
    pub const write = 1;
    /// `open(path, flags, mode) -> fd`. `path` is NUL-terminated; read-only.
    pub const open = 2;
    /// `close(fd) -> 0`.
    pub const close = 3;
    /// `sched_yield() -> 0`: give the CPU to another ready thread.
    pub const sched_yield = 24;
    /// `exit(status)`: terminate the calling process. Does not return.
    pub const exit = 60;
    /// `gettid() -> id` of the calling thread.
    pub const gettid = 186;

    /// First private (non-Linux) syscall number, far above Linux's range
    /// (under 500) and below the x32 bit (0x4000_0000). Milestone 6 replaces
    /// the private calls with Linux ones.
    pub const PRIVATE_BASE = 0x4D59_00; // "MY"
    /// `getchar() -> character`: block until a key is pressed.
    pub const myos_getchar = PRIVATE_BASE + 0;
    /// `run(path) -> exit status`: start the program at the NUL-terminated
    /// `path` and wait for it to exit.
    pub const myos_run = PRIVATE_BASE + 1;
};

/// Error numbers. A failing syscall returns the negated value in RAX.
pub const E = enum(u16) {
    /// No such file or directory.
    NOENT = 2,
    /// Exec format error: not a program MyOS can load.
    NOEXEC = 8,
    /// Bad file descriptor.
    BADF = 9,
    /// Resource temporarily unavailable: a limit on processes was reached.
    AGAIN = 11,
    /// Out of memory.
    NOMEM = 12,
    /// Bad address: a pointer argument is outside user space or not mapped.
    FAULT = 14,
    /// Invalid argument.
    INVAL = 22,
    /// Too many open files in this process.
    MFILE = 24,
    /// Read-only file system.
    ROFS = 30,
    /// File name too long.
    NAMETOOLONG = 36,
    /// Function not implemented: unknown syscall number.
    NOSYS = 38,
};

/// Largest error number a syscall result can encode, as on Linux: results
/// from -4095 to -1 are errors, everything else is a value.
pub const MAX_ERRNO = 4095;

/// The syscall result for error `e`: `-errno` as an unsigned register value.
pub fn err(e: E) u64 {
    return @bitCast(-@as(i64, @backingInt(e)));
}

/// True if the syscall result `ret` is an error (`-4095...-1`).
pub fn isError(ret: u64) bool {
    return ret > ~@as(u64, MAX_ERRNO);
}

/// The error number in the syscall result `ret`, or 0 if it is not an error.
pub fn errno(ret: u64) u16 {
    return if (isError(ret)) @intCast(0 -% ret) else 0;
}

/// Most bytes one `read` or `write` transfers; longer counts are shortened
/// to this (Linux's `MAX_RW_COUNT`: 2 GiB minus one page).
pub const MAX_RW_COUNT: u64 = 0x7FFF_F000;

/// Longest path, including the terminating NUL. Linux's `PATH_MAX` is 4096;
/// MyOS's is smaller because paths are copied to the 16 KiB kernel stack.
pub const PATH_MAX = 256;

/// `open` flags (Linux's values). Only read-only opens are supported.
pub const O = struct {
    pub const RDONLY = 0;
    pub const WRONLY = 1;
    pub const RDWR = 2;
    /// Mask of the access mode bits.
    pub const ACCMODE = 3;
    pub const CREAT = 0o100;
    pub const TRUNC = 0o1000;
    pub const APPEND = 0o2000;
};

/// The low 8 bits of an exit status are what the parent sees, as on Linux.
pub fn exitStatus(code: u64) u64 {
    return code & 0xFF;
}

/// Descriptors every process starts with: 0 (input), 1 and 2 (the console).
pub const STDIN = 0;
pub const STDOUT = 1;
pub const STDERR = 2;
