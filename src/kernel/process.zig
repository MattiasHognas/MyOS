const heap = @import("heap.zig");
const pmm = @import("pmm.zig");
const thread = @import("thread.zig");
const elf = @import("elf.zig");
const vmm = @import("../arch/x86_64/vmm.zig");
const context = @import("../arch/x86_64/context.zig");
const vfs = @import("vfs.zig");

pub const Process = struct {
    root: u64,
    entry: u64,
    name: []const u8, // owned copy, freed in destroy
    files: [16]?*vfs.OpenFile = @splat(null), // fd table
};

const STACK_TOP: u64 = 0x0000_7FFF_FFFF_0000;
const STACK_PAGES = 4; // 16 KiB

pub fn spawnPath(path: []const u8) !*Process {
    const node = vfs.lookup(path) orelse return error.FileNotFound;
    const image = try heap.allocator.alloc(u8, node.size);
    defer heap.allocator.free(image); // elf.load copies it into the process's pages
    if (vfs.read(&node, 0, image) != node.size) return error.ReadFailed;
    return spawn(path, image);
}

pub fn destroy(p: *Process) void {
    for (p.files) |f| if (f) |of| heap.allocator.destroy(of);
    vmm.destroyAddressSpace(p.root);
    heap.allocator.free(p.name);
    heap.allocator.destroy(p);
}

pub fn spawn(name: []const u8, image: []const u8) !*Process {
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
    p.* = .{ .root = root, .entry = entry, .name = name_copy };

    _ = try thread.spawn(userStart, p);
    return p;
}

fn userStart() void {
    const p = thread.current().process.?;
    context.enterUser(p.entry, STACK_TOP - 8); // -8: as if _start had been called
}
