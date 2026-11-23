//! User processes: an address space, a loaded ELF program, a user stack and a
//! file descriptor table, run by a single thread.
//!
//! Every process has `Limits` on what it may use: memory, open files, and
//! how many processes may be alive below it. A child inherits its parent's
//! limits. They bound what one program and the programs it starts can take;
//! they do not divide memory between unrelated programs.

const context = @import("../arch/x86_64/context.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const kstack = @import("kstack.zig");
const vmm = @import("../arch/x86_64/vmm.zig");
const elf = @import("elf.zig");
const elf_image = @import("elf_image.zig");
const heap = @import("heap.zig");
const pmm = @import("pmm.zig");
const thread = @import("thread.zig");
const vfs = @import("vfs.zig");

/// Initial user stack pointer; the stack grows down from here.
pub const STACK_TOP: u64 = 0x0000_7FFF_FFFF_0000;
const STACK_PAGES = 4; // 16 KiB
/// Address space below `STACK_TOP` kept for the user stack: 8 MiB, Linux's
/// default stack limit. Only `STACK_PAGES` of it are mapped; a program image
/// may not be loaded into any of it.
pub const STACK_RESERVE: u64 = 8 * 1024 * 1024;
/// Lowest address a program may be loaded at. The first 64 KiB stay unmapped
/// (as on Linux), so a null pointer faults even with a small offset added.
pub const IMAGE_MIN: u64 = 0x1_0000;
/// Most memory the segments of one program may take under the default limits.
pub const MAX_IMAGE_BYTES: u64 = 256 * 1024 * 1024;
/// Size of a process's descriptor table, and so the most `Limits.max_files` can allow.
pub const MAX_FILES = 16;

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
        .max_addr = STACK_TOP - STACK_RESERVE,
        .max_bytes = (limits.max_pages -| (STACK_PAGES + kstack.STACK_PAGES)) * pmm.PAGE_SIZE,
    };
}

/// `imageLimits` for the default limits.
pub const image_limits: elf_image.Limits = imageLimits(.{});

/// Exit status of a process the kernel killed (a fault in ring 3, or a
/// state it could not return to).
pub const EXIT_KILLED = 255;

/// A user process. Owned by its thread and freed by `destroy` when that thread is reaped.
pub const Process = struct {
    /// Physical address of the process's PML4.
    root: u64,
    /// User-space entry point from the ELF header.
    entry: u64,
    /// Heap-allocated copy of the name the process was spawned with.
    name: []const u8,
    /// File descriptor table, indexed by fd. Slots 0-2 are the standard
    /// streams and stay null: the console is not a file yet.
    files: [MAX_FILES]?*vfs.OpenFile = @splat(null),
    /// Thread woken with the exit code (in `wake_value`) when the process exits.
    waiter: ?*thread.Thread = null,
    /// What this process may use.
    limits: Limits = .{},
    /// Pages of physical memory the process takes (see `Limits.max_pages`).
    pages: u64 = 0,
    /// The process that started this one, if a process did. It waits for
    /// this one to exit, so it outlives it.
    parent: ?*Process = null,
    /// Processes alive below this one (see `Limits.max_descendants`).
    descendants: u32 = 0,
};

/// How a process is started.
pub const SpawnOptions = struct {
    /// Thread to wake with the exit code when the process exits.
    waiter: ?*thread.Thread = null,
    /// The process starting this one, which must stay alive until it exits.
    parent: ?*Process = null,
    /// Limits for the new process; by default the parent's, or the default
    /// limits for a process the kernel starts.
    limits: ?Limits = null,
};

/// Count a new process against every ancestor from `parent` up. Fails,
/// changing nothing, if one of them already has as many descendants as it
/// may. Interrupts must be off.
fn chargeDescendant(parent: ?*Process) error{TooManyProcesses}!void {
    var a = parent;
    while (a) |anc| : (a = anc.parent) {
        if (anc.descendants >= anc.limits.max_descendants) return error.TooManyProcesses;
    }
    a = parent;
    while (a) |anc| : (a = anc.parent) anc.descendants += 1;
}

/// Undo `chargeDescendant`. Interrupts must be off.
fn releaseDescendant(parent: ?*Process) void {
    var a = parent;
    while (a) |anc| : (a = anc.parent) anc.descendants -= 1;
}

/// Terminate the current process with exit status `code` (0-255; the
/// `exit` syscall masks it, as on Linux).
///
/// Wakes the waiting parent (if any) with the exit code, then exits the
/// current thread. The process's memory is freed later, when the scheduler
/// reaps the thread. Must be called from a thread that belongs to a process.
pub fn exit(code: u64) noreturn {
    _ = cpu.saveAndDisableInterrupts(); // never restored: we're done
    const p = thread.current().process.?;
    releaseDescendant(p.parent); // before the parent can run again
    if (p.waiter) |w| {
        w.wake_value = code;
        thread.wake(w);
    }
    thread.exit();
}

/// Load the executable at `path` from the VFS and start it as a new process.
///
/// Returns immediately without waiting for the process. Returns
/// `error.FileNotFound` if the file doesn't exist, `error.ReadFailed` if it
/// can't be read completely, or any error from `spawn`.
pub fn spawnPath(path: []const u8, options: SpawnOptions) !*Process {
    const node = vfs.lookup(path) orelse return error.FileNotFound;
    const image = try heap.allocator.alloc(u8, node.size);
    defer heap.allocator.free(image); // elf.load copies it into the process's pages
    if (vfs.read(&node, 0, image) != node.size) return error.ReadFailed;
    return spawn(path, image, options);
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
/// thread that enters user mode at the entry point. Returns immediately
/// without waiting for the process.
///
/// Fails with `error.TooManyProcesses` if an ancestor has reached its
/// descendant limit, `error.TooLarge` if the program does not fit the memory
/// limit, `error.OutOfMemory`, or an error of the ELF loader. On error
/// nothing is leaked and nothing is counted.
pub fn spawn(name: []const u8, image: []const u8, options: SpawnOptions) !*Process {
    const limits = options.limits orelse if (options.parent) |parent| parent.limits else Limits{};

    const root = try vmm.createAddressSpace();
    errdefer vmm.destroyAddressSpace(root);

    const loaded = try elf.load(root, image, imageLimits(limits));

    for (1..STACK_PAGES + 1) |i| {
        const phys = pmm.alloc() orelse return error.OutOfMemory;
        @memset(pmm.physToVirt(phys)[0..pmm.PAGE_SIZE], 0);
        vmm.map(root, STACK_TOP - i * pmm.PAGE_SIZE, phys, vmm.USER | vmm.WRITABLE | vmm.NX, false) catch |e| {
            pmm.free(phys); // not mapped, so destroying the address space would not free it
            return e;
        };
    }

    // Everything the process takes, now that its page tables exist.
    const pages = loaded.pages + STACK_PAGES + vmm.userTablePages(root) + kstack.STACK_PAGES;
    if (pages > limits.max_pages) return error.TooLarge;

    const p = try heap.allocator.create(Process);
    errdefer heap.allocator.destroy(p);
    const name_copy = try heap.allocator.dupe(u8, name);
    errdefer heap.allocator.free(name_copy);
    p.* = .{
        .root = root,
        .entry = loaded.entry,
        .name = name_copy,
        .waiter = options.waiter,
        .limits = limits,
        .pages = pages,
        .parent = options.parent,
    };

    // From here to the end nothing may run in between: the new process
    // counts as alive exactly when it has a thread.
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    try chargeDescendant(options.parent);
    errdefer releaseDescendant(options.parent);
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
