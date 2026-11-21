const limine = @import("../../boot/limine.zig");
const pmm = @import("../../kernel/pmm.zig");

pub const PRESENT: u64 = 1 << 0;
pub const WRITABLE: u64 = 1 << 1;
pub const USER: u64 = 1 << 2;
pub const HUGE: u64 = 1 << 7;
pub const NX: u64 = 1 << 63;
pub const PWT: u64 = 1 << 3;
pub const PCD: u64 = 1 << 4;

const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;
const MIB2: u64 = 2 * 1024 * 1024;

pub var kernel_root: u64 = 0; // physical address of our PML4

// Separate from the HHDM, so these 4 KiB mappings never collide with its 2 MiB pages.
var mmio_next: usize = 0xFFFF_A000_0000_0000;

extern const __text_start: u8;
extern const __text_end: u8;
extern const __rodata_start: u8;
extern const __rodata_end: u8;
extern const __data_start: u8;
extern const __data_end: u8;

pub const USER_END: u64 = 0x0000_8000_0000_0000;

fn table(phys: u64) *[512]u64 {
    return @ptrCast(@alignCast(pmm.physToVirt(phys)));
}

fn allocTable() u64 {
    const p = pmm.alloc() orelse @panic("vmm: out of memory");
    @memset(pmm.physToVirt(p)[0..pmm.PAGE_SIZE], 0);
    return p;
}

// Follow an entry to the next-level table, creating it if missing.
// Intermediate entries are permissive; the final entry decides access.
fn next(entry: *u64) u64 {
    if (entry.* & PRESENT == 0) entry.* = allocTable() | PRESENT | WRITABLE | USER;
    return entry.* & ADDR_MASK;
}

fn freeTable(phys: u64, level: u6) void { // 2 = PDPT, 1 = PD, 0 = PT
    for (table(phys)) |e| {
        if (e & PRESENT == 0) continue;
        if (level == 0) pmm.free(e & ADDR_MASK) else freeTable(e & ADDR_MASK, level - 1);
    }
    pmm.free(phys);
}

// Map one page: 4 KiB, or 2 MiB if `huge`.
pub fn map(root: u64, virt: u64, phys: u64, flags: u64, huge: bool) void {
    const last: u6 = if (huge) 1 else 0;
    var t = table(root);
    var level: u6 = 3; // 3 = PML4, 2 = PDPT, 1 = PD, 0 = PT
    while (level > last) : (level -= 1) {
        const idx: usize = @intCast((virt >> (12 + 9 * level)) & 0x1FF);
        t = table(next(&t[idx]));
    }
    const idx: usize = @intCast((virt >> (12 + 9 * last)) & 0x1FF);
    t[idx] = (phys & ADDR_MASK) | flags | PRESENT | (if (huge) HUGE else 0);
}

fn mapKernelRange(start: *const u8, end: *const u8, flags: u64, k: *const limine.KernelAddressResponse) void {
    var v = @intFromPtr(start);
    while (v < @intFromPtr(end)) : (v += pmm.PAGE_SIZE) {
        map(kernel_root, v, v - k.virtual_base + k.physical_base, flags, false);
    }
}

fn rdmsr(msr: u32) u64 {
    return asm volatile (
        \\ rdmsr
        \\ shlq $32, %%rdx
        \\ orq %%rdx, %%rax
        : [ret] "={rax}" (-> u64),
        : [msr] "{ecx}" (msr),
        : .{ .rdx = true });
}

fn wrmsr(msr: u32, val: u64) void {
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (@as(u32, @truncate(val))),
          [hi] "{edx}" (@as(u32, @truncate(val >> 32))),
          [msr] "{ecx}" (msr),
    );
}

// New PML4: empty user half, kernel half shared with every other address space.
pub fn createAddressSpace() u64 {
    const root = allocTable();
    @memcpy(table(root)[256..512], table(kernel_root)[256..512]);
    return root;
}

pub fn loadRoot(root: u64) void {
    asm volatile ("mov %[r], %%cr3"
        :
        : [r] "r" (root),
        : .{ .memory = true });
}

// Free every page and page table in the user half, then the PML4 itself.
// Must not be the currently loaded address space.
pub fn destroyAddressSpace(root: u64) void {
    for (table(root)[0..256]) |e| {
        if (e & PRESENT != 0) freeTable(e & ADDR_MASK, 2);
    }
    pmm.free(root);
}

// Map a device's registers uncached; returns the virtual address of `phys`.
pub fn mapMmio(phys: u64, size: usize) usize {
    const base = phys & ~@as(u64, 0xFFF);
    const end = (phys + size + 0xFFF) & ~@as(u64, 0xFFF);
    const virt = mmio_next;
    var p = base;
    while (p < end) : (p += pmm.PAGE_SIZE) {
        map(kernel_root, virt + (p - base), p, WRITABLE | NX | PCD | PWT, false);
    }
    mmio_next += end - base;
    return virt + (phys - base);
}

pub fn init(mm: *const limine.MemmapResponse, k: *const limine.KernelAddressResponse, hhdm: u64) void {
    wrmsr(0xC0000080, rdmsr(0xC0000080) | (1 << 11)); // EFER.NXE: allow the NX bit

    kernel_root = allocTable();

    const kh = table(kernel_root);
    for (256..512) |i| kh[i] = allocTable() | PRESENT | WRITABLE;

    // 1. HHDM: every memory map region, in 2 MiB pages.
    for (mm.entries[0..mm.entry_count]) |e| {
        var p = e.base & ~(MIB2 - 1);
        const end = (e.base + e.length + MIB2 - 1) & ~(MIB2 - 1);
        while (p < end) : (p += MIB2) map(kernel_root, hhdm + p, p, WRITABLE | NX, true);
    }

    // 2. Kernel sections, each with its own permissions.
    mapKernelRange(&__text_start, &__text_end, 0, k);
    mapKernelRange(&__rodata_start, &__rodata_end, NX, k);
    mapKernelRange(&__data_start, &__data_end, WRITABLE | NX, k);

    // 3. Switch. Takes effect on the next instruction.
    asm volatile ("mov %[r], %%cr3"
        :
        : [r] "r" (kernel_root),
        : .{ .memory = true });
}
