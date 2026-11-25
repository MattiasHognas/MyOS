//! `/test/linux_abi`: check what a Linux program relies on before `main`
//! and in its first calls: the initial stack (arguments, environment,
//! auxiliary vector), the FS and GS base, and `writev`, `ioctl`,
//! `set_tid_address` and `exit_group`.
//!
//! The kernel test starts it with the arguments `abi`, `x y` and an empty
//! one, and the environment `A=1`; started with fewer arguments it skips
//! the checks of their contents. Two copies run at once, so each one's FS
//! and GS base must survive the other running.
//!
//! Exits with 0 through `exit_group`, or with the number of the first
//! failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const Sys = lib.Sys;
const abi = lib.abi;
const AT = abi.AT;

fn expect(ok: bool, check: u64) void {
    if (!ok) lib.exit(check);
}

fn eql(s: [*:0]const u8, want: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(s), want);
}

/// The 8 bytes at offset 0 from the FS (or GS) base.
fn readFs() u64 {
    return asm volatile ("mov %%fs:0, %[v]"
        : [v] "=r" (-> u64),
    );
}

fn readGs() u64 {
    return asm volatile ("mov %%gs:0, %[v]"
        : [v] "=r" (-> u64),
    );
}

var fs_block: [2]u64 = .{ 0, 0 };
var gs_block: [2]u64 = .{ 0, 0 };

pub fn main() noreturn {
    // The initial stack.
    const argv = lib.argv();
    const env = lib.environ();
    expect(argv.len >= 1, 1);
    if (argv.len == 3) {
        expect(eql(argv[0], "abi") and eql(argv[1], "x y") and eql(argv[2], ""), 2);
        expect(env.len == 1 and eql(env[0], "A=1"), 3);
        // In order of address, as on Linux, and the environment after them.
        expect(@intFromPtr(argv[0]) < @intFromPtr(argv[1]) and @intFromPtr(argv[2]) < @intFromPtr(env[0]), 4);
    }
    expect(lib.auxValue(AT.PAGESZ) == 4096, 5);
    expect(lib.auxValue(AT.CLKTCK) == 100, 6);
    expect(lib.auxValue(AT.BASE) == 0 and lib.auxValue(AT.UID) == 0 and lib.auxValue(AT.SECURE) == 0, 7);
    // The program headers: how many and how large, and, if this program's
    // are part of what was loaded (that is up to how it was linked), where
    // they are; then the loadable segments (type 1) can be read there.
    const phdr = lib.auxValue(AT.PHDR) orelse lib.exit(8);
    const phnum = lib.auxValue(AT.PHNUM) orelse lib.exit(8);
    expect(phnum >= 1 and phnum < 64 and lib.auxValue(AT.PHENT) == 56, 9);
    if (phdr != 0) {
        var loads: usize = 0;
        for (0..phnum) |i| {
            const ph: *align(1) const u32 = @ptrFromInt(phdr + i * 56);
            if (ph.* == 1) loads += 1;
        }
        expect(loads >= 1, 10);
    }
    // The entry point is in this program's code, near `main`.
    const entry = lib.auxValue(AT.ENTRY) orelse lib.exit(11);
    const here = @intFromPtr(&main);
    expect(entry != 0 and (if (entry > here) entry - here else here - entry) < 16 * 1024 * 1024, 11);
    // Sixteen random bytes, not all the same.
    const random: *const [16]u8 = @ptrFromInt(lib.auxValue(AT.RANDOM) orelse lib.exit(12));
    expect(!std.mem.allEqual(u8, random, random[0]), 12);
    const execfn: [*:0]const u8 = @ptrFromInt(lib.auxValue(AT.EXECFN) orelse lib.exit(13));
    expect(eql(execfn, "/test/linux_abi"), 13);
    const platform: [*:0]const u8 = @ptrFromInt(lib.auxValue(AT.PLATFORM) orelse lib.exit(14));
    expect(eql(platform, "x86_64"), 14);
    expect(lib.auxValue(33) == null, 15); // no vDSO

    // set_tid_address returns the thread's ID.
    const tid = lib.gettid();
    var tid_slot: u32 = 0;
    expect(lib.syscall(Sys.set_tid_address, @intFromPtr(&tid_slot), 0, 0) == tid, 20);

    // FS and GS base: set, read back, used by the CPU, and still there
    // after other programs have run.
    fs_block[0] = 0xF500_0000 + tid;
    gs_block[0] = 0x6500_0000 + tid;
    expect(lib.syscall(Sys.arch_prctl, abi.ARCH.SET_FS, @intFromPtr(&fs_block), 0) == 0, 21);
    expect(lib.syscall(Sys.arch_prctl, abi.ARCH.SET_GS, @intFromPtr(&gs_block), 0) == 0, 22);
    for (0..200) |_| {
        expect(readFs() == 0xF500_0000 + tid and readGs() == 0x6500_0000 + tid, 23);
        lib.yield();
    }
    var spin: usize = 0;
    while (spin < 30_000_000) : (spin += 1) { // long enough to be preempted
        if (spin % 1_000_000 == 0) expect(readFs() == 0xF500_0000 + tid and readGs() == 0x6500_0000 + tid, 24);
    }
    var got: u64 = 0;
    expect(lib.syscall(Sys.arch_prctl, abi.ARCH.GET_FS, @intFromPtr(&got), 0) == 0 and got == @intFromPtr(&fs_block), 25);
    expect(lib.syscall(Sys.arch_prctl, abi.ARCH.GET_GS, @intFromPtr(&got), 0) == 0 and got == @intFromPtr(&gs_block), 26);
    // A base outside user space is refused and changes nothing.
    for ([_]u64{ 0xFFFF_8000_0000_0000, 0xFFFF_FFFF_FFFF_F000, 0x0000_8000_0000_0000, 0x8000_0000_0000_0000 }) |bad| {
        expect(lib.syscall(Sys.arch_prctl, abi.ARCH.SET_FS, bad, 0) == lib.err(.PERM), 27);
        expect(lib.syscall(Sys.arch_prctl, abi.ARCH.SET_GS, bad, 0) == lib.err(.PERM), 28);
    }
    expect(readFs() == 0xF500_0000 + tid and readGs() == 0x6500_0000 + tid, 29);
    expect(lib.syscall(Sys.arch_prctl, 0x1234, 0, 0) == lib.err(.INVAL), 30);
    expect(lib.syscall(Sys.arch_prctl, abi.ARCH.GET_FS, 0xFFFF_8000_0000_0000, 0) == lib.err(.FAULT), 31);
    expect(lib.syscall(Sys.arch_prctl, abi.ARCH.GET_FS, 8, 0) == lib.err(.FAULT), 32);

    // ioctl: nothing is a terminal yet.
    expect(lib.syscall(Sys.ioctl, 1, 0x5413, 0) == lib.err(.NOTTY), 40);
    expect(lib.syscall(Sys.ioctl, 99, 0x5413, 0) == lib.err(.BADF), 41);

    // writev.
    const a = "linux_abi: ";
    const b = "writev works\n";
    const iov = [_]abi.IoVec{
        .{ .base = @intFromPtr(a), .len = a.len },
        .{ .base = 0, .len = 0 }, // an empty buffer may point anywhere
        .{ .base = @intFromPtr(b), .len = b.len },
    };
    expect(lib.syscall(Sys.writev, 1, @intFromPtr(&iov), iov.len) == a.len + b.len, 50);
    expect(lib.syscall(Sys.writev, 1, @intFromPtr(&iov), 0) == 0, 51);
    expect(lib.syscall(Sys.writev, 5, @intFromPtr(&iov), iov.len) == lib.err(.BADF), 52);
    expect(lib.syscall(Sys.writev, 1, @intFromPtr(&iov), abi.IOV_MAX + 1) == lib.err(.INVAL), 53);
    expect(lib.syscall(Sys.writev, 1, 8, 1) == lib.err(.FAULT), 54);
    // A first buffer that cannot be read: nothing written, EFAULT. A later
    // one: what came before it is written and counted.
    const bad_first = [_]abi.IoVec{.{ .base = 8, .len = 4 }};
    expect(lib.syscall(Sys.writev, 1, @intFromPtr(&bad_first), 1) == lib.err(.FAULT), 55);
    const bad_second = [_]abi.IoVec{ .{ .base = @intFromPtr(b), .len = b.len }, .{ .base = 8, .len = 4 } };
    expect(lib.syscall(Sys.writev, 1, @intFromPtr(&bad_second), 2) == b.len, 56);
    // Lengths that add up past what one call may move.
    const huge = [_]abi.IoVec{ .{ .base = @intFromPtr(a), .len = 1 << 62 }, .{ .base = @intFromPtr(a), .len = 1 << 62 }, .{ .base = @intFromPtr(a), .len = 1 << 63 } };
    expect(lib.syscall(Sys.writev, 1, @intFromPtr(&huge), 3) == lib.err(.INVAL), 57);

    // Signals: nothing is delivered yet, but what a program sets up at
    // startup is recorded and reads back.
    const SIGUSR1 = 10;
    var act: abi.SigAction = .{ .handler = 0x1234_5000, .flags = 0x0400_0000, .mask = ~@as(u64, 0) };
    var old: abi.SigAction = undefined;
    expect(lib.syscall6(Sys.rt_sigaction, SIGUSR1, 0, @intFromPtr(&old), 8, 0, 0) == 0 and old.handler == 0, 60);
    expect(lib.syscall6(Sys.rt_sigaction, SIGUSR1, @intFromPtr(&act), 0, 8, 0, 0) == 0, 61);
    expect(lib.syscall6(Sys.rt_sigaction, SIGUSR1, 0, @intFromPtr(&old), 8, 0, 0) == 0, 62);
    // As set, except that SIGKILL and SIGSTOP are never in a mask.
    expect(old.handler == 0x1234_5000 and old.flags == 0x0400_0000 and old.mask == ~@as(u64, (1 << 8) | (1 << 18)), 63);
    expect(lib.syscall6(Sys.rt_sigaction, abi.SIGKILL, @intFromPtr(&act), 0, 8, 0, 0) == lib.err(.INVAL), 64);
    expect(lib.syscall6(Sys.rt_sigaction, abi.SIGKILL, 0, @intFromPtr(&old), 8, 0, 0) == 0, 65); // asking is fine
    expect(lib.syscall6(Sys.rt_sigaction, 0, 0, 0, 8, 0, 0) == lib.err(.INVAL), 66);
    expect(lib.syscall6(Sys.rt_sigaction, 65, 0, 0, 8, 0, 0) == lib.err(.INVAL), 67);
    expect(lib.syscall6(Sys.rt_sigaction, SIGUSR1, 0, 0, 4, 0, 0) == lib.err(.INVAL), 68);
    expect(lib.syscall6(Sys.rt_sigaction, SIGUSR1, 8, 0, 8, 0, 0) == lib.err(.FAULT), 69);

    var set: u64 = (1 << (SIGUSR1 - 1)) | (1 << (abi.SIGKILL - 1));
    var was: u64 = 123;
    expect(lib.syscall6(Sys.rt_sigprocmask, abi.SIG.BLOCK, @intFromPtr(&set), @intFromPtr(&was), 8, 0, 0) == 0 and was == 0, 70);
    expect(lib.syscall6(Sys.rt_sigprocmask, abi.SIG.BLOCK, 0, @intFromPtr(&was), 8, 0, 0) == 0 and was == 1 << (SIGUSR1 - 1), 71);
    expect(lib.syscall6(Sys.rt_sigprocmask, abi.SIG.UNBLOCK, @intFromPtr(&set), 0, 8, 0, 0) == 0, 72);
    expect(lib.syscall6(Sys.rt_sigprocmask, abi.SIG.SETMASK, 0, @intFromPtr(&was), 8, 0, 0) == 0 and was == 0, 73);
    expect(lib.syscall6(Sys.rt_sigprocmask, 7, @intFromPtr(&set), 0, 8, 0, 0) == lib.err(.INVAL), 74);
    expect(lib.syscall6(Sys.rt_sigprocmask, abi.SIG.BLOCK, @intFromPtr(&set), 0, 16, 0, 0) == lib.err(.INVAL), 75);

    var stack: abi.SigStack = undefined;
    expect(lib.syscall(Sys.sigaltstack, 0, @intFromPtr(&stack), 0) == 0 and stack.flags == abi.SS.DISABLE, 80);
    var new_stack: abi.SigStack = .{ .sp = @intFromPtr(&fs_block), .flags = 0, .size = 8192 };
    expect(lib.syscall(Sys.sigaltstack, @intFromPtr(&new_stack), 0, 0) == 0, 81);
    expect(lib.syscall(Sys.sigaltstack, 0, @intFromPtr(&stack), 0) == 0 and stack.sp == @intFromPtr(&fs_block) and stack.size == 8192 and stack.flags == 0, 82);
    new_stack.size = 100;
    expect(lib.syscall(Sys.sigaltstack, @intFromPtr(&new_stack), 0, 0) == lib.err(.NOMEM), 83);
    new_stack = .{ .flags = abi.SS.DISABLE };
    expect(lib.syscall(Sys.sigaltstack, @intFromPtr(&new_stack), 0, 0) == 0, 84);

    // poll: the standard streams are open; output can be written.
    var fds = [_]abi.PollFd{
        .{ .fd = 0, .events = 0, .revents = -1 },
        .{ .fd = 1, .events = 0, .revents = -1 },
        .{ .fd = 2, .events = 0, .revents = -1 },
    };
    expect(lib.syscall(Sys.poll, @intFromPtr(&fds), 3, 0) == 0 and fds[0].revents == 0 and fds[2].revents == 0, 90);
    fds[1].events = abi.POLL.OUT | abi.POLL.IN;
    fds[2] = .{ .fd = 99, .events = abi.POLL.IN, .revents = 0 };
    fds[0] = .{ .fd = -1, .events = abi.POLL.IN, .revents = 7 }; // a negative descriptor is skipped
    expect(lib.syscall(Sys.poll, @intFromPtr(&fds), 3, 0) == 2, 91);
    expect(fds[0].revents == 0 and fds[1].revents == abi.POLL.OUT and fds[2].revents == abi.POLL.NVAL, 92);
    expect(lib.syscall(Sys.poll, @intFromPtr(&fds), 2000, 0) == lib.err(.INVAL), 93); // more than there can be descriptors
    expect(lib.syscall(Sys.poll, 8, 1, 0) == lib.err(.FAULT), 94);
    expect(lib.syscall(Sys.poll, @intFromPtr(&fds), 1, 20) == 0, 95); // waits out the 20 ms, nothing comes

    // membarrier: the expedited private barrier is offered, registered and made.
    const MB = abi.MEMBARRIER;
    expect(lib.syscall(Sys.membarrier, MB.QUERY, 0, 0) == MB.PRIVATE_EXPEDITED | MB.REGISTER_PRIVATE_EXPEDITED, 100);
    expect(lib.syscall(Sys.membarrier, MB.REGISTER_PRIVATE_EXPEDITED, 0, 0) == 0, 101);
    expect(lib.syscall(Sys.membarrier, MB.PRIVATE_EXPEDITED, 0, 0) == 0, 102);
    expect(lib.syscall(Sys.membarrier, 1, 0, 0) == lib.err(.INVAL), 103); // the global one is not
    expect(lib.syscall(Sys.membarrier, MB.PRIVATE_EXPEDITED, 1, 0) == lib.err(.INVAL), 104);

    // sysinfo: there is memory, some of it free, and one process at least.
    var info: abi.SysInfo = undefined;
    expect(lib.syscall(Sys.sysinfo, @intFromPtr(&info), 0, 0) == 0, 105);
    expect(info.mem_unit == 1 and info.totalram >= 16 << 20 and info.freeram != 0 and info.freeram < info.totalram, 106);
    expect(info.procs >= 1 and info.totalswap == 0, 107);
    expect(lib.syscall(Sys.sysinfo, 8, 0, 0) == lib.err(.FAULT), 108);

    // statfs: the filesystem is in memory and read-only; a missing path is missing.
    var fs: abi.StatFs = undefined;
    expect(lib.syscall(Sys.statfs, @intFromPtr("/etc/motd"), @intFromPtr(&fs), 0) == 0, 109);
    expect(fs.type == abi.TMPFS_MAGIC and fs.bsize == 4096 and fs.flags & 1 == 1, 110);
    expect(lib.syscall(Sys.statfs, @intFromPtr("/"), @intFromPtr(&fs), 0) == 0, 111);
    expect(lib.syscall(Sys.statfs, @intFromPtr("/sys/fs/cgroup"), @intFromPtr(&fs), 0) == lib.err(.NOENT), 112);
    expect(lib.syscall(Sys.statfs, @intFromPtr("/etc/motd"), 8, 0) == lib.err(.FAULT), 113);
    expect(lib.syscall(Sys.statfs, 8, @intFromPtr(&fs), 0) == lib.err(.FAULT), 114);

    // get_mempolicy: the default policy and no node chosen.
    var mode: i32 = -1;
    var mask: [2]u64 = .{ ~@as(u64, 0), ~@as(u64, 0) };
    expect(lib.syscall6(Sys.get_mempolicy, @intFromPtr(&mode), @intFromPtr(&mask), 65, 0, 0, 0) == 0, 115);
    expect(mode == 0 and mask[0] == 0 and mask[1] == 0, 116);
    expect(lib.syscall6(Sys.get_mempolicy, 0, 0, 0, 0, 0, 0) == 0, 117);
    expect(lib.syscall6(Sys.get_mempolicy, 8, 0, 0, 0, 0, 0) == lib.err(.FAULT), 118);
    expect(lib.syscall6(Sys.get_mempolicy, @intFromPtr(&mode), 0, 0, 0, 1, 0) == lib.err(.INVAL), 119);

    // mlock and munlock: nothing is ever paged out; the range must be the program's.
    expect(lib.syscall(Sys.mlock, @intFromPtr(&mode), 4, 0) == 0 and lib.syscall(Sys.munlock, @intFromPtr(&mode), 4, 0) == 0, 120);
    expect(lib.syscall(Sys.mlock, 0xFFFF_8000_0000_0000, 4096, 0) == lib.err(.NOMEM), 121);

    // The path calls a dynamic loader finds its libraries with.
    var st: abi.Stat = undefined;
    const cwd: u64 = @bitCast(@as(i64, abi.AT_FDCWD));
    expect(lib.syscall6(Sys.newfstatat, cwd, @intFromPtr("/etc/motd"), @intFromPtr(&st), 0, 0, 0) == 0, 130);
    expect(st.mode & abi.S.IFMT == abi.S.IFREG and st.size == 17 and st.ino != 0, 131);
    const motd_ino = st.ino;
    expect(lib.syscall6(Sys.newfstatat, cwd, @intFromPtr("/bin/hello"), @intFromPtr(&st), 0, 0, 0) == 0 and st.ino != motd_ino, 132);
    expect(lib.syscall6(Sys.newfstatat, cwd, @intFromPtr("/etc/nothing"), @intFromPtr(&st), 0, 0, 0) == lib.err(.NOENT), 133);
    expect(lib.syscall6(Sys.newfstatat, cwd, @intFromPtr("/etc/motd"), 8, 0, 0, 0) == lib.err(.FAULT), 134);
    expect(lib.syscall6(Sys.newfstatat, cwd, 8, @intFromPtr(&st), 0, 0, 0) == lib.err(.FAULT), 135);
    expect(lib.syscall6(Sys.newfstatat, cwd, @intFromPtr("/etc/motd"), @intFromPtr(&st), 0x4000_0000, 0, 0) == lib.err(.INVAL), 136);
    // Of a descriptor itself, with an empty path: the same file as by its path.
    const motd_fd = lib.open("/etc/motd");
    expect(lib.syscall6(Sys.newfstatat, motd_fd, @intFromPtr(""), @intFromPtr(&st), abi.AT_EMPTY_PATH, 0, 0) == 0 and st.ino == motd_ino, 137);
    expect(lib.syscall6(Sys.newfstatat, 1, @intFromPtr(""), @intFromPtr(&st), abi.AT_EMPTY_PATH, 0, 0) == 0 and st.mode & abi.S.IFMT == abi.S.IFCHR, 138);
    expect(lib.syscall6(Sys.newfstatat, 99, @intFromPtr(""), @intFromPtr(&st), abi.AT_EMPTY_PATH, 0, 0) == lib.err(.BADF), 139);
    // A relative path needs a directory, and there are none.
    expect(lib.syscall6(Sys.newfstatat, motd_fd, @intFromPtr("motd"), @intFromPtr(&st), 0, 0, 0) == lib.err(.NOTDIR), 140);
    expect(lib.syscall6(Sys.newfstatat, 99, @intFromPtr("motd"), @intFromPtr(&st), 0, 0, 0) == lib.err(.BADF), 141);
    expect(lib.syscall6(Sys.newfstatat, motd_fd, @intFromPtr("/etc/motd"), @intFromPtr(&st), 0, 0, 0) == 0, 142); // absolute: the descriptor does not matter
    _ = lib.close(motd_fd);

    expect(lib.syscall(Sys.access, @intFromPtr("/etc/motd"), abi.ACCESS.R_OK, 0) == 0, 143);
    expect(lib.syscall(Sys.access, @intFromPtr("/bin/hello"), abi.ACCESS.R_OK | abi.ACCESS.X_OK, 0) == 0, 144);
    expect(lib.syscall(Sys.access, @intFromPtr("/etc/motd"), abi.ACCESS.W_OK, 0) == lib.err(.ROFS), 145);
    expect(lib.syscall(Sys.access, @intFromPtr("/etc/ld.so.preload"), abi.ACCESS.R_OK, 0) == lib.err(.NOENT), 146);
    expect(lib.syscall(Sys.access, @intFromPtr("/etc/motd"), 8, 0) == lib.err(.INVAL), 147);
    expect(lib.syscall(Sys.access, 8, 0, 0) == lib.err(.FAULT), 148);
    expect(lib.syscall(Sys.faccessat, cwd, @intFromPtr("/etc/motd"), abi.ACCESS.F_OK) == 0, 149);
    expect(lib.syscall6(Sys.faccessat2, cwd, @intFromPtr("/nothing"), abi.ACCESS.F_OK, 0, 0, 0) == lib.err(.NOENT), 150);

    var link: [16]u8 = undefined;
    expect(lib.syscall(Sys.readlink, @intFromPtr("/etc/motd"), @intFromPtr(&link), link.len) == lib.err(.INVAL), 151); // not a link
    expect(lib.syscall(Sys.readlink, @intFromPtr("/etc/nothing"), @intFromPtr(&link), link.len) == lib.err(.NOENT), 152);
    expect(lib.syscall(Sys.readlink, @intFromPtr("/etc"), @intFromPtr(&link), link.len) == lib.err(.INVAL), 160); // a directory is no link either
    expect(lib.syscall6(Sys.readlinkat, cwd, @intFromPtr("/etc/motd"), @intFromPtr(&link), link.len, 0, 0) == lib.err(.INVAL), 153);

    expect(lib.syscall(Sys.getcwd, @intFromPtr(&link), link.len, 0) == 2 and link[0] == '/' and link[1] == 0, 154);
    expect(lib.syscall(Sys.getcwd, @intFromPtr(&link), 1, 0) == lib.err(.RANGE), 155);
    expect(lib.syscall(Sys.getcwd, 8, 16, 0) == lib.err(.FAULT), 156);

    // What a C library registers for its threads at startup.
    expect(lib.syscall(Sys.set_robust_list, @intFromPtr(&link), abi.ROBUST_LIST_HEAD_SIZE, 0) == 0, 157);
    expect(lib.syscall(Sys.set_robust_list, @intFromPtr(&link), 8, 0) == lib.err(.INVAL), 158);
    expect(lib.syscall6(Sys.rseq, @intFromPtr(&link), 32, 0, 0, 0, 0) == lib.err(.NOSYS), 159); // not offered

    // prctl: no option is known.
    expect(lib.syscall(Sys.prctl, 15, 0, 0) == lib.err(.INVAL), 122);

    _ = lib.syscall(Sys.exit_group, 0, 0, 0);
    lib.exit(99); // exit_group returned
}
