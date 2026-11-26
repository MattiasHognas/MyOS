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
    /// `dup(fd) -> new fd`, and `dup2(old, new)`.
    pub const dup = 32;
    pub const dup2 = 33;
    /// `stat(path, statbuf)` and `lstat`, which does not follow a link at
    /// the end of the path.
    pub const stat = 4;
    pub const lstat = 6;
    /// `access(path, mode) -> 0`: whether the file is there and may be
    /// used that way.
    pub const access = 21;
    /// `pipe(fds) -> 0`: a pipe's reading and writing descriptors.
    pub const pipe = 22;
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
    /// `sched_setaffinity(pid, size, mask) -> 0`: accepted if the mask
    /// has a CPU that is up; threads run on any CPU all the same.
    pub const sched_setaffinity = 203;
    /// `time(tloc) -> seconds`.
    pub const time = 201;
    /// `socket(domain, type, protocol)`: there is no networking yet
    /// (`EAFNOSUPPORT`).
    pub const socket = 41;
    /// `readv(fd, iov, iovcnt) -> bytes read`: `read` into several buffers.
    pub const readv = 19;
    /// `pwrite64(fd, buf, count, offset)`: `write` at an offset.
    pub const pwrite64 = 18;
    /// `fsync(fd)` and `fdatasync(fd)`: nothing is ever unwritten.
    pub const fsync = 74;
    pub const fdatasync = 75;
    /// `truncate(path, length)` and `ftruncate(fd, length)`.
    pub const truncate = 76;
    pub const ftruncate = 77;
    /// `rename(old, new)`, `mkdir(path, mode)`, `rmdir(path)`,
    /// `unlink(path)`, and the same relative to directory descriptors.
    pub const rename = 82;
    pub const mkdir = 83;
    pub const rmdir = 84;
    pub const unlink = 87;
    pub const mkdirat = 258;
    pub const unlinkat = 263;
    pub const renameat = 264;
    pub const renameat2 = 316;
    /// `fchmod(fd, mode)`: there are no permissions to change; accepted
    /// for a file that can be written, `EROFS` otherwise.
    pub const fchmod = 91;
    /// `mknodat(dirfd, path, mode, dev)`: no devices or FIFOs can be made.
    pub const mknodat = 259;
    /// `memfd_create(name, flags)`: files that exist only in memory are
    /// not offered yet (`ENOSYS`).
    pub const memfd_create = 319;
    /// `chdir(path)` and `fchdir(fd)`: the working directory.
    pub const chdir = 80;
    pub const fchdir = 81;
    /// `getdents64(fd, buf, count) -> bytes`: the next entries of a directory.
    pub const getdents64 = 217;
    /// `getcwd(buf, size) -> length with the NUL`.
    pub const getcwd = 79;
    /// `readlink(path, buf, size)`: there are no symbolic links (`EINVAL`).
    pub const readlink = 89;
    /// `gettimeofday(tv, tz) -> 0`.
    pub const gettimeofday = 96;
    /// `getsid(pid) -> session ID`: every process is its own session.
    pub const getsid = 124;
    /// The scheduling policy calls. There is one policy, `SCHED_OTHER`,
    /// with priority 0: `sched_setparam(pid, param)`,
    /// `sched_getparam(pid, param)`, `sched_setscheduler(pid, policy,
    /// param)`, `sched_getscheduler(pid) -> policy`,
    /// `sched_get_priority_max(policy)` and `_min`.
    pub const sched_setparam = 142;
    pub const sched_getparam = 143;
    pub const sched_setscheduler = 144;
    pub const sched_getscheduler = 145;
    pub const sched_get_priority_max = 146;
    pub const sched_get_priority_min = 147;
    /// `sysinfo(info) -> 0`: memory and uptime.
    pub const sysinfo = 99;
    /// `mremap(old, old_size, new_size, flags, new) -> address`: grow or
    /// shrink a mapping where it is.
    pub const mremap = 25;
    /// `sigaltstack(ss, old_ss) -> 0`: the stack signal handlers may run on.
    pub const sigaltstack = 131;
    /// `statfs(path, buf) -> 0`: what kind of filesystem a path is on.
    pub const statfs = 137;
    /// `mlock(addr, length) -> 0` and `munlock`: memory is never paged out.
    pub const mlock = 149;
    pub const munlock = 150;
    /// `prctl(option, ...)`: no option is supported yet (`EINVAL`).
    pub const prctl = 157;
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
    /// `newfstatat(dirfd, path, statbuf, flags) -> 0`: `stat` by path, or
    /// of `dirfd` itself with `AT_EMPTY_PATH`.
    pub const newfstatat = 262;
    /// `readlinkat(dirfd, path, buf, size)`.
    pub const readlinkat = 267;
    /// `clone3(args, size) -> thread ID`: `clone` with its arguments in a
    /// structure.
    pub const clone3 = 435;
    /// `faccessat(dirfd, path, mode)` and `faccessat2(..., flags)`.
    pub const faccessat = 269;
    pub const faccessat2 = 439;
    /// `set_robust_list(head, size) -> 0`: the list of locks to release
    /// if the thread dies holding them. Recorded only.
    pub const set_robust_list = 273;
    /// `rseq(...)`: restartable sequences are not offered (`ENOSYS`).
    pub const rseq = 334;
    /// `pipe2(fds, flags) -> 0`: `pipe` with `O_NONBLOCK` and `O_CLOEXEC`.
    pub const pipe2 = 293;
    /// `dup3(old, new, flags) -> new`.
    pub const dup3 = 292;
    /// `prlimit64(pid, resource, new, old) -> 0`.
    pub const prlimit64 = 302;
    /// `getrandom(buf, length, flags) -> bytes written`.
    pub const getrandom = 318;
    /// `get_mempolicy(mode, nodemask, maxnode, addr, flags) -> 0`: there
    /// is one memory node and the default policy.
    pub const get_mempolicy = 239;
    /// `membarrier(command, flags, cpu)`: make every CPU running the
    /// process pass a memory barrier.
    pub const membarrier = 324;

    /// First private (non-Linux) syscall number, far above Linux's range
    /// (under 500) and below the x32 bit (0x4000_0000). Milestone 6 replaces
    /// the private calls with Linux ones.
    pub const PRIVATE_BASE = 0x4D59_00; // "MY"
    // PRIVATE_BASE + 0 was `myos_getchar`: keys come through `read` on
    // descriptor 0 now. The number stays unused.
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
    /// Permission denied.
    ACCES = 13,
    /// Out of memory.
    NOMEM = 12,
    /// Bad address: a pointer argument is outside user space or not mapped.
    FAULT = 14,
    /// Already exists.
    EXIST = 17,
    /// No such device: the object cannot be mapped.
    /// Device or resource busy: a mount point cannot be removed.
    BUSY = 16,
    /// A rename from one filesystem to another.
    XDEV = 18,
    NODEV = 19,
    /// Not a directory.
    NOTDIR = 20,
    /// Is a directory.
    ISDIR = 21,
    /// The result does not fit the buffer.
    RANGE = 34,
    /// Directory not empty.
    NOTEMPTY = 39,
    /// Address family not supported.
    AFNOSUPPORT = 97,
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
    /// File too large.
    FBIG = 27,
    /// No space left on the device.
    NOSPC = 28,
    SPIPE = 29,
    /// Broken pipe: nobody is left to read what is written.
    PIPE = 32,
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

/// Longest path, including the terminating NUL: Linux's `PATH_MAX`.
pub const PATH_MAX = 4096;

/// `getdents64`: bytes of a `struct linux_dirent64` before the name
/// (inode number, offset of the next entry, record length, type), and the
/// types.
pub const DIRENT_HEADER = 19;
pub const DT = struct {
    pub const CHR = 2;
    pub const DIR = 4;
    pub const REG = 8;
    pub const LNK = 10;
};

/// `open` flags (Linux's values). Only read-only opens are supported.
pub const O = struct {
    pub const RDONLY = 0;
    pub const WRONLY = 1;
    pub const RDWR = 2;
    /// Mask of the access mode bits.
    pub const ACCMODE = 3;
    pub const CREAT = 0o100;
    pub const EXCL = 0o200;
    pub const TRUNC = 0o1000;
    pub const APPEND = 0o2000;
    pub const NONBLOCK = 0o4000;
    pub const DIRECTORY = 0o200000;
    pub const CLOEXEC = 0o2000000;
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

/// `mremap` flags.
pub const MREMAP = struct {
    pub const MAYMOVE = 1;
    pub const FIXED = 2;
};

/// `mmap` flags.
pub const MAP = struct {
    pub const SHARED = 0x01;
    pub const PRIVATE = 0x02;
    pub const FIXED = 0x10;
    pub const ANONYMOUS = 0x20;
    /// Ignored, as on Linux.
    pub const DENYWRITE = 0x0800;
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
    pub const ERR = 0x008;
    pub const HUP = 0x010;
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
    /// Mask of the file type bits.
    pub const IFMT = 0o170000;
    pub const IFCHR = 0o020000;
    pub const IFIFO = 0o010000;
    pub const IFREG = 0o100000;
    pub const IFDIR = 0o040000;
    pub const IFLNK = 0o120000;
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

/// `membarrier` commands.
pub const MEMBARRIER = struct {
    pub const QUERY = 0;
    pub const PRIVATE_EXPEDITED = 1 << 3;
    pub const REGISTER_PRIVATE_EXPEDITED = 1 << 4;
};

/// `struct sysinfo`.
pub const SysInfo = extern struct {
    uptime: i64 = 0,
    loads: [3]u64 = .{ 0, 0, 0 },
    totalram: u64 = 0,
    freeram: u64 = 0,
    sharedram: u64 = 0,
    bufferram: u64 = 0,
    totalswap: u64 = 0,
    freeswap: u64 = 0,
    procs: u16 = 0,
    _pad: u16 = 0,
    _pad2: u32 = 0,
    totalhigh: u64 = 0,
    freehigh: u64 = 0,
    /// Size of the unit the memory fields are in, in bytes.
    mem_unit: u32 = 1,
    _reserved: u32 = 0,
};

/// `struct statfs`.
pub const StatFs = extern struct {
    type: i64 = 0,
    bsize: i64 = 4096,
    blocks: u64 = 0,
    bfree: u64 = 0,
    bavail: u64 = 0,
    files: u64 = 0,
    ffree: u64 = 0,
    fsid: [2]i32 = .{ 0, 0 },
    namelen: i64 = 255,
    frsize: i64 = 4096,
    flags: i64 = 1, // read-only
    spare: [4]i64 = .{ 0, 0, 0, 0 },
};
/// The magic number of a RAM-backed filesystem (`TMPFS_MAGIC`), which is
/// the nearest thing to the initrd.
pub const TMPFS_MAGIC = 0x01021994;

/// `access` modes and `AT_*` flags of the path calls.
pub const ACCESS = struct {
    pub const F_OK = 0;
    pub const X_OK = 1;
    pub const W_OK = 2;
    pub const R_OK = 4;
};
pub const AT_EMPTY_PATH = 0x1000;
pub const AT_SYMLINK_NOFOLLOW = 0x100;
/// Size of the structure `set_robust_list` registers.
pub const ROBUST_LIST_HEAD_SIZE = 24;

/// `struct clone_args` of `clone3`, as far as its first version goes
/// (64 bytes); later versions add fields at the end.
pub const CloneArgs = extern struct {
    flags: u64,
    pidfd: u64,
    child_tid: u64,
    parent_tid: u64,
    exit_signal: u64,
    /// Lowest address of the new thread's stack, and its size.
    stack: u64,
    stack_size: u64,
    tls: u64,
};

/// Scheduling policies. Only `OTHER` exists; `BATCH` and `IDLE` are the
/// same thing to this scheduler and are refused rather than ignored.
pub const SCHED = struct {
    pub const OTHER = 0;
    pub const FIFO = 1;
    pub const RR = 2;
};

/// `unlinkat`: remove a directory, as `rmdir` does.
pub const AT_REMOVEDIR = 0x200;

/// `struct termios` as the kernel has it (`TCGETS`, `TCSETS`).
pub const Termios = extern struct {
    iflag: u32 = 0,
    oflag: u32 = 0,
    cflag: u32 = 0,
    lflag: u32 = 0,
    line: u8 = 0,
    cc: [19]u8 = @splat(0),
};

pub const TERMIOS = struct {
    // iflag
    pub const ICRNL = 0o400;
    // oflag
    pub const OPOST = 0o1;
    pub const ONLCR = 0o4;
    // cflag
    pub const B38400 = 0o17;
    pub const CS8 = 0o60;
    pub const CREAD = 0o200;
    // lflag
    pub const ISIG = 0o1;
    pub const ICANON = 0o2;
    pub const ECHO = 0o10;
    pub const ECHOE = 0o20;
    pub const ECHOK = 0o40;
    // cc
    pub const VINTR = 0;
    pub const VERASE = 2;
    pub const VKILL = 3;
    pub const VEOF = 4;
    pub const VTIME = 5;
    pub const VMIN = 6;
};

/// `struct winsize` (`TIOCGWINSZ`).
pub const WinSize = extern struct {
    rows: u16,
    cols: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

/// The terminal's `ioctl` requests.
pub const TIOC = struct {
    pub const TCGETS = 0x5401;
    pub const TCSETS = 0x5402;
    pub const TCSETSW = 0x5403;
    pub const TCSETSF = 0x5404;
    pub const TCFLSH = 0x540B;
    pub const TIOCGPGRP = 0x540F;
    pub const TIOCSPGRP = 0x5410;
    pub const TIOCGWINSZ = 0x5413;
    pub const FIONREAD = 0x541B;
};
