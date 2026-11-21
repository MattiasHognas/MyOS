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

// Add a thread to the ready queue. The caller must disable interrupts to avoid a race with dequeue().
fn enqueue(t: *Thread) void {
    t.next = null;
    if (ready_tail) |tail| tail.next = t else ready_head = t;
    ready_tail = t;
}

// Dequeue the next ready thread, or return null if none are ready. The caller must disable interrupts to avoid a race with enqueue().
fn dequeue() ?*Thread {
    const t = ready_head orelse return null;
    ready_head = t.next;
    if (ready_head == null) ready_tail = null;
    return t;
}

// Free any threads that have exited. This is called after a context switch, so that the current thread is not freed while it is still running.
fn reap() void {
    while (zombies) |z| {
        zombies = z.next;
        if (z.process) |p| proc.destroy(p);
        heap.allocator.free(z.stack.?);
        heap.allocator.destroy(z);
    }
}

// The idle thread runs when no other threads are ready. It yields to any ready threads, then sleeps until the next interrupt.
pub const State = enum { ready, running, blocked, dead };

// A thread is a single execution context, with its own stack and CPU registers. It may be part of a process, or it may be a kernel thread with no process.
pub const Thread = struct {
    id: usize,
    rsp: usize = 0,
    stack: ?[]u8,
    state: State,
    next: ?*Thread = null,
    process: ?*Process = null,
    wake_pending: bool = false, // a wake() arrived before block()
    wake_value: u64 = 0, // passed from waker to sleeper (e.g. exit code)
};

// Block the current thread until another thread wakes it. If a wake() already happened, return immediately. Otherwise, yield to other threads until woken.
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

// Wake a blocked thread. If the thread is not blocked, set a flag so that the next block() returns immediately.
pub fn wake(t: *Thread) void {
    t.wake_pending = true;
    if (t.state == .blocked) {
        t.state = .ready;
        enqueue(t);
    }
}

// Create a new thread that starts executing at `entry`. The thread is added to the ready queue, but does not run until the scheduler picks it. The thread's stack is allocated from the heap and freed when the thread exits.
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

// Yield to another thread. If no other threads are ready, return immediately.
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

// Called by the timer interrupt handler to implement preemptive multitasking. Decrements the current thread's time slice, and yields if it reaches zero.
pub fn tick() void {
    if (slice_left > 0) slice_left -= 1;
    if (slice_left == 0) yield();
}

// Exit the current thread. The thread is marked as dead and added to the zombie list, so that its resources can be freed later. The thread's process is destroyed if it has one.
pub fn exit() noreturn {
    _ = cpu.saveAndDisableInterrupts(); // never restored: this thread is done
    current_thread.state = .dead;
    current_thread.next = zombies;
    zombies = current_thread;
    yield();
    root.halt();
}

// Return the currently running thread.
pub fn current() *Thread {
    return current_thread;
}

// Return the ID of the currently running thread.
pub fn id() usize {
    return current_thread.id;
}

// The entry point for new threads. This function is called by the thread's stack, which was set up by initStack(). It calls the thread's start function, then exits the thread when it returns.
fn start(entry: usize) callconv(.c) noreturn {
    asm volatile ("sti"); // new threads begin inside yield, with interrupts off
    const f: *const fn () void = @ptrFromInt(entry);
    f();
    exit();
}
