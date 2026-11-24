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
//! | `exit` | open files; its place in the process tree; its exit status becomes available and waiters wake |
//! | its thread is reaped | the address space, the kernel stack, the thread |
//! | the last reference is released | the `Process` structure and its name |
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
//! ## One thread per process
//!
//! Everything here assumes it: a process "runs" when its thread does and
//! exits when its thread does; `exit` ends the process; the descriptor
//! table and the address space are used without locks because only that
//! thread touches them; and blocking syscalls block the whole process.
//! Milestone 7 (threads) has to revisit each of these.
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

const context = @import("../arch/x86_64/context.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const vmm = @import("../arch/x86_64/vmm.zig");
const assert = @import("debug/assert.zig");
const elf = @import("elf.zig");
const elf_image = @import("elf_image.zig");
const heap = @import("heap.zig");
const kstack = @import("kstack.zig");
const pmm = @import("pmm.zig");
const SpinLock = @import("sync/spinlock.zig").SpinLock;
const WaitQueue = @import("sync/wait_queue.zig").WaitQueue;
const thread = @import("thread.zig");
const vfs = @import("vfs.zig");
const random = @import("random.zig");

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
    /// Stack pointer the program starts with.
    entry_rsp: u64 = STACK_TOP_MAX - 8,
    /// Heap-allocated copy of the name the process was spawned with.
    name: []const u8,
    /// File descriptor table, indexed by fd. Slots 0-2 are the standard
    /// streams and stay null: the console is not a file yet.
    files: [MAX_FILES]?*vfs.OpenFile = @splat(null),
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
/// `exit` syscall masks it, as on Linux).
///
/// Closes its files, hands its children to its parent, leaves the process
/// tree, records the exit status, wakes every thread waiting for it and
/// exits the current thread. The address space is freed when the scheduler
/// reaps the thread. Must be called from a thread that belongs to a process.
pub fn exit(code: u64) noreturn {
    _ = cpu.saveAndDisableInterrupts(); // never restored: we're done
    const p = thread.current().process.?;
    closeFiles(p); // only this thread uses them
    tree_lock.take();
    assert.check(.process, p.exit_code == null, "process '{s}' exits twice", .{p.name});
    reparentChildren(p);
    unlinkChild(p);
    releaseDescendant(p.parent);
    p.parent = null;
    p.exit_code = code;
    _ = p.exited.wakeAll(); // before the lock is released: the waiters are still there
    tree_lock.drop();
    thread.exit();
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

/// Number of `Process` structures that exist: processes that run, and
/// exited ones somebody still holds a reference to.
pub fn liveCount() usize {
    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    return live;
}

// Guarded by the tree lock.
var live: usize = 0;

/// Close every open file of `p`.
fn closeFiles(p: *Process) void {
    for (&p.files) |*slot| {
        if (slot.*) |of| heap.allocator.destroy(of);
        slot.* = null;
    }
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

/// Called by the scheduler when the thread of `p` has been reaped: nothing
/// runs in `p` any more. Its address space may still be loaded, if only
/// kernel threads ran since, so it is switched away from first. Frees the
/// address space and gives up the thread's reference. Interrupts are off
/// and no lock is held.
///
/// With several CPUs the address space may also be loaded on another one
/// that only ran kernel threads since; that CPU has to be asked to switch
/// away first (3.4).
pub fn teardown(p: *Process) void {
    assert.check(.process, p.exit_code != null, "tearing down process '{s}', which has not exited", .{p.name});
    assert.check(.process, p.root != 0, "process '{s}' torn down twice", .{p.name});
    vmm.unloadRoot(p.root);
    vmm.destroyAddressSpace(p.root);
    p.root = 0;
    release(p);
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

    const loaded = try elf.load(root, image, imageLimits(limits));

    // Where the stack goes, and where in its top page the program starts:
    // 8 below a 16-byte boundary, as if the entry point had been called.
    const stack_top = if (options.randomize) STACK_TOP_MAX - random.below(STACK_RANDOM_PAGES) * pmm.PAGE_SIZE else STACK_TOP_MAX;
    const entry_rsp = stack_top - 8 - (if (options.randomize) random.below(STACK_RANDOM_OFFSET / 16) * 16 else 0);

    for (1..STACK_PAGES + 1) |i| {
        const phys = pmm.allocZeroed() orelse return error.OutOfMemory;
        vmm.map(root, stack_top - i * pmm.PAGE_SIZE, phys, vmm.USER | vmm.WRITABLE | vmm.NX, false) catch |e| {
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
        .stack_top = stack_top,
        .entry_rsp = entry_rsp,
        .name = name_copy,
        .limits = limits,
        .pages = pages,
        .parent = options.parent,
        .refs = 2, // the thread's and the caller's
    };

    // Everything that can fail for lack of memory happens before the
    // tree lock, which is held for the few lines that put the process in
    // the tree: it is in the tree exactly when its thread is started.
    const t = try thread.create(userStart, p);
    errdefer thread.destroy(t);

    const held = tree_lock.acquire();
    defer tree_lock.release(held);
    if (options.parent) |parent| {
        assert.check(.process, parent.exit_code == null, "process '{s}' starts a child after exiting", .{parent.name});
    }
    try chargeDescendant(options.parent);
    linkChild(p);
    live += 1;
    thread.start(t);
    return p;
}

/// Thread entry point for a new process: jump to the process's entry point in
/// ring 3 on its user stack. The scheduler has already loaded the process's
/// address space. Never returns.
fn userStart() void {
    const p = thread.current().process.?;
    context.enterUser(p.entry, p.entry_rsp);
}
