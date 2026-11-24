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
//! - **running**: on the CPU; in no queue.
//! - **blocked**: called `block` and waits for `wake`; in no scheduler queue
//!   (it may be on a `WaitQueue`, which is how others find it).
//! - **dead**: called `exit`; on the zombie list until the next thread that
//!   runs frees it. Never runs again.
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
//! There is no idle thread. When a thread blocks or exits and nothing is
//! ready, the CPU halts right there, in `block` or `exit` on that thread's
//! stack, until an interrupt makes a thread ready. So a ready thread never
//! waits behind an idle one, and the check for "nothing to run" and the
//! halt happen with interrupts off, with no gap a wake-up could fall into.
//!
//! ## Address spaces
//!
//! A thread of a process runs on its process's address space. A kernel
//! thread runs on whichever one is loaded: it only uses kernel addresses,
//! which are mapped the same in all of them. So a switch to a kernel thread
//! and back costs no CR3 load and no TLB flush.
//!
//! All scheduler state is protected by turning interrupts off (one CPU).

const std = @import("std");
const root = @import("root");

const context = @import("../arch/x86_64/context.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const fpu = @import("../arch/x86_64/fpu.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const vmm = @import("../arch/x86_64/vmm.zig");
const assert = @import("debug/assert.zig");
const heap = @import("heap.zig");
const kstack = @import("kstack.zig");
const proc = @import("process.zig");
const Process = proc.Process;
const WaitQueue = @import("sync/wait_queue.zig").WaitQueue;

const SLICE_TICKS = 5; // 50 ms at 100 Hz
var slice_left: u32 = SLICE_TICKS;

var boot_thread: Thread = .{ .id = 0, .stack = null, .state = .running };
var current_thread: *Thread = &boot_thread;
var next_id: usize = 1;

// FIFO ready queue
var ready_head: ?*Thread = null;
var ready_tail: ?*Thread = null;

var zombies: ?*Thread = null;
var reaped: usize = 0;
var switches: usize = 0;
var halts: usize = 0;

/// Append `t` to the tail of the ready queue. Callers must have interrupts disabled.
fn enqueue(t: *Thread) void {
    assert.check(.thread, t.state == .ready, "enqueueing thread {d} in state {t}", .{ t.id, t.state });
    assert.check(.thread, t.link == .none, "thread {d} is already queued ({t})", .{ t.id, t.link });
    t.link = .ready_queue;
    t.next = null;
    if (ready_tail) |tail| tail.next = t else ready_head = t;
    ready_tail = t;
}

/// Remove and return the thread at the head of the ready queue, or null if it
/// is empty. Callers must have interrupts disabled.
fn dequeue() ?*Thread {
    const t = ready_head orelse return null;
    ready_head = t.next;
    if (ready_head == null) ready_tail = null;
    t.next = null;
    t.link = .none;
    return t;
}

/// Free every thread on the zombie list, together with its process (if any)
/// and its stack, after recording how much of the stack it used. Called after a context switch, when the dead threads are
/// guaranteed not to be running.
fn reap() void {
    while (zombies) |z| {
        zombies = z.next;
        assert.check(.thread, z.state == .dead and z.link == .zombie_list, "reaping thread {d} in state {t} ({t})", .{ z.id, z.state, z.link });
        assert.check(.thread, z != current_thread, "thread {d} reaps itself", .{z.id});
        z.link = .none;
        reaped += 1;
        if (z.process) |p| proc.teardown(p);
        if (kstack.used(z.stack.?)) |bytes| kstack.record(z.id, bytes); // -Dstack-usage
        kstack.free(z.stack.?);
        if (z.fpu_alloc) |a| heap.allocator.free(a);
        heap.allocator.destroy(z);
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
/// condition they wait for. Callers must disable interrupts between
/// checking that condition and calling `block`, so a wake cannot slip in
/// between; interrupts are off again on return.
///
/// While no thread is ready the CPU sleeps here, with interrupts on, until
/// an interrupt wakes this thread or makes another one ready.
pub fn block() void {
    const me = current_thread;
    assert.check(.thread, cpu.readFlags() & (1 << 9) == 0, "thread {d} blocks with interrupts on", .{me.id});
    if (me.wake_pending) { // the event already happened
        me.wake_pending = false;
        return;
    }
    me.state = .blocked;
    while (me.state == .blocked) {
        if (!switchToNext()) idleOnce();
    }
    me.wake_pending = false;
}

/// Sleep until the next interrupt, then turn interrupts off again. The
/// `sti` takes effect after the following instruction, so no interrupt can
/// arrive between enabling them and halting. Only called when the ready
/// queue is empty, with interrupts off since that was found out.
fn idleOnce() void {
    assert.check(.thread, ready_head == null, "halting while thread {d} is ready", .{if (ready_head) |t| t.id else 0});
    halts += 1;
    asm volatile ("sti; hlt; cli");
}

/// Wake thread `t`: if it is blocked, make it runnable; otherwise leave a
/// permit so its next `block` returns immediately. Does nothing to a dead
/// thread. Callers must have interrupts disabled. Safe from interrupt handlers.
pub fn wake(t: *Thread) void {
    assert.check(.thread, cpu.readFlags() & (1 << 9) == 0, "wake of thread {d} with interrupts on", .{t.id});
    if (t.state == .dead) return;
    t.wake_pending = true;
    if (t.state != .blocked) return;
    if (t == current_thread) {
        // It is blocked but still on the CPU, idling in `block` because
        // nothing else was ready: it just carries on.
        t.state = .running;
    } else {
        t.state = .ready;
        enqueue(t);
    }
}

/// Create a thread that runs `entry` and put it in the ready queue.
///
/// `process` is the user process the thread belongs to, or null for a kernel
/// thread. The thread gets a guarded kernel stack from `kstack` and, if it
/// belongs to a process, clean extended CPU state (`fpu.initArea`); when `entry`
/// returns the thread exits. Returns `error.OutOfMemory` if an allocation
/// fails or all kernel stacks are in use.
pub fn spawn(entry: *const fn () void, process: ?*Process) !*Thread {
    const t = try heap.allocator.create(Thread);
    errdefer heap.allocator.destroy(t);
    const fpu_alloc: ?[]u8 = if (process != null) try heap.allocator.alloc(u8, fpu.areaSize() + fpu.AREA_ALIGN) else null;
    errdefer if (fpu_alloc) |a| heap.allocator.free(a);
    const stack = kstack.alloc() orelse return error.OutOfMemory;

    t.* = .{
        .id = next_id,
        .stack = stack,
        .state = .ready,
        .rsp = context.initStack(@intFromPtr(stack.ptr) + stack.len, @intFromPtr(&start), @intFromPtr(entry)),
        .process = process,
        .fpu_alloc = fpu_alloc,
    };
    if (t.fpuArea()) |area| fpu.initArea(area[0..fpu.areaSize()]);

    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    t.id = next_id;
    next_id += 1;
    enqueue(t);
    return t;
}

/// Record `stack` as the boot thread's kernel stack. Called once by `kmain`
/// right before it moves off the bootloader's stack, so that the boot thread
/// has a guard page like every other thread and fault reports know its stack.
pub fn adoptBootStack(stack: []u8) void {
    assert.check(.thread, current_thread == &boot_thread and boot_thread.stack == null, "adoptBootStack called twice or too late", .{});
    boot_thread.stack = stack;
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
/// and returns.
pub fn yield() void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    _ = switchToNext();
}

/// The switch behind `yield`. Returns false, having done nothing, if no
/// other thread is ready. Interrupts must be off.
fn switchToNext() bool {
    const next = dequeue() orelse return false;
    const prev = current_thread;
    assert.check(.thread, next != prev, "thread {d} is in the ready queue while running", .{prev.id});

    if (prev.state == .running) {
        prev.state = .ready;
        enqueue(prev);
    }
    next.state = .running;
    current_thread = next;
    slice_left = SLICE_TICKS;
    switches += 1;

    if (next.stack) |s| {
        const top = @intFromPtr(s.ptr) + s.len;
        gdt.setKernelStack(top); // for interrupts from ring 3
        percpu.setKernelStack(top); // for syscalls
    }

    // A kernel thread uses kernel addresses only, and those are mapped the
    // same in every address space: it runs on whichever is loaded, and CR3
    // (and the TLB) is left alone. `process.teardown` switches away from an
    // address space before it is destroyed.
    if (next.process) |p| {
        if (p.root != vmm.loadedRoot()) vmm.loadRoot(p.root);
    }

    fpu.switchState(prev.fpuArea(), next.fpuArea());

    context.switchTo(&prev.rsp, next.rsp);

    reap(); // we're running again; any zombie is now some *other* thread
    return true;
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
    if (slice_left > 0) slice_left -= 1;
    if (slice_left == 0) yield();
}

/// Terminate the current thread. It is marked dead and put on the zombie list;
/// the next thread to run frees its stack and its process (if any). Never returns.
pub fn exit() noreturn {
    _ = cpu.saveAndDisableInterrupts(); // never restored: this thread is done
    const me = current_thread;
    assert.check(.thread, me.state == .running and me.link == .none, "thread {d} exits in state {t} ({t})", .{ me.id, me.state, me.link });
    assert.check(.thread, me.wait_queue == null, "thread {d} exits while on a wait queue", .{me.id});
    me.state = .dead;
    me.link = .zombie_list;
    me.next = zombies;
    zombies = me;
    // Never comes back from the switch. If nothing is ready (every other
    // thread sleeps), idle on this stack until an interrupt wakes one.
    while (true) {
        if (!switchToNext()) idleOnce();
    }
}

/// Threads freed since boot. With `spawnedCount`, tests use it to see that
/// every thread that exited was reaped, once.
pub fn reapedCount() usize {
    return reaped;
}

/// Threads created since boot (not counting the boot thread).
pub fn spawnedCount() usize {
    return next_id - 1;
}

/// Context switches since boot.
pub fn switchCount() usize {
    return switches;
}

/// Times the CPU was halted because no thread was ready, since boot.
pub fn haltCount() usize {
    return halts;
}

/// Record how much of its kernel stack the current thread has used so far
/// (see `kstack.record`) and return it; null if usage is not measured or the
/// thread has no stack of its own yet. Exited threads are recorded when they
/// are reaped; this is for threads that never exit, like the boot thread.
pub fn recordStackUsage() ?usize {
    const stack = current_thread.stack orelse return null;
    const bytes = kstack.used(stack) orelse return null;
    kstack.record(current_thread.id, bytes);
    return bytes;
}

/// Return the thread that is currently running.
pub fn current() *Thread {
    return current_thread;
}

/// Return the ID of the thread that is currently running. The boot thread has ID 0.
pub fn id() usize {
    return current_thread.id;
}

/// First code a new thread runs, reached through `thread_trampoline` (see
/// `context.initStack`). Enables interrupts, calls the thread's entry
/// function and exits the thread when it returns.
fn start(entry: usize) callconv(.c) noreturn {
    asm volatile ("sti"); // new threads begin inside yield, with interrupts off
    const f: *const fn () void = @ptrFromInt(entry);
    f();
    exit();
}
