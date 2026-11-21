const heap = @import("heap.zig");
const pmm = @import("pmm.zig");
const thread = @import("thread.zig");
const elf = @import("elf.zig");
const vmm = @import("../arch/x86_64/vmm.zig");
const context = @import("../arch/x86_64/context.zig");
const vfs = @import("vfs.zig");
const cpu = @import("../arch/x86_64/cpu.zig");

const STACK_TOP: u64 = 0x0000_7FFF_FFFF_0000;
const STACK_PAGES = 4; // 16 KiB

pub const Process = struct {
    root: u64,
    entry: u64,
    name: []const u8,
    files: [16]?*vfs.OpenFile = @splat(null),
    waiter: ?*thread.Thread = null, // woken with the exit code when we exit
};

// Exit the current process with the given exit code. The current thread is marked as dead, and any thread that is waiting for this process to exit is woken with the exit code. The current thread is then blocked forever, and will be reaped by the scheduler.
pub fn exit(code: u64) noreturn {
    _ = cpu.saveAndDisableInterrupts(); // never restored: we're done
    const p = thread.current().process.?;
    if (p.waiter) |w| {
        w.wake_value = code;
        thread.wake(w);
    }
    thread.exit();
}

// Create a new process that runs the given ELF image in user space. The process is created with a new address space, and a new thread is spawned to run it. The current thread is blocked until the new thread exits, at which point the new thread's exit value is returned.
pub fn spawnPath(path: []const u8, waiter: ?*thread.Thread) !*Process {
    const node = vfs.lookup(path) orelse return error.FileNotFound;
    const image = try heap.allocator.alloc(u8, node.size);
    defer heap.allocator.free(image); // elf.load copies it into the process's pages
    if (vfs.read(&node, 0, image) != node.size) return error.ReadFailed;
    return spawn(path, image, waiter);
}

// Free all resources associated with a process. The process must have exited, and no threads must be running in it. The process's address space is destroyed, and all open files are closed.
pub fn destroy(p: *Process) void {
    for (p.files) |f| if (f) |of| heap.allocator.destroy(of);
    vmm.destroyAddressSpace(p.root);
    heap.allocator.free(p.name);
    heap.allocator.destroy(p);
}

// Create a new process that runs the given ELF image in user space. The process is created with a new address space, and a new thread is spawned to run it. The current thread is blocked until the new thread exits, at which point the new thread's exit value is returned.
pub fn spawn(name: []const u8, image: []const u8, waiter: ?*thread.Thread) !*Process {
    const root = vmm.createAddressSpace();
    errdefer vmm.destroyAddressSpace(root);

    const entry = try elf.load(root, image);

    for (1..STACK_PAGES + 1) |i| {
        const phys = pmm.alloc() orelse return error.OutOfMemory;
        @memset(pmm.physToVirt(phys)[0..pmm.PAGE_SIZE], 0);
        vmm.map(root, STACK_TOP - i * pmm.PAGE_SIZE, phys, vmm.USER | vmm.WRITABLE | vmm.NX, false);
    }

    const p = try heap.allocator.create(Process);
    errdefer heap.allocator.destroy(p);
    const name_copy = try heap.allocator.dupe(u8, name);
    errdefer heap.allocator.free(name_copy);
    p.* = .{ .root = root, .entry = entry, .name = name_copy, .waiter = waiter };

    _ = try thread.spawn(userStart, p);
    return p;
}

// Start executing the current thread's process in user space. The process must have been created with spawn() and have a valid entry point. The thread's stack pointer is set to the top of the user stack, and the CPU switches to user mode. This function does not return.
fn userStart() void {
    const p = thread.current().process.?;
    context.enterUser(p.entry, STACK_TOP - 8); // -8: as if _start had been called
}
