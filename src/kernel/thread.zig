//! Kernel threads and the round-robin scheduler.
//!
//! Ready threads wait in a FIFO queue. `yield` switches to the next one,
//! loading its address space and kernel stack, and the timer calls `tick` to
//! preempt a thread once its time slice runs out. Exited threads are parked on
//! a zombie list and freed by the next thread that runs, since a thread cannot
//! free the stack it is still running on.

const root = @import("root");
const heap = @import("heap.zig");
const context = @import("../arch/x86_64/context.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const arch_syscall = @import("../arch/x86_64/syscall.zig");
const vmm = @import("../arch/x86_64/vmm.zig");
const proc = @import("process.zig"); // the file: for proc.destroy
const Process = proc.Process; // the struct: for fields and parameters

const SLICE_TICKS = 5; // 50 ms at 100 Hz
var slice_left: u32 = SLICE_TICKS;
const STACK_SIZE = 16 * 1024;

var boot_thread: Thread = .{ .id = 0, .stack = null, .state = .running };
var current_thread: *Thread = &boot_thread;
var next_id: usize = 1;

var loaded_root: u64 = 0;

// FIFO ready queue
var ready_head: ?*Thread = null;
var ready_tail: ?*Thread = null;

var zombies: ?*Thread = null;

/// Append `t` to the tail of the ready queue. Callers must have interrupts disabled.
fn enqueue(t: *Thread) void {
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
    return t;
}

/// Free every thread on the zombie list, together with its process (if any)
/// and its stack. Called after a context switch, when the dead threads are
/// guaranteed not to be running.
fn reap() void {
    while (zombies) |z| {
        zombies = z.next;
        if (z.process) |p| proc.destroy(p);
        heap.allocator.free(z.stack.?);
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

/// A kernel thread: a stack, saved registers and scheduling state. A thread
/// either belongs to a user process or is a pure kernel thread (`process == null`).
pub const Thread = struct {
    id: usize,
    /// Saved stack pointer while the thread is not running.
    rsp: usize = 0,
    /// Kernel stack, owned by the thread. Null only for the boot thread.
    stack: ?[]u8,
    state: State,
    /// Link in the ready queue or the zombie list.
    next: ?*Thread = null,
    /// Process this thread runs, if any.
    process: ?*Process = null,
    /// A `wake` arrived before `block`, so the next `block` returns at once.
    wake_pending: bool = false,
    /// Value passed from waker to sleeper (e.g. a child's exit code).
    wake_value: u64 = 0,
};

/// Block the current thread until another thread or interrupt handler calls
/// `wake` on it. Returns immediately if a wake is already pending. Callers
/// must disable interrupts between checking their wait condition and calling
/// `block`, so a wake cannot slip in between.
pub fn block() void {
    const me = current_thread;
    if (me.wake_pending) { // the event already happened
        me.wake_pending = false;
        return;
    }
    me.state = .blocked;
    while (me.state == .blocked) yield(); // the idle thread is always ready
    me.wake_pending = false;
}

/// Wake thread `t`: if it is blocked, make it ready and queue it; otherwise
/// remember the wake so its next `block` returns immediately. Callers must
/// have interrupts disabled.
pub fn wake(t: *Thread) void {
    t.wake_pending = true;
    if (t.state == .blocked) {
        t.state = .ready;
        enqueue(t);
    }
}

/// Create a thread that runs `entry` and put it in the ready queue.
///
/// `process` is the user process the thread belongs to, or null for a kernel
/// thread. The thread gets a 16 KiB kernel stack from the heap; when `entry`
/// returns the thread exits. Returns `error.OutOfMemory` if the allocation fails.
pub fn spawn(entry: *const fn () void, process: ?*Process) !*Thread {
    const t = try heap.allocator.create(Thread);
    errdefer heap.allocator.destroy(t);
    const stack = try heap.allocator.alloc(u8, STACK_SIZE);

    t.* = .{
        .id = next_id,
        .stack = stack,
        .state = .ready,
        .rsp = context.initStack(@intFromPtr(stack.ptr) + stack.len, @intFromPtr(&start), @intFromPtr(entry)),
        .process = process,
    };

    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    t.id = next_id;
    next_id += 1;
    enqueue(t);
    return t;
}

/// Switch to the next ready thread, if there is one.
///
/// A running thread goes back to the tail of the ready queue; a blocked or
/// dead one does not. Loads the next thread's address space and kernel stack,
/// resets the time slice and switches context. When this thread is scheduled
/// again, frees any zombie threads and returns.
pub fn yield() void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);

    const next = dequeue() orelse return;
    const prev = current_thread;

    if (prev.state == .running) {
        prev.state = .ready;
        enqueue(prev);
    }
    next.state = .running;
    current_thread = next;
    slice_left = SLICE_TICKS;

    if (next.stack) |s| {
        const top = @intFromPtr(s.ptr) + s.len;
        gdt.setKernelStack(top); // for interrupts from ring 3
        arch_syscall.setKernelStack(top); // for syscalls
    }

    const new_root = if (next.process) |p| p.root else vmm.kernel_root;
    if (new_root != loaded_root) {
        vmm.loadRoot(new_root);
        loaded_root = new_root;
    }

    context.switchTo(&prev.rsp, next.rsp);

    reap(); // we're running again; any zombie is now some *other* thread
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
    current_thread.state = .dead;
    current_thread.next = zombies;
    zombies = current_thread;
    yield();
    root.halt();
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
