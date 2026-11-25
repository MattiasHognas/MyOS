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
    /// `fstat(fd, statbuf) -> 0`.
    pub const fstat = 5;
    /// `poll(fds, nfds, timeout_ms) -> number of descriptors with events`.
    pub const poll = 7;
    /// `lseek(fd, offset, whence) -> new offset`.
    pub const lseek = 8;
    /// `mmap(addr, length, prot, flags, fd, offset) -> address`: anonymous
    /// memory, given page by page as it is touched.
    pub const mmap = 9;
    /// `mprotect(addr, length, prot) -> 0`.
    pub const mprotect = 10;
    /// `munmap(addr, length) -> 0`.
    pub const munmap = 11;
    /// `brk(addr) -> end of the heap`: move it, or with 0 just ask.
    pub const brk = 12;
    /// `rt_sigaction(signal, act, oldact, sigsetsize) -> 0`: what a signal does.
    pub const rt_sigaction = 13;
    /// `rt_sigprocmask(how, set, oldset, sigsetsize) -> 0`: the thread's blocked signals.
    pub const rt_sigprocmask = 14;
    /// `pread64(fd, buf, count, offset) -> bytes read`, leaving the file's offset.
    pub const pread64 = 17;
    /// `ioctl(fd, request, arg)`: no device has requests yet, so `ENOTTY`.
    pub const ioctl = 16;
    /// `writev(fd, iov, iovcnt) -> bytes written`: `write` from several buffers.
    pub const writev = 20;
    /// `sched_yield() -> 0`: give the CPU to another ready thread.
    pub const sched_yield = 24;
    /// `madvise(addr, length, advice) -> 0`.
    pub const madvise = 28;
    /// `nanosleep(request, remaining) -> 0`.
    pub const nanosleep = 35;
    /// `getpid() -> id` of the calling process.
    pub const getpid = 39;
    /// `clone(flags, stack, parent_tid, child_tid, tls) -> thread id`: a new thread.
    pub const clone = 56;
    /// `exit(status)`: terminate the calling thread; the process with it
    /// if it was the last. Does not return.
    pub const exit = 60;
    /// `kill(pid, signal)`.
    pub const kill = 62;
    /// `uname(buf) -> 0`.
    pub const uname = 63;
    /// `fcntl(fd, command, arg)`.
    pub const fcntl = 72;
    /// `gettimeofday(tv, tz) -> 0`.
    pub const gettimeofday = 96;
    /// `sigaltstack(ss, old_ss) -> 0`: the stack signal handlers may run on.
    pub const sigaltstack = 131;
    /// `arch_prctl(code, addr)`: get or set the thread's FS or GS base (`ARCH`).
    pub const arch_prctl = 158;
    /// `gettid() -> id` of the calling thread.
    pub const gettid = 186;
    /// `tkill(tid, signal)`.
    pub const tkill = 200;
    /// `futex(addr, op, value, timeout, addr2, value3)`.
    pub const futex = 202;
    /// `sched_getaffinity(pid, size, mask) -> bytes written`.
    pub const sched_getaffinity = 204;
    /// `set_tid_address(ptr) -> id` of the calling thread; `ptr` is where
    /// the thread's exit is to be announced.
    pub const set_tid_address = 218;
    /// `clock_gettime(clock, timespec) -> 0`.
    pub const clock_gettime = 228;
    /// `clock_nanosleep(clock, flags, request, remaining) -> 0`.
    pub const clock_nanosleep = 230;
    /// `exit_group(status)`: terminate the calling process, all threads.
    pub const exit_group = 231;
    /// `tgkill(pid, tid, signal)`.
    pub const tgkill = 234;
    /// `openat(dirfd, path, flags, mode) -> fd`.
    pub const openat = 257;
    /// `prlimit64(pid, resource, new, old) -> 0`.
    pub const prlimit64 = 302;
    /// `getrandom(buf, length, flags) -> bytes written`.
    pub const getrandom = 318;

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
    /// No such process.
    SRCH = 3,
    /// Interrupted: the call was cut short.
    INTR = 4,
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
    /// Illegal seek: the descriptor has no position.
    SPIPE = 29,
    /// The time ran out.
    TIMEDOUT = 110,
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

/// Signal numbers go from 1 to this.
pub const NSIG = 64;
pub const SIGKILL = 9;
pub const SIGSTOP = 19;
/// A signal mask is this many bytes: one bit per signal.
pub const SIGSET_SIZE = 8;

/// `struct sigaction` as the kernel takes it from `rt_sigaction`.
pub const SigAction = extern struct {
    /// The handler's address, or `SIG_DFL` (0) or `SIG_IGN` (1).
    handler: u64 = 0,
    flags: u64 = 0,
    restorer: u64 = 0,
    mask: u64 = 0,
};

/// `rt_sigprocmask`'s `how`.
pub const SIG = struct {
    pub const BLOCK = 0;
    pub const UNBLOCK = 1;
    pub const SETMASK = 2;
};

/// `stack_t` of `sigaltstack`.
pub const SigStack = extern struct {
    sp: u64 = 0,
    flags: i32 = SS.DISABLE,
    size: u64 = 0,
};

pub const SS = struct {
    pub const ONSTACK = 1;
    pub const DISABLE = 2;
    /// Smallest alternate stack (`MINSIGSTKSZ`).
    pub const MIN_SIZE = 2048;
};

/// `struct pollfd`.
pub const PollFd = extern struct {
    fd: i32,
    events: i16,
    revents: i16,
};

pub const POLL = struct {
    pub const IN = 0x001;
    pub const OUT = 0x004;
    pub const NVAL = 0x020;
};

/// `struct timespec`.
pub const TimeSpec = extern struct {
    sec: i64,
    nsec: i64,
};

pub const CLOCK = struct {
    pub const REALTIME = 0;
    pub const MONOTONIC = 1;
    pub const PROCESS_CPUTIME_ID = 2;
    pub const THREAD_CPUTIME_ID = 3;
    pub const MONOTONIC_RAW = 4;
    pub const REALTIME_COARSE = 5;
    pub const MONOTONIC_COARSE = 6;
    pub const BOOTTIME = 7;
};

/// `futex` operations: the low bits of `op`, and its flags.
pub const FUTEX = struct {
    pub const WAIT = 0;
    pub const WAKE = 1;
    pub const REQUEUE = 3;
    pub const CMP_REQUEUE = 4;
    pub const WAIT_BITSET = 9;
    pub const WAKE_BITSET = 10;
    pub const CMD_MASK = 0x7F;
    pub const PRIVATE = 0x80;
    pub const CLOCK_REALTIME = 0x100;
};

/// `openat`'s "relative to the current directory".
pub const AT_FDCWD: i32 = -100;

/// `struct stat`.
pub const Stat = extern struct {
    dev: u64 = 0,
    ino: u64 = 0,
    nlink: u64 = 1,
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    _pad0: u32 = 0,
    rdev: u64 = 0,
    size: i64 = 0,
    blksize: i64 = 4096,
    blocks: i64 = 0,
    atime: TimeSpec = .{ .sec = 0, .nsec = 0 },
    mtime: TimeSpec = .{ .sec = 0, .nsec = 0 },
    ctime: TimeSpec = .{ .sec = 0, .nsec = 0 },
    _unused: [3]i64 = .{ 0, 0, 0 },
};

/// File types in `Stat.mode`.
pub const S = struct {
    pub const IFCHR = 0o020000;
    pub const IFREG = 0o100000;
};

pub const SEEK = struct {
    pub const SET = 0;
    pub const CUR = 1;
    pub const END = 2;
};

/// `struct utsname`: six strings of 65 bytes.
pub const UtsName = extern struct {
    sysname: [65]u8 = @splat(0),
    nodename: [65]u8 = @splat(0),
    release: [65]u8 = @splat(0),
    version: [65]u8 = @splat(0),
    machine: [65]u8 = @splat(0),
    domainname: [65]u8 = @splat(0),
};

/// `struct rlimit`.
pub const RLimit = extern struct {
    cur: u64,
    max: u64,
};
pub const RLIM_INFINITY: u64 = ~@as(u64, 0);
pub const RLIMIT = struct {
    pub const STACK = 3;
    pub const NOFILE = 7;
};
