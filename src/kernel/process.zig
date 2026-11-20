const heap = @import("heap.zig");
const pmm = @import("pmm.zig");
const thread = @import("thread.zig");
const elf = @import("elf.zig");
const vmm = @import("../arch/x86_64/vmm.zig");
const context = @import("../arch/x86_64/context.zig");

pub const Process = struct {
    root: u64, // physical address of this process's PML4
    entry: u64,
    name: []const u8,
};

const STACK_TOP: u64 = 0x0000_7FFF_FFFF_0000;
const STACK_PAGES = 4; // 16 KiB

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
    p.* = .{ .root = root, .entry = entry, .name = name };

    _ = try thread.spawn(userStart, p);
    return p;
}

// First code of every user thread (in the kernel, already in the process's address space).
fn userStart() void {
    const p = thread.current().process.?;
    context.enterUser(p.entry, STACK_TOP - 8); // -8: as if _start had been called
}
