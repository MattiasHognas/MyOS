//! Kernel threads and the round-robin scheduler.
//!
//! Ready threads wait in a FIFO queue. `yield` switches to the next one,
//! loading its address space and kernel stack, and the timer calls `tick` to
//! preempt a thread once its time slice runs out. Exited threads are parked on
//! a zombie list and freed by the next thread that runs, since a thread cannot
//! free the stack it is still running on.
//!
//! Every thread runs on a guarded kernel stack from `kstack.zig`, including
//! the boot thread once `adoptBootStack` has been called.
//!
//! ## States
//!
//!     spawn -> ready <-> running -> dead -> (reaped)
//!                ^          |
//!                +- blocked +
//!
//! - **ready**: in the ready queue, and nowhere else.
//! - **running**: on a CPU; in no queue.
//! - **blocked**: called `block` and waits for `wake`; in no scheduler queue
//!   (it may be on a `WaitQueue`, which is how others find it).
//! - **dead**: called `exit`; on the zombie list once its CPU has left its
//!   stack, until the next thread that runs on any CPU frees it. Never runs
//!   again.
//!
//! A thread is in at most one scheduler queue, and `Thread.link` says which.
//! Every insertion checks it, so a thread can never be queued twice, and
//! `reap` checks it too, so a thread is freed exactly once.
//!
//! ## Blocking
//!
//! `block` and `wake` are the two halves of every sleep. `wake` leaves a
//! permit when its target is not blocked (yet), and `block` returns at once
//! if a permit is there, so a wake-up that arrives just before the thread
//! blocks is not lost. Because a permit can be left over from an earlier
//! wake-up, `block` may return with nothing having happened: callers loop
//! on their condition. `sync/wait_queue.zig` is the interface to use; it
//! does this.
//!
//! ## Idling
//!
//! There is no idle thread that takes turns with the others. When a thread
//! blocks and nothing is ready, its CPU halts right there, in `block` on
//! that thread's stack, until an interrupt makes a thread ready. So a ready
//! thread never waits behind an idle one. A blocked thread whose CPU idles
//! on its stack is still "on a CPU" (`Thread.on_cpu`): waking it lets it
//! carry on where it is and does not put it in the ready queue, where
//! another CPU could pick it up and run on the same stack.
//!
//! ## Address spaces
//!
//! A thread of a process runs on its process's address space. A kernel
//! thread runs on whichever one is loaded: it only uses kernel addresses,
//! which are mapped the same in all of them. So a switch to a kernel thread
//! and back costs no CR3 load and no TLB flush.
//!
//! ## Locking
//!
//! One spinlock, the scheduler lock, protects the ready queue, the zombie
//! list and every thread's `state`, `link`, `on_cpu` and wake-up permit
//! (`docs/locking.md`). It is nearly innermost: nothing is allocated, freed
//! or printed while it is held, so threads are created before it is taken
//! and exited ones are freed after it is released.
//!
//! **The lock is held across the context switch and released by the thread
//! that is switched to** (`finishSwitch`; a new thread's first code does it
//! too). A thread that blocks marks itself blocked and then leaves its
//! stack; if the lock were released in between, another CPU could wake it
//! and a third could run it while the first is still on its stack.
//!
//! The running thread and what is left of its time slice belong to the CPU
//! and are kept in its `PerCpu` (`percpu.zig`), changed with interrupts
//! off. `current` reads the running thread in one instruction, so it is
//! right for code that can be preempted too.
//!
//! ## Several CPUs
//!
//! There is one ready queue, and every CPU takes threads from it: a thread
//! runs on whichever CPU picks it up, and may be on a different one after
//! every switch. Each CPU starts in a context of its own, which `adoptCpu`
//! makes a thread; once the CPU is up that thread retires, like the boot
//! thread.
//!
//! Each CPU has a thread of its own to fall back to (`PerCpu.idle_thread`:
//! the one it started in, or one made for it), for the two cases where it
//! cannot halt in the thread it ran last: that thread has exited, and
//! would not be freed for as long as the CPU sat on its stack; or the CPU
//! is parked. It is not an idle thread that takes turns: it is never in
//! the ready queue, and a CPU whose thread merely blocks still halts right
//! there.
//!
//! A CPU that halts with nothing to run says so (`PerCpu.idle`). Whoever
//! makes a thread ready sends one idle CPU an interrupt, and whoever wakes
//! a thread in place sends it to that thread's CPU, so neither waits for
//! the next timer tick.
//!
//! A CPU can be **parked** (`setParked`): it gives up the thread it runs,
//! goes back to the thread it started in and halts there, taking only
//! interrupts, until it is unparked. The tests use it to have the machine
//! to themselves; it is also the first half of taking a CPU offline.

const std = @import("std");
const stats = @import("stats.zig");
const clock = @import("clock.zig");
const root = @import("root");
const abi = @import("abi");

const context = @import("../arch/x86_64/context.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const fpu = @import("../arch/x86_64/fpu.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const ipi = @import("../arch/x86_64/ipi.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const vmm = @import("../arch/x86_64/vmm.zig");
const assert = @import("debug/assert.zig");
const heap = @import("heap.zig");
const kstack = @import("kstack.zig");
const proc = @import("process.zig");
const Process = proc.Process;
const spinlock = @import("sync/spinlock.zig");
const SpinLock = spinlock.SpinLock;
const WaitQueue = @import("sync/wait_queue.zig").WaitQueue;

const SLICE_TICKS = 5; // 50 ms at 100 Hz

/// The thread the boot CPU starts in.
var boot_thread: Thread = .{ .id = 0, .stack = null, .state = .running, .on_cpu = true };

/// The scheduler lock. Protects everything below, and in every `Thread`
/// the fields `state`, `link`, `next`, `on_cpu` and `wake_pending`.
var lock: SpinLock = .{ .rank = .scheduler };

var next_id: usize = 1;

// FIFO ready queue
var ready_head: ?*Thread = null;
var ready_tail: ?*Thread = null;

var zombies: ?*Thread = null;
/// The thread a CPU is switching away from, from just before the switch
/// until `finishSwitch` on the other side. The lock is held all that time,
/// so one variable does for every CPU.
var switched_from: ?*Thread = null;
/// Threads freed: counted when their memory is back, which is after the
/// lock has been released, so not under it.
var reaped: std.atomic.Value(usize) = .init(0);
var exited: usize = 0;
var switches: usize = 0;

/// Append `t` to the tail of the ready queue. The scheduler lock must be held.
fn enqueue(t: *Thread) void {
    assert.check(.thread, t.state == .ready, "enqueueing thread {d} in state {t}", .{ t.id, t.state });
    assert.check(.thread, t.link == .none, "thread {d} is already queued ({t})", .{ t.id, t.link });
    t.link = .ready_queue;
    t.next = null;
    t.ready_since = stats.rdtsc();
    if (ready_tail) |tail| tail.next = t else ready_head = t;
    ready_tail = t;
}

/// Remove and return the thread at the head of the ready queue, or null if it
/// is empty. The scheduler lock must be held.
fn dequeue() ?*Thread {
    const t = ready_head orelse return null;
    ready_head = t.next;
    if (ready_head == null) ready_tail = null;
    t.next = null;
    t.link = .none;
    return t;
}

/// Take every thread off the zombie list and return them, linked through
/// `next`. The scheduler lock must be held; the threads belong to the
/// caller afterwards, to be freed with `reap` once the lock is released.
fn takeZombies() ?*Thread {
    const list = zombies;
    zombies = null;
    var z = list;
    while (z) |t| : (z = t.next) {
        assert.check(.thread, t.state == .dead and t.link == .zombie_list and !t.on_cpu, "reaping thread {d} in state {t} ({t})", .{ t.id, t.state, t.link });
        t.link = .none;
    }
    return list;
}

/// Free every thread on `list` (from `takeZombies`), together with its
/// process (if any) and its stack, after recording how much of the stack it
/// used. Interrupts are off and no lock is held: this allocator work is
/// what the scheduler lock must not cover.
fn reap(list: ?*Thread) void {
    var rest = list;
    while (rest) |z| {
        rest = z.next;
        assert.check(.thread, z != current(), "thread {d} reaps itself", .{z.id});
        const process = z.process;
        if (kstack.used(z.stack.?)) |bytes| kstack.record(z.id, bytes); // -Dstack-usage
        kstack.free(z.stack.?);
        if (z.fpu_alloc) |a| heap.allocator.free(a);
        heap.allocator.destroy(z);
        // After the thread's own memory: when its reference to its
        // process is gone, nothing of the thread is left either.
        if (process) |p| proc.teardown(p);
        _ = reaped.fetchAdd(1, .release); // counted when everything is back
    }
}

/// Scheduling state of a thread.
pub const State = enum {
    /// In the ready queue, waiting for the CPU.
    ready,
    /// Currently on the CPU.
    running,
    /// Waiting for `wake`.
    blocked,
    /// Exited; waiting to be reaped.
    dead,
};

/// Which scheduler queue a thread is in.
pub const Link = enum { none, ready_queue, zombie_list };

/// A kernel thread: a stack, saved registers and scheduling state. A thread
/// either belongs to a user process or is a pure kernel thread (`process == null`).
pub const Thread = struct {
    /// Its time (TSC cycles, `stats.zig`): running, ready but waiting for
    /// a CPU, and the time slices it got; and when it last became ready
    /// and last started running. Under the scheduler lock.
    run_cycles: u64 = 0,
    wait_cycles: u64 = 0,
    slices: u64 = 0,
    ready_since: u64 = 0,
    run_since: u64 = 0,
    id: usize,
    /// Saved stack pointer while the thread is not running.
    rsp: usize = 0,
    /// Kernel stack (from `kstack`), owned by the thread. Null only for the
    /// boot thread until `adoptBootStack`.
    stack: ?[]u8,
    state: State,
    /// Link in the ready queue or the zombie list.
    next: ?*Thread = null,
    /// The scheduler queue the thread is in.
    link: Link = .none,
    /// The wait queue the thread sleeps on, if any, and its link there.
    wait_queue: ?*WaitQueue = null,
    wait_next: ?*Thread = null,
    /// Process this thread runs, if any.
    process: ?*Process = null,
    /// A `wake` arrived while the thread was not blocked, so its next
    /// `block` returns at once.
    wake_pending: bool = false,
    /// A CPU is executing on this thread's stack: from when it is switched
    /// to until the CPU that switches away from it has left the stack. A
    /// blocked thread with this set is idling in `block`.
    on_cpu: bool = false,
    /// The FS and GS base the thread's user code runs with (`arch_prctl`):
    /// where a program keeps its thread-local data. Loaded whenever the
    /// thread gets a CPU.
    fs_base: u64 = 0,
    gs_base: u64 = 0,
    /// Where the thread's exit is to be announced (`set_tid_address`), a
    /// user address; 0 if nowhere. Used once there are threads to wait for.
    clear_child_tid: u64 = 0,
    /// Link in its process's list of threads (`Process.thread_list`,
    /// under the process-tree lock).
    proc_next: ?*Thread = null,
    /// For a thread made by `clone`: the user registers it starts with, a
    /// heap block it frees when it has taken them. Null otherwise.
    user_frame: ?*anyopaque = null,
    /// Return from the current system call with `iretq`, which restores
    /// RCX and R11 as the frame has them (`execve`, which zeroes them as
    /// Linux does; `sysretq` would put the return address and flags
    /// there). Cleared on the way out.
    return_by_iret: bool = false,
    /// Set while the thread reads user memory under a spinlock: a page
    /// fault then fails the read instead of being resolved, which would
    /// need the address-space lock (`futex.zig`).
    no_fault: bool = false,
    /// Signals the thread has blocked (bit n-1 for signal n), and the
    /// stack it wants its handlers run on; `SIGKILL` and `SIGSTOP` cannot
    /// be blocked. Changed by the thread itself only (`signal.zig`).
    signal_mask: u64 = 0,
    signal_stack: abi.SigStack = .{},
    /// Its restartable-sequence area, if it registered one (`rseq.zig`),
    /// and whether it has been switched onto a CPU since it last returned
    /// to its program (set by the scheduler; `rseq.atReturn` acts on it).
    rseq: @import("rseq.zig").Registration = .{},
    rseq_resume: bool = false,
    /// Signals sent to this thread and not yet delivered (`tgkill`, and
    /// those from its faults). Others set bits, the thread clears them.
    signal_pending: std.atomic.Value(u64) = .init(0),
    /// What was queued with them (`signal.Queue`), under the process's
    /// `signal_lock`.
    signal_queue: @import("signal.zig").Queue = .{},
    /// What the fault that became a pending signal was: delivered with
    /// it, on the way back to the program that made it.
    signal_fault: ?@import("signal_frame.zig").SigInfo = null,
    signal_fault_regs: struct { err: u64 = 0, trapno: u64 = 0, cr2: u64 = 0 } = .{},
    /// The mask to go back to after `rt_sigsuspend`'s handler: saved in
    /// its frame instead of the one that waited.
    signal_saved_mask: ?u64 = null,
    /// The CPU that runs the thread, or ran it last. Null until it has run.
    cpu: ?*percpu.PerCpu = null,
    /// Heap block holding the saved x87/SSE/AVX state while the thread is
    /// not running (`fpu.zig`). Null for kernel threads, which have none.
    fpu_alloc: ?[]u8 = null,

    /// The save area inside `fpu_alloc`, at the alignment the CPU requires
    /// (the heap aligns to 16 bytes only, so the block is 64 bytes larger).
    pub fn fpuArea(t: *const Thread) ?[*]align(fpu.AREA_ALIGN) u8 {
        const raw = t.fpu_alloc orelse return null;
        return @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(raw.ptr), fpu.AREA_ALIGN));
    }
};

/// Block the current thread until another thread or interrupt handler calls
/// `wake` on it. Returns immediately if a wake is already pending, and may
/// return for a wake-up left over from earlier, so callers loop on the
/// condition they wait for. Interrupts must be off and no spinlock held;
/// interrupts are off again on return.
///
/// This is the bottom half of waiting. Checking a condition and blocking
/// must be covered by a lock the waker takes too, released only after the
/// thread is on a wait queue: `WaitQueue.wait` does all of that and is
/// what to call.
///
/// While no thread is ready the CPU sleeps here, with interrupts on, until
/// an interrupt wakes this thread or makes another one ready.
pub fn block() void {
    assert.check(.thread, cpu.readFlags() & (1 << 9) == 0, "thread {d} blocks with interrupts on", .{current().id});
    spinlock.assertHeld(0, "blocking");
    lock.take();
    const me = current();
    if (me.wake_pending) { // the event already happened
        me.wake_pending = false;
        lock.drop();
        return;
    }
    me.state = .blocked;
    while (me.state == .blocked) {
        if (!switchToNext()) idleOnce();
    }
    me.wake_pending = false;
    const dead = takeZombies();
    lock.drop();
    reap(dead);
}

/// Sleep until the next interrupt. Called with the scheduler lock held and
/// the ready queue empty (or this CPU parked); the lock is released for the sleep and held again
/// on return. The `sti` takes effect after the following instruction, so no
/// interrupt of this CPU can arrive between enabling them and halting.
///
/// Another CPU can make a thread ready in that gap. It finds this CPU
/// marked idle and sends it an interrupt, which is taken the moment the
/// halt begins.
///
/// A request to switch threads (`preemptForWoken`) that came for the
/// thread this CPU ran before it blocked is dropped here: there is no
/// thread to switch from, and the ready queue is looked at anyway. Left
/// standing, it made `pollForWork` find work at once on every round, and
/// the CPU went round `block` with interrupts off for ever: on the boot
/// CPU, time itself stopped (its tick runs the timers), and every timed
/// wait in the system with it.
///
/// And whatever `pollForWork` finds, interrupts that are waiting are let
/// in before the CPU looks again (`sti; nop; cli`: one instruction with
/// them on), so that no flag left standing can shut this CPU's interrupts
/// out for good.
fn idleOnce() void {
    const c = percpu.current();
    assert.check(.thread, ready_head == null or !c.runs_threads, "halting while thread {d} is ready", .{if (ready_head) |t| t.id else 0});
    c.idle = true;
    c.preempt_requested = false; // under the scheduler lock, as it is set
    vmm.enterLazy(); // not to be woken for flushes of the address space it has loaded
    lock.drop();
    if (!pollForWork(c)) {
        c.halts += 1;
        asm volatile ("sti; hlt; cli");
    } else {
        asm volatile ("sti; nop; cli");
    }
    vmm.leaveLazy();
    lock.take();
    c.idle = false;
}

/// How long a CPU with nothing to run spins before it halts: work that
/// comes meanwhile is taken without the halt, and without the interrupt
/// that would end it, which for a virtual CPU means leaving the guest
/// twice (Linux's guest halt polling, which waits up to 200 µs).
const POLL_NS: u64 = 50_000;

/// Spin, with interrupts off and the scheduler lock released, until there
/// may be work for this CPU (another CPU took it off the idle list to give
/// it a thread, woke the thread it idles in, or a thread is ready) or
/// `POLL_NS` have passed. True if there may be work: the caller does not
/// halt. While spinning the CPU says so (`PerCpu.polling`), and wakers
/// skip the interrupt; it stops saying so before it looks one last time,
/// and a waker makes the work visible before it looks whether the CPU
/// polls, so one of them sees the other and no wake-up is lost.
fn pollForWork(c: *percpu.PerCpu) bool {
    const me = current();
    const hz = clock.tscHz();
    if (hz == 0) return false; // no clock to poll by
    const until = stats.rdtsc() + POLL_NS * hz / std.time.ns_per_s;
    @atomicStore(bool, &c.polling, true, .seq_cst);
    while (stats.rdtsc() < until) {
        if (workMayBeThere(c, me)) break;
        ipi.poll(); // a request for this CPU is not to wait either
        std.atomic.spinLoopHint();
    }
    @atomicStore(bool, &c.polling, false, .seq_cst);
    return workMayBeThere(c, me);
}

fn workMayBeThere(c: *percpu.PerCpu, me: *Thread) bool {
    if (!@atomicLoad(bool, &c.idle, .seq_cst)) return true; // chosen to run a ready thread
    if (@atomicLoad(State, &me.state, .seq_cst) != .blocked and me != @as(?*Thread, @ptrCast(@alignCast(c.idle_thread)))) return true;
    if (@atomicLoad(bool, &c.preempt_requested, .seq_cst)) return true;
    return c.runs_threads and @atomicLoad(?*Thread, &ready_head, .seq_cst) != null;
}

/// Have the halted (or polling) CPU `c` look for work: an interrupt,
/// unless it is polling and will see it anyway (`pollForWork`). The work
/// is to be visible already. Scheduler lock held.
fn wakeCpu(c: *percpu.PerCpu) void {
    if (@atomicLoad(bool, &c.polling, .seq_cst)) return;
    ipi.wake(c);
}

/// A thread has just been put in the ready queue: if a CPU is halted with
/// nothing to run, end its halt so it picks the thread up. One thread, one
/// CPU: the CPU is marked as no longer idle, so the next thread wakes
/// another. The scheduler lock must be held.
fn kickIdleCpu() bool {
    const me = percpu.current();
    for (0..percpu.count()) |i| {
        const c = percpu.get(i);
        if (c == me or !c.idle or !c.runs_threads) continue;
        @atomicStore(bool, &c.idle, false, .seq_cst);
        wakeCpu(c);
        return true;
    }
    return false;
}

/// A woken thread is in the ready queue and no CPU is idle to take it:
/// have the CPU whose thread has used most of its time slice switch now,
/// so the woken one does not wait for a slice to end (up to
/// `SLICE_TICKS`). A thread that has not run for a tick yet is left alone,
/// so threads waking each other cannot keep a third from running. On this
/// CPU the switch happens at the next tick (at once, if it is a timer that
/// woke the thread: the tick comes right after); another is interrupted.
/// The scheduler lock must be held.
fn preemptForWoken() void {
    const me = percpu.current();
    var best: ?*percpu.PerCpu = null;
    for (0..percpu.count()) |i| {
        const c = percpu.get(i);
        if (!c.runs_threads or c.idle or c.preempt_requested) continue;
        if (c.thread == c.idle_thread) continue; // halting in its own thread
        if (c.slice_left >= SLICE_TICKS) continue; // has not run a tick yet
        if (best == null or c.slice_left < best.?.slice_left) best = c;
    }
    const c = best orelse return;
    c.preempt_requested = true;
    if (c == me) {
        c.slice_left = 0;
    } else {
        ipi.preempt(c);
    }
}

/// For tests: leave a request to switch threads standing on this CPU, as
/// `preemptForWoken` does for a thread that then blocks before the
/// interrupt is taken.
pub fn requestPreemptHere() void {
    const held = lock.acquire();
    defer lock.release(held);
    percpu.current().preempt_requested = true;
}

/// The interrupt `preemptForWoken` sends: switch threads, if the request
/// still stands.
pub fn preemptRequested() void {
    const c = percpu.current();
    {
        const held = lock.acquire();
        defer lock.release(held);
        if (!c.preempt_requested) return;
        c.preempt_requested = false;
    }
    if (c.runs_threads) yield();
}

/// Wake thread `t`: if it is blocked, make it runnable; otherwise leave a
/// permit so its next `block` returns immediately. Does nothing to a dead
/// thread. Safe from interrupt handlers.
///
/// `t` must still exist. A waker knows that by holding the lock of the
/// condition `t` waits for, which `t` needs to stop waiting
/// (`docs/locking.md`): wake first, release that lock afterwards.
pub fn wake(t: *Thread) void {
    const held = lock.acquire();
    defer lock.release(held);
    if (t.state == .dead) return;
    t.wake_pending = true;
    if (t.state != .blocked) return;
    if (t.on_cpu) {
        // It is blocked but a CPU is still on its stack, idling in `block`
        // because nothing else was ready: it just carries on there. If that
        // is another CPU, it is halted and has to be told.
        @atomicStore(State, &t.state, .running, .seq_cst);
        const c = t.cpu.?;
        if (c != percpu.current()) wakeCpu(c);
    } else {
        t.state = .ready;
        enqueue(t);
        if (!kickIdleCpu()) preemptForWoken();
    }
}

/// Create a thread that will run `entry`, without starting it: it runs
/// once `start` is called, and until then `destroy` takes it back.
///
/// `process` is the user process the thread belongs to, or null for a kernel
/// thread. The thread gets a guarded kernel stack from `kstack` and, if it
/// belongs to a process, clean extended CPU state (`fpu.initArea`); when `entry`
/// returns the thread exits. Returns `error.OutOfMemory` if an allocation
/// fails or all kernel stacks are in use.
pub fn create(entry: *const fn () void, process: ?*Process) !*Thread {
    const t = try heap.allocator.create(Thread);
    errdefer heap.allocator.destroy(t);
    const fpu_alloc: ?[]u8 = if (process != null) try heap.allocator.alloc(u8, fpu.areaSize() + fpu.AREA_ALIGN) else null;
    errdefer if (fpu_alloc) |a| heap.allocator.free(a);
    const stack = kstack.alloc() orelse return error.OutOfMemory;

    t.* = .{
        .id = 0, // `start` numbers it
        .stack = stack,
        .state = .ready,
        .rsp = context.initStack(@intFromPtr(stack.ptr) + stack.len, @intFromPtr(&firstRun), @intFromPtr(entry)),
        .process = process,
        .fpu_alloc = fpu_alloc,
    };
    if (t.fpuArea()) |area| fpu.initArea(area[0..fpu.areaSize()]);
    return t;
}

/// Free a thread from `create` that was never started.
pub fn destroy(t: *Thread) void {
    assert.check(.thread, t.id == 0 and t.link == .none, "destroying thread {d}, which was started", .{t.id});
    kstack.free(t.stack.?);
    if (t.fpu_alloc) |a| heap.allocator.free(a);
    heap.allocator.destroy(t);
}

/// Give a thread from `create` its ID, without starting it: for a caller
/// that has to tell someone the ID before the thread runs (`clone`).
/// `start` does this itself otherwise. A thread with an ID can no longer
/// be taken back with `destroy`, only with `discard`.
pub fn assignId(t: *Thread) usize {
    const held = lock.acquire();
    defer lock.release(held);
    if (t.id == 0) {
        t.id = next_id;
        next_id += 1;
    }
    return t.id;
}

/// Free a thread that has an ID but was never started. It counts as a
/// thread that came and went.
pub fn discard(t: *Thread) void {
    assert.check(.thread, t.link == .none and !t.on_cpu, "discarding thread {d}, which was started", .{t.id});
    {
        const held = lock.acquire();
        defer lock.release(held);
        exited += 1;
    }
    kstack.free(t.stack.?);
    if (t.fpu_alloc) |a| heap.allocator.free(a);
    heap.allocator.destroy(t);
    _ = reaped.fetchAdd(1, .release);
}

/// Give a thread from `create` its ID (if it has none) and put it in the
/// ready queue. From here on it runs, exits and is freed on its own.
pub fn start(t: *Thread) void {
    const held = lock.acquire();
    defer lock.release(held);
    if (t.id == 0) {
        t.id = next_id;
        next_id += 1;
    }
    enqueue(t);
    _ = kickIdleCpu();
}

/// Make thread `t` notice, soon, that something has changed for it (its
/// process is ending): a thread that sleeps is woken, and one that runs on
/// another CPU is interrupted, so that it comes through the kernel and
/// looks. A thread that waits for something else goes back to waiting
/// unless the wait is one that ends for this (`WaitQueue.waitKillable`).
pub fn interrupt(t: *Thread) void {
    wake(t);
    const held = lock.acquire();
    defer lock.release(held);
    if (t.on_cpu) {
        if (t.cpu) |c| {
            if (c != percpu.current()) ipi.wake(c);
        }
    }
}

/// True if the calling thread belongs to a process that is ending, so
/// that the thread is to end too instead of waiting or returning to its
/// program (`process.dieIfKilled`).
pub fn dying() bool {
    const me = current();
    const p = me.process orelse return false;
    return proc.ending(p) or proc.endsForExec(p, me);
}

/// True if the calling thread is to stop waiting: its process is ending,
/// or a signal it does not block has come for it, which it is to take on
/// its way back to the program (`signal.zig`). Waits a program may be in
/// for as long as it likes look at this; the system call then returns
/// `EINTR` (and may be made again).
pub fn interrupted() bool {
    return dying() or @import("signal.zig").pending(current());
}

/// Create a thread that runs `entry` and put it in the ready queue: `create`
/// and `start` in one.
pub fn spawn(entry: *const fn () void, process: ?*Process) !*Thread {
    const t = try create(entry, process);
    start(t);
    return t;
}

/// Record `stack` as the boot thread's kernel stack. Called once by `kmain`
/// right before it moves off the bootloader's stack, so that the boot thread
/// has a guard page like every other thread and fault reports know its stack.
pub fn adoptBootStack(stack: []u8) void {
    assert.check(.thread, current() == &boot_thread and boot_thread.stack == null, "adoptBootStack called twice or too late", .{});
    boot_thread.stack = stack;
}

/// Make the boot thread the boot CPU's running thread. Called once, right
/// after `percpu.init`.
pub fn init() void {
    const c = percpu.current();
    c.thread = &boot_thread;
    c.slice_left = SLICE_TICKS;
    boot_thread.cpu = c;
}

/// Give CPU `c` a thread to idle in, for a CPU whose first thread goes on
/// to do other things: the boot CPU, whose boot thread runs the rest of
/// boot and may end up on any CPU. (The other CPUs idle in the thread they
/// started in.) The thread only ever runs on `c`, when `c` has nothing
/// else and must leave the thread it ran: see `switchToNext`. Returns
/// `error.OutOfMemory` if there is no memory for it.
pub fn createIdle(c: *percpu.PerCpu) !void {
    const t = try create(idleBody, null);
    t.state = .blocked;
    {
        const held = lock.acquire();
        defer lock.release(held);
        t.id = next_id;
        next_id += 1;
        c.idle_thread = t;
    }
}

fn idleBody() void {
    retire();
}

/// Create the thread that CPU `c` starts in: the context it runs on `stack`
/// from its first instruction of kernel code. Called for a CPU that is
/// about to be started, by the CPU that starts it. The thread is running
/// from the outset and never in the ready queue until it is switched away
/// from. Returns `error.OutOfMemory` if there is no memory for it.
pub fn adoptCpu(c: *percpu.PerCpu, stack: []u8) !*Thread {
    const t = try heap.allocator.create(Thread);
    t.* = .{ .id = 0, .stack = stack, .state = .running, .on_cpu = true, .cpu = c };
    {
        const held = lock.acquire();
        defer lock.release(held);
        t.id = next_id;
        next_id += 1;
    }
    c.thread = t;
    c.idle_thread = t;
    c.slice_left = SLICE_TICKS;
    const top = @intFromPtr(stack.ptr) + stack.len;
    c.kernel_rsp = top;
    c.tables.?.tss.rsp0 = top;
    return t;
}

/// Switch to the next ready thread, if there is one.
///
/// A running thread goes back to the tail of the ready queue; a blocked or
/// dead one does not. Loads the next thread's address space (if it belongs
/// to a process; a kernel thread keeps the one that is loaded), kernel stack
/// and extended CPU state (saving the previous thread's), resets the time
/// slice and switches context. Everything happens with interrupts off, on
/// the previous thread's kernel stack, which stays mapped in every address
/// space. When this thread is scheduled again, frees any zombie threads
/// and returns. No spinlock may be held.
pub fn yield() void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    spinlock.assertHeld(0, "yielding");
    lock.take();
    _ = switchToNext();
    const dead = takeZombies();
    lock.drop();
    reap(dead);
}

/// The switch behind `yield`. Returns false, having done nothing, if no
/// other thread is ready. The scheduler lock is held on entry and on
/// return, but not by the same thread in between: it is handed to the
/// thread switched to, and whichever thread later switches back to this
/// one hands it over again.
fn switchToNext() bool {
    spinlock.assertHeld(1, "switching threads");
    // Switched to from an interrupt taken while halting (preemption by the
    // tick): no longer lazy, and flushed if a flush passed this CPU by,
    // before a thread of the address space it has loaded runs.
    vmm.leaveLazy();
    const c = percpu.current();
    const prev = current();
    const next: *Thread = (if (c.runs_threads) dequeue() else null) orelse blk: {
        // Nothing to take from the queue. The CPU halts where it is,
        // unless it has a thread of its own to do that in (`idle_thread`,
        // which sits blocked in `retire` and is in no queue) and a reason
        // to leave this one: the CPU is parked, so it may not
        // go on running `prev`; or `prev` has exited, and would not be
        // freed for as long as the CPU idled on its stack.
        const idle: *Thread = @ptrCast(@alignCast(c.idle_thread orelse return false));
        if (prev == idle) return false;
        if (c.runs_threads and prev.state != .dead) return false;
        break :blk idle;
    };
    assert.check(.thread, next != prev and !next.on_cpu, "thread {d} is to be run while on a CPU", .{next.id});

    // Safe before the switch only because the lock is held across it:
    // nobody can take `prev` from the queue while this CPU is on its stack.
    if (prev.state == .running) {
        prev.state = .ready;
        enqueue(prev);
        _ = kickIdleCpu(); // it need not wait for this CPU to come back to it
    }
    const now = stats.rdtsc();
    if (prev.run_since != 0) prev.run_cycles += now -% prev.run_since;
    if (next.ready_since != 0) next.wait_cycles += now -% next.ready_since;
    next.ready_since = 0;
    next.run_since = now;
    next.slices += 1;
    next.state = .running;
    next.on_cpu = true;
    if (next.rseq.area != 0) next.rseq_resume = true;
    next.cpu = c;
    c.thread = next;
    c.slice_left = SLICE_TICKS;
    c.preempt_requested = false;
    switches += 1;

    if (next.stack) |s| {
        const top = @intFromPtr(s.ptr) + s.len;
        gdt.setKernelStack(top); // for interrupts from ring 3
        percpu.setKernelStack(top); // for syscalls
    }

    // A kernel thread uses kernel addresses only, and those are mapped the
    // same in every address space: it runs on whichever is loaded, and CR3
    // (and the TLB) is left alone. `process.exit` takes an address space
    // away from every CPU before it is destroyed.
    if (next.process) |p| {
        assert.check(.thread, p.root != 0, "thread {d} is to run in a process that has exited", .{next.id});
        if (p.root != vmm.loadedRoot()) vmm.loadRoot(p.root);
    }

    // A program can change its bases itself: what they are now is prev's.
    if (prev.process != null) saveUserBases(prev);
    fpu.switchState(prev.fpuArea(), next.fpuArea());
    if (next.process != null) percpu.setUserBases(next.fs_base, next.gs_base);

    switched_from = prev;
    context.switchTo(&prev.rsp, next.rsp);
    finishSwitch(); // we're running again, switched to by some other thread
    return true;
}

/// The first thing a thread does when it gets a CPU, on its own stack, with
/// the scheduler lock still held from the other side of the switch: the
/// thread it was switched from is off its stack now. Only from here on may
/// that thread be run by another CPU (once the lock is released) or, if it
/// has exited, be freed.
fn finishSwitch() void {
    const prev = switched_from.?;
    switched_from = null;
    prev.on_cpu = false;
    if (prev.state == .dead) {
        prev.link = .zombie_list;
        prev.next = zombies;
        zombies = prev;
    }
}

/// Stop running the current thread for good without freeing it: it blocks
/// and nothing wakes it, so it never gets the CPU again. For the boot
/// thread once the system is up. While no other thread is ready, the CPU
/// sleeps here or in `block` of whichever thread blocked last. Never returns.
pub fn retire() noreturn {
    _ = cpu.saveAndDisableInterrupts(); // `block` wants them off; it turns them on to sleep
    while (true) block();
}

/// Timer tick: count down the current thread's time slice and preempt it with
/// `yield` once the slice is used up. Called from the timer interrupt handler.
pub fn tick() void {
    const c = percpu.current();
    c.ticks += 1;
    if (!c.runs_threads) {
        // Parked while it was running a thread: give the thread back.
        if (c.thread != c.idle_thread) yield();
        return;
    }
    if (c.slice_left > 0) c.slice_left -= 1;
    if (c.slice_left == 0) yield();
}

/// Terminate the current thread. It is marked dead; the next thread to run
/// puts it on the zombie list, once this CPU has left its stack, and frees
/// its stack and its process (if any). Never returns.
pub fn exit() noreturn {
    _ = cpu.saveAndDisableInterrupts(); // never restored: this thread is done
    spinlock.assertHeld(0, "exiting");
    lock.take(); // released by the thread that is switched to
    const me = current();
    assert.check(.thread, me.state == .running and me.link == .none, "thread {d} exits in state {t} ({t})", .{ me.id, me.state, me.link });
    assert.check(.thread, me.wait_queue == null, "thread {d} exits while on a wait queue", .{me.id});
    me.state = .dead;
    exited += 1;
    // Never comes back from the switch. If nothing is ready (every other
    // thread sleeps), idle on this stack until an interrupt wakes one.
    while (true) {
        if (!switchToNext()) idleOnce();
    }
}

/// Park or unpark CPU number `n` (not one whose first thread still runs): see "Several CPUs" at
/// the top of the file. Returns at once; a CPU that is told to park gives
/// up its thread at its next timer tick, or sooner if the thread blocks,
/// and `isParked` says when it has.
pub fn setParked(n: usize, parked: bool) void {
    const c = percpu.get(n);
    assert.check(.thread, c.idle_thread != null, "CPU {d} cannot be parked", .{n});
    const held = lock.acquire();
    defer lock.release(held);
    c.runs_threads = !parked;
    if (!parked and c != percpu.current()) {
        c.idle = false;
        ipi.wake(c); // it is halted: have it look at the ready queue
    }
}

/// True if CPU number `n` is parked and has given up the thread it ran.
pub fn isParked(n: usize) bool {
    const c = percpu.get(n);
    const held = lock.acquire();
    defer lock.release(held);
    return !c.runs_threads and c.thread == c.idle_thread;
}

/// Record in `t`, the thread this CPU runs or last ran in ring 3, the FS
/// and GS base its user code has now. Interrupts must be off.
fn saveUserBases(t: *Thread) void {
    const b = percpu.userBases();
    t.fs_base = b.fs;
    t.gs_base = b.gs;
}

/// The calling thread's FS and GS base as its user code has them now.
pub fn userBases() struct { fs: u64, gs: u64 } {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const me = current();
    if (me.process != null) saveUserBases(me);
    return .{ .fs = me.fs_base, .gs = me.gs_base };
}

/// Set the FS or GS base of the calling thread's user code, now and
/// whenever it runs again.
pub fn setUserBase(which: enum { fs, gs }, value: u64) void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const me = current();
    saveUserBases(me); // the other one, as the program may have set it
    switch (which) {
        .fs => me.fs_base = value,
        .gs => me.gs_base = value,
    }
    percpu.setUserBases(me.fs_base, me.gs_base);
}

/// Threads freed since boot. With `spawnedCount`, tests use it to see that
/// every thread that exited was reaped, once.
pub fn reapedCount() usize {
    return reaped.load(.acquire);
}

/// Threads that have exited since boot. The difference to `reapedCount` is
/// the threads that are gone but not freed yet: on the way off their CPU,
/// or waiting for the next thread switch on any CPU.
pub fn exitedCount() usize {
    const held = lock.acquire();
    defer lock.release(held);
    return exited;
}

/// Threads created since boot (not counting the boot thread).
pub fn spawnedCount() usize {
    const held = lock.acquire();
    defer lock.release(held);
    return next_id - 1;
}

/// Context switches since boot.
pub fn switchCount() usize {
    const held = lock.acquire();
    defer lock.release(held);
    return switches;
}

/// Times the CPU this is called on was halted because no thread was
/// ready, since boot.
pub fn haltCount() usize {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    return percpu.current().halts;
}

/// Record how much of its kernel stack the current thread has used so far
/// (see `kstack.record`) and return it; null if usage is not measured or the
/// thread has no stack of its own yet. Exited threads are recorded when they
/// are reaped; this is for threads that never exit, like the boot thread.
pub fn recordStackUsage() ?usize {
    const me = current();
    const stack = me.stack orelse return null;
    const bytes = kstack.used(stack) orelse return null;
    kstack.record(me.id, bytes);
    return bytes;
}

/// Return the thread that is currently running.
pub fn current() *Thread {
    const t = percpu.currentThread() orelse return &boot_thread; // before `init`
    return @ptrCast(@alignCast(t));
}

/// Return the ID of the thread that is currently running. The boot thread has ID 0.
pub fn id() usize {
    return current().id;
}

/// First code a new thread runs, reached through `thread_trampoline` (see
/// `context.initStack`). It was switched to like any other thread, so it
/// finishes that switch and releases the scheduler lock; then it enables
/// interrupts, calls the thread's entry function and exits the thread when
/// it returns.
fn firstRun(entry: usize) callconv(.c) noreturn {
    finishSwitch();
    const dead = takeZombies();
    lock.drop();
    reap(dead);
    asm volatile ("sti"); // new threads begin inside a switch, with interrupts off
    const f: *const fn () void = @ptrFromInt(entry);
    f();
    exit();
}
