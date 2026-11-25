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
    /// `mmap(addr, length, prot, flags, fd, offset) -> address`: anonymous
    /// memory, given page by page as it is touched.
    pub const mmap = 9;
    /// `mprotect(addr, length, prot) -> 0`.
    pub const mprotect = 10;
    /// `munmap(addr, length) -> 0`.
    pub const munmap = 11;
    /// `brk(addr) -> end of the heap`: move it, or with 0 just ask.
    pub const brk = 12;
    /// `ioctl(fd, request, arg)`: no device has requests yet, so `ENOTTY`.
    pub const ioctl = 16;
    /// `writev(fd, iov, iovcnt) -> bytes written`: `write` from several buffers.
    pub const writev = 20;
    /// `sched_yield() -> 0`: give the CPU to another ready thread.
    pub const sched_yield = 24;
    /// `madvise(addr, length, advice) -> 0`.
    pub const madvise = 28;
    /// `exit(status)`: terminate the calling process. Does not return.
    pub const exit = 60;
    /// `arch_prctl(code, addr)`: get or set the thread's FS or GS base (`ARCH`).
    pub const arch_prctl = 158;
    /// `gettid() -> id` of the calling thread.
    pub const gettid = 186;
    /// `set_tid_address(ptr) -> id` of the calling thread; `ptr` is where
    /// the thread's exit is to be announced (with threads, milestone 7).
    pub const set_tid_address = 218;
    /// `exit_group(status)`: terminate the calling process, all threads.
    pub const exit_group = 231;

    /// First private (non-Linux) syscall number, far above Linux's range
    /// (under 500) and below the x32 bit (0x4000_0000). Milestone 6 replaces
    /// the private calls with Linux ones.
    pub const PRIVATE_BASE = 0x4D59_00; // "MY"
    /// `getchar() -> character`: block until a key is pressed.
    pub const myos_getchar = PRIVATE_BASE + 0;
    /// `run(path, argv, envp) -> exit status`: start the program at the
    /// NUL-terminated `path` and wait for it to exit. `argv` and `envp` are
    /// NULL-terminated arrays of NUL-terminated strings, as for `execve`;
    /// either may be NULL (no environment; the path as the only argument).
    pub const myos_run = PRIVATE_BASE + 1;
};

/// Error numbers. A failing syscall returns the negated value in RAX.
pub const E = enum(u16) {
    /// Operation not permitted.
    PERM = 1,
    /// No such file or directory.
    NOENT = 2,
    /// Argument list too long.
    @"2BIG" = 7,
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
    /// Already exists.
    EXIST = 17,
    /// No such device: the object cannot be mapped.
    NODEV = 19,
    /// Invalid argument.
    INVAL = 22,
    /// Not a terminal: the descriptor has no such `ioctl`.
    NOTTY = 25,
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

/// `arch_prctl` codes.
pub const ARCH = struct {
    pub const SET_GS = 0x1001;
    pub const SET_FS = 0x1002;
    pub const GET_FS = 0x1003;
    pub const GET_GS = 0x1004;
};

/// One buffer of a `writev`: `struct iovec`.
pub const IoVec = extern struct {
    base: u64,
    len: u64,
};
/// Most buffers one `writev` takes (Linux's `IOV_MAX`).
pub const IOV_MAX = 1024;

/// Keys of the auxiliary vector a program finds on its initial stack, above
/// the environment: pairs of key and value, ended by `NULL`.
pub const AT = struct {
    pub const NULL = 0;
    /// Address of the program headers in memory, their size and number.
    pub const PHDR = 3;
    pub const PHENT = 4;
    pub const PHNUM = 5;
    pub const PAGESZ = 6;
    /// Where the interpreter was loaded; 0 without one.
    pub const BASE = 7;
    pub const FLAGS = 8;
    pub const ENTRY = 9;
    pub const UID = 11;
    pub const EUID = 12;
    pub const GID = 13;
    pub const EGID = 14;
    /// Address of the string "x86_64".
    pub const PLATFORM = 15;
    /// CPUID.1:EDX.
    pub const HWCAP = 16;
    /// Clock ticks per second for `times`.
    pub const CLKTCK = 17;
    pub const SECURE = 23;
    /// Address of 16 random bytes.
    pub const RANDOM = 25;
    /// Address of the path the program was started with.
    pub const EXECFN = 31;
};

/// Most bytes the arguments, environment and auxiliary vector of a new
/// program may take on its stack together.
pub const ARG_MAX = 8192;
/// Most arguments and environment strings together.
pub const ARG_COUNT_MAX = 256;

/// `mmap` and `mprotect` permissions.
pub const PROT = struct {
    pub const NONE = 0;
    pub const READ = 1;
    pub const WRITE = 2;
    pub const EXEC = 4;
};

/// `mmap` flags.
pub const MAP = struct {
    pub const SHARED = 0x01;
    pub const PRIVATE = 0x02;
    pub const FIXED = 0x10;
    pub const ANONYMOUS = 0x20;
    pub const NORESERVE = 0x4000;
    pub const STACK = 0x20000;
    pub const FIXED_NOREPLACE = 0x100000;
};

/// `madvise` advice.
pub const MADV = struct {
    pub const DONTNEED = 4;
    pub const FREE = 8;
};
