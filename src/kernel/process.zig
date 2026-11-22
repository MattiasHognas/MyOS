//! User processes: an address space, a loaded ELF program, a user stack and a
//! file descriptor table, run by a single thread.

const heap = @import("heap.zig");
const pmm = @import("pmm.zig");
const thread = @import("thread.zig");
const elf = @import("elf.zig");
const vmm = @import("../arch/x86_64/vmm.zig");
const context = @import("../arch/x86_64/context.zig");
const vfs = @import("vfs.zig");
const cpu = @import("../arch/x86_64/cpu.zig");

/// Initial user stack pointer; the stack grows down from here.
const STACK_TOP: u64 = 0x0000_7FFF_FFFF_0000;
const STACK_PAGES = 4; // 16 KiB

/// A user process. Owned by its thread and freed by `destroy` when that thread is reaped.
pub const Process = struct {
    /// Physical address of the process's PML4.
    root: u64,
    /// User-space entry point from the ELF header.
    entry: u64,
    /// Heap-allocated copy of the name the process was spawned with.
    name: []const u8,
    /// File descriptor table, indexed by fd.
    files: [16]?*vfs.OpenFile = @splat(null),
    /// Thread woken with the exit code (in `wake_value`) when the process exits.
    waiter: ?*thread.Thread = null,
};

/// Terminate the current process with exit code `code`.
///
/// Wakes the waiting parent (if any) with the exit code, then exits the
/// current thread. The process's memory is freed later, when the scheduler
/// reaps the thread. Must be called from a thread that belongs to a process.
pub fn exit(code: u64) noreturn {
    _ = cpu.saveAndDisableInterrupts(); // never restored: we're done
    const p = thread.current().process.?;
    if (p.waiter) |w| {
        w.wake_value = code;
        thread.wake(w);
    }
    thread.exit();
}

/// Load the executable at `path` from the VFS and start it as a new process.
///
/// `waiter` is woken with the exit code when the process exits. Returns
/// immediately without waiting for the process. Returns
/// `error.FileNotFound` if the file doesn't exist, `error.ReadFailed` if it
/// can't be read completely, or any error from `spawn`.
pub fn spawnPath(path: []const u8, waiter: ?*thread.Thread) !*Process {
    const node = vfs.lookup(path) orelse return error.FileNotFound;
    const image = try heap.allocator.alloc(u8, node.size);
    defer heap.allocator.free(image); // elf.load copies it into the process's pages
    if (vfs.read(&node, 0, image) != node.size) return error.ReadFailed;
    return spawn(path, image, waiter);
}

/// Free everything owned by process `p`: open files, its address space, its
/// name and the `Process` itself. No thread may still be running in it, and
/// its address space must not be loaded.
pub fn destroy(p: *Process) void {
    for (p.files) |f| if (f) |of| heap.allocator.destroy(of);
    vmm.destroyAddressSpace(p.root);
    heap.allocator.free(p.name);
    heap.allocator.destroy(p);
}

/// Create a process named `name` that runs the ELF executable `image`.
///
/// Creates a new address space, loads `image` into it (`image` is copied and
/// may be freed afterwards), maps a zeroed 16 KiB user stack and spawns a
/// thread that enters user mode at the entry point. `waiter` is woken with
/// the exit code when the process exits. Returns immediately without waiting
/// for the process. On error nothing is leaked.
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

/// Thread entry point for a new process: jump to the process's entry point in
/// ring 3 on its user stack. The scheduler has already loaded the process's
/// address space. Never returns.
fn userStart() void {
    const p = thread.current().process.?;
    context.enterUser(p.entry, STACK_TOP - 8); // -8: as if _start had been called
}
