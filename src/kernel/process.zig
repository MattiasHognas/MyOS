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
pub const Limits = struct {
    /// Most pages of physical memory the process may take: its program
    /// (code, data, `.bss`), its stack, the page tables of its address
    /// space and its thread's kernel stack.
    max_pages: u64 = MAX_IMAGE_BYTES / pmm.PAGE_SIZE,
    /// Most processes that may be alive below this one at once: children,
    /// their children, and so on. Starting one more fails.
    max_descendants: u32 = 1024,
    /// Most descriptors the process may have, the three standard streams
    /// included; at most `MAX_FILES`.
    max_files: u32 = MAX_FILES,
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
    signal_actions: [abi.NSIG]abi.SigAction = @splat(.{}),
    signal_lock: SpinLock = .{ .rank = .descriptor_table },
    /// Signals sent to the process as a whole (`kill`) and not yet
    /// delivered: any of its threads that does not block one takes it.
    signal_pending: std.atomic.Value(u64) = .init(0),
    /// Its regions of memory, `brk` heap and the lock for them and its
    /// page tables (`user_memory.zig`).
    mem: user_memory.UserMemory = .{},
    /// This process's children that have not exited, and its link in its
    /// parent's list.
    first_child: ?*Process = null,
    next_sibling: ?*Process = null,
};

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

/// Give the children of `p`, which is exiting, to its parent (or to nobody).
/// The ancestors above `p` already count them as descendants, so only the
/// links change. The tree lock must be held.
fn reparentChildren(p: *Process) void {
    while (p.first_child) |child| {
        p.first_child = child.next_sibling;
        child.next_sibling = null;
        child.parent = p.parent;
        linkChild(child);
    }
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
    reparentChildren(p);
    unlinkChild(p);
    releaseDescendant(p.parent);
    p.parent = null;
    p.exit_code = code;
    _ = p.exited.wakeAll(); // before the lock is released: the waiters are still there
    tree_lock.drop();
    thread.exit();
}

/// Take `t` out of the thread list of `p`. The tree lock must be held.
fn unlinkThread(p: *Process, t: *thread.Thread) void {
    var link = &p.thread_list;
    while (link.*) |other| : (link = &other.proc_next) {
        if (other != t) continue;
        link.* = t.proc_next;
        t.proc_next = null;
        p.thread_count -= 1;
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
    const p = thread.current().process orelse return;
    if (p.killed.load(.acquire)) die();
    const code = p.exit_request.load(.acquire);
    if (code != NO_REQUEST) exit(code);
}

const NO_REQUEST = std.math.maxInt(u64);

/// The program the terminal's Ctrl+C ends: the one the shell started and
/// waits for. Under the tree lock. Whoever sets it holds a reference to it
/// until it has taken it back.
var foreground: ?*Process = null;

/// What `giveForeground` did.
pub const Handover = enum {
    /// Another program has the terminal: nothing changed.
    not_given,
    /// Nobody had it; now `to` does.
    from_nobody,
    /// The caller had it; now `to` does.
    from_caller,
};

/// Give the terminal to `to`, a program `from` has started and waits
/// for, if `from` has the terminal or nobody has. A program that does not
/// have it cannot take it from the one that does (two programs started at
/// once by two others: the first keeps it). The caller holds a reference
/// to `to` until `takeForegroundBack`.
pub fn giveForeground(from: *Process, to: *Process) Handover {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    if (foreground == null) {
        foreground = to;
        return .from_nobody;
    }
    if (foreground == from) {
        foreground = to;
        return .from_caller;
    }
    return .not_given;
}

/// Undo `giveForeground` once `to` has ended: the terminal goes back to
/// `from` or to nobody, whichever had it, unless `to` passed it on and the
/// program it went to still has it (which cannot happen once `to` has
/// waited for that program).
pub fn takeForegroundBack(from: *Process, to: *Process, handover: Handover) void {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    if (foreground != to) return;
    foreground = switch (handover) {
        .not_given => return,
        .from_nobody => null,
        .from_caller => from,
    };
}

/// Make `p` the foreground program, or nobody: for tests.
pub fn setForeground(p: ?*Process) ?*Process {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    const before = foreground;
    foreground = p;
    return before;
}

/// End the foreground program, if there is one, with status `code`. For
/// the terminal's Ctrl+C: callable from an interrupt handler holding no
/// lock. True if there was one.
pub fn terminateForeground(code: u64) bool {
    _ = code;
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    const p = foreground orelse return false;
    // SIGINT, which ends it unless it handles or ignores it.
    @import("signal.zig").sendProcessLocked(p, @import("signal.zig").SIG.INT);
    return true;
}

/// Send `sig` to the process `p` (`signal.sendProcessLocked`, with the
/// tree lock taken here). `p` must be alive: a reference, or the caller.
pub fn signalProcess(p: *Process, sig: u32) void {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    @import("signal.zig").sendProcessLocked(p, sig);
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

/// `wait` for a thread of a program, which may itself be told to end
/// while it waits: then this returns null, and the caller still has its
/// reference to `p`.
pub fn waitKillable(p: *Process) ?u64 {
    const code = blk: {
        const held = tree_lock.acquire();
        defer tree_lock.release(held);
        while (p.exit_code == null) {
            // Not ended by a signal: the child runs already, and the call
            // could not be made again.
            if (!p.exited.waitUnlessEnding(&tree_lock)) return null;
        }
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
        live -= 1;
    }
    // Nobody else has a reference, so nobody else can reach it.
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
        if (slot.*) |of| {
            of.refs -= 1;
            if (of.refs == 0) open_file.destroy(of);
        }
        slot.* = null;
    }
    heap.allocator.free(p.files);
    p.files = &.{};
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
    const old = blk: {
        const held = p.files_lock.acquire();
        defer p.files_lock.release(held);
        if (p.files.len >= want) break :blk new; // not needed after all
        @memcpy(new[0..p.files.len], p.files);
        @memset(new[p.files.len..], null);
        const before = p.files;
        p.files = new;
        break :blk before;
    };
    heap.allocator.free(old);
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
    const limits = options.limits orelse if (options.parent) |parent| parent.limits else Limits{};

    const root = try vmm.createAddressSpace();
    errdefer vmm.destroyAddressSpace(root);

    // The regions of the new address space: the program's segments, then
    // the stack. They become the process's once it exists.
    var regions: vm_regions.Regions = .{};
    errdefer regions.deinit(heap.allocator);
    const image_limits_now = imageLimits(limits);
    const program = try loadProgram(root, image, image_limits_now, options.randomize, &regions);
    const loaded = &program.loaded;

    // Where the stack goes, and how far below its top the program's
    // startup data ends (a multiple of 16 bytes), so that nothing on the
    // stack is at a fixed offset within its page either.
    const stack_top = if (options.randomize) STACK_TOP_MAX - random.below(STACK_RANDOM_PAGES) * pmm.PAGE_SIZE else STACK_TOP_MAX;
    const data_top = stack_top - (if (options.randomize) random.below(STACK_RANDOM_OFFSET / 16) * 16 else 0);

    // The stack may grow to `STACK_RESERVE`: all of that is its region,
    // and the pages come as they are touched (`user_memory.zig`). The
    // top ones are given now, for the startup data.
    regions.add(heap.allocator, stack_top - STACK_RESERVE, STACK_RESERVE, vm_regions.Prot.rw, .stack) catch return error.OutOfMemory;
    var stack_pages: [STACK_PAGES]u64 = undefined; // physical; [0] is the highest page
    for (0..STACK_PAGES) |i| {
        const phys = pmm.allocZeroed() orelse return error.OutOfMemory;
        vmm.map(root, stack_top - (i + 1) * pmm.PAGE_SIZE, phys, vmm.USER | vmm.WRITABLE | vmm.NX, false) catch |e| {
            pmm.free(phys); // not mapped, so destroying the address space would not free it
            return e;
        };
        stack_pages[i] = phys;
    }

    // A program that names an interpreter (the dynamic loader) is not
    // started itself: the interpreter is loaded beside it and started,
    // and finds the program through the auxiliary vector.
    const mmap_top = stack_top - STACK_RESERVE - 256 * pmm.PAGE_SIZE;
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

    const entry_rsp = try writeStartupData(name, options, loaded, interp_base, &stack_pages, stack_top, data_top);

    // Everything the process takes, now that its page tables exist.
    const pages = loaded.pages + interp_pages + STACK_PAGES + vmm.userTablePages(root) + kstack.STACK_PAGES;
    if (pages > limits.max_pages) return error.TooLarge;

    const p = try heap.allocator.create(Process);
    errdefer heap.allocator.destroy(p);
    const name_copy = try heap.allocator.dupe(u8, name);
    errdefer heap.allocator.free(name_copy);
    // The standard streams: three descriptors for one open console.
    const console = try heap.allocator.create(open_file.OpenFile);
    errdefer heap.allocator.destroy(console);
    console.* = .{ .kind = .console, .refs = 3 };
    const files = try heap.allocator.alloc(?*open_file.OpenFile, FILES_INITIAL);
    errdefer heap.allocator.free(files);
    const cwd = try heap.allocator.dupe(u8, options.cwd);
    errdefer heap.allocator.free(cwd);
    @memset(files, null);
    @memset(files[0..3], console);
    p.* = .{
        .root = root,
        .start_ticks = timer.now(),
        .entry = first_entry,
        .stack_top = stack_top,
        .entry_rsp = entry_rsp,
        .name = name_copy,
        .limits = limits,
        .pages = pages,
        .parent = options.parent,
        .refs = 2, // the thread's and the caller's
        .mem = .{
            .regions = regions,
            .brk_start = loaded.end,
            .brk_end = loaded.end,
            .mmap_top = mmap_top,
        },
    };
    p.files = files;
    p.cwd = cwd;
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
    live += 1;
    p.pid = thread.assignId(t);
    p.thread_list = t;
    p.thread_count = 1;
    thread.start(t);
    return p;
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
