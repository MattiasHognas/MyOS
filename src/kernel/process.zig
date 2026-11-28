//! User processes: an address space, a loaded ELF program, a user stack and a
//! file descriptor table, run by a single thread.
//!
//! ## Ownership
//!
//! - A **process** owns its address space (the pages of its program and
//!   stack, and its page tables), its open files and its name. It is run by
//!   exactly one thread, which is created with it and is the only way it
//!   ends: `exit`, from the `exit` syscall or because the kernel kills it.
//! - A **thread** owns its kernel stack and its saved CPU state
//!   (`thread.zig`). It is freed by the scheduler after it exits, by
//!   whichever thread runs next.
//! - The `Process` structure itself is shared, and counted: one reference
//!   belongs to its thread, and one to whoever called `spawn`, who must
//!   give it up with `wait` (collect the exit status) or `release` (not
//!   interested). The structure is freed when the last reference goes.
//!
//! What is freed when:
//!
//! | When | What |
//! | --- | --- |
//! | `exit` | open files; the address space (all the process's memory); its place in the process tree; then its exit status becomes available and waiters wake |
//! | its thread is reaped | the kernel stack, the thread |
//! | the last reference is released | the `Process` structure and its name |
//!
//! The memory goes before the waiters are woken, so whoever waited for a
//! process can use what it had: a parent that runs one child after another
//! close to its memory limit never finds the last one's memory still
//! taken. Only the thread and its kernel stack follow a moment later, when
//! the CPU has left that stack.
//!
//! So a process that has exited but has not been waited for costs one small
//! structure, and its exit status stays available for as long as anyone
//! holds a reference: a child may exit long before its parent waits.
//!
//! ## The process tree
//!
//! A process started by another one is its child. Each process counts the
//! processes alive below it (for `Limits.max_descendants`). When a process
//! exits while it has children, they become children of its own parent, or
//! of nobody if it had none, so `parent` always points at a live process.
//!
//! ## Threads
//!
//! A process starts with one thread and may make more (`cloneThread`,
//! behind `clone`). They share everything the process owns: its address
//! space, its open files, what its signals do. Each has its own kernel
//! stack, registers, FS and GS base and signal mask (`thread.zig`), and
//! each holds a reference to the process for as long as it exists.
//!
//! - **A thread ends** with `exitThread` (`exit`). The others go on. The
//!   last thread to end ends the process, with that thread's status.
//! - **The process ends** with `exit` here (`exit_group`, or the kernel
//!   killing it for a fault): the calling thread marks the process as
//!   ending (`killed`), makes every other thread come through the kernel
//!   (`thread.interrupt`), waits until they have all gone, and only then
//!   gives up what the process owns. A thread finds out at the points
//!   where it would return to its program, and in the waits a program can
//!   stay in for as long as it likes (`dieIfKilled`, `thread.dying`).
//! - What several threads use at once has a lock: the address space
//!   (`user_memory.zig`) and the descriptor table (`files_lock`).
//!
//! ## Locking
//!
//! One spinlock, the process-tree lock, protects every process's parent
//! and child links, descendant count, reference count and exit status, and
//! the wait queue of threads waiting for that status (`docs/locking.md`).
//! It is outermost in the lock order, and nothing is allocated or freed
//! while it is held. Everything else in a `Process` is set before the
//! process can be seen, or used only by its own thread.
//!
//! Every process has `Limits` on what it may use: memory, open files, and
//! how many processes may be alive below it. A child inherits its parent's
//! limits. They bound what one program and the programs it starts can take;
//! they do not divide memory between unrelated programs.

const std = @import("std");

const arch_syscall = @import("../arch/x86_64/syscall.zig");
const context = @import("../arch/x86_64/context.zig");
const fpu = @import("../arch/x86_64/fpu.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const vmm = @import("../arch/x86_64/vmm.zig");
const assert = @import("debug/assert.zig");
const elf = @import("elf.zig");
const futex = @import("futex.zig");
const uaccess = @import("uaccess.zig");
const elf_image = @import("elf_image.zig");
const heap = @import("heap.zig");
const kstack = @import("kstack.zig");
const pmm = @import("pmm.zig");
const SpinLock = @import("sync/spinlock.zig").SpinLock;
const WaitQueue = @import("sync/wait_queue.zig").WaitQueue;
const thread = @import("thread.zig");
const open_file = @import("open_file.zig");
const vfs = @import("vfs.zig");
const random = @import("random.zig");
const startup_stack = @import("startup_stack.zig");
const user_memory = @import("user_memory.zig");
const vm_regions = @import("vm_regions.zig");
const timer = @import("timer.zig");
const signal = @import("signal.zig");
const vdso = @import("vdso.zig");
const abi = @import("abi");

/// Highest address a user stack can end at. Each process's stack ends at
/// a random page up to `STACK_RANDOM_PAGES` below this (`Process.stack_top`).
pub const STACK_TOP_MAX: u64 = 0x0000_7FFF_FFFF_0000;
/// Number of positions the top of a stack can have: 2^22 pages, a range of
/// 16 GiB, as on Linux. A program that needs the address of something on
/// the stack (to overwrite a return address, say) has to guess among them.
pub const STACK_RANDOM_PAGES: u64 = 1 << 22;
/// The initial stack pointer is moved down by a random multiple of 16
/// bytes below this many, so data at the very top is not at a fixed
/// offset within its page either.
const STACK_RANDOM_OFFSET: u64 = 2048;
const STACK_PAGES = 4; // 16 KiB
/// Address space below the top of the stack kept for the user stack: 8 MiB, Linux's
/// default stack limit. Only `STACK_PAGES` of it are mapped; a program image
/// may not be loaded into any of it.
pub const STACK_RESERVE: u64 = 8 * 1024 * 1024;
/// Lowest address a program may be loaded at. The first 64 KiB stay unmapped
/// (as on Linux), so a null pointer faults even with a small offset added.
pub const IMAGE_MIN: u64 = 0x1_0000;
/// Where a position-independent program is loaded: at a random page up to
/// `PIE_RANDOM_PAGES` (1 TiB, Linux's 28 bits) above this, which is where
/// Linux starts too. Its `brk` heap follows it; `mmap` works down from
/// the stack, far above.
pub const PIE_BASE: u64 = 0x5555_5555_4000;
pub const PIE_RANDOM_PAGES: u64 = 1 << 28;
/// Most memory the segments of one program may take under the default limits.
pub const MAX_IMAGE_BYTES: u64 = 256 * 1024 * 1024;
/// Most descriptors a process can have, and so the most
/// `Limits.max_files` can allow: Linux's default limit. The table starts
/// with `FILES_INITIAL` slots and is doubled when a descriptor beyond it is
/// needed (`growFiles`).
pub const MAX_FILES = 1024;
pub const FILES_INITIAL = 32;

/// What one process may use. Inherited by the processes it starts.
///
/// Each limit has the value enforced (Linux's soft limit) and a ceiling
/// (its hard limit): a process may change the first up to the second and
/// lower the second, never raise it (`prlimit64`). There are no users to
/// let one raise it.
pub const Limits = struct {
    /// Most pages of physical memory the process may take: its program
    /// (code, data, `.bss`), its stack, the page tables of its address
    /// space and its thread's kernel stack. `RLIMIT_DATA` (in bytes).
    max_pages: u64 = MAX_IMAGE_BYTES / pmm.PAGE_SIZE,
    max_pages_hard: u64 = UNLIMITED,
    /// Most processes that may be alive below this one at once: children,
    /// their children, and so on. Starting one more fails. `RLIMIT_NPROC`
    /// (which Linux counts per user).
    max_descendants: u64 = 1024,
    max_descendants_hard: u64 = UNLIMITED,
    /// Most descriptors the process may have, the three standard streams
    /// included; at most `MAX_FILES`. `RLIMIT_NOFILE`.
    max_files: u32 = MAX_FILES,
    max_files_hard: u32 = MAX_FILES,

    pub const UNLIMITED = std.math.maxInt(u64);

    /// The limits of a process nothing else started: a memory limit of
    /// three quarters of the machine's memory, so that one program cannot
    /// take everything on a small machine and is not held back on a large
    /// one.
    pub fn default() Limits {
        return .{ .max_pages = pmm.totalPages() / 4 * 3 };
    }

    /// `resource` as `getrlimit` reports it; null for one this does not
    /// enforce (`Process.other_limits` has those).
    pub fn get(l: *const Limits, resource: u32) ?abi.RLimit {
        return switch (resource) {
            abi.RLIMIT.DATA => .{ .cur = bytes(l.max_pages), .max = bytes(l.max_pages_hard) },
            abi.RLIMIT.NPROC => .{ .cur = count(l.max_descendants), .max = count(l.max_descendants_hard) },
            abi.RLIMIT.NOFILE => .{ .cur = l.max_files, .max = l.max_files_hard },
            else => null,
        };
    }

    /// Set `resource`, one `get` answers for, to `want`, which the caller
    /// has checked: `cur` not above `max`, and `max` not above what `get`
    /// says now.
    pub fn set(l: *Limits, resource: u32, want: abi.RLimit) void {
        switch (resource) {
            abi.RLIMIT.DATA => {
                l.max_pages = pages(want.cur);
                l.max_pages_hard = pages(want.max);
            },
            abi.RLIMIT.NPROC => {
                l.max_descendants = want.cur;
                l.max_descendants_hard = want.max;
            },
            abi.RLIMIT.NOFILE => {
                l.max_files = @intCast(want.cur);
                l.max_files_hard = @intCast(want.max);
            },
            else => unreachable,
        }
    }

    fn bytes(n: u64) u64 {
        return if (n == UNLIMITED) abi.RLIM_INFINITY else n *| pmm.PAGE_SIZE;
    }
    fn pages(b: u64) u64 {
        return if (b == abi.RLIM_INFINITY) UNLIMITED else b / pmm.PAGE_SIZE;
    }
    fn count(n: u64) u64 {
        return if (n == UNLIMITED) abi.RLIM_INFINITY else n;
    }
};

/// Where a program image may be loaded and how large it may be under
/// `limits`: from `IMAGE_MIN` up to the region reserved for the stack, and
/// as many pages as the memory limit leaves after the two stacks. This is
/// the early check, before anything is allocated; `spawn` checks the exact
/// total, page tables included, once the address space is built.
pub fn imageLimits(limits: Limits) elf_image.Limits {
    return .{
        .min_addr = IMAGE_MIN,
        .max_addr = STACK_TOP_MAX - STACK_RANDOM_PAGES * pmm.PAGE_SIZE - STACK_RESERVE,
        .max_bytes = (limits.max_pages -| (STACK_PAGES + kstack.STACK_PAGES)) * pmm.PAGE_SIZE,
    };
}

/// `imageLimits` for the default limits.
pub const image_limits: elf_image.Limits = imageLimits(.{});

/// Exit status of a process the kernel killed (a fault in ring 3, or a
/// state it could not return to).
pub const EXIT_KILLED = 255;

/// A user process. See the ownership rules at the top of this file.
pub const Process = struct {
    /// Physical address of the process's PML4; 0 once the address space
    /// has been freed.
    root: u64,
    /// User-space entry point from the ELF header.
    entry: u64,
    /// First address above the user stack; page aligned, chosen at random.
    stack_top: u64 = STACK_TOP_MAX,
    /// Stack pointer the program starts with: it points at `argc`, on a
    /// 16-byte boundary, as on Linux.
    entry_rsp: u64 = STACK_TOP_MAX,
    /// Heap-allocated copy of the name the process was spawned with.
    name: []const u8,
    /// Its arguments as `/proc/<pid>/cmdline` gives them, each ending in a
    /// NUL; on the heap (empty for a structure that never ran). Replaced by
    /// `execve` under `files_lock`.
    cmdline: []u8 = &.{},
    /// File descriptor table, indexed by fd. A process starts with 0, 1
    /// and 2 open on the console. Several descriptors can refer to one
    /// open file (`dup`), which is counted (`OpenFile.refs`).
    /// The working directory: what relative paths start from. Absolute and
    /// normalized, in memory of its own that is replaced when it changes,
    /// under `files_lock`.
    cwd: []u8 = &.{},
    /// The table is replaced by a longer one when it has to grow, so its
    /// address and length are read under `files_lock` too.
    files: []?*open_file.OpenFile = &.{},
    /// `FD_CLOEXEC` of each descriptor: closed by `execve`. As long as
    /// `files`, and replaced with it.
    fd_cloexec: []bool = &.{},
    /// What this process may use.
    limits: Limits = .{},
    /// Pages of physical memory the process takes (see `Limits.max_pages`).
    pages: u64 = 0,
    /// References to this structure: its thread's, and one per `spawn`
    /// caller that has not called `wait` or `release` yet.
    refs: u32 = 0,
    /// Exit status, once the process has exited.
    exit_code: ?u64 = null,
    /// Threads waiting in `wait` for the process to exit.
    exited: WaitQueue = .{},
    /// The process that started this one (or adopted it), if any. Always a
    /// process that has not exited.
    parent: ?*Process = null,
    /// Processes alive below this one (see `Limits.max_descendants`).
    descendants: u32 = 0,
    /// The ID programs know the process by (`getpid`): its first thread's.
    pid: usize = 0,
    /// Its threads, linked through `Thread.proc_next`, and how many there
    /// are. Under the process-tree lock.
    thread_list: ?*thread.Thread = null,
    thread_count: u32 = 0,
    /// When it was started, in timer ticks since boot.
    start_ticks: u64 = 0,
    /// Set, once, when the process is ending: its threads are to end too.
    killed: std.atomic.Value(bool) = .init(false),
    /// Set by someone else who wants the process ended (`terminate`): the
    /// exit status for it, or `NO_REQUEST`. The first of its threads to
    /// come through the kernel ends it with that status.
    exit_request: std.atomic.Value(u64) = .init(NO_REQUEST),
    /// Where the thread that ends the process waits for the others to go.
    /// Under the process-tree lock.
    threads_gone: WaitQueue = .{},
    /// Protects `files` and the reference counts of the open files.
    files_lock: SpinLock = .{ .rank = .descriptor_table },
    /// What each signal does (`rt_sigaction`), by signal number minus
    /// one, under `signal_lock`.
    /// (On the heap: 2 KiB, which a structure built on the stack would
    /// carry. `none_set` for a process structure that never runs.)
    signal_actions: *[abi.NSIG]abi.SigAction = &none_set,
    signal_lock: SpinLock = .{ .rank = .descriptor_table },
    /// Signals sent to the process as a whole (`kill`) and not yet
    /// delivered: any of its threads that does not block one takes it.
    signal_pending: std.atomic.Value(u64) = .init(0),
    /// What was queued with them (`signal.Queue`), and how many entries
    /// there are of this process's, its threads' included: under
    /// `signal_lock`.
    signal_queue: signal.Queue = .{},
    signals_queued: u64 = 0,
    /// Moves on with every signal sent to the process or one of its
    /// threads: for edge-triggered `epoll` on a `signalfd`.
    signal_version: std.atomic.Value(u64) = .init(0),
    /// Its regions of memory, `brk` heap and the lock for them and its
    /// page tables (`user_memory.zig`).
    mem: user_memory.UserMemory = .{},
    /// The parent's process ID (0 for none), kept with `parent` by
    /// `setParentLocked`: what `getppid` reads, without the tree lock.
    parent_pid: std.atomic.Value(u64) = .init(0),
    /// This process's children, and its link in its parent's list. A
    /// child that has exited stays in the list, a zombie, until its
    /// parent collects its status (`waitChild`) or exits itself; the
    /// list holds a reference to it (`refs`) for that.
    first_child: ?*Process = null,
    next_sibling: ?*Process = null,
    /// Threads of this process waiting in `wait4` for a child to change.
    /// Under the tree lock.
    children_changed: WaitQueue = .{},
    /// The signal the parent gets when this process ends (`clone`'s low
    /// byte; `SIGCHLD` for `fork`), 0 for none.
    exit_signal: u32 = 0,
    /// The signal that ended the process, 0 if it ended by itself or by
    /// the kernel without one: what `wait4` reports.
    term_signal: std.atomic.Value(u32) = .init(0),
    /// Its process group and session (`setpgid`, `setsid`): a process
    /// starts in its parent's, or in its own if it has no parent. Under the
    /// tree lock.
    pgid: u64 = 0,
    sid: u64 = 0,
    /// The thread that is replacing the program (`execve`), while it makes
    /// the others end.
    exec_thread: std.atomic.Value(?*thread.Thread) = .init(null),
    /// Link in the list of every process (`all_processes`), from when it is
    /// started until its structure is freed. Under the tree lock.
    all_next: ?*Process = null,
    /// Made by `vfork` (`CLONE_VFORK`): its parent's thread waits until it
    /// has called `execve` or ended, which sets this. Under the tree lock.
    vfork_pending: bool = false,
    /// Stopped by a signal (`SIGSTOP`, `SIGTSTP`, `SIGTTIN`, `SIGTTOU`)
    /// until `SIGCONT` comes: each of its threads waits on `resumed` on
    /// its way back to the program (`waitWhileStopped`). Written under the
    /// tree lock.
    stopped: std.atomic.Value(bool) = .init(false),
    resumed: WaitQueue = .{},
    /// What `wait4` has yet to tell the parent: the signal that stopped
    /// the process (`WUNTRACED`), and that it was continued
    /// (`WCONTINUED`). Under the tree lock.
    stop_report: u32 = 0,
    continued_report: bool = false,
    /// The limits not enforced (`RLIMIT_STACK`, `RLIMIT_CORE`,
    /// `RLIMIT_CPU`, ...), by number: kept as the program sets them and
    /// reported (`Limits` has those that are). Inherited like `limits`.
    /// The stack is reserved at 8 MiB whatever `RLIMIT_STACK` says.
    other_limits: [abi.RLIMIT.COUNT]abi.RLimit = default_other_limits,
};

const default_other_limits = blk: {
    var all: [abi.RLIMIT.COUNT]abi.RLimit = @splat(.{ .cur = abi.RLIM_INFINITY, .max = abi.RLIM_INFINITY });
    all[abi.RLIMIT.STACK].cur = STACK_RESERVE;
    // Signals queued at once (Linux sizes it by the machine's memory, to
    // thousands; each takes 136 bytes here).
    all[abi.RLIMIT.SIGPENDING] = .{ .cur = 1024, .max = 1024 };
    break :blk all;
};

/// The signal actions of a process structure that is not a real process
/// (tests' stand-ins): every one the default, never changed.
var none_set: [abi.NSIG]abi.SigAction = @splat(.{});

/// A table of signal actions for a new process: a copy of `from`, or all
/// defaults.
fn newActions(from: ?*const [abi.NSIG]abi.SigAction) error{OutOfMemory}!*[abi.NSIG]abi.SigAction {
    const t = try heap.allocator.create([abi.NSIG]abi.SigAction);
    if (from) |f| {
        @memcpy(t, f);
    } else {
        for (t) |*a| a.* = .{};
    }
    return t;
}

/// Every process that has been started and not freed, newest first, for
/// finding one by its ID (`kill`). Under the tree lock.
var all_processes: ?*Process = null;

fn registerLocked(p: *Process) void {
    p.all_next = all_processes;
    all_processes = p;
}

fn unregisterLocked(p: *Process) void {
    var link = &all_processes;
    while (link.*) |q| : (link = &q.all_next) {
        if (q == p) {
            link.* = p.all_next;
            return;
        }
    }
}

/// What `/proc/<pid>/stat` says of `p`.
pub fn describe(p: *Process) struct { state: u8, ppid: u64, pgid: u64, sid: u64, threads: u32 } {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    // R: a thread of it runs or is ready to; S: all of them wait; Z:
    // ended, not collected. (The states are read without the scheduler's
    // lock: what `ps` shows may be a moment old.)
    var running = false;
    var t = p.thread_list;
    while (t) |one| : (t = one.proc_next) {
        const st = @atomicLoad(@TypeOf(one.state), &one.state, .monotonic);
        if (st == .running or st == .ready) running = true;
    }
    return .{
        .state = if (p.exit_code != null) 'Z' else if (p.stopped.load(.acquire)) 'T' else if (running) 'R' else 'S',
        .ppid = if (p.parent) |parent| parent.pid else 0,
        .pgid = p.pgid,
        .sid = p.sid,
        .threads = p.thread_count,
    };
}

/// What `/proc/<pid>/schedstat` says of `p`: time running and ready but
/// waiting, in TSC cycles, and time slices, over all its threads alive
/// now.
pub fn schedTotals(p: *Process) struct { run: u64, wait: u64, slices: u64 } {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    var r: @TypeOf(schedTotals(p)) = .{ .run = 0, .wait = 0, .slices = 0 };
    const now = @import("stats.zig").rdtsc();
    var t = p.thread_list;
    while (t) |one| : (t = one.proc_next) {
        r.run += @atomicLoad(u64, &one.run_cycles, .monotonic);
        // A thread on a CPU now: its slice so far counts too, as on Linux.
        const since = @atomicLoad(u64, &one.run_since, .monotonic);
        if (@atomicLoad(bool, &one.on_cpu, .monotonic) and since != 0) r.run += now -% since;
        r.wait += @atomicLoad(u64, &one.wait_cycles, .monotonic);
        r.slices += @atomicLoad(u64, &one.slices, .monotonic);
    }
    return r;
}

/// The process with ID `pid`, with a reference the caller gives up with
/// `release`; null if there is none.
pub fn findRetained(pid: u64) ?*Process {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    var q = all_processes;
    while (q) |p| : (q = p.all_next) {
        if (p.pid == pid) {
            p.refs += 1;
            return p;
        }
    }
    return null;
}

/// The lowest process ID above `prev`, or null: for listing `/proc`.
pub fn pidAfter(prev: u64) ?u64 {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    var best: ?u64 = null;
    var q = all_processes;
    while (q) |p| : (q = p.all_next) {
        if (p.pid > prev and (best == null or p.pid < best.?)) best = p.pid;
    }
    return best;
}

/// The arguments as `/proc/<pid>/cmdline` gives them: each followed by a
/// NUL, on the heap.
fn joinArgs(argv: []const []const u8, name: []const u8) error{OutOfMemory}![]u8 {
    const list: []const []const u8 = if (argv.len != 0) argv else &.{name};
    var len: usize = 0;
    for (list) |a| len += a.len + 1;
    const out = try heap.allocator.alloc(u8, len);
    var at: usize = 0;
    for (list) |a| {
        @memcpy(out[at..][0..a.len], a);
        out[at + a.len] = 0;
        at += a.len + 1;
    }
    return out;
}

/// Send `sig` to the process with ID `pid` (`kill`); 0 checks only. False
/// if there is no such process, or it has ended (as a zombie it gets
/// nothing, and that is not an error on Linux: `zombie_ok`).
pub const SignalResult = enum { sent, no_such, zombie, full };

pub fn signalPid(pid: u64, sig: u32) SignalResult {
    return signalPidInfo(pid, sig, signal.fromCaller(sig, signal.SI.USER));
}

/// `signalPid` with the `siginfo` given (`rt_sigqueueinfo`), from the
/// calling process.
pub fn signalPidInfo(pid: u64, sig: u32, info: signal.SigInfo) SignalResult {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    var q = all_processes;
    while (q) |p| : (q = p.all_next) {
        if (p.pid != pid) continue;
        if (p.exit_code != null) return .zombie;
        if (sig != 0) signal.sendLocked(p, null, sig, info) catch return .full;
        return .sent;
    }
    return .no_such;
}

/// Send `sig` with `info` to the thread `tid` of `p` (`rt_tgsigqueueinfo`).
pub fn signalThreadInfo(p: *Process, tid: u64, sig: u32, info: signal.SigInfo) SignalResult {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    var t = p.thread_list;
    while (t) |one| : (t = one.proc_next) {
        if (one.id != tid) continue;
        if (sig != 0) signal.sendLocked(p, one, sig, info) catch return .full;
        return .sent;
    }
    return .no_such;
}

/// For a panic report: every process with its threads, their states and
/// signals, printed with `print`. Takes no lock (the other CPUs are
/// stopped, and one of them may hold any): what it shows can be a moment
/// out of date, never wrong for long.
pub fn dumpForPanic(comptime print: fn (comptime []const u8, anytype) void) void {
    var p = all_processes;
    var shown: usize = 0;
    while (p) |one| : (p = one.all_next) {
        shown += 1;
        if (shown > 64) return print("  (more processes)\n", .{});
        print("  pid {d} {s}: signals pending 0x{x}\n", .{ one.pid, one.name, one.signal_pending.load(.monotonic) });
        var t = one.thread_list;
        var threads: usize = 0;
        while (t) |th| : (t = th.proc_next) {
            threads += 1;
            if (threads > 32) break;
            const where: usize = if (th.cpu) |c| c.id else 99;
            print("    thread {d}: {t}{s} cpu {d}, pending 0x{x}, blocked 0x{x}{s}\n", .{
                th.id,                                                  th.state,                           if (th.on_cpu) " on" else "",
                where,                                                  th.signal_pending.load(.monotonic), th.signal_mask,
                if (th.wait_queue != null) ", on a wait queue" else "",
            });
        }
    }
}

/// Send `sig` to every process but `init` and `except` (`kill(-1)`).
/// Returns how many got it.
pub fn signalAll(sig: u32, except: *Process) usize {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    var n: usize = 0;
    var q = all_processes;
    while (q) |p| : (q = p.all_next) {
        if (p == except or p == init_process or p.exit_code != null) continue;
        if (sig != 0) signal.sendFromCallerLocked(p, null, sig) catch {};
        n += 1;
    }
    return n;
}

/// The process that adopts orphans: `init`, once the kernel has started
/// it (`setInit`). Under the tree lock.
var init_process: ?*Process = null;

/// Make `p` the process orphans go to. Its reference is the caller's.
pub fn setInit(p: ?*Process) void {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    init_process = p;
}

/// The process-tree lock: see "Locking" at the top of this file.
var tree_lock: SpinLock = .{ .rank = .process_tree };

/// How a process is started.
pub const SpawnOptions = struct {
    /// The process starting this one.
    parent: ?*Process = null,
    /// Limits for the new process; by default the parent's, or the default
    /// limits for a process the kernel starts.
    limits: ?Limits = null,
    /// Put the stack at a random address. Off only where a test or a
    /// debugging session needs the same layout every time.
    randomize: bool = true,
    /// The program's arguments; `argv[0]` is by convention its name. Empty
    /// means the name it is started under, alone.
    argv: []const []const u8 = &.{},
    /// Its environment: strings of the form `NAME=value`.
    envp: []const []const u8 = &.{},
    /// The working directory it starts in: absolute and normalized.
    cwd: []const u8 = "/",
};

/// Count a new process against every ancestor from `parent` up. Fails,
/// changing nothing, if one of them already has as many descendants as it
/// may. The tree lock must be held.
fn chargeDescendant(parent: ?*Process) error{TooManyProcesses}!void {
    var a = parent;
    while (a) |anc| : (a = anc.parent) {
        if (anc.descendants >= anc.limits.max_descendants) return error.TooManyProcesses;
    }
    a = parent;
    while (a) |anc| : (a = anc.parent) anc.descendants += 1;
}

/// Undo `chargeDescendant`. The tree lock must be held.
fn releaseDescendant(parent: ?*Process) void {
    var a = parent;
    while (a) |anc| : (a = anc.parent) anc.descendants -= 1;
}

/// Put `child` in the child list of `child.parent`. The tree lock must be held.
fn linkChild(child: *Process) void {
    const parent = child.parent orelse return;
    child.next_sibling = parent.first_child;
    parent.first_child = child;
}

/// Take `child` out of its parent's child list. The tree lock must be held.
fn unlinkChild(child: *Process) void {
    const parent = child.parent orelse return;
    var link = &parent.first_child;
    while (link.*) |c| : (link = &c.next_sibling) {
        if (c != child) continue;
        link.* = child.next_sibling;
        child.next_sibling = null;
        return;
    }
    assert.check(.process, false, "process '{s}' is not in its parent's child list", .{child.name});
}

/// Give the children of `p`, which is exiting, to `init` if `p` is one of
/// its descendants, or else to `p`'s parent (or to nobody). The ancestors
/// on the way already count them as descendants, so only the links
/// change. Children that have exited (zombies) nobody will collect now,
/// nor those that go to nobody: they are returned, linked through
/// `next_sibling`, for the caller to release once the lock is dropped.
/// The tree lock must be held.
fn reparentChildren(p: *Process) ?*Process {
    const adopter: ?*Process = blk: {
        const init = init_process orelse break :blk p.parent;
        if (init == p) break :blk null;
        var a = p.parent;
        while (a) |anc| : (a = anc.parent) {
            if (anc == init) break :blk init;
        }
        break :blk p.parent;
    };
    var gone: ?*Process = null;
    while (p.first_child) |child| {
        p.first_child = child.next_sibling;
        child.next_sibling = null;
        if (child.exit_code != null or adopter == null) {
            setParentLocked(child, null);
            child.next_sibling = gone;
            gone = child;
            continue;
        }
        setParentLocked(child, adopter);
        linkChild(child);
        // Adopted by init: it collects them (`waitChild`); an orphan that
        // ended already is news for it.
        if (adopter) |a| _ = a.children_changed.wakeAll();
    }
    return gone;
}

/// Terminate the current process with exit status `code` (0-255; the
/// `exit_group` syscall masks it, as on Linux), all its threads with it.
///
/// Makes the other threads end and waits for them, closes its files,
/// frees its address space, hands its children to its parent, leaves the
/// process tree, records the exit status, wakes every thread waiting for
/// it and exits the current thread. If another thread is already ending
/// the process, this one just ends. Must be called from a thread that
/// belongs to a process.
pub fn exit(code: u64) noreturn {
    _ = cpu.saveAndDisableInterrupts(); // never restored: we're done
    const me = thread.current();
    const p = me.process.?;
    if (p.killed.swap(true, .acq_rel)) die(); // another thread got there first

    // The other threads: each ends as soon as it comes through the kernel.
    tree_lock.take();
    var t = p.thread_list;
    while (t) |other| : (t = other.proc_next) {
        if (other != me) thread.interrupt(other);
    }
    while (p.thread_count > 1) p.threads_gone.wait(&tree_lock);
    tree_lock.drop();

    closeFiles(p); // nothing else uses them now
    freeAddressSpace(p); // before anyone is told: the memory is back when they hear
    tree_lock.take();
    assert.check(.process, p.exit_code == null, "process '{s}' exits twice", .{p.name});
    unlinkThread(p, me);
    var gone = reparentChildren(p);
    releaseDescendant(p.parent);
    p.exit_code = code;
    p.vfork_pending = false;
    // The last of the terminal's foreground group: the terminal has none
    // now, until a shell gives it to another.
    if (p.pgid == foreground_group and !groupExistsLocked(p.pgid)) foreground_group = 0;
    wakeOrphanedLocked();
    _ = p.exited.wakeAll(); // before the lock is released: the waiters are still there
    // A zombie in its parent's list until the parent collects it.
    if (p.parent) |parent| {
        _ = parent.children_changed.wakeAll();
        if (p.exit_signal != 0) signal.sendProcessLocked(parent, p.exit_signal);
    }
    if (p == init_process) init_process = null;
    tree_lock.drop();
    // The references this process's list held to children it had to let go.
    while (gone) |c| {
        gone = c.next_sibling;
        c.next_sibling = null;
        release(c);
    }
    thread.exit();
}

/// `exit` for a process a signal ends: `wait4` says so.
pub fn exitBySignal(sig: u32) noreturn {
    const p = thread.current().process.?;
    _ = p.term_signal.cmpxchgStrong(0, sig, .acq_rel, .acquire);
    exit(128 + sig);
}

/// `exit` for a process the kernel kills for a fault it does not handle:
/// as if the fault's signal had ended it, as on Linux.
pub fn exitForFault(sig: u32) noreturn {
    const p = thread.current().process.?;
    _ = p.term_signal.cmpxchgStrong(0, sig, .acq_rel, .acquire);
    exit(EXIT_KILLED);
}

/// Take `t` out of the thread list of `p`. The tree lock must be held.
fn unlinkThread(p: *Process, t: *thread.Thread) void {
    var link = &p.thread_list;
    while (link.*) |other| : (link = &other.proc_next) {
        if (other != t) continue;
        link.* = t.proc_next;
        t.proc_next = null;
        p.thread_count -= 1;
        signal.dropThreadQueue(p, t); // signals for it alone go with it
        return;
    }
    assert.check(.process, false, "thread {d} is not in the thread list of '{s}'", .{ t.id, p.name });
}

/// End the calling thread because its process is ending: leave the
/// process's list of threads, tell the thread that waits for that, and go.
fn die() noreturn {
    _ = cpu.saveAndDisableInterrupts();
    const me = thread.current();
    const p = me.process.?;
    tree_lock.take();
    unlinkThread(p, me);
    _ = p.threads_gone.wakeAll();
    tree_lock.drop();
    thread.exit();
}

/// End the calling thread if its process is ending, and the process if
/// someone asked for that. Called where a thread is about to return to
/// its program: after a system call and after an interrupt taken in ring
/// 3. No lock may be held.
pub fn dieIfKilled() void {
    const me = thread.current();
    const p = me.process orelse return;
    if (p.killed.load(.acquire) or endsForExec(p, me)) die();
    const code = p.exit_request.load(.acquire);
    if (code != NO_REQUEST) exit(code);
}

const NO_REQUEST = std.math.maxInt(u64);

/// The program the terminal's Ctrl+C ends: the one the shell started and
/// waits for. Under the tree lock. Whoever sets it holds a reference to it
/// until it has taken it back.
var foreground: ?*Process = null;

/// Make `p` the foreground program (null: none), the one Ctrl+C sends
/// `SIGINT` to while no process group has the terminal. For the kernel's
/// tests, which have no shell. Returns the previous one.
pub fn setForeground(p: ?*Process) ?*Process {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    const before = foreground;
    foreground = p;
    return before;
}

/// Send `sig` to the foreground: the terminal's foreground process group,
/// if a shell has set one; else the foreground program a kernel test set
/// (`setForeground`). For the terminal's Ctrl+C (`SIGINT`), Ctrl+\
/// (`SIGQUIT`) and Ctrl+Z (`SIGTSTP`): callable from an interrupt handler
/// holding no lock. True if there was anyone to send it to.
pub fn signalForeground(sig: u32) bool {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    if (foreground_group != 0) return signalGroupLocked(foreground_group, sig) != 0;
    const p = foreground orelse return false;
    signal.sendProcessLocked(p, sig);
    return true;
}

/// Whether the calling process is in the background on the terminal: a
/// shell has given the terminal to a group, and not to the caller's.
pub fn inBackground() bool {
    const me = thread.current().process orelse return false;
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    return foreground_group != 0 and me.pgid != foreground_group;
}

/// The terminal's foreground process group (`TIOCSPGRP`), 0 for none.
/// Under the tree lock.
var foreground_group: u64 = 0;

pub fn setForegroundGroup(pgid: u64) enum { ok, no_such } {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    if (pgid != 0 and !groupExistsLocked(pgid)) return .no_such;
    foreground_group = pgid;
    return .ok;
}

pub fn foregroundGroup() u64 {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    return foreground_group;
}

fn groupExistsLocked(pgid: u64) bool {
    var q = all_processes;
    while (q) |p| : (q = p.all_next) {
        if (p.pgid == pgid and p.exit_code == null) return true;
    }
    return false;
}

/// Send `sig` to every live process of the group `pgid`; how many got it.
/// The tree lock must be held.
fn signalGroupLocked(pgid: u64, sig: u32) usize {
    return signalGroupFrom(pgid, sig, false);
}

/// `signalGroupLocked`, from the calling process (`kill`) if `by_caller`.
fn signalGroupFrom(pgid: u64, sig: u32, by_caller: bool) usize {
    var n: usize = 0;
    var q = all_processes;
    while (q) |p| : (q = p.all_next) {
        if (p.pgid != pgid or p.exit_code != null) continue;
        if (sig != 0) {
            if (by_caller) signal.sendFromCallerLocked(p, null, sig) catch {} else signal.sendProcessLocked(p, sig);
        }
        n += 1;
    }
    return n;
}

/// `kill(-pgid)`: `sig` to the group from the calling process; how many
/// got it.
pub fn signalGroup(pgid: u64, sig: u32) usize {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    return signalGroupFrom(pgid, sig, true);
}

pub const GroupError = error{ NoSuchProcess, NotPermitted, Invalid };

/// `setpgid(pid, pgid)`: put the process `pid` (the caller or one of its
/// children; 0 for the caller) in the group `pgid` (0: its own ID), which
/// must be its own ID or a group of the caller's session. A session
/// leader cannot change its group.
pub fn setGroup(pid: u64, pgid: u64) GroupError!void {
    const me = thread.current().process.?;
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    const target = if (pid == 0 or pid == me.pid) me else blk: {
        var c = me.first_child;
        while (c) |child| : (c = child.next_sibling) {
            if (child.pid == pid and child.exit_code == null) break :blk child;
        }
        return error.NoSuchProcess;
    };
    if (target.sid != me.sid) return error.NotPermitted;
    if (target.pid == target.sid) return error.NotPermitted; // a session leader
    const want = if (pgid == 0) target.pid else pgid;
    if (want != target.pid) {
        // An existing group of the same session.
        var found = false;
        var q = all_processes;
        while (q) |p| : (q = p.all_next) {
            if (p.pgid == want and p.sid == me.sid and p.exit_code == null) found = true;
        }
        if (!found) return error.NotPermitted;
    }
    target.pgid = want;
}

/// `setsid`: the caller starts a new session and group of its own, with no
/// terminal. `EPERM` (`NotPermitted`) for a group leader.
pub fn newSession() GroupError!u64 {
    const me = thread.current().process.?;
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    if (me.pgid == me.pid) return error.NotPermitted;
    me.pgid = me.pid;
    me.sid = me.pid;
    return me.pid;
}

/// The group or session of the process `pid` (0 for the caller).
pub fn groupOf(pid: u64, which: enum { group, session }) ?u64 {
    const me = thread.current().process.?;
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    var q: ?*Process = if (pid == 0) me else all_processes;
    while (q) |p| : (q = p.all_next) {
        if (pid == 0 or p.pid == pid) return if (which == .group) p.pgid else p.sid;
    }
    return null;
}

/// Whether the process group `pgid` is orphaned: no live member has a
/// parent outside the group but in the same session, so no shell is left
/// to continue it. Linux throws away the terminal's stop signals for such
/// a group (`SIGTSTP`, `SIGTTIN`, `SIGTTOU`). Tree lock held.
fn orphanedLocked(pgid: u64) bool {
    var q = all_processes;
    while (q) |p| : (q = p.all_next) {
        if (p.pgid != pgid or p.exit_code != null) continue;
        const parent = p.parent orelse continue;
        if (parent.exit_code == null and parent.pgid != pgid and parent.sid == p.sid) return false;
    }
    return true;
}

/// `orphanedLocked` for the calling process's group.
pub fn ownGroupOrphaned() bool {
    const me = thread.current().process orelse return true;
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    return orphanedLocked(me.pgid);
}

/// After a process has ended: a group it left orphaned that has a
/// stopped process gets `SIGHUP` and `SIGCONT`, as on Linux, so it is not
/// stopped for ever with nobody to continue it. Any stopped process will
/// do to look at, since there are few. Tree lock held.
fn wakeOrphanedLocked() void {
    var q = all_processes;
    while (q) |m| : (q = m.all_next) {
        if (m.exit_code != null or !m.stopped.load(.acquire) or !orphanedLocked(m.pgid)) continue;
        // Continued now, so the group's other members are passed over.
        _ = signalGroupLocked(m.pgid, signal.SIG.HUP);
        _ = signalGroupLocked(m.pgid, signal.SIG.CONT);
    }
}

/// Stop `p` for the signal `sig`: its threads wait on their way back to
/// the program until it is continued, and its parent hears of it
/// (`wait4` with `WUNTRACED`, and `SIGCHLD` unless it asked not to with
/// `SA_NOCLDSTOP`). With the tree lock held. Nothing for a process that is
/// stopped or ending already.
pub fn stopLocked(p: *Process, sig: u32) void {
    if (p.stopped.load(.acquire) or ending(p)) return;
    p.stopped.store(true, .release);
    p.stop_report = sig;
    p.continued_report = false;
    var t = p.thread_list;
    while (t) |one| : (t = one.proc_next) thread.interrupt(one);
    if (p.parent) |parent| {
        _ = parent.children_changed.wakeAll();
        if (signal.tellsOfStops(parent)) signal.sendProcessLocked(parent, signal.SIG.CHLD);
    }
}

/// `stopLocked`, taking the tree lock.
pub fn stopProcess(p: *Process, sig: u32) void {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    stopLocked(p, sig);
}

/// Continue `p` if it is stopped (`SIGCONT`, as it is sent): its threads
/// go on, and its parent hears of it (`wait4` with `WCONTINUED`, and
/// `SIGCHLD` unless `SA_NOCLDSTOP`). With the tree lock held.
pub fn continueLocked(p: *Process) void {
    if (!p.stopped.load(.acquire)) return;
    p.stopped.store(false, .release);
    p.stop_report = 0;
    p.continued_report = true;
    _ = p.resumed.wakeAll();
    if (p.parent) |parent| {
        _ = parent.children_changed.wakeAll();
        if (signal.tellsOfStops(parent)) signal.sendProcessLocked(parent, signal.SIG.CHLD);
    }
}

/// Wait while the calling thread's process is stopped. Called on the way
/// back to the program, holding no lock; only the end of the process
/// (`SIGKILL`) ends the wait early: other signals stay pending until it
/// is continued, as on Linux.
pub fn waitWhileStopped() void {
    const p = thread.current().process orelse return;
    if (!p.stopped.load(.acquire)) return;
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    while (p.stopped.load(.acquire)) {
        if (!p.resumed.waitUnlessEnding(&tree_lock)) return;
    }
}

/// Send `sig` to the process `p` (`signal.sendProcessLocked`, with the
/// tree lock taken here). `p` must be alive: a reference, or the caller.
pub fn signalProcess(p: *Process, sig: u32) void {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    signal.sendFromCallerLocked(p, null, sig) catch {};
}

/// The thread of `p` with ID `tid`, alive, with a reference? Threads have
/// none: so this calls `f` with it under the tree lock, which keeps it
/// from being freed meanwhile. False if there is no such thread.
pub fn withThread(p: *Process, tid: u64, f: *const fn (*Process, *thread.Thread, u32) void, sig: u32) bool {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    var t = p.thread_list;
    while (t) |one| : (t = one.proc_next) {
        if (one.id == tid) {
            f(p, one, sig);
            return true;
        }
    }
    return false;
}

/// Have the process `p` end with status `code`, as if it had called
/// `exit_group`, the next time one of its threads comes through the
/// kernel: at once for a thread that is running a program (it is
/// interrupted) or waiting in a way it may be woken from. What its
/// threads hold is freed by the process itself, as in any exit. A process
/// that is ending already ends as it was going to. Callable with
/// interrupts off and from any thread; `p` must be alive (a reference).
pub fn terminate(p: *Process, code: u64) void {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    requestExit(p, code);
}

/// `terminate` with the tree lock held.
pub fn requestExitLocked(p: *Process, code: u64) void {
    requestExit(p, code);
}

/// End `p` because of the signal `sig` (`SIGKILL`), with the tree lock held.
pub fn requestKillLocked(p: *Process, sig: u32) void {
    if (p.killed.load(.acquire)) return;
    _ = p.term_signal.cmpxchgStrong(0, sig, .acq_rel, .acquire);
    requestExit(p, 128 + sig);
}

fn requestExit(p: *Process, code: u64) void {
    if (p.killed.load(.acquire)) return;
    _ = p.exit_request.cmpxchgStrong(NO_REQUEST, code, .acq_rel, .acquire);
    var t = p.thread_list;
    while (t) |one| : (t = one.proc_next) thread.interrupt(one);
}

/// Whether someone has asked `p` to end (`terminate`) or it is ending.
pub fn ending(p: *const Process) bool {
    return p.killed.load(.acquire) or p.exit_request.load(.acquire) != NO_REQUEST;
}

/// Whether `t` is to end because another thread of `p` is replacing the
/// program (`execve`).
pub fn endsForExec(p: *const Process, t: *const thread.Thread) bool {
    const by = p.exec_thread.load(.acquire) orelse return false;
    return by != t;
}

/// Terminate the calling thread with status `code` (the `exit` syscall).
/// The process's other threads go on; if there are none, the process ends
/// with that status. A thread that asked for it (`set_tid_address`, or
/// `CLONE_CHILD_CLEARTID`) has its exit announced: zero is written where
/// it said, and one thread waiting on that address as a futex is woken.
/// That is how `pthread_join` finds out.
pub fn exitThread(code: u64) noreturn {
    const me = thread.current();
    const p = me.process.?;
    {
        const held = tree_lock.acquire();
        const last = p.thread_count == 1;
        if (!last and !p.killed.load(.acquire)) {
            unlinkThread(p, me);
            tree_lock.release(held);
            // The process lives on: its memory is there to write to.
            if (me.clear_child_tid != 0) {
                const zero: u32 = 0;
                uaccess.copyToUser(me.clear_child_tid, std.mem.asBytes(&zero)) catch {};
                _ = futex.wake(p, me.clear_child_tid, 1, futex.ANY);
            }
            thread.exit();
        }
        tree_lock.release(held);
    }
    exit(code); // the last thread, or the process is ending anyway
}

/// Flags of `clone` (Linux's values).
pub const CLONE = struct {
    pub const VM = 0x100;
    pub const FS = 0x200;
    pub const FILES = 0x400;
    pub const SIGHAND = 0x800;
    pub const THREAD = 0x10000;
    pub const SYSVSEM = 0x40000;
    pub const VFORK = 0x4000;
    pub const SETTLS = 0x80000;
    pub const PARENT_SETTID = 0x100000;
    pub const CHILD_CLEARTID = 0x200000;
    pub const DETACHED = 0x400000;
    pub const CHILD_SETTID = 0x1000000;
    /// What makes a `clone` a new thread of the calling process.
    pub const THREAD_FLAGS = VM | SIGHAND | THREAD;
};

/// What `cloneThread` needs to know about the new thread.
pub const CloneArgs = struct {
    flags: u64,
    /// The stack pointer it starts with; 0 for its creator's.
    stack: u64,
    parent_tid: u64,
    child_tid: u64,
    tls: u64,
};

/// Make a new thread in the calling thread's process (`clone` with
/// `CLONE_VM | CLONE_SIGHAND | CLONE_THREAD`). It starts as if it had just
/// returned from the same `clone` call with result 0: with a copy of the
/// caller's registers `frame` and extended state, on the stack `args.stack`,
/// and with the caller's FS base unless `CLONE_SETTLS` gives it its own.
/// Returns the new thread's ID.
pub fn cloneThread(frame: *const arch_syscall.Frame, args: CloneArgs) error{ OutOfMemory, Fault, BadAddress, ProcessEnding }!usize {
    const me = thread.current();
    const p = me.process.?;
    if (args.flags & CLONE.SETTLS != 0 and args.tls >= vmm.USER_END) return error.BadAddress;

    // Until the thread has an ID, an error takes it back here; after that
    // it is taken back by hand below (`discard`).
    var unnumbered = true;
    const t = try thread.create(cloneStart, p);
    errdefer if (unnumbered) thread.destroy(t);
    const start_frame = try heap.allocator.create(arch_syscall.Frame);
    errdefer if (unnumbered) heap.allocator.destroy(start_frame);
    start_frame.* = frame.*;
    start_frame.rax = 0; // what `clone` returns in the new thread
    if (args.stack != 0) start_frame.rsp = args.stack;
    t.user_frame = start_frame;
    const bases = thread.userBases(); // as the program has them now
    t.fs_base = if (args.flags & CLONE.SETTLS != 0) args.tls else bases.fs;
    t.gs_base = bases.gs;
    t.signal_mask = me.signal_mask;
    if (args.flags & CLONE.CHILD_CLEARTID != 0) t.clear_child_tid = args.child_tid;
    // The extended state as it is now, in the registers.
    if (t.fpuArea()) |area| {
        const flags = cpu.saveAndDisableInterrupts();
        fpu.saveCurrent(area);
        cpu.restoreInterrupts(flags);
    }

    // The ID is needed before the thread runs: both may be told it in memory.
    const tid = thread.assignId(t);
    unnumbered = false;
    const tid32: u32 = @truncate(tid);
    const told = blk: {
        if (args.flags & CLONE.PARENT_SETTID != 0) uaccess.copyToUser(args.parent_tid, std.mem.asBytes(&tid32)) catch break :blk false;
        if (args.flags & CLONE.CHILD_SETTID != 0) uaccess.copyToUser(args.child_tid, std.mem.asBytes(&tid32)) catch break :blk false;
        break :blk true;
    };
    const held = tree_lock.acquire();
    if (!told or p.killed.load(.acquire)) {
        tree_lock.release(held);
        heap.allocator.destroy(start_frame);
        thread.discard(t);
        return if (!told) error.Fault else error.ProcessEnding;
    }
    p.refs += 1; // the thread's, given up when it is freed
    t.proc_next = p.thread_list;
    p.thread_list = t;
    p.thread_count += 1;
    thread.start(t);
    tree_lock.release(held);
    return tid;
}

/// First kernel code of a thread made by `cloneThread`: take the registers
/// it was given and go to ring 3 with them.
fn cloneStart() void {
    const me = thread.current();
    const given: *arch_syscall.Frame = @ptrCast(@alignCast(me.user_frame.?));
    const frame = given.*; // on this thread's kernel stack, which stays
    heap.allocator.destroy(given);
    me.user_frame = null;
    arch_syscall.enterUserFrame(&frame);
}

/// Collect `child`, which the caller has waited for and holds a reference
/// to, from its parent's list if it is still there as a zombie: for the
/// kernel's own code that starts and waits for a child of a process.
pub fn reap(child: *Process) void {
    const drop = blk: {
        const held = tree_lock.acquire();
        defer tree_lock.release(held);
        if (child.exit_code == null) break :blk false;
        if (child.parent == null) break :blk false;
        unlinkChild(child);
        setParentLocked(child, null);
        break :blk true;
    };
    if (drop) release(child);
}

/// What `waitChild` is to report besides children that ended.
pub const WaitFor = struct {
    /// Report `none_yet` instead of waiting (`WNOHANG`).
    nohang: bool = false,
    /// Children that stopped (`WUNTRACED`).
    stopped: bool = false,
    /// Children that were continued (`WCONTINUED`).
    continued: bool = false,
};

/// What `waitChild` found.
pub const WaitResult = union(enum) {
    /// A child that ended, stopped or was continued: its process ID and
    /// the status `wait4` reports (`(code << 8)`, the signal that ended
    /// it, `(sig << 8) | 0x7f` for a stop, `0xffff` for a continue).
    exited: struct { pid: usize, status: u32 },
    /// Children there are, and none has ended (`WNOHANG`).
    none_yet,
    /// No child matches.
    no_child,
    /// The thread was interrupted (a signal, or its process is ending).
    interrupted,
};

/// `wait4`: wait for a child of the calling process to end and collect
/// it, or, as `how` asks, to stop or be continued. `pid` -1 means any
/// child; a positive one, that child; 0, any in the caller's process
/// group; below -1, any in the group `-pid`.
pub fn waitChild(pid: i64, how: WaitFor) WaitResult {
    const me = thread.current().process.?;
    const found: *Process = blk: {
        const held = tree_lock.acquire();
        defer tree_lock.release(held);
        while (true) {
            var any = false;
            const group: ?u64 = if (pid == 0) me.pgid else if (pid < -1) @intCast(-pid) else null;
            var c = me.first_child;
            while (c) |child| : (c = child.next_sibling) {
                if (pid > 0 and child.pid != @as(u64, @intCast(pid))) continue;
                if (group) |g| if (child.pgid != g) continue;
                any = true;
                if (child.exit_code != null) {
                    unlinkChild(child);
                    setParentLocked(child, null);
                    break :blk child;
                }
                if (how.stopped and child.stop_report != 0) {
                    const sig = child.stop_report;
                    child.stop_report = 0;
                    return .{ .exited = .{ .pid = child.pid, .status = (sig << 8) | 0x7f } };
                }
                if (how.continued and child.continued_report) {
                    child.continued_report = false;
                    return .{ .exited = .{ .pid = child.pid, .status = 0xffff } };
                }
            }
            if (!any) return .no_child;
            if (how.nohang) return .none_yet;
            if (!me.children_changed.waitKillable(&tree_lock)) return .interrupted;
        }
    };
    const sig = found.term_signal.load(.acquire);
    const status: u32 = if (sig != 0) sig else @as(u32, @intCast(found.exit_code.? & 0xFF)) << 8;
    const child_pid = found.pid;
    release(found); // the list's reference
    return .{ .exited = .{ .pid = child_pid, .status = status } };
}

/// The parent's process ID, or 0 for a process with none.
pub fn parentPid(p: *Process) usize {
    return p.parent_pid.load(.acquire); // no lock: `getppid` is called often
}

/// Make `parent` the parent of `child` (null: none), and its ID what
/// `getppid` says. Tree lock held.
fn setParentLocked(child: *Process, parent: ?*Process) void {
    child.parent = parent;
    child.parent_pid.store(if (parent) |q| q.pid else 0, .release);
}

/// Make a new process that is a copy of the calling one (`fork`, and
/// `clone` without `CLONE_THREAD`). It has a copy of the caller's memory
/// (every page copied now: there is no copy-on-write yet), of its
/// descriptors (sharing their open files), its working directory, its
/// signal actions and limits, and one thread that starts as if it had
/// just returned from the same call with result 0, with the caller's
/// registers, extended state, FS and GS base and signal mask.
///
/// `CLONE_VM` (with `CLONE_VFORK`, which is how `vfork` and
/// `posix_spawn` use it) gets a copy too, not the same memory: what the
/// child writes before `execve` stays its own. `CLONE_VFORK` holds the
/// caller until the child calls `execve` or ends. `CLONE_SETTLS`,
/// `CLONE_PARENT_SETTID`, `CLONE_CHILD_SETTID` and `CLONE_CHILD_CLEARTID`
/// work as for threads. `exit_signal` goes to this process when the
/// child ends. Returns the child's process ID.
pub fn forkProcess(frame: *const arch_syscall.Frame, args: CloneArgs, exit_signal: u32) error{ OutOfMemory, Fault, BadAddress, TooManyProcesses, Interrupted }!usize {
    const me = thread.current();
    const parent = me.process.?;
    if (args.flags & CLONE.SETTLS != 0 and args.tls >= vmm.USER_END) return error.BadAddress;

    const root = try vmm.createAddressSpace();
    errdefer vmm.destroyAddressSpace(root);
    var mem: user_memory.UserMemory = .{};
    errdefer mem.regions.deinit(heap.allocator);
    const copied = try copyMemory(parent, root, &mem);
    const pages = copied + kstack.STACK_PAGES;
    if (pages > parent.limits.max_pages) return error.OutOfMemory;

    const child = try heap.allocator.create(Process);
    errdefer heap.allocator.destroy(child);
    const name = try heap.allocator.dupe(u8, parent.name);
    errdefer heap.allocator.free(name);

    // Descriptors: the same open files, each with a reference more.
    const fds = try copyDescriptors(parent);
    const files = fds.files;
    const cloexec = fds.cloexec;
    const cwd = fds.cwd;
    errdefer heap.allocator.free(cwd);
    errdefer heap.allocator.free(cloexec);
    errdefer heap.allocator.free(files);
    var files_given = false;
    errdefer if (!files_given) for (files) |slot| if (slot) |of| open_file.unref(of);

    initChild(child, parent, root, name, pages, exit_signal, args.flags & CLONE.VFORK != 0, &mem);
    child.files = files;
    child.fd_cloexec = cloexec;
    child.cwd = cwd;
    child.signal_actions = try newActions(null);
    errdefer heap.allocator.destroy(child.signal_actions);
    child.cmdline = try heap.allocator.dupe(u8, parent.cmdline);
    errdefer heap.allocator.free(child.cmdline);
    {
        const held = parent.signal_lock.acquire();
        defer parent.signal_lock.release(held);
        @memcpy(child.signal_actions, parent.signal_actions); // (not by assignment: that copies 2 KiB through the stack)
    }

    // Until the thread has an ID, an error takes it back here; after that,
    // by hand below.
    var unnumbered = true;
    const made = try newChildThread(child, frame, args, me);
    const t = made[0];
    const start_frame = made[1];
    errdefer if (unnumbered) {
        heap.allocator.destroy(start_frame);
        thread.destroy(t);
    };

    const tid = thread.assignId(t);
    unnumbered = false;
    const tid32: u32 = @truncate(tid);
    // Told in the parent's memory, and in the child's copy.
    if (args.flags & CLONE.PARENT_SETTID != 0) uaccess.copyToUser(args.parent_tid, std.mem.asBytes(&tid32)) catch {};
    if (args.flags & CLONE.CHILD_SETTID != 0) writeInto(root, args.child_tid, tid32);

    const charged = blk: {
        const held = tree_lock.acquire();
        defer tree_lock.release(held);
        chargeDescendant(parent) catch break :blk false;
        linkChild(child);
        registerLocked(child);
        live += 1;
        child.pid = tid;
        child.pgid = parent.pgid;
        child.sid = parent.sid;
        child.thread_list = t;
        child.thread_count = 1;
        files_given = true;
        thread.start(t);
        break :blk true;
    };
    if (!charged) {
        // Freed outside the tree lock; the rest goes with the errdefers.
        heap.allocator.destroy(start_frame);
        thread.discard(t);
        return error.TooManyProcesses;
    }

    if (child.vfork_pending) waitForVfork(child);
    return tid;
}

/// Hold the calling thread until `child`, made by `vfork`, has called
/// `execve` or ended. It cannot be freed meanwhile: its exit wakes this
/// wait before anyone can collect it.
noinline fn waitForVfork(child: *Process) void {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    while (child.vfork_pending) {
        if (!child.exited.waitUnlessEnding(&tree_lock)) break;
    }
}

/// The fields of `forkProcess`'s child that come from its parent. Not
/// inlined, as `copyMemory`.
noinline fn initChild(child: *Process, parent: *Process, root: u64, name: []const u8, pages: u64, exit_signal: u32, vfork: bool, mem: *const user_memory.UserMemory) void {
    child.* = .{
        .root = root,
        .entry = parent.entry,
        .stack_top = parent.stack_top,
        .entry_rsp = parent.entry_rsp,
        .name = name,
        .limits = parent.limits,
        .other_limits = parent.other_limits,
        .pages = pages,
        .parent = parent,
        .parent_pid = .init(parent.pid),
        .refs = 2, // the thread's and the parent's list's
        .start_ticks = timer.now(),
        .exit_signal = exit_signal,
        .vfork_pending = vfork,
        .mem = mem.*,
    };
}

/// `forkProcess`'s thread for the child: made, not started, with the
/// registers `frame` (returning 0), the stack, the FS and GS base, the
/// signal mask and alternate stack and the extended state of `me`. Not
/// inlined, as `copyMemory`.
noinline fn newChildThread(child: *Process, frame: *const arch_syscall.Frame, args: CloneArgs, me: *thread.Thread) error{OutOfMemory}!struct { *thread.Thread, *arch_syscall.Frame } {
    const t = try thread.create(cloneStart, child);
    errdefer thread.destroy(t);
    const start_frame = try heap.allocator.create(arch_syscall.Frame);
    start_frame.* = frame.*;
    start_frame.rax = 0;
    if (args.stack != 0) start_frame.rsp = args.stack;
    t.user_frame = start_frame;
    const bases = thread.userBases();
    t.fs_base = if (args.flags & CLONE.SETTLS != 0) args.tls else bases.fs;
    t.gs_base = bases.gs;
    t.signal_mask = me.signal_mask;
    t.signal_stack = me.signal_stack;
    // A forked child keeps its registration (its copy of the area); one
    // that shares the parent's memory does not, as on Linux.
    if (args.flags & CLONE.VM == 0) t.rseq = me.rseq;
    if (args.flags & CLONE.CHILD_CLEARTID != 0) t.clear_child_tid = args.child_tid;
    if (t.fpuArea()) |area| {
        const flags = cpu.saveAndDisableInterrupts();
        fpu.saveCurrent(area);
        cpu.restoreInterrupts(flags);
    }
    return .{ t, start_frame };
}

/// `forkProcess`'s copy of the memory of `parent` into the empty address
/// space `root`: the regions and the pages, at one moment (under the
/// address-space lock). Returns the pages and tables `root` took. Not
/// inlined: it keeps its locals off `forkProcess`'s frame.
noinline fn copyMemory(parent: *Process, root: u64, mem: *user_memory.UserMemory) error{OutOfMemory}!usize {
    // The regions' room first (it needs memory, and the lock is a
    // spinlock), then everything at once under the lock.
    var room: usize = 0;
    while (true) {
        {
            const held = parent.mem.lock.acquire();
            defer parent.mem.lock.release(held);
            if (mem.regions.list.capacity >= parent.mem.regions.list.items.len) {
                mem.regions.list.clearRetainingCapacity();
                mem.regions.list.appendSliceAssumeCapacity(parent.mem.regions.list.items);
                mem.regions.holdAll(); // the child's regions hold what the parent's do (memory objects)
                mem.brk_start = parent.mem.brk_start;
                mem.brk_end = parent.mem.brk_end;
                mem.mmap_top = parent.mem.mmap_top;
                // (An empty space has nothing mapped already.)
                return vmm.copyUserSpace(parent.root, root) catch error.OutOfMemory;
            }
            room = parent.mem.regions.list.items.len + 8;
        }
        try mem.regions.list.ensureTotalCapacity(heap.allocator, room);
    }
}

/// `forkProcess`'s copy of the descriptor table and working directory of
/// `parent`: the same open files, each with a reference more. Not inlined,
/// as `copyMemory`.
noinline fn copyDescriptors(parent: *Process) error{OutOfMemory}!struct { files: []?*open_file.OpenFile, cloexec: []bool, cwd: []u8 } {
    var files: []?*open_file.OpenFile = &.{};
    var cloexec: []bool = &.{};
    var cwd: []u8 = &.{};
    while (true) {
        const want = blk: {
            const held = parent.files_lock.acquire();
            defer parent.files_lock.release(held);
            if (files.len == parent.files.len and cwd.len == parent.cwd.len) {
                @memcpy(files, parent.files);
                @memcpy(cloexec, parent.fd_cloexec);
                @memcpy(cwd, parent.cwd);
                for (files) |slot| if (slot) |of| open_file.retain(of);
                return .{ .files = files, .cloexec = cloexec, .cwd = cwd };
            }
            break :blk .{ parent.files.len, parent.cwd.len };
        };
        heap.allocator.free(files);
        heap.allocator.free(cloexec);
        heap.allocator.free(cwd);
        files = &.{};
        cloexec = &.{};
        cwd = &.{};
        files = try heap.allocator.alloc(?*open_file.OpenFile, want[0]);
        cloexec = heap.allocator.alloc(bool, want[0]) catch |e| {
            heap.allocator.free(files);
            return e;
        };
        cwd = heap.allocator.alloc(u8, want[1]) catch |e| {
            heap.allocator.free(files);
            heap.allocator.free(cloexec);
            return e;
        };
    }
}

/// Write `value` at the user address `addr` of the address space `root`,
/// which need not be loaded: through the kernel's mapping of the page.
/// Nothing is written if the page is not there or not writable. A page
/// shared copy-on-write (the child of a `fork`, before it runs) gets its
/// own copy first; nothing else uses `root` yet.
fn writeInto(root: u64, addr: u64, value: u32) void {
    if (addr % 4 != 0 or addr >= vmm.USER_END) return;
    var e = vmm.leafEntry(root, addr) orelse return;
    if (e & vmm.COW != 0 and e & vmm.USER != 0) {
        _ = vmm.breakCow(root, addr) catch return;
        e = vmm.leafEntry(root, addr) orelse return;
    }
    if (e & vmm.WRITABLE == 0 or e & vmm.USER == 0) return;
    const phys = vmm.translate(root, addr) orelse return;
    @as(*u32, @ptrCast(@alignCast(pmm.physToVirt(phys)))).* = value;
}

/// Wait for `p` to exit and return its exit status, giving up the caller's
/// reference: `p` must not be used afterwards. Returns at once if it has
/// already exited, however long ago. Several threads may wait for the same
/// process, each with a reference of its own (`retain`).
pub fn wait(p: *Process) u64 {
    const code = blk: {
        const held = tree_lock.acquire();
        defer tree_lock.release(held);
        while (p.exit_code == null) p.exited.wait(&tree_lock);
        break :blk p.exit_code.?;
    };
    release(p);
    return code;
}

/// Take another reference to `p`, for a second thread that will `wait` for
/// it or look at it. The caller must already hold one.
pub fn retain(p: *Process) void {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    assert.check(.process, p.refs > 0, "retaining process '{s}', which has no references", .{p.name});
    p.refs += 1;
}

/// Give up a reference to `p` without waiting for it. The process runs on
/// regardless; its structure is freed when the last reference is gone.
pub fn release(p: *Process) void {
    {
        const held = tree_lock.acquire();
        defer tree_lock.release(held);
        assert.check(.process, p.refs > 0, "releasing process '{s}', which has no references", .{p.name});
        p.refs -= 1;
        if (p.refs > 0) return;
        assert.check(.process, p.exit_code != null and p.root == 0, "freeing process '{s}' while it is alive", .{p.name});
        assert.check(.process, p.exited.waiting() == 0 and p.first_child == null, "freeing process '{s}' that others still point at", .{p.name});
        unregisterLocked(p);
        live -= 1;
    }
    // Nobody else has a reference, so nobody else can reach it.
    signal.dropProcessQueue(p);
    if (p.signal_actions != &none_set) heap.allocator.destroy(p.signal_actions);
    heap.allocator.free(p.cmdline);
    heap.allocator.free(p.name);
    heap.allocator.destroy(p);
}

/// Whether `tid` is a thread of `p` that has not exited.
pub fn hasThread(p: *Process, tid: u64) bool {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    var t = p.thread_list;
    while (t) |one| : (t = one.proc_next) {
        if (one.id == tid) return true;
    }
    return false;
}

/// Number of `Process` structures that exist: processes that run, and
/// exited ones somebody still holds a reference to.
pub fn liveCount() usize {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    return live;
}

// Guarded by the tree lock.
var live: usize = 0;

/// Close every open file of `p` and free its descriptor table. Nothing
/// else uses them: the caller is the process's last thread.
fn closeFiles(p: *Process) void {
    for (p.files) |*slot| {
        if (slot.*) |of| open_file.unref(of);
        slot.* = null;
    }
    heap.allocator.free(p.files);
    p.files = &.{};
    heap.allocator.free(p.fd_cloexec);
    p.fd_cloexec = &.{};
    heap.allocator.free(p.cwd);
    p.cwd = &.{};
}

/// Make the descriptor table of `p` at least `slots` long (at most
/// `MAX_FILES`), keeping what is in it. False if there is no memory for it.
/// The new table is allocated without the lock and put in place with it;
/// if another thread has made the table long enough meanwhile, that one
/// stays.
pub fn growFiles(p: *Process, slots: usize) bool {
    std.debug.assert(slots <= MAX_FILES);
    var want: usize = FILES_INITIAL;
    while (want < slots) want *= 2;
    const new = heap.allocator.alloc(?*open_file.OpenFile, want) catch return false;
    const new_flags = heap.allocator.alloc(bool, want) catch {
        heap.allocator.free(new);
        return false;
    };
    const old, const old_flags = blk: {
        const held = p.files_lock.acquire();
        defer p.files_lock.release(held);
        if (p.files.len >= want) break :blk .{ new, new_flags }; // not needed after all
        @memcpy(new[0..p.files.len], p.files);
        @memset(new[p.files.len..], null);
        @memcpy(new_flags[0..p.files.len], p.fd_cloexec);
        @memset(new_flags[p.files.len..], false);
        const before = .{ p.files, p.fd_cloexec };
        p.files = new;
        p.fd_cloexec = new_flags;
        break :blk before;
    };
    heap.allocator.free(old);
    heap.allocator.free(old_flags);
    return true;
}

/// The file at the absolute path `path`, symbolic links followed: what
/// `/bin/sh` or `/lib64/ld-linux-x86-64.so.2` is. Released with
/// `vfs.release`. `error.FileNotFound`, `error.NameTooLong`,
/// `error.OutOfMemory`.
pub fn lookupFollowing(path: []const u8) !vfs.Node {
    const storage = try heap.allocator.alloc(u8, 3 * abi.PATH_MAX);
    defer heap.allocator.free(storage);
    const plain = vfs.normalize(storage[0..abi.PATH_MAX], "/", path) catch return error.FileNotFound;
    const followed = vfs.followLinks(storage[abi.PATH_MAX..][0..abi.PATH_MAX], storage[2 * abi.PATH_MAX ..], plain, true) catch return error.FileNotFound;
    return vfs.lookup(followed) orelse error.FileNotFound;
}

/// Load the executable at `path` from the VFS and start it as a new process.
///
/// Returns immediately without waiting for the process. Returns
/// `error.FileNotFound` if the file doesn't exist, `error.ReadFailed` if it
/// can't be read completely, or any error from `spawn`.
pub fn spawnPath(path: []const u8, options: SpawnOptions) !*Process {
    const node = try lookupFollowing(path);
    defer vfs.release(&node);
    const size = vfs.sizeOf(&node);
    const image = try heap.allocator.alloc(u8, size);
    defer heap.allocator.free(image); // elf.load copies it into the process's pages
    if (vfs.read(&node, 0, image) != size) return error.ReadFailed;
    return spawn(path, image, options);
}

/// Free the address space of `p`, whose only thread is the caller and is
/// exiting. The thread is in the kernel for good and uses kernel addresses
/// only from here on, so it moves to the kernel's own page tables; every
/// other CPU that still has the address space loaded (because it ran this
/// thread once and only kernel threads since) is made to do the same; then
/// nothing uses it and it is freed. Interrupts are off and stay off until
/// the thread is gone, so the scheduler cannot put the thread, and with it
/// the address space, back on a CPU.
fn freeAddressSpace(p: *Process) void {
    assert.check(.process, p.root != 0, "process '{s}' frees its address space twice", .{p.name});
    vmm.unloadRoot(p.root);
    vmm.destroyAddressSpace(p.root);
    p.root = 0;
    user_memory.deinit(p);
}

/// Called by the scheduler when a thread of `p` has been freed: gives up
/// that thread's reference. The process itself may be running on (it has
/// other threads) or long gone.
pub fn teardown(p: *Process) void {
    release(p);
}

/// Put on the new stack what the program finds there: arguments,
/// environment and the auxiliary vector, laid out as on Linux
/// (`startup_stack.zig`), ending at `data_top`. `interp_base` is where
/// the interpreter was loaded, 0 without one. Returns the stack pointer
/// the program starts with. Not inlined, for the reason given at
/// `loadInterpreter`.
noinline fn writeStartupData(
    name: []const u8,
    options: SpawnOptions,
    loaded: *const elf.Loaded,
    interp_base: u64,
    vdso_base: u64,
    stack_pages: *const [STACK_PAGES]u64,
    stack_top: u64,
    data_top: u64,
) !u64 {
    var random_bytes: [16]u8 = undefined;
    random.bytes(&random_bytes);
    const start_args: startup_stack.Args = .{
        .argv = if (options.argv.len != 0) options.argv else &.{name},
        .envp = options.envp,
        .execfn = name,
        .random = random_bytes,
        .phdr = loaded.phdr,
        .phent = elf_image.PHDR_SIZE,
        .phnum = loaded.phnum,
        .entry = loaded.entry,
        .base = interp_base,
        .hwcap = cpu.cpuid(1, 0).edx,
        .hwcap2 = if (@import("../arch/x86_64/percpu.zig").fsgsbase) abi.HWCAP2.FSGSBASE else 0,
        .clktck = timer.HZ,
        .sysinfo_ehdr = vdso_base,
    };
    const start_size = startup_stack.size(start_args) catch return error.ArgumentsTooLong;
    if (start_size > abi.ARG_MAX) return error.ArgumentsTooLong;
    const start_block = try heap.allocator.alloc(u8, start_size);
    defer heap.allocator.free(start_block);
    const entry_rsp = startup_stack.build(start_block, data_top, start_args) catch unreachable; // it has the size asked for
    copyToStack(stack_pages, stack_top, entry_rsp, start_block);
    return entry_rsp;
}

/// Load the program `image` into the empty address space `root`. A
/// position-independent one goes where Linux puts one: two thirds up the
/// address space, at a random page from there if `randomize`. Also
/// returns the path of the interpreter it names, if any (inside `image`).
/// Not inlined, for the reason given at `loadInterpreter`.
noinline fn loadProgram(root: u64, image: []const u8, limits: elf_image.Limits, randomize: bool, regions: *vm_regions.Regions) !struct { loaded: elf.Loaded, interp: ?[]const u8 } {
    const img = try elf_image.parse(image, limits);
    const bias = if (img.dynamic) blk: {
        const base = PIE_BASE + (if (randomize) random.below(PIE_RANDOM_PAGES) * pmm.PAGE_SIZE else 0);
        if (base < img.lowest or !img.fitsAt(base - img.lowest, limits)) return error.BadSegment;
        break :blk base - img.lowest;
    } else 0;
    return .{ .loaded = try elf.loadAt(root, &img, bias, regions), .interp = img.interp };
}

/// Load the program at `path` into the address space `root` as the
/// interpreter of the program that is there already (its dynamic loader).
/// A position-independent one goes where `mmap` would put it: the highest
/// free place below `mmap_top`. Fails with `error.FileNotFound`,
/// `error.Unsupported` if it names an interpreter of its own (one level,
/// as on Linux), or as `elf.loadAt` does.
///
/// A function of its own, never inlined, to keep the image and its
/// headers off the stack frame of `spawn`.
noinline fn loadInterpreter(root: u64, path: []const u8, limits: elf_image.Limits, regions: *vm_regions.Regions, mmap_top: u64) !elf.Loaded {
    const node = try lookupFollowing(path);
    defer vfs.release(&node);
    const size = vfs.sizeOf(&node);
    const image = try heap.allocator.alloc(u8, size);
    defer heap.allocator.free(image);
    if (vfs.read(&node, 0, image) != size) return error.ReadFailed;
    const img = try elf_image.parse(image, limits);
    if (img.interp != null) return error.Unsupported;
    const bias = if (img.dynamic) blk: {
        const at = regions.findFree(img.highest - img.lowest, IMAGE_MIN, mmap_top) orelse return error.OutOfMemory;
        break :blk at - img.lowest;
    } else 0;
    return elf.loadAt(root, &img, bias, regions);
}

/// Why `execve` did not replace the program.
pub const ExecError = error{ FileNotFound, ReadFailed, OutOfMemory, TooLarge, ArgumentsTooLong, NotExecutable, Interrupted };

/// `execve`: replace the calling process's program with the one in the
/// file at `path` (absolute and normalized), with arguments `argv` and
/// environment `envp`, and set `frame` so that the system call returns
/// to its first instruction. A file that starts with `#!` names its
/// interpreter, which is run instead with the file as an argument, as on
/// Linux (one level).
///
/// The new program is loaded first: on an error the old one goes on as
/// it was. Then the process's other threads end, and the process keeps
/// its ID, parent, children, descriptors (but those marked close-on-exec),
/// working directory, signal mask and pending signals, and limits; signal
/// handlers go back to the default (ignored signals stay ignored), the
/// alternate stack, FS and GS base and extended state are cleared, and a
/// parent waiting in `vfork` goes on.
pub fn execve(frame: *arch_syscall.Frame, path: []const u8, argv: []const []const u8, envp: []const []const u8) ExecError!void {
    const me = thread.current();
    const p = me.process.?;
    const file = readProgram(path, argv) catch |e| return e;
    defer heap.allocator.free(file.image);
    defer if (file.argv_storage) |a| heap.allocator.free(a);
    defer if (file.argv) |a| heap.allocator.free(a);
    const run_argv = if (file.argv) |a| a else argv;
    const run_path = file.run_path orelse path;

    // (The working directory does not matter: `path` is absolute.)
    const img = buildImage(run_path, file.image, .{ .argv = run_argv, .envp = envp }, p.limits) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooLarge => error.TooLarge,
        error.ArgumentsTooLong => error.ArgumentsTooLong,
        error.FileNotFound => error.FileNotFound,
        else => error.NotExecutable,
    };
    errdefer img.destroy();
    return execWith(frame, p, me, &img, path, run_argv, run_path);
}

/// The rest of `execve`, once the new program is loaded into `img`: the
/// other threads end, and this one goes on in the new program. Not
/// inlined, so that `execve`'s frame, which is on the stack while the
/// program is looked up and loaded (deep, in a Debug build), stays small.
/// On an error `execve` destroys `img`.
noinline fn execWith(frame: *arch_syscall.Frame, p: *Process, me: *thread.Thread, img: *const Image, path: []const u8, run_argv: []const []const u8, run_path: []const u8) ExecError!void {
    const name = try heap.allocator.dupe(u8, path);
    errdefer heap.allocator.free(name);
    const cmdline = try joinArgs(run_argv, run_path);
    errdefer heap.allocator.free(cmdline);

    // The other threads end; this one, if another got here first or the
    // process is ending, goes with them.
    if (p.exec_thread.cmpxchgStrong(null, me, .acq_rel, .acquire) != null) return error.Interrupted;
    {
        const held = tree_lock.acquire();
        defer tree_lock.release(held);
        var t = p.thread_list;
        while (t) |other| : (t = other.proc_next) {
            if (other != me) thread.interrupt(other);
        }
        while (p.thread_count > 1) p.threads_gone.wait(&tree_lock);
    }
    p.exec_thread.store(null, .release);
    if (p.killed.load(.acquire)) return error.Interrupted;

    replaceProgram(p, img, name, cmdline);
    resetForExec(p, me);

    // Into the new program, as a new process starts: every register zero
    // but the stack pointer and the instruction pointer.
    frame.* = std.mem.zeroes(arch_syscall.Frame);
    frame.rip = img.entry;
    frame.rsp = img.entry_rsp;
    frame.rflags = 0x202;
    me.return_by_iret = true; // RCX and R11 zero too, as on Linux
    frame.cs = @import("../arch/x86_64/sysret.zig").USER_CS;
    frame.ss = @import("../arch/x86_64/sysret.zig").USER_SS;
}

/// `execve`'s switch to the new program's address space, name and
/// arguments, freeing the old ones. Not inlined, to keep `execve`'s frame
/// small.
noinline fn replaceProgram(p: *Process, img: *const Image, name: []const u8, cmdline: []u8) void {
    // The new address space in, the old one out.
    const old_root = p.root;
    var old_regions: vm_regions.Regions = undefined;
    {
        const flags = cpu.saveAndDisableInterrupts();
        defer cpu.restoreInterrupts(flags);
        vmm.loadRoot(img.root);
        const held = p.mem.lock.acquire();
        defer p.mem.lock.release(held);
        old_regions = p.mem.regions;
        p.mem.regions = img.regions;
        p.mem.brk_start = img.brk;
        p.mem.brk_end = img.brk;
        p.mem.mmap_top = img.mmap_top;
        p.root = img.root;
        p.pages = img.pages + kstack.STACK_PAGES;
    }
    vmm.unloadRoot(old_root); // no other CPU should have it, but make sure
    vmm.destroyAddressSpace(old_root);
    old_regions.deinit(heap.allocator);
    p.entry = img.entry;
    p.entry_rsp = img.entry_rsp;
    p.stack_top = img.stack_top;
    const old_name = p.name;
    p.name = name;
    heap.allocator.free(old_name);
    const old_cmdline = blk: {
        // Under the descriptor lock, which readers of it take (`procfs`).
        const held = p.files_lock.acquire();
        defer p.files_lock.release(held);
        const before = p.cmdline;
        p.cmdline = cmdline;
        break :blk before;
    };
    heap.allocator.free(old_cmdline);
}

/// What `execve` resets once the new program is in place: descriptors
/// marked close-on-exec, signal handlers, the thread's bases, extended
/// state and alternate stack, and a waiting `vfork` parent. Not inlined.
noinline fn resetForExec(p: *Process, me: *thread.Thread) void {
    closeOnExec(p);
    {
        const held = p.signal_lock.acquire();
        defer p.signal_lock.release(held);
        for (p.signal_actions) |*a| {
            if (a.handler != 1) a.* = .{}; // SIG_IGN stays
        }
    }
    {
        const flags = cpu.saveAndDisableInterrupts();
        defer cpu.restoreInterrupts(flags);
        me.fs_base = 0;
        me.gs_base = 0;
        @import("../arch/x86_64/percpu.zig").setUserBases(0, 0);
        if (me.fpuArea()) |area| fpu.resetCurrent(area);
    }
    me.signal_stack = .{};
    me.rseq = .{};
    me.rseq_resume = false;
    me.signal_saved_mask = null;
    me.clear_child_tid = 0;
    {
        const held = tree_lock.acquire();
        defer tree_lock.release(held);
        if (p.vfork_pending) {
            p.vfork_pending = false;
            _ = p.exited.wakeAll();
        }
    }
}

/// Close the descriptors of `p` marked close-on-exec.
fn closeOnExec(p: *Process) void {
    while (true) {
        const of = blk: {
            const held = p.files_lock.acquire();
            defer p.files_lock.release(held);
            for (p.files, p.fd_cloexec) |*slot, *ce| {
                if (!ce.*) continue;
                ce.* = false;
                const one = slot.* orelse continue;
                slot.* = null;
                break :blk one;
            }
            return;
        };
        open_file.unref(of); // outside the lock: it may free a pipe
    }
}

/// A program file `execve` is to run: its contents, and for a script the
/// interpreter to run instead and the arguments for it.
const ProgramFile = struct {
    image: []u8,
    run_path: ?[]const u8 = null,
    argv: ?[][]const u8 = null,
    /// What `run_path` and `argv` point into, freed with the image.
    argv_storage: ?[]u8 = null,
};

/// Read the program at `path`. A script (`#!interpreter [argument]` on
/// its first line, at most 256 bytes) is read as its interpreter, whose
/// arguments are the interpreter, the argument if there is one, the
/// script's path, and then `argv` from its second on, as on Linux.
fn readProgram(path: []const u8, argv: []const []const u8) ExecError!ProgramFile {
    const first = readWhole(path) catch |e| return e;
    if (first.len < 2 or first[0] != '#' or first[1] != '!') return .{ .image = first };
    return readScript(first, path, argv);
}

/// `readProgram` for a script (`first` starts with `#!`), which it frees.
/// Not inlined: its temporaries stay out of `readProgram`'s frame, which
/// is on the stack while the program's path is looked up.
noinline fn readScript(first: []u8, path: []const u8, argv: []const []const u8) ExecError!ProgramFile {
    defer heap.allocator.free(first);
    const line_end = std.mem.indexOfScalar(u8, first[0..@min(first.len, 256)], '\n') orelse return error.NotExecutable;
    const line = std.mem.trim(u8, first[2..line_end], " \t");
    const sep = std.mem.indexOfAny(u8, line, " \t");
    const interp = if (sep) |i| line[0..i] else line;
    const arg = if (sep) |i| std.mem.trim(u8, line[i..], " \t") else "";
    if (interp.len == 0 or interp[0] != '/') return error.NotExecutable;
    // The interpreter path and its argument outlive `first`: a copy.
    const storage = try heap.allocator.alloc(u8, interp.len + arg.len + path.len);
    errdefer heap.allocator.free(storage);
    @memcpy(storage[0..interp.len], interp);
    @memcpy(storage[interp.len..][0..arg.len], arg);
    @memcpy(storage[interp.len + arg.len ..], path);
    const image = readWhole(storage[0..interp.len]) catch |e| return e;
    if (image.len >= 2 and image[0] == '#' and image[1] == '!') {
        heap.allocator.free(image);
        return error.NotExecutable; // one level, as on Linux
    }
    errdefer heap.allocator.free(image);
    const rest = if (argv.len > 0) argv[1..] else argv;
    const list = try heap.allocator.alloc([]const u8, @as(usize, 2) + @intFromBool(arg.len != 0) + rest.len);
    var n: usize = 0;
    list[n] = storage[0..interp.len];
    n += 1;
    if (arg.len != 0) {
        list[n] = storage[interp.len..][0..arg.len];
        n += 1;
    }
    list[n] = storage[interp.len + arg.len ..];
    n += 1;
    @memcpy(list[n..], rest);
    return .{ .image = image, .run_path = storage[0..interp.len], .argv = list, .argv_storage = storage };
}

/// The whole file at `path`, symbolic links followed, on the heap.
fn readWhole(path: []const u8) ExecError![]u8 {
    const node = lookupFollowing(path) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.FileNotFound,
    };
    defer vfs.release(&node);
    const size = vfs.sizeOf(&node);
    const image = try heap.allocator.alloc(u8, size);
    errdefer heap.allocator.free(image);
    if (vfs.read(&node, 0, image) != size) return error.ReadFailed;
    return image;
}

/// A program loaded into an address space of its own, ready to run: what
/// `spawn` starts a process with and `execve` replaces one's with.
const Image = struct {
    root: u64,
    regions: vm_regions.Regions,
    /// Where it starts (its interpreter's entry, if it has one), with which
    /// stack pointer, and the top of its stack.
    entry: u64,
    entry_rsp: u64,
    stack_top: u64,
    mmap_top: u64,
    /// Where the `brk` heap begins: the end of the program.
    brk: u64,
    /// Pages it takes: program, interpreter, stack, page tables.
    pages: u64,

    fn destroy(img: *const Image) void {
        var r = img.regions;
        r.deinit(heap.allocator);
        vmm.destroyAddressSpace(img.root);
    }
};

/// Load the program `image` into a new address space, with a stack holding
/// its arguments, environment and auxiliary vector, and its interpreter if
/// it names one. `name` is the path it is started under. On error nothing
/// is left. Not inlined: its frame stays out of its callers'.
noinline fn buildImage(name: []const u8, image: []const u8, options: SpawnOptions, limits: Limits) !Image {
    const root = try vmm.createAddressSpace();
    errdefer vmm.destroyAddressSpace(root);

    // The regions of the new address space: the program's segments, then
    // the stack. They become the process's once it exists.
    var regions: vm_regions.Regions = .{};
    errdefer regions.deinit(heap.allocator);
    const image_limits_now = imageLimits(limits);
    const program = try loadProgram(root, image, image_limits_now, options.randomize, &regions);
    const loaded = &program.loaded;

    var stack_pages: [STACK_PAGES]u64 = undefined; // physical; [0] is the highest page
    const layout = try setUpStack(root, &regions, options.randomize, &stack_pages);
    const stack_top = layout.stack_top;
    const data_top = layout.data_top;
    const mmap_top = layout.mmap_top;
    const vdso_base = layout.vdso_base;
    // A program that names an interpreter (the dynamic loader) is not
    // started itself: the interpreter is loaded beside it and started,
    // and finds the program through the auxiliary vector.
    var interp_limits = image_limits_now;
    interp_limits.max_bytes -|= loaded.pages * pmm.PAGE_SIZE;
    var first_entry = loaded.entry;
    var interp_base: u64 = 0;
    var interp_pages: u64 = 0;
    if (program.interp) |path| {
        const interp = try loadInterpreter(root, path, interp_limits, &regions, mmap_top);
        first_entry = interp.entry;
        interp_base = interp.bias;
        interp_pages = interp.pages;
    }

    const entry_rsp = try writeStartupData(name, options, loaded, interp_base, vdso_base, &stack_pages, stack_top, data_top);

    // Everything the program takes, now that its page tables exist (the
    // thread's kernel stack comes on top).
    const pages = loaded.pages + interp_pages + STACK_PAGES + vmm.userTablePages(root);
    if (pages + kstack.STACK_PAGES > limits.max_pages) return error.TooLarge;
    return .{
        .root = root,
        .regions = regions,
        .entry = first_entry,
        .entry_rsp = entry_rsp,
        .stack_top = stack_top,
        .mmap_top = mmap_top,
        .brk = loaded.end,
        .pages = pages,
    };
}

/// `buildImage`'s stack and vDSO: where the stack goes, and how far below
/// its top the program's startup data ends (a multiple of 16 bytes), so
/// that nothing on the stack is at a fixed offset within its page either;
/// its top pages, given now for the startup data (their physical addresses
/// in `stack_pages`); where mappings go, with the vDSO at the top of that.
/// Not inlined: its temporaries stay out of `buildImage`'s frame, which is
/// on the stack while programs are loaded.
noinline fn setUpStack(root: u64, regions: *vm_regions.Regions, randomize: bool, stack_pages: *[STACK_PAGES]u64) !struct { stack_top: u64, data_top: u64, mmap_top: u64, vdso_base: u64 } {
    const stack_top = if (randomize) STACK_TOP_MAX - random.below(STACK_RANDOM_PAGES) * pmm.PAGE_SIZE else STACK_TOP_MAX;
    const data_top = stack_top - (if (randomize) random.below(STACK_RANDOM_OFFSET / 16) * 16 else 0);

    // The stack may grow to `STACK_RESERVE`: all of that is its region,
    // and the pages come as they are touched (`user_memory.zig`).
    regions.add(heap.allocator, stack_top - STACK_RESERVE, STACK_RESERVE, vm_regions.Prot.rw, .stack) catch return error.OutOfMemory;
    for (0..STACK_PAGES) |i| {
        const phys = pmm.allocZeroed() orelse return error.OutOfMemory;
        vmm.map(root, stack_top - (i + 1) * pmm.PAGE_SIZE, phys, vmm.USER | vmm.WRITABLE | vmm.NX, false) catch |e| {
            pmm.free(phys); // not mapped, so destroying the address space would not free it
            return e;
        };
        stack_pages[i] = phys;
    }

    var mmap_top = stack_top - STACK_RESERVE - 256 * pmm.PAGE_SIZE;
    // The vDSO, at the top of where mappings go: its clock page, then the
    // image, shared by every process and faulted in when first touched.
    var vdso_base: u64 = 0;
    if (vdso.present()) {
        const vvar_at = mmap_top - vdso.PAGES * pmm.PAGE_SIZE;
        try regions.add(heap.allocator, vvar_at, pmm.PAGE_SIZE, .{ .read = true }, .vvar);
        try regions.add(heap.allocator, vvar_at + pmm.PAGE_SIZE, vdso.TEXT_PAGES * pmm.PAGE_SIZE, .{ .read = true, .exec = true }, .vdso);
        vdso_base = vvar_at + pmm.PAGE_SIZE;
        mmap_top = vvar_at - pmm.PAGE_SIZE; // a page apart from the first mapping
    }
    return .{ .stack_top = stack_top, .data_top = data_top, .mmap_top = mmap_top, .vdso_base = vdso_base };
}

/// Create a process named `name` that runs the ELF executable `image`.
///
/// Creates a new address space, loads `image` into it (`image` is copied and
/// may be freed afterwards), maps a zeroed 16 KiB user stack and spawns a
/// thread that enters user mode at the entry point. Returns immediately
/// without waiting for the process. The caller receives a reference to the
/// new process and must give it up with `wait` or `release`.
///
/// Fails with `error.TooManyProcesses` if an ancestor has reached its
/// descendant limit, `error.TooLarge` if the program does not fit the memory
/// limit, `error.OutOfMemory`, or an error of the ELF loader. On error
/// nothing is leaked and nothing is counted.
pub fn spawn(name: []const u8, image: []const u8, options: SpawnOptions) !*Process {
    const limits = options.limits orelse if (options.parent) |parent| parent.limits else Limits.default();
    const img = try buildImage(name, image, options, limits);
    errdefer img.destroy();
    return spawnWith(name, &img, options, limits);
}

/// The rest of `spawn`, once the program is loaded into `img`: the process
/// and its thread. Not inlined, so that `spawn`'s frame, which is on the
/// stack while the program is loaded (deep, in a Debug build), stays small.
/// On an error `spawn` destroys `img`.
noinline fn spawnWith(name: []const u8, img: *const Image, options: SpawnOptions, limits: Limits) !*Process {
    const regions = img.regions;
    const mmap_top = img.mmap_top;
    const pages = img.pages + kstack.STACK_PAGES;
    const loaded_end = img.brk;

    const p = try heap.allocator.create(Process);
    errdefer heap.allocator.destroy(p);
    const name_copy = try heap.allocator.dupe(u8, name);
    errdefer heap.allocator.free(name_copy);
    const fds = try newDescriptors(options.cwd);
    const console = fds.files[0].?;
    const files = fds.files;
    const fd_cloexec = fds.cloexec;
    const cwd = fds.cwd;
    errdefer heap.allocator.destroy(console);
    errdefer heap.allocator.free(files);
    errdefer heap.allocator.free(fd_cloexec);
    errdefer heap.allocator.free(cwd);
    initNew(p, img, name_copy, limits, pages, options.parent, regions, loaded_end, mmap_top);
    p.files = files;
    p.fd_cloexec = fd_cloexec;
    p.cwd = cwd;
    p.signal_actions = try newActions(null);
    errdefer heap.allocator.destroy(p.signal_actions);
    p.cmdline = try joinArgs(options.argv, name);
    errdefer heap.allocator.free(p.cmdline);
    // (On an error below, the list is freed through `regions`, which
    // still refers to it; the structure goes separately.)

    // Everything that can fail for lack of memory happens before the
    // tree lock, which is held for the few lines that put the process in
    // the tree: it is in the tree exactly when its thread is started.
    const t = try thread.create(userStart, p);
    // (Taken back with `destroy` on an error below: it has no ID until
    // the last step, after which nothing fails.)
    errdefer thread.destroy(t);

    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    if (options.parent) |parent| {
        assert.check(.process, parent.exit_code == null, "process '{s}' starts a child after exiting", .{parent.name});
    }
    try chargeDescendant(options.parent);
    linkChild(p);
    registerLocked(p);
    live += 1;
    p.pid = thread.assignId(t);
    p.pgid = if (options.parent) |parent| parent.pgid else p.pid;
    p.sid = if (options.parent) |parent| parent.sid else p.pid;
    p.thread_list = t;
    p.thread_count = 1;
    thread.start(t);
    return p;
}

/// Fill in the new process `p` of `spawn`. Not inlined: a `Process` built
/// in place is a temporary of over a kilobyte in a Debug build, which
/// would sit in `spawn`'s frame under the deep paths `spawn` takes before
/// it gets here (loading the program).
noinline fn initNew(p: *Process, img: *const Image, name: []u8, limits: Limits, pages: u64, parent: ?*Process, regions: vm_regions.Regions, loaded_end: u64, mmap_top: u64) void {
    p.* = .{
        .root = img.root,
        .start_ticks = timer.now(),
        .entry = img.entry,
        .stack_top = img.stack_top,
        .entry_rsp = img.entry_rsp,
        .name = name,
        .limits = limits,
        .pages = pages,
        .parent = parent,
        .parent_pid = .init(if (parent) |q| q.pid else 0),
        .refs = if (parent != null) 3 else 2, // the thread's, the caller's, and the parent's list's
        .mem = .{
            .regions = regions,
            .brk_start = loaded_end,
            .brk_end = loaded_end,
            .mmap_top = mmap_top,
        },
    };
}

/// A new process's descriptor table, with the standard streams: three
/// descriptors for one open console; and its working directory. Not
/// inlined: it keeps `spawn`'s frame small.
noinline fn newDescriptors(cwd_path: []const u8) error{OutOfMemory}!struct { files: []?*open_file.OpenFile, cloexec: []bool, cwd: []u8 } {
    const console = try heap.allocator.create(open_file.OpenFile);
    errdefer heap.allocator.destroy(console);
    console.* = .{ .kind = .console, .refs = 3 };
    const files = try heap.allocator.alloc(?*open_file.OpenFile, FILES_INITIAL);
    errdefer heap.allocator.free(files);
    const cloexec = try heap.allocator.alloc(bool, FILES_INITIAL);
    errdefer heap.allocator.free(cloexec);
    const cwd = try heap.allocator.dupe(u8, cwd_path);
    @memset(cloexec, false);
    @memset(files, null);
    @memset(files[0..3], console);
    return .{ .files = files, .cloexec = cloexec, .cwd = cwd };
}

/// Copy `data` to the address `addr` of a new process's stack, whose pages
/// are `pages` (physical addresses, highest page first) below `stack_top`.
/// The address space is not loaded, so the pages are written through the
/// kernel's own mapping of them.
fn copyToStack(pages: *const [STACK_PAGES]u64, stack_top: u64, addr: u64, data: []const u8) void {
    var done: usize = 0;
    while (done < data.len) {
        const at = addr + done;
        const page = (stack_top - 1 - at) / pmm.PAGE_SIZE;
        const offset: usize = @intCast(at % pmm.PAGE_SIZE);
        const n = @min(data.len - done, pmm.PAGE_SIZE - offset);
        @memcpy(pmm.physToVirt(pages[page])[offset..][0..n], data[done..][0..n]);
        done += n;
    }
}

/// Thread entry point for a new process: jump to the process's entry point in
/// ring 3 on its user stack. The scheduler has already loaded the process's
/// address space. Never returns.
fn userStart() void {
    const p = thread.current().process.?;
    context.enterUser(p.entry, p.entry_rsp);
}
