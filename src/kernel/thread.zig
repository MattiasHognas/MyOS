const root = @import("root");
const heap = @import("heap.zig");
const context = @import("../arch/x86_64/context.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const gdt = @import("../arch/x86_64/gdt.zig");

const SLICE_TICKS = 5; // 50 ms at 100 Hz
var slice_left: u32 = SLICE_TICKS;

const STACK_SIZE = 16 * 1024;

pub const State = enum { ready, running, dead };

pub const Thread = struct {
    id: usize,
    rsp: usize = 0,
    stack: ?[]u8, // null for the boot thread (it runs on Limine's stack)
    state: State,
    next: ?*Thread = null,
};

var boot_thread: Thread = .{ .id = 0, .stack = null, .state = .running };
var current: *Thread = &boot_thread;
var next_id: usize = 1;

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
        heap.allocator.free(z.stack.?);
        heap.allocator.destroy(z);
    }
}

pub fn id() usize {
    return current.id;
}

pub fn spawn(entry: *const fn () void) !*Thread {
    const t = try heap.allocator.create(Thread);
    errdefer heap.allocator.destroy(t);
    const stack = try heap.allocator.alloc(u8, STACK_SIZE);

    t.* = .{
        .id = next_id,
        .stack = stack,
        .state = .ready,
        .rsp = context.initStack(@intFromPtr(stack.ptr) + stack.len, @intFromPtr(&start), @intFromPtr(entry)),
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
    const prev = current;
    if (prev.state == .running) {
        prev.state = .ready;
        enqueue(prev);
    }
    next.state = .running;
    current = next;
    slice_left = SLICE_TICKS;

    if (next.stack) |s| gdt.setKernelStack(@intFromPtr(s.ptr) + s.len);

    context.switchTo(&prev.rsp, next.rsp);

    reap(); // we're running again; any zombie is now some *other* thread
}

pub fn tick() void {
    if (slice_left > 0) slice_left -= 1;
    if (slice_left == 0) yield();
}

pub fn exit() noreturn {
    _ = cpu.saveAndDisableInterrupts(); // never restored: this thread is done
    current.state = .dead;
    current.next = zombies;
    zombies = current;
    yield();
    root.halt();
}

fn start(entry: usize) callconv(.c) noreturn {
    asm volatile ("sti"); // new threads begin inside yield, with interrupts off
    const f: *const fn () void = @ptrFromInt(entry);
    f();
    exit();
}
