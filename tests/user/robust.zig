//! `/test/robust`: futexes in shared memory and robust mutexes, as Linux
//! has them. A futex without `FUTEX_PRIVATE_FLAG` in a shared mapping is
//! the same futex in every process that maps it, at whatever address (a
//! waiter in one is woken from the other); a private one stays the
//! process's. A process that ends holding a robust mutex has it marked
//! `FUTEX_OWNER_DIED` (keeping `FUTEX_WAITERS`), and its waiter is woken;
//! a word it does not own stays as it was. `get_robust_list` says what
//! was registered. Exits with 0, or with the number of the first failing
//! check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

const FUTEX_WAIT = 0;
const FUTEX_WAKE = 1;
const PRIVATE = 128;
const WAITERS: u32 = 0x8000_0000;
const OWNER_DIED: u32 = 0x4000_0000;

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn futex(addr: *u32, op: u64, val: u32, timeout: ?*const abi.TimeSpec) u64 {
    return lib.syscall6(Sys.futex, @intFromPtr(addr), op, val, if (timeout) |t| @intFromPtr(t) else 0, 0, 0);
}

fn sleepMs(ms: u64) void {
    var t: abi.TimeSpec = .{ .sec = 0, .nsec = @intCast(ms * 1_000_000) };
    _ = lib.syscall(Sys.nanosleep, @intFromPtr(&t), 0, 0);
}

fn wait(pid: u64) i32 {
    var status: i32 = -1;
    _ = lib.syscall6(Sys.wait4, pid, @intFromPtr(&status), 0, 0, 0, 0);
    return status;
}

fn mmap(addr: u64, len: u64, flags: u64, fd: i64) u64 {
    return lib.syscall6(Sys.mmap, addr, len, 3, flags, @bitCast(fd), 0);
}

pub fn main() noreturn {
    // --- Shared anonymous memory: a waiter in the child, woken from here.
    const shared = mmap(0, 4096, 0x01 | 0x20, -1); // MAP_SHARED | MAP_ANONYMOUS
    expect(!lib.isError(shared), 1);
    const word: *u32 = @ptrFromInt(shared);
    word.* = 0;
    const waiter = lib.syscall(Sys.fork, 0, 0, 0);
    if (waiter == 0) {
        // Without the private flag: the shared futex.
        const r = futex(word, FUTEX_WAIT, 0, null);
        lib.exit(if (r == 0 or r == lib.err(.AGAIN)) 0 else 40);
    }
    sleepMs(20);
    @atomicStore(u32, word, 1, .seq_cst);
    // Woken until it is (it may not be waiting yet the first time).
    var woken: u64 = 0;
    for (0..100) |_| {
        woken += futex(word, FUTEX_WAKE, 1, null);
        if (woken != 0) break;
        sleepMs(1);
    }
    expect(wait(waiter) == 0, 2);

    // A private wait on shared memory is the process's own: a shared wake
    // from another process does not reach it.
    word.* = 0;
    const private = lib.syscall(Sys.fork, 0, 0, 0);
    if (private == 0) {
        const limit: abi.TimeSpec = .{ .sec = 0, .nsec = 80_000_000 };
        lib.exit(if (futex(word, FUTEX_WAIT | PRIVATE, 0, &limit) == lib.err(.TIMEDOUT)) 0 else 41);
    }
    sleepMs(20);
    expect(futex(word, FUTEX_WAKE, 1, null) == 0, 3); // nobody on the shared one
    expect(wait(private) == 0, 4);

    // --- A memory file mapped at another address in the child: the same futex.
    const fd = lib.syscall(Sys.memfd_create, @intFromPtr("futex"), 0, 0);
    expect(!lib.isError(fd) and lib.syscall(Sys.ftruncate, fd, 8192, 0) == 0, 5);
    const here = mmap(0, 8192, 0x01, @intCast(fd));
    expect(!lib.isError(here), 6);
    const mine: *u32 = @ptrFromInt(here + 4096);
    mine.* = 7;
    const other = lib.syscall(Sys.fork, 0, 0, 0);
    if (other == 0) {
        _ = lib.syscall(Sys.munmap, here, 8192, 0);
        const there = mmap(0, 4 * 4096, 0x01, @intCast(fd)); // elsewhere, and bigger
        if (lib.isError(there) or there == here) lib.exit(42);
        const theirs: *u32 = @ptrFromInt(there + 4096);
        const r = futex(theirs, FUTEX_WAIT, 7, null);
        lib.exit(if (r == 0 or r == lib.err(.AGAIN)) 0 else 43);
    }
    sleepMs(20);
    @atomicStore(u32, mine, 8, .seq_cst);
    woken = 0;
    for (0..100) |_| {
        woken += futex(mine, FUTEX_WAKE, 1, null);
        if (woken != 0) break;
        sleepMs(1);
    }
    expect(wait(other) == 0, 7);

    // --- A file of /tmp, mapped shared by two processes that open it
    // each (how .NET keeps a named mutex): one memory, one futex.
    {
        var path_buf: [40]u8 = undefined;
        const text = std.fmt.bufPrint(path_buf[0..39], "/tmp/shm-{d}", .{lib.syscall(Sys.getpid, 0, 0, 0)}) catch unreachable;
        path_buf[text.len] = 0;
        const path: [*:0]const u8 = @ptrCast(&path_buf);
        const tf = lib.syscall(Sys.open, @intFromPtr(path), abi.O.RDWR | abi.O.CREAT, 0o600);
        expect(!lib.isError(tf) and lib.syscall(Sys.ftruncate, tf, 4096, 0) == 0, 20);
        const m = mmap(0, 4096, 0x01, @intCast(tf));
        expect(!lib.isError(m), 21);
        const flag: *u32 = @ptrFromInt(m + 128);
        flag.* = 0;
        const peer = lib.syscall(Sys.fork, 0, 0, 0);
        if (peer == 0) {
            // Its own open file and mapping of it, not the inherited ones.
            _ = lib.syscall(Sys.munmap, m, 4096, 0);
            const cf = lib.syscall(Sys.open, @intFromPtr(path), abi.O.RDWR, 0);
            const cm = mmap(0, 4096, 0x01, @intCast(cf));
            if (lib.isError(cm)) lib.exit(46);
            const data: [*]u8 = @ptrFromInt(cm);
            @memcpy(data[0..5], "hello");
            const cflag: *u32 = @ptrFromInt(cm + 128);
            sleepMs(20);
            @atomicStore(u32, cflag, 1, .seq_cst);
            for (0..100) |_| {
                if (futex(cflag, FUTEX_WAKE, 1, null) != 0) break;
                sleepMs(1);
            }
            lib.exit(0);
        }
        const r = futex(flag, FUTEX_WAIT, 0, null); // woken from the other process
        expect(r == 0 or r == lib.err(.AGAIN), 22);
        expect(wait(peer) == 0 and flag.* == 1, 23);
        const data: [*]const u8 = @ptrFromInt(m);
        expect(std.mem.eql(u8, data[0..5], "hello"), 24); // the child's write, in this mapping
        var back: [5]u8 = undefined;
        expect(lib.syscall6(Sys.pread64, tf, @intFromPtr(&back), 5, 0, 0, 0) == 5 and std.mem.eql(u8, &back, "hello"), 25); // and in the file
        // A private mapping of it: its writes are its own.
        const pm = mmap(0, 4096, 0x02, @intCast(tf)); // MAP_PRIVATE
        expect(!lib.isError(pm), 26);
        @as(*u8, @ptrFromInt(pm)).* = 'J';
        expect(data[0] == 'h', 27);
        _ = lib.syscall(Sys.munmap, pm, 4096, 0);
        _ = lib.syscall(Sys.munmap, m, 4096, 0);
        _ = lib.syscall(Sys.close, tf, 0, 0);
        expect(lib.syscall(Sys.unlink, @intFromPtr(path), 0, 0) == 0, 28);
    }

    // --- A robust mutex whose owner dies: marked, and its waiter woken.
    // In shared memory: the list head and an entry, and two futex words
    // 64 bytes after their entries.
    const base: [*]u8 = @ptrFromInt(shared);
    const head_at = shared + 256;
    const entry_at = shared + 512;
    const owned: *u32 = @ptrFromInt(entry_at + 64);
    const other_entry = shared + 768;
    const not_owned: *u32 = @ptrFromInt(other_entry + 64);
    _ = base;
    const owner = lib.syscall(Sys.fork, 0, 0, 0);
    if (owner == 0) {
        const tid: u32 = @intCast(lib.syscall(Sys.gettid, 0, 0, 0));
        // The list: head -> entry -> other entry -> head.
        const head: *[3]u64 = @ptrFromInt(head_at);
        head.* = .{ entry_at, 64, 0 };
        @as(*u64, @ptrFromInt(entry_at)).* = other_entry;
        @as(*u64, @ptrFromInt(other_entry)).* = head_at;
        owned.* = tid | WAITERS; // held, and someone waits
        not_owned.* = 12345; // somebody else's
        if (lib.syscall(Sys.set_robust_list, head_at, 24, 0) != 0) lib.exit(44);
        var got_head: u64 = 0;
        var got_len: u64 = 0;
        if (lib.syscall(Sys.get_robust_list, 0, @intFromPtr(&got_head), @intFromPtr(&got_len)) != 0 or got_head != head_at or got_len != 24) lib.exit(45);
        sleepMs(30); // the parent is waiting by then
        lib.exit(0); // dies holding it
    }
    // Wait for the owner to have taken it, then on it.
    for (0..200) |_| {
        if (@atomicLoad(u32, owned, .seq_cst) & WAITERS != 0) break;
        sleepMs(1);
    }
    const seen = @atomicLoad(u32, owned, .seq_cst);
    expect(seen & WAITERS != 0, 8);
    const r = futex(owned, FUTEX_WAIT, seen, null); // woken when the owner dies
    expect(r == 0 or r == lib.err(.AGAIN), 9);
    expect(wait(owner) == 0, 10);
    expect(@atomicLoad(u32, owned, .seq_cst) == OWNER_DIED | WAITERS, 11);
    expect(@atomicLoad(u32, not_owned, .seq_cst) == 12345, 12); // not its own: untouched
    lib.exit(0);
}
