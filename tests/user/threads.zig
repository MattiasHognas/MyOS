//! `/test/threads`: threads and futexes through the raw system calls, for
//! the cases a pthreads program does not reach on purpose.
//!
//! Without arguments it runs the checks that must succeed and exits with
//! 0, or with the number of the first failing check. With one argument it
//! ends in a way the kernel test knows the status of:
//!
//!   exitgroup  a second thread ends the process (status 7) while the
//!              first sleeps in a futex nothing will ever wake
//!   fault      a second thread touches address 0: the whole process is
//!              killed (255)
//!   mainexits  the first thread exits; the process lives until the
//!              second one does, and ends with its status (5)

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;
const FUTEX = abi.FUTEX;

const CLONE_VM = 0x100;
const CLONE_FS = 0x200;
const CLONE_FILES = 0x400;
const CLONE_SIGHAND = 0x800;
const CLONE_THREAD = 0x10000;
const CLONE_SETTLS = 0x80000;
const CLONE_PARENT_SETTID = 0x100000;
const CLONE_CHILD_CLEARTID = 0x200000;
const THREAD_FLAGS = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD;

// clone_raw(flags: rdi, stack: rsi, ptid: rdx, ctid: rcx, tls: r8) -> tid.
// The new thread finds its argument and its function at the top of its
// stack, calls the function, and exits (itself only) with what it returns.
comptime {
    asm (
        \\.section .text
        \\.global clone_raw
        \\.type clone_raw, @function
        \\clone_raw:
        \\  mov %rcx, %r10
        \\  mov $56, %eax
        \\  syscall
        \\  test %rax, %rax
        \\  jnz 1f
        \\  pop %rdi
        \\  pop %rax
        \\  call *%rax
        \\  mov %eax, %edi
        \\  mov $60, %eax
        \\  syscall
        \\  ud2
        \\1:
        \\  ret
    );
}
extern fn clone_raw(flags: u64, stack: u64, ptid: u64, ctid: u64, tls: u64) callconv(.c) u64;

// clone3_raw(args: rdi, size: rsi) -> tid. The new thread starts as one
// made by `clone_raw` does.
comptime {
    asm (
        \\.section .text
        \\.global clone3_raw
        \\.type clone3_raw, @function
        \\clone3_raw:
        \\  mov $435, %eax
        \\  syscall
        \\  test %rax, %rax
        \\  jnz 1f
        \\  pop %rdi
        \\  pop %rax
        \\  call *%rax
        \\  mov %eax, %edi
        \\  mov $60, %eax
        \\  syscall
        \\  ud2
        \\1:
        \\  ret
    );
}
extern fn clone3_raw(args: *const abi.CloneArgs, size: u64) callconv(.c) u64;

/// `start` through `clone3`, as newer C libraries make their threads: the
/// stack is given by its lowest address and its size.
fn start3(h: *Handle, func: ThreadFn, arg: usize, size: u64, flags: u64) u64 {
    h.stack = lib.mmap(0, STACK_SIZE, abi.PROT.READ | abi.PROT.WRITE, abi.MAP.STACK);
    if (lib.isError(h.stack)) lib.exit(90);
    const top: [*]u64 = @ptrFromInt(h.stack + STACK_SIZE);
    (top - 1)[0] = @intFromPtr(func);
    (top - 2)[0] = arg;
    // Two words longer than the first version, as a later version is.
    const args: extern struct { known: abi.CloneArgs, later: [2]u64 } = .{
        .known = .{
            .flags = flags,
            .pidfd = 0,
            .child_tid = @intFromPtr(&h.tid),
            .parent_tid = @intFromPtr(&h.tid),
            .exit_signal = 0,
            .stack = h.stack,
            .stack_size = STACK_SIZE - 16,
            .tls = @intFromPtr(&h.tls),
        },
        .later = .{ 0, 0 },
    };
    return clone3_raw(&args.known, size);
}

const ThreadFn = *const fn (usize) callconv(.c) u32;
const STACK_SIZE = 64 * 1024;

/// What the main thread keeps about a thread it started.
const Handle = struct {
    /// Set to the thread's ID when it is created, and to 0 by the kernel
    /// when it has exited: what `join` waits on.
    tid: std.atomic.Value(u32) = .init(0),
    stack: u64 = 0,
    /// Its thread-local block: FS points here.
    tls: [4]u64 = .{ 0, 0, 0, 0 },
};

fn start(h: *Handle, func: ThreadFn, arg: usize) u64 {
    h.stack = lib.mmap(0, STACK_SIZE, abi.PROT.READ | abi.PROT.WRITE, abi.MAP.STACK);
    if (lib.isError(h.stack)) lib.exit(90);
    const top: [*]u64 = @ptrFromInt(h.stack + STACK_SIZE);
    (top - 1)[0] = @intFromPtr(func);
    (top - 2)[0] = arg;
    return clone_raw(
        THREAD_FLAGS | CLONE_SETTLS | CLONE_PARENT_SETTID | CLONE_CHILD_CLEARTID,
        @intFromPtr(top - 2),
        @intFromPtr(&h.tid),
        @intFromPtr(&h.tid),
        @intFromPtr(&h.tls),
    );
}

fn futex(addr: *const std.atomic.Value(u32), op: u64, value: u32, timeout: ?*const abi.TimeSpec) u64 {
    return lib.syscall6(Sys.futex, @intFromPtr(addr), op, value, @intFromPtr(timeout), 0, 0);
}

/// Wait until the thread has exited, as `pthread_join` does.
fn join(h: *Handle) void {
    while (true) {
        const tid = h.tid.load(.acquire);
        if (tid == 0) break;
        _ = futex(&h.tid, FUTEX.WAIT, tid, null);
    }
    _ = lib.munmap(h.stack, STACK_SIZE);
}

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn nowNs() u64 {
    var ts: abi.TimeSpec = undefined;
    _ = lib.syscall(Sys.clock_gettime, abi.CLOCK.MONOTONIC, @intFromPtr(&ts), 0);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn sleepMs(ms: u64) void {
    const ts: abi.TimeSpec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(ms % 1000 * 1_000_000) };
    _ = lib.syscall(Sys.nanosleep, @intFromPtr(&ts), 0, 0);
}

fn readFs(index: usize) u64 {
    return switch (index) {
        0 => asm volatile ("mov %%fs:0, %[v]"
            : [v] "=r" (-> u64),
        ),
        else => asm volatile ("mov %%fs:8, %[v]"
            : [v] "=r" (-> u64),
        ),
    };
}

// --- Counting under a lock made of a futex.

var word_lock: std.atomic.Value(u32) = .init(0); // 0 free, 1 held, 2 held and wanted
var counter: u64 = 0;
var pid_seen_differs: std.atomic.Value(u32) = .init(0);
var main_pid: u64 = 0;
const ROUNDS = 5000;

fn lock() void {
    if (word_lock.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
    while (word_lock.swap(2, .acquire) != 0) _ = futex(&word_lock, FUTEX.WAIT, 2, null);
}

fn unlock() void {
    if (word_lock.swap(0, .release) == 2) _ = futex(&word_lock, FUTEX.WAKE, 1, null);
}

fn counting(index: usize) callconv(.c) u32 {
    // This thread's own block, through FS; nobody else's gets written.
    const tid = lib.gettid();
    asm volatile ("mov %[v], %%fs:0"
        :
        : [v] "r" (tid),
    );
    if (lib.syscall(Sys.getpid, 0, 0, 0) != main_pid or tid == main_pid) pid_seen_differs.store(1, .release);
    for (0..ROUNDS) |i| {
        lock();
        const seen = counter;
        if (i % 512 == index) lib.yield();
        counter = seen + 1;
        unlock();
    }
    asm volatile ("mov %[v], %%fs:8"
        :
        : [v] "r" (@as(u64, index + 1000)),
    );
    return if (readFs(0) == tid and readFs(1) == index + 1000) @intCast(index) else 99;
}

// --- Sleepers for the wake and requeue checks.

var gate_a: std.atomic.Value(u32) = .init(0);
var gate_b: std.atomic.Value(u32) = .init(0);
var woken: std.atomic.Value(u32) = .init(0);

fn sleeper(_: usize) callconv(.c) u32 {
    // Returns when woken, whichever word it was moved to meanwhile.
    _ = futex(&gate_a, FUTEX.WAIT, 0, null);
    _ = woken.fetchAdd(1, .release);
    return 0;
}

/// Let the sleepers get into the kernel: nothing in user space says when.
fn settle() void {
    sleepMs(30);
}

// --- The modes that end the process.

var never: std.atomic.Value(u32) = .init(0);

fn endsProcess(code: usize) callconv(.c) u32 {
    sleepMs(30); // the main thread is asleep in its futex by now
    _ = lib.syscall(Sys.exit_group, code, 0, 0);
    return 0;
}

fn faults(_: usize) callconv(.c) u32 {
    sleepMs(30);
    const p: *volatile u8 = @ptrFromInt(8);
    p.* = 1;
    return 0;
}

fn outlives(code: usize) callconv(.c) u32 {
    sleepMs(60); // the first thread is long gone
    return @intCast(code); // the last thread's exit status is the process's
}

const FAULT_PAGES = 512;
var fault_area: u64 = 0;
var fault_go: std.atomic.Value(u32) = .init(0);
var fault_wrong: std.atomic.Value(u32) = .init(0);

/// Touch every page of `fault_area`, in an order of this thread's own so
/// that the threads meet on pages rather than follow each other.
fn touches(index: usize) callconv(.c) u32 {
    while (fault_go.load(.acquire) == 0) _ = futex(&fault_go, FUTEX.WAIT, 0, null);
    for (0..FAULT_PAGES) |n| {
        const page = if (index % 2 == 0) n else FAULT_PAGES - 1 - n;
        const bytes: [*]volatile u8 = @ptrFromInt(fault_area + page * 4096);
        // What is there is zero, or another thread's mark in its own place.
        for (0..4) |other| {
            const seen = bytes[other * 64];
            if (seen != 0 and seen != other + 1) fault_wrong.store(1, .release);
        }
        if (bytes[4095] != 0) fault_wrong.store(1, .release);
        bytes[index * 64] = @intCast(index + 1);
    }
    return 0;
}

var marked: std.atomic.Value(u32) = .init(0);

fn marks(value: usize) callconv(.c) u32 {
    marked.store(@intCast(value), .release);
    return 0;
}

fn eql(s: [*:0]const u8, want: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(s), want);
}

var handles: [4]Handle = @splat(.{});

pub fn main() noreturn {
    main_pid = lib.syscall(Sys.getpid, 0, 0, 0);
    const args = lib.argv();
    if (args.len > 1) {
        if (eql(args[1], "exitgroup")) {
            _ = start(&handles[0], endsProcess, 7);
            _ = futex(&never, FUTEX.WAIT, 0, null);
        } else if (eql(args[1], "fault")) {
            _ = start(&handles[0], faults, 0);
            _ = futex(&never, FUTEX.WAIT, 0, null);
        } else if (eql(args[1], "mainexits")) {
            _ = start(&handles[0], outlives, 5);
            _ = lib.syscall(Sys.exit, 0, 0, 0); // this thread only
        }
        _ = lib.syscall(Sys.exit_group, 98, 0, 0);
    }

    // --- The process and its first thread have the same ID.
    expect(main_pid == lib.gettid() and main_pid != 0, 1);

    // --- Four threads, one counter, a lock made of a futex.
    for (&handles, 0..) |*h, i| {
        const tid = start(h, counting, i);
        expect(!lib.isError(tid) and tid != main_pid, 2);
        expect(h.tid.load(.acquire) == 0 or h.tid.load(.acquire) == tid, 3); // told its ID, unless it is gone already
    }
    for (&handles) |*h| join(h);
    expect(counter == 4 * ROUNDS, 4); // no update lost
    expect(pid_seen_differs.load(.acquire) == 0, 5); // one process ID, different thread IDs
    for (&handles, 0..) |*h, i| {
        expect(h.tls[1] == i + 1000 and h.tls[0] != 0, 6); // each wrote to its own block
        for (handles[0..i]) |other| expect(other.tls[0] != h.tls[0], 7);
    }

    // --- A futex wait only sleeps if the word is what the caller saw.
    expect(futex(&gate_a, FUTEX.WAIT, 1, null) == lib.err(.AGAIN), 10);
    // With a time limit it comes back when the time is up, not before.
    const limit: abi.TimeSpec = .{ .sec = 0, .nsec = 30_000_000 };
    const t0 = nowNs();
    expect(futex(&gate_a, FUTEX.WAIT, 0, &limit) == lib.err(.TIMEDOUT), 11);
    const waited = nowNs() - t0;
    expect(waited >= 30_000_000 and waited < 500_000_000, 12);
    // Until a time that has passed: at once.
    const past: abi.TimeSpec = .{ .sec = 0, .nsec = 1 };
    expect(lib.syscall6(Sys.futex, @intFromPtr(&gate_a), FUTEX.WAIT_BITSET, 0, @intFromPtr(&past), 0, 0xFFFF_FFFF) == lib.err(.TIMEDOUT), 13);
    // Waking where nobody waits wakes nobody.
    expect(futex(&gate_a, FUTEX.WAKE, 10, null) == 0, 14);
    // What is refused.
    expect(lib.syscall6(Sys.futex, @intFromPtr(&gate_a) + 1, FUTEX.WAKE, 1, 0, 0, 0) == lib.err(.INVAL), 15);
    expect(lib.syscall6(Sys.futex, 0xFFFF_8000_0000_0000, FUTEX.WAKE, 1, 0, 0, 0) == lib.err(.FAULT), 16);
    expect(lib.syscall6(Sys.futex, 4096, FUTEX.WAIT, 0, 0, 0, 0) == lib.err(.FAULT), 17); // not mapped
    expect(lib.syscall6(Sys.futex, @intFromPtr(&gate_a), 77, 1, 0, 0, 0) == lib.err(.NOSYS), 18);
    expect(lib.syscall6(Sys.futex, @intFromPtr(&gate_a), FUTEX.WAIT_BITSET, 0, 0, 0, 0) == lib.err(.INVAL), 19); // empty bit set

    // --- Three sleepers: a wake of two wakes two.
    woken.store(0, .release);
    for (handles[0..3]) |*h| expect(!lib.isError(start(h, sleeper, 0)), 20);
    settle();
    expect(futex(&gate_a, FUTEX.WAKE, 2, null) == 2, 21);
    settle();
    expect(woken.load(.acquire) == 2, 22);
    expect(futex(&gate_a, FUTEX.WAKE, 2, null) == 1, 23); // the one that was left
    for (handles[0..3]) |*h| join(h);

    // --- Moving sleepers to another word: they wake when that one is woken.
    woken.store(0, .release);
    for (handles[0..3]) |*h| expect(!lib.isError(start(h, sleeper, 0)), 24);
    settle();
    // Wake one, move the other two to gate_b; only if gate_a is still 0.
    expect(lib.syscall6(Sys.futex, @intFromPtr(&gate_a), FUTEX.CMP_REQUEUE, 1, 2, @intFromPtr(&gate_b), 5) == lib.err(.AGAIN), 25);
    expect(lib.syscall6(Sys.futex, @intFromPtr(&gate_a), FUTEX.CMP_REQUEUE, 1, 2, @intFromPtr(&gate_b), 0) == 3, 26);
    settle();
    expect(woken.load(.acquire) == 1, 27);
    expect(futex(&gate_a, FUTEX.WAKE, 10, null) == 0, 28); // nobody is on the first word any more
    expect(futex(&gate_b, FUTEX.WAKE, 10, null) == 2, 29);
    for (handles[0..3]) |*h| join(h);
    expect(woken.load(.acquire) == 3, 30);

    // --- What clone refuses for threads (processes: `/test/fork`).
    expect(clone_raw(0x400 | 0x11, 0, 0, 0, 0) == lib.err(.INVAL), 40); // a process sharing the descriptor table
    expect(clone_raw(CLONE_VM | CLONE_SIGHAND, 0, 0, 0, 0) == lib.err(.INVAL), 41); // not in this thread group
    expect(clone_raw(THREAD_FLAGS | CLONE_SETTLS, 0, 0, 0, 0xFFFF_8000_0000_0000) == lib.err(.PERM), 42);
    expect(clone_raw(THREAD_FLAGS | CLONE_PARENT_SETTID, 0, 8, 0, 0) == lib.err(.FAULT), 43); // nowhere to write the ID

    // --- Page faults on several CPUs at once in one address space: four
    // threads go through the same untouched memory, so that the same page
    // is asked for by more than one of them at the same moment. Each must
    // find zeroes or what another has written, never anything else, and
    // nothing any of them wrote may be lost.
    fault_area = lib.mmap(0, FAULT_PAGES * 4096, abi.PROT.READ | abi.PROT.WRITE, 100);
    expect(!lib.isError(fault_area), 130);
    fault_wrong.store(0, .release);
    fault_go.store(0, .release);
    for (&handles, 0..) |*h, i| expect(!lib.isError(start(h, touches, i)), 131);
    fault_go.store(1, .release);
    _ = futex(&fault_go, FUTEX.WAKE, 4, null);
    for (&handles) |*h| join(h);
    expect(fault_wrong.load(.acquire) == 0, 132);
    for (0..FAULT_PAGES) |page| {
        const bytes: [*]const u8 = @ptrFromInt(fault_area + page * 4096);
        for (0..handles.len) |i| expect(bytes[i * 64] == i + 1, 133); // every thread's mark is there
        expect(bytes[4095] == 0, 134);
    }
    expect(lib.munmap(fault_area, FAULT_PAGES * 4096) == 0, 135);

    // --- clone3: the same thread, asked for with a structure.
    const all_flags = THREAD_FLAGS | CLONE_SETTLS | CLONE_PARENT_SETTID | CLONE_CHILD_CLEARTID;
    const tid3 = start3(&handles[0], marks, 77, @sizeOf(abi.CloneArgs), all_flags);
    expect(!lib.isError(tid3) and tid3 != 0, 140);
    join(&handles[0]);
    expect(marked.load(.acquire) == 77, 141);
    // A later, longer version of the structure with nothing in the new fields.
    expect(!lib.isError(start3(&handles[0], marks, 78, @sizeOf(abi.CloneArgs) + 16, all_flags)), 142);
    join(&handles[0]);
    expect(marked.load(.acquire) == 78, 143);
    // What is refused: nothing below starts a thread.
    var ca: extern struct { known: abi.CloneArgs, later: [2]u64 } = .{
        .known = .{ .flags = all_flags, .pidfd = 0, .child_tid = 0, .parent_tid = 0, .exit_signal = 0, .stack = 0, .stack_size = 0, .tls = 0 },
        .later = .{ 0, 1 },
    };
    const cap = @intFromPtr(&ca);
    expect(lib.syscall(Sys.clone3, cap, @sizeOf(abi.CloneArgs) + 16, 0) == lib.err(.INVAL), 144); // a field this kernel does not know
    expect(lib.syscall(Sys.clone3, cap, @sizeOf(abi.CloneArgs) - 8, 0) == lib.err(.INVAL), 145); // shorter than the first version
    expect(lib.syscall(Sys.clone3, cap, 8192, 0) == lib.err(.INVAL), 146);
    expect(lib.syscall(Sys.clone3, 8, @sizeOf(abi.CloneArgs), 0) == lib.err(.FAULT), 147);
    ca.known.flags = CLONE_VM | 0x400; // a process sharing the descriptor table
    expect(lib.syscall(Sys.clone3, cap, @sizeOf(abi.CloneArgs), 0) == lib.err(.INVAL), 148);
    ca.known.flags = all_flags;
    ca.known.exit_signal = 17;
    expect(lib.syscall(Sys.clone3, cap, @sizeOf(abi.CloneArgs), 0) == lib.err(.INVAL), 149);
    ca.known.exit_signal = 0;
    ca.known.stack_size = 4096; // a size and no stack
    expect(lib.syscall(Sys.clone3, cap, @sizeOf(abi.CloneArgs), 0) == lib.err(.INVAL), 155);
    ca.known.stack = ~@as(u64, 0xFFF); // the end wraps around
    ca.known.stack_size = 8192;
    expect(lib.syscall(Sys.clone3, cap, @sizeOf(abi.CloneArgs), 0) == lib.err(.INVAL), 156);

    // --- Time, and the number of CPUs.
    const before = nowNs();
    sleepMs(20);
    expect(nowNs() - before >= 20_000_000, 50);
    var real: abi.TimeSpec = undefined;
    expect(lib.syscall(Sys.clock_gettime, abi.CLOCK.REALTIME, @intFromPtr(&real), 0) == 0 and real.sec > 1_700_000_000, 51);
    expect(lib.syscall(Sys.clock_gettime, 99, @intFromPtr(&real), 0) == lib.err(.INVAL), 52);
    var seconds: i64 = 0;
    const t = lib.syscall(Sys.time, @intFromPtr(&seconds), 0, 0);
    expect(t >= @as(u64, @intCast(real.sec)) and t <= @as(u64, @intCast(real.sec)) + 2 and seconds == @as(i64, @intCast(t)), 157);
    expect(lib.syscall(Sys.time, 0, 0, 0) >= t and lib.syscall(Sys.time, 8, 0, 0) == lib.err(.FAULT), 158);
    var mask: u64 = 0;
    expect(lib.syscall(Sys.sched_getaffinity, 0, 8, @intFromPtr(&mask)) == 8 and mask & 1 == 1, 53);
    expect(lib.syscall(Sys.sched_getaffinity, 0, 4, @intFromPtr(&mask)) == lib.err(.INVAL), 54);

    _ = lib.syscall(Sys.exit_group, 0, 0, 0);
    unreachable;
}
