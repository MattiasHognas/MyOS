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

pub const State = enum { ready, running, dead };

pub const Thread = struct {
    id: usize,
    rsp: usize = 0,
    stack: ?[]u8,
    state: State,
    next: ?*Thread = null,
    process: ?*Process = null,
};

var boot_thread: Thread = .{ .id = 0, .stack = null, .state = .running };
var current_thread: *Thread = &boot_thread;
var next_id: usize = 1;

var loaded_root: u64 = 0;

// ---- FIFO ready queue ----
var ready_head: ?*Thread = null;
var ready_tail: ?*Thread = null;

fn enqueue(t: *Thread) void {
    t.next = null;
    if (ready_tail) |tail| tail.next = t else ready_head = t;
    ready_tail = t;
}

fn dequeue() ?*Thread {
    const t = ready_head orelse return null;
    ready_head = t.next;
    if (ready_head == null) ready_tail = null;
    return t;
}

var zombies: ?*Thread = null;

fn reap() void {
    while (zombies) |z| {
        zombies = z.next;
        if (z.process) |p| proc.destroy(p);
        heap.allocator.free(z.stack.?);
        heap.allocator.destroy(z);
    }
}

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

pub fn tick() void {
    if (slice_left > 0) slice_left -= 1;
    if (slice_left == 0) yield();
}

pub fn exit() noreturn {
    _ = cpu.saveAndDisableInterrupts(); // never restored: this thread is done
    current_thread.state = .dead;
    current_thread.next = zombies;
    zombies = current_thread;
    yield();
    root.halt();
}

pub fn current() *Thread {
    return current_thread;
}

pub fn id() usize {
    return current_thread.id;
}

fn start(entry: usize) callconv(.c) noreturn {
    asm volatile ("sti"); // new threads begin inside yield, with interrupts off
    const f: *const fn () void = @ptrFromInt(entry);
    f();
    exit();
}
