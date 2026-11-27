//! `/test/errors`: every system call MyOS implements, made from ring 3
//! with arguments for which Linux's manual pages document the result: an
//! error number (a bad descriptor, a bad address, an unknown flag, a
//! missing file), or success where a call has no error that is cheap to
//! reach. One table, one row a call or more; each row is a check of its
//! own; every one that fails is reported in the log, and the program
//! exits with the number of the first (its row in the table, from 1), or
//! 0.
//!
//! The struct layouts these calls fill are checked on the host
//! (`tests/host/abi_test.zig`); what the calls do when they work is the
//! business of the other programs here (`/test/files`, `/test/fork`, ...).

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

/// A descriptor no process has open.
const BAD_FD: u64 = 999;
/// An address in the kernel half, rejected before anything is touched.
const KERNEL: u64 = 0xFFFF_FFFF_8000_0000;
/// An address in user space below where programs are loaded: never mapped.
const UNMAPPED: u64 = 0x1000;
const AT_FDCWD: u64 = @bitCast(@as(i64, abi.AT_FDCWD));
const NEG1: u64 = @bitCast(@as(i64, -1));

/// What a row expects.
const Want = union(enum) {
    /// This error.
    e: abi.E,
    /// Exactly this value.
    is: u64,
    /// Any result that is not an error.
    ok,
};

const Row = struct { nr: u64, a: [6]u64 = @splat(0), want: Want };

fn row(nr: u64, a: anytype, want: Want) Row {
    var r: Row = .{ .nr = nr, .want = want };
    inline for (a, 0..) |v, i| r.a[i] = v;
    return r;
}

var buf: [4096]u8 align(16) = undefined;
var zero_mask: u64 = 0;
var big_mask: u64 = 1 << 40;

pub fn main() noreturn {
    // What the rows work on.
    const file = lib.open("/etc/motd");
    const dir = lib.open("/etc");
    var pfd: [2]i32 = undefined;
    _ = lib.syscall(Sys.pipe2, @intFromPtr(&pfd), 0, 0);
    const prd: u64 = @intCast(pfd[0]);
    const b = @intFromPtr(&buf);
    const me = lib.syscall(Sys.getpid, 0, 0, 0);
    const iov_bad: abi.IoVec = .{ .base = UNMAPPED, .len = 8 };
    const iovb = @intFromPtr(&iov_bad);
    const policy_param: i32 = 0;
    const pp = @intFromPtr(&policy_param);
    const bad_policy_param: i32 = 5;
    const bpp = @intFromPtr(&bad_policy_param);

    const rows = [_]Row{
        // Descriptors and I/O.
        row(Sys.read, .{ BAD_FD, b, 1 }, .{ .e = .BADF }),
        row(Sys.read, .{ file, KERNEL, 1 }, .{ .e = .FAULT }),
        row(Sys.read, .{ dir, b, 1 }, .{ .e = .ISDIR }),
        row(Sys.write, .{ BAD_FD, b, 1 }, .{ .e = .BADF }),
        row(Sys.write, .{ file, b, 1 }, .{ .e = .BADF }), // opened read-only
        row(Sys.write, .{ 1, b, 0 }, .{ .is = 0 }),
        row(Sys.close, .{BAD_FD}, .{ .e = .BADF }),
        row(Sys.readv, .{ BAD_FD, iovb, 1 }, .{ .e = .BADF }),
        row(Sys.readv, .{ file, iovb, 2000 }, .{ .e = .INVAL }), // above IOV_MAX
        row(Sys.writev, .{ 1, KERNEL, 1 }, .{ .e = .FAULT }),
        row(Sys.pread64, .{ BAD_FD, b, 1, 0 }, .{ .e = .BADF }),
        row(Sys.pread64, .{ prd, b, 1, 0 }, .{ .e = .SPIPE }),
        row(Sys.pread64, .{ file, b, 1, NEG1 }, .{ .e = .INVAL }),
        row(Sys.pwrite64, .{ BAD_FD, b, 1, 0 }, .{ .e = .BADF }),
        row(Sys.preadv, .{ BAD_FD, iovb, 1, 0 }, .{ .e = .BADF }),
        row(Sys.pwritev, .{ BAD_FD, iovb, 1, 0 }, .{ .e = .BADF }),
        row(Sys.preadv2, .{ BAD_FD, iovb, 1, 0, 0 }, .{ .e = .BADF }),
        row(Sys.pwritev2, .{ BAD_FD, iovb, 1, 0, 0 }, .{ .e = .BADF }),
        row(Sys.lseek, .{ BAD_FD, 0, 0 }, .{ .e = .BADF }),
        row(Sys.lseek, .{ file, 0, 99 }, .{ .e = .INVAL }),
        row(Sys.lseek, .{ prd, 0, 0 }, .{ .e = .SPIPE }),
        row(Sys.dup, .{BAD_FD}, .{ .e = .BADF }),
        row(Sys.dup2, .{ BAD_FD, 5 }, .{ .e = .BADF }),
        row(Sys.dup2, .{ file, file }, .{ .is = file }), // the same: nothing to do
        row(Sys.dup3, .{ file, file, 0 }, .{ .e = .INVAL }),
        row(Sys.dup3, .{ file, 20, 0x40 }, .{ .e = .INVAL }), // unknown flag
        row(Sys.fcntl, .{ BAD_FD, 1, 0 }, .{ .e = .BADF }),
        row(Sys.fcntl, .{ file, 9999, 0 }, .{ .e = .INVAL }),
        row(Sys.ioctl, .{ BAD_FD, abi.TIOC.TCGETS, b }, .{ .e = .BADF }),
        row(Sys.ioctl, .{ file, abi.TIOC.TCGETS, b }, .{ .e = .NOTTY }),
        row(Sys.fsync, .{BAD_FD}, .{ .e = .BADF }),
        row(Sys.fdatasync, .{BAD_FD}, .{ .e = .BADF }),
        row(Sys.fsync, .{file}, .{ .is = 0 }),
        row(Sys.fdatasync, .{file}, .{ .is = 0 }),
        row(Sys.ftruncate, .{ BAD_FD, 0 }, .{ .e = .BADF }),
        row(Sys.ftruncate, .{ file, 0 }, .{ .e = .INVAL }), // not open for writing
        row(Sys.fchmod, .{ BAD_FD, 0o644 }, .{ .e = .BADF }),
        row(Sys.getdents64, .{ BAD_FD, b, buf.len }, .{ .e = .BADF }),
        row(Sys.getdents64, .{ file, b, buf.len }, .{ .e = .NOTDIR }),
        row(Sys.pipe, .{KERNEL}, .{ .e = .FAULT }),
        row(Sys.pipe2, .{ b, 0x40 }, .{ .e = .INVAL }),
        row(Sys.poll, .{ KERNEL, 1, 0 }, .{ .e = .FAULT }),
        row(Sys.poll, .{ b, 0, 0 }, .{ .is = 0 }),

        // Paths.
        row(Sys.open, .{KERNEL}, .{ .e = .FAULT }),
        row(Sys.open, .{@intFromPtr("/nonexistent")}, .{ .e = .NOENT }),
        row(Sys.open, .{ @intFromPtr("/etc/motd/x"), 0 }, .{ .e = .NOTDIR }),
        row(Sys.openat, .{ BAD_FD, @intFromPtr("motd"), 0 }, .{ .e = .BADF }),
        row(Sys.openat, .{ file, @intFromPtr("motd"), 0 }, .{ .e = .NOTDIR }),
        row(Sys.stat, .{ KERNEL, b }, .{ .e = .FAULT }),
        row(Sys.stat, .{ @intFromPtr("/nonexistent"), b }, .{ .e = .NOENT }),
        row(Sys.stat, .{ @intFromPtr("/etc/motd/x"), b }, .{ .e = .NOTDIR }),
        row(Sys.stat, .{ @intFromPtr("/nonexistent/x"), b }, .{ .e = .NOENT }),
        row(Sys.lstat, .{ @intFromPtr("/nonexistent"), b }, .{ .e = .NOENT }),
        row(Sys.fstat, .{ BAD_FD, b }, .{ .e = .BADF }),
        row(Sys.fstat, .{ file, KERNEL }, .{ .e = .FAULT }),
        row(Sys.newfstatat, .{ BAD_FD, @intFromPtr("motd"), b, 0 }, .{ .e = .BADF }),
        row(Sys.newfstatat, .{ AT_FDCWD, @intFromPtr("/etc"), b, 0x9999 }, .{ .e = .INVAL }),
        row(Sys.statx, .{ AT_FDCWD, KERNEL, 0, 0, b }, .{ .e = .FAULT }),
        row(Sys.statx, .{ AT_FDCWD, @intFromPtr("/etc"), 0x9999_0000, 0, b }, .{ .e = .INVAL }),
        row(Sys.access, .{ @intFromPtr("/nonexistent"), 0 }, .{ .e = .NOENT }),
        row(Sys.access, .{ @intFromPtr("/etc"), 99 }, .{ .e = .INVAL }),
        row(Sys.faccessat, .{ BAD_FD, @intFromPtr("motd"), 0 }, .{ .e = .BADF }),
        row(Sys.faccessat2, .{ AT_FDCWD, @intFromPtr("/etc"), 0, 0x9999 }, .{ .e = .INVAL }),
        row(Sys.readlink, .{ @intFromPtr("/nonexistent"), b, 64 }, .{ .e = .NOENT }),
        row(Sys.readlink, .{ @intFromPtr("/etc/motd"), b, 64 }, .{ .e = .INVAL }), // not a link
        row(Sys.readlinkat, .{ BAD_FD, @intFromPtr("x"), b, 64 }, .{ .e = .BADF }),
        row(Sys.getcwd, .{ b, 1 }, .{ .e = .RANGE }),
        row(Sys.getcwd, .{ KERNEL, 64 }, .{ .e = .FAULT }),
        row(Sys.chdir, .{@intFromPtr("/nonexistent")}, .{ .e = .NOENT }),
        row(Sys.chdir, .{@intFromPtr("/etc/motd")}, .{ .e = .NOTDIR }),
        row(Sys.fchdir, .{BAD_FD}, .{ .e = .BADF }),
        row(Sys.fchdir, .{file}, .{ .e = .NOTDIR }),
        row(Sys.mkdir, .{ @intFromPtr("/etc"), 0o755 }, .{ .e = .EXIST }),
        row(Sys.mkdirat, .{ BAD_FD, @intFromPtr("x"), 0o755 }, .{ .e = .BADF }),
        row(Sys.rmdir, .{@intFromPtr("/tmp/nonexistent")}, .{ .e = .NOENT }),
        row(Sys.unlink, .{@intFromPtr("/tmp/nonexistent")}, .{ .e = .NOENT }),
        row(Sys.unlinkat, .{ AT_FDCWD, @intFromPtr("/tmp/x"), 0x9999 }, .{ .e = .INVAL }),
        row(Sys.rename, .{ @intFromPtr("/tmp/nonexistent"), @intFromPtr("/tmp/y") }, .{ .e = .NOENT }),
        row(Sys.renameat, .{ BAD_FD, @intFromPtr("x"), AT_FDCWD, @intFromPtr("/tmp/y") }, .{ .e = .BADF }),
        row(Sys.renameat2, .{ AT_FDCWD, @intFromPtr("/tmp/x"), AT_FDCWD, @intFromPtr("/tmp/y"), 0x9999 }, .{ .e = .INVAL }),
        row(Sys.truncate, .{ @intFromPtr("/tmp/nonexistent"), 0 }, .{ .e = .NOENT }),
        row(Sys.mknodat, .{ AT_FDCWD, @intFromPtr("/tmp/dev"), abi.S.IFCHR | 0o600, 0 }, .{ .e = .PERM }),
        row(Sys.statfs, .{ KERNEL, b }, .{ .e = .FAULT }),
        row(Sys.statfs, .{ @intFromPtr("/nonexistent"), b }, .{ .e = .NOENT }),

        // Memory.
        row(Sys.mmap, .{ 0, 0, abi.PROT.READ, abi.MAP.PRIVATE | abi.MAP.ANONYMOUS, NEG1, 0 }, .{ .e = .INVAL }), // no length
        row(Sys.mmap, .{ 0, 4096, abi.PROT.READ, abi.MAP.PRIVATE, BAD_FD, 0 }, .{ .e = .BADF }),
        row(Sys.mmap, .{ 0, 4096, abi.PROT.READ, abi.MAP.PRIVATE | abi.MAP.ANONYMOUS, NEG1, 1 }, .{ .e = .INVAL }), // offset not page-aligned
        row(Sys.munmap, .{ 1, 4096 }, .{ .e = .INVAL }),
        row(Sys.mprotect, .{ 1, 4096, abi.PROT.READ }, .{ .e = .INVAL }),
        row(Sys.madvise, .{ 1, 4096, 4 }, .{ .e = .INVAL }),
        row(Sys.mremap, .{ 1, 4096, 8192, 0, 0 }, .{ .e = .INVAL }),
        row(Sys.mlock, .{ UNMAPPED, 4096 }, .{ .e = .NOMEM }),
        row(Sys.mlock, .{ b, 64 }, .{ .is = 0 }),
        row(Sys.munlock, .{ UNMAPPED, 4096 }, .{ .e = .NOMEM }),
        row(Sys.brk, .{0}, .ok), // where the heap ends

        // Signals.
        row(Sys.rt_sigaction, .{ 9, b, 0, abi.SIGSET_SIZE }, .{ .e = .INVAL }), // SIGKILL
        row(Sys.rt_sigaction, .{ 0, 0, b, abi.SIGSET_SIZE }, .{ .e = .INVAL }),
        row(Sys.rt_sigaction, .{ 10, 0, b, 4 }, .{ .e = .INVAL }), // set size
        row(Sys.rt_sigprocmask, .{ 99, @intFromPtr(&zero_mask), 0, abi.SIGSET_SIZE }, .{ .e = .INVAL }),
        row(Sys.rt_sigprocmask, .{ 0, KERNEL, 0, abi.SIGSET_SIZE }, .{ .e = .FAULT }),
        row(Sys.rt_sigpending, .{ KERNEL, abi.SIGSET_SIZE }, .{ .e = .FAULT }),
        row(Sys.rt_sigsuspend, .{ @intFromPtr(&zero_mask), 4 }, .{ .e = .INVAL }),
        row(Sys.sigaltstack, .{ KERNEL, 0 }, .{ .e = .FAULT }),
        row(Sys.kill, .{ me, 99 }, .{ .e = .INVAL }),
        row(Sys.kill, .{ 99999, 0 }, .{ .e = .SRCH }),
        row(Sys.kill, .{ me, 0 }, .{ .is = 0 }),
        row(Sys.tgkill, .{ me, 99999, 0 }, .{ .e = .SRCH }),
        row(Sys.tkill, .{ 99999, 0 }, .{ .e = .SRCH }),
        row(Sys.tkill, .{ me, 0 }, .{ .is = 0 }), // the main thread's ID is the process's

        // Processes and scheduling.
        row(Sys.wait4, .{ NEG1, b, 0, 0 }, .{ .e = .CHILD }),
        row(Sys.wait4, .{ NEG1, b, 0x9999, 0 }, .{ .e = .INVAL }),
        row(Sys.execve, .{ KERNEL, 0, 0 }, .{ .e = .FAULT }),
        row(Sys.execve, .{ @intFromPtr("/nonexistent"), 0, 0 }, .{ .e = .NOENT }),
        // No permission bits: a file that is not a program is ENOEXEC, as
        // Linux says for an executable file of no format it knows.
        row(Sys.execve, .{ @intFromPtr("/etc/motd"), 0, 0 }, .{ .e = .NOEXEC }),
        row(Sys.execveat, .{ BAD_FD, @intFromPtr("x"), 0, 0, 0 }, .{ .e = .BADF }),
        row(Sys.clone3, .{ KERNEL, 64 }, .{ .e = .FAULT }),
        row(Sys.clone3, .{ b, 8 }, .{ .e = .INVAL }), // smaller than the first version
        row(Sys.getpid, .{}, .{ .is = me }),
        row(Sys.gettid, .{}, .{ .is = me }),
        row(Sys.getppid, .{}, .ok),
        row(Sys.getpgrp, .{}, .ok),
        row(Sys.getpgid, .{99999}, .{ .e = .SRCH }),
        row(Sys.getsid, .{99999}, .{ .e = .SRCH }),
        row(Sys.setpgid, .{ 99999, 0 }, .{ .e = .SRCH }),
        row(Sys.setsid, .{}, .{ .e = .PERM }), // a group leader
        row(Sys.sched_yield, .{}, .{ .is = 0 }),
        row(Sys.sched_getaffinity, .{ 0, 0, b }, .{ .e = .INVAL }), // no room for the mask
        row(Sys.sched_getaffinity, .{ 99999, 8, b }, .{ .e = .SRCH }),
        row(Sys.sched_setaffinity, .{ 0, 8, @intFromPtr(&zero_mask) }, .{ .e = .INVAL }), // no CPU
        row(Sys.sched_setaffinity, .{ 0, 8, @intFromPtr(&big_mask) }, .{ .e = .INVAL }), // only CPUs that are not there
        row(Sys.sched_getscheduler, .{99999}, .{ .e = .SRCH }),
        row(Sys.sched_getscheduler, .{0}, .{ .is = abi.SCHED.OTHER }),
        row(Sys.sched_getparam, .{ 0, KERNEL }, .{ .e = .FAULT }),
        row(Sys.sched_setscheduler, .{ 0, 99, pp }, .{ .e = .INVAL }),
        row(Sys.sched_setparam, .{ 0, bpp }, .{ .e = .INVAL }), // SCHED_OTHER takes priority 0 only
        row(Sys.sched_get_priority_max, .{99}, .{ .e = .INVAL }),
        row(Sys.sched_get_priority_min, .{abi.SCHED.OTHER}, .{ .is = 0 }),
        row(Sys.prlimit64, .{ 0, 99, 0, b }, .{ .e = .INVAL }),
        row(Sys.getrlimit, .{ abi.RLIMIT.NOFILE, KERNEL }, .{ .e = .FAULT }),
        row(Sys.setrlimit, .{ abi.RLIMIT.NOFILE, KERNEL }, .{ .e = .FAULT }),
        row(Sys.prctl, .{ 9999, 0, 0, 0, 0 }, .{ .e = .INVAL }),
        row(Sys.arch_prctl, .{ 0x9999, 0 }, .{ .e = .INVAL }),
        row(Sys.arch_prctl, .{ abi.ARCH.SET_FS, KERNEL }, .{ .e = .PERM }),
        row(Sys.set_tid_address, .{0}, .{ .is = me }),
        row(Sys.set_robust_list, .{ b, 1 }, .{ .e = .INVAL }),
        row(Sys.rseq, .{ b, 32, 0, 0 }, .{ .e = .NOSYS }),
        row(Sys.membarrier, .{ 0x9999, 0, 0 }, .{ .e = .INVAL }),
        row(Sys.get_mempolicy, .{ 0, 0, 0, 0, 0x9999 }, .{ .e = .INVAL }),

        // Time.
        row(Sys.clock_gettime, .{ 99, b }, .{ .e = .INVAL }),
        row(Sys.clock_gettime, .{ abi.CLOCK.MONOTONIC, KERNEL }, .{ .e = .FAULT }),
        row(Sys.clock_nanosleep, .{ 99, 0, b, 0 }, .{ .e = .INVAL }),
        row(Sys.clock_nanosleep, .{ abi.CLOCK.MONOTONIC, 0, KERNEL, 0 }, .{ .e = .FAULT }),
        row(Sys.nanosleep, .{ KERNEL, 0 }, .{ .e = .FAULT }),
        row(Sys.gettimeofday, .{ KERNEL, 0 }, .{ .e = .FAULT }),
        row(Sys.time, .{KERNEL}, .{ .e = .FAULT }),
        row(Sys.time, .{0}, .ok),

        // Waiting on several things; counters.
        row(Sys.epoll_create, .{0}, .{ .e = .INVAL }),
        row(Sys.epoll_create1, .{0x40}, .{ .e = .INVAL }),
        row(Sys.epoll_ctl, .{ BAD_FD, abi.EPOLL.CTL_ADD, 0, b }, .{ .e = .BADF }),
        row(Sys.epoll_wait, .{ BAD_FD, b, 1, 0 }, .{ .e = .BADF }),
        row(Sys.epoll_pwait, .{ BAD_FD, b, 1, 0, 0, abi.SIGSET_SIZE }, .{ .e = .BADF }),
        row(Sys.epoll_pwait2, .{ BAD_FD, b, 1, 0, 0, abi.SIGSET_SIZE }, .{ .e = .BADF }),
        row(Sys.eventfd2, .{ 0, 0x40 }, .{ .e = .INVAL }),
        row(Sys.futex, .{ KERNEL, abi.FUTEX.WAIT, 0, 0 }, .{ .e = .FAULT }),
        row(Sys.futex, .{ b, 99, 0, 0 }, .{ .e = .NOSYS }),
        row(Sys.futex, .{ b + 1, abi.FUTEX.WAKE, 1, 0 }, .{ .e = .INVAL }), // not aligned

        // The machine.
        row(Sys.uname, .{KERNEL}, .{ .e = .FAULT }),
        row(Sys.sysinfo, .{KERNEL}, .{ .e = .FAULT }),
        row(Sys.getrandom, .{ KERNEL, 8, 0 }, .{ .e = .FAULT }),
        row(Sys.getrandom, .{ b, 8, 0x9999 }, .{ .e = .INVAL }),
        row(Sys.getrandom, .{ b, 8, 0 }, .{ .is = 8 }),
        row(Sys.getrandom, .{ b, 8, 1 }, .{ .is = 8 }), // GRND_NONBLOCK
        row(Sys.socket, .{ 2, 1, 0 }, .{ .e = .AFNOSUPPORT }),
        row(Sys.memfd_create, .{ @intFromPtr("x"), 0 }, .{ .e = .NOSYS }),
    };

    var first_failed: u64 = 0;
    for (rows, 1..) |r, n| {
        const got = lib.syscall6(r.nr, r.a[0], r.a[1], r.a[2], r.a[3], r.a[4], r.a[5]);
        const ok = switch (r.want) {
            .e => |e| got == lib.err(e),
            .is => |v| got == v,
            .ok => !lib.isError(got),
        };
        if (!ok) {
            // Which call, and what it said instead, for the log.
            var line: [96]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "  row {d}: syscall {d} returned {d}\n", .{ n, r.nr, @as(i64, @bitCast(got)) }) catch "";
            lib.write(text);
            if (first_failed == 0) first_failed = n;
        }
    }
    if (first_failed != 0) lib.exit(first_failed); // every failing row is in the log

    // The ones that need more than a row.
    // `uname` says it is Linux on x86-64.
    var u: abi.UtsName = .{};
    if (lib.syscall(Sys.uname, @intFromPtr(&u), 0, 0) != 0) lib.exit(1000);
    if (!std.mem.eql(u8, std.mem.sliceTo(&u.sysname, 0), "Linux") or !std.mem.eql(u8, std.mem.sliceTo(&u.machine, 0), "x86_64")) lib.exit(1001);
    // `eventfd` (without flags) makes a counter.
    const efd = lib.syscall(Sys.eventfd, 3, 0, 0);
    if (lib.isError(efd)) lib.exit(1002);
    _ = lib.close(efd);
    // `pause` waits until a signal comes: a child that pauses ends when
    // it is sent SIGTERM.
    const child = lib.syscall(Sys.fork, 0, 0, 0);
    if (child == 0) {
        _ = lib.syscall(Sys.pause, 0, 0, 0);
        lib.exit(1);
    }
    const ts: abi.TimeSpec = .{ .sec = 0, .nsec = 20_000_000 };
    _ = lib.syscall(Sys.nanosleep, @intFromPtr(&ts), 0, 0);
    _ = lib.syscall(Sys.kill, child, 15, 0);
    var status: i32 = 0;
    if (lib.syscall6(Sys.wait4, child, @intFromPtr(&status), 0, 0, 0, 0) != child or status != 15) lib.exit(1003);
    lib.exit(0);
}
