//! Virtual memory manager: 4-level x86-64 page tables.
//!
//! The kernel's own PML4 (`kernel_root`) maps the higher-half direct map
//! (HHDM) of all physical memory in 2 MiB pages, the kernel image with
//! per-section permissions, and an MMIO window for device registers. Every
//! user address space shares the kernel half (entries 256-511) of that PML4.

const limine = @import("../../boot/limine.zig");
const pmm = @import("../../kernel/pmm.zig");

/// Page table entry flag: the mapping is valid.
pub const PRESENT: u64 = 1 << 0;
/// Page table entry flag: writes are allowed.
pub const WRITABLE: u64 = 1 << 1;
/// Page table entry flag: accessible from ring 3.
pub const USER: u64 = 1 << 2;
/// Page table entry flag: this PD entry maps a 2 MiB page directly.
pub const HUGE: u64 = 1 << 7;
/// Page table entry flag: instruction fetches are not allowed (requires EFER.NXE).
pub const NX: u64 = 1 << 63;
/// Page table entry flag: write-through caching.
pub const PWT: u64 = 1 << 3;
/// Page table entry flag: caching disabled.
pub const PCD: u64 = 1 << 4;

// Separate from the HHDM, so these 4 KiB mappings never collide with its 2 MiB pages.
var mmio_next: usize = 0xFFFF_A000_0000_0000;

/// Physical address of the kernel's PML4. Set by `init`.
pub var kernel_root: u64 = 0;

const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;
const MIB2: u64 = 2 * 1024 * 1024;

extern const __text_start: u8;
extern const __text_end: u8;
extern const __rodata_start: u8;
extern const __rodata_end: u8;
extern const __data_start: u8;
extern const __data_end: u8;

/// First address above the user half of the address space.
pub const USER_END: u64 = 0x0000_8000_0000_0000;

/// Return the 512-entry page table at physical address `phys`, via the HHDM.
fn table(phys: u64) *[512]u64 {
    return @ptrCast(@alignCast(pmm.physToVirt(phys)));
}

/// Allocate and zero a page for a new page table. Returns its physical address.
/// Panics if physical memory is exhausted.
fn allocTable() u64 {
    const p = pmm.alloc() orelse @panic("vmm: out of memory");
    @memset(pmm.physToVirt(p)[0..pmm.PAGE_SIZE], 0);
    return p;
}

/// Follow `entry` to the next-level table, creating it if it is missing.
/// Returns the physical address of that table.
///
/// Intermediate entries are permissive (writable, user); the final entry
/// decides the actual access rights.
fn next(entry: *u64) u64 {
    if (entry.* & PRESENT == 0) entry.* = allocTable() | PRESENT | WRITABLE | USER;
    return entry.* & ADDR_MASK;
}

/// Recursively free the page table at `phys`, every table below it and every
/// page mapped by its leaf entries. `level` is 2 for a PDPT, 1 for a PD and 0
/// for a PT. Does not handle huge pages, so it is only used on user mappings.
fn freeTable(phys: u64, level: u6) void {
    for (table(phys)) |e| {
        if (e & PRESENT == 0) continue;
        if (level == 0) pmm.free(e & ADDR_MASK) else freeTable(e & ADDR_MASK, level - 1);
    }
    pmm.free(phys);
}

/// Map the kernel image section `[start, end)` into `kernel_root` with 4 KiB
/// pages and the given `flags`, translating addresses using the load location
/// reported by the bootloader in `k`.
fn mapKernelRange(start: *const u8, end: *const u8, flags: u64, k: *const limine.KernelAddressResponse) void {
    var v = @intFromPtr(start);
    while (v < @intFromPtr(end)) : (v += pmm.PAGE_SIZE) {
        map(kernel_root, v, v - k.virtual_base + k.physical_base, flags, false);
    }
}

/// Read the model-specific register `msr`.
fn rdmsr(msr: u32) u64 {
    return asm volatile (
        \\ rdmsr
        \\ shlq $32, %%rdx
        \\ orq %%rdx, %%rax
        : [ret] "={rax}" (-> u64),
        : [msr] "{ecx}" (msr),
        : .{ .rdx = true });
}

/// Write `val` to the model-specific register `msr`.
fn wrmsr(msr: u32, val: u64) void {
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (@as(u32, @truncate(val))),
          [hi] "{edx}" (@as(u32, @truncate(val >> 32))),
          [msr] "{ecx}" (msr),
    );
}

/// Map one page at `virt` to `phys` in the address space whose PML4 is `root`.
///
/// Maps a 4 KiB page, or a 2 MiB page if `huge` (both addresses must then be
/// 2 MiB aligned). Missing intermediate tables are allocated. `PRESENT` is
/// always added to `flags`. Any existing mapping is overwritten; the TLB is
/// not flushed.
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

/// Create a new address space and return the physical address of its PML4.
///
/// The user half starts empty; the kernel half points at the same tables as
/// `kernel_root`, so kernel mappings are shared with every address space.
pub fn createAddressSpace() u64 {
    const root = allocTable();
    @memcpy(table(root)[256..512], table(kernel_root)[256..512]);
    return root;
}

/// Switch to the address space whose PML4 is at physical address `root` by
/// loading CR3. This also flushes all non-global TLB entries.
pub fn loadRoot(root: u64) void {
    asm volatile ("mov %[r], %%cr3"
        :
        : [r] "r" (root),
        : .{ .memory = true });
}

/// Free every page and page table in the user half of `root`, then the PML4
/// itself. The shared kernel half is left alone. `root` must not be the
/// currently loaded address space.
pub fn destroyAddressSpace(root: u64) void {
    for (table(root)[0..256]) |e| {
        if (e & PRESENT != 0) freeTable(e & ADDR_MASK, 2);
    }
    pmm.free(root);
}

/// Map `size` bytes of device registers at physical address `phys` into the
/// kernel's MMIO window, uncached and non-executable.
///
/// Returns the virtual address corresponding to `phys` (which need not be page
/// aligned). Each call takes fresh virtual space; mappings are never removed.
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

/// Build the kernel's page tables and switch to them.
///
/// Enables the NX bit, preallocates all kernel-half PDPTs (so later address
/// spaces can share them), maps every memory map region into the HHDM at
/// offset `hhdm` with 2 MiB pages, maps the kernel's text, rodata and data
/// sections with their own permissions, and finally loads the new PML4.
/// Requires `pmm.init` to have run.
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
