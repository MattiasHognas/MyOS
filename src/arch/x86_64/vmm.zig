//! Virtual memory manager: 4-level x86-64 page tables.
//!
//! The kernel's own PML4 (`kernel_root`) maps the higher-half direct map
//! (HHDM) of all physical memory in 2 MiB pages, the kernel image with
//! per-section permissions, and an MMIO window for device registers. Every
//! user address space shares the kernel half (entries 256-511) of that PML4.
//!
//! Kernel memory is never writable and executable at once, under any
//! address: the image's code, constants and relocated tables are read-only
//! both where the kernel runs and where the direct map shows the same
//! physical pages (in 4 KiB pages there, so the rest of those 2 MiB stays
//! writable).
//!
//! Kernel mappings are global: the CPU keeps their TLB entries when CR3 is
//! loaded, since they are the same in every address space. `unmap` still
//! removes them, because `invlpg` flushes global entries too.
//!
//! Page tables have no lock of their own. A user address space is changed
//! under its process's lock (today: by its only thread, or before the
//! process runs, or after it has gone). The kernel half is changed under
//! the lock of the region the address is in: the heap, the kernel stacks
//! and the device window each have one, and each region has its own entry
//! in the PML4, whose tables `init` allocates. So two regions never share
//! a page table below the PML4, and the PML4's kernel half never changes
//! (`docs/locking.md`).
//!
//! Rules the rest of the kernel relies on:
//!
//! - `map` never replaces a mapping. Mapping over a page that is already
//!   mapped is `error.AlreadyMapped`, so no page can be lost by being
//!   overwritten; to change a mapping, `unmap` it first.
//! - `map` either succeeds or changes nothing. When memory runs out while
//!   it builds page tables, the tables it had already added are removed
//!   again and it returns `error.OutOfMemory`.
//! - `unmap` flushes the page from this CPU's TLB and gives page tables that
//!   became empty back to the PMM.
//! - Running out of memory is an error to the caller, never a panic, once
//!   boot is over.

const limine = @import("../../boot/limine.zig");
const cpu = @import("cpu.zig");
const assert = @import("../../kernel/debug/assert.zig");
const panicFmt = @import("../../kernel/debug/panic.zig").panicFmt;
const pmm = @import("../../kernel/pmm.zig");
const SpinLock = @import("../../kernel/sync/spinlock.zig").SpinLock;

/// Page table entry flag: the mapping is valid.
pub const PRESENT: u64 = 1 << 0;
/// Page table entry flag: writes are allowed.
pub const WRITABLE: u64 = 1 << 1;
/// Page table entry flag: accessible from ring 3.
pub const USER: u64 = 1 << 2;
/// Page table entry flag: this PD entry maps a 2 MiB page directly.
pub const HUGE: u64 = 1 << 7;
/// Page table entry flag: the mapping is the same in every address space,
/// so its TLB entry survives a CR3 load (requires CR4.PGE). `map` sets it
/// on every kernel address and on no user address.
pub const GLOBAL: u64 = 1 << 8;
/// Page table entry flag: instruction fetches are not allowed (requires EFER.NXE).
pub const NX: u64 = 1 << 63;
/// Page table entry flag: write-through caching.
pub const PWT: u64 = 1 << 3;
/// Page table entry flag: caching disabled.
pub const PCD: u64 = 1 << 4;

// Separate from the HHDM, so these 4 KiB mappings never collide with its 2 MiB pages.
var mmio_next: usize = 0xFFFF_A000_0000_0000;
/// Protects the device window: `mmio_next` and the page tables under it.
var mmio_lock: SpinLock = .{ .rank = .kernel_region };

/// Physical address of the kernel's PML4. Set by `init`.
pub var kernel_root: u64 = 0;

// The PML4 in CR3, as `loadRoot` last set it. One CPU today; per CPU with SMP (3.2).
var loaded_root: u64 = 0;
// CR3 loads since boot. A statistic, read by tests.
var root_loads: usize = 0;

const CR4_PGE: u64 = 1 << 7;

const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;
const MIB2: u64 = 2 * 1024 * 1024;

extern const __text_start: u8;
extern const __text_end: u8;
extern const __rodata_start: u8;
extern const __rodata_end: u8;
extern const __relro_start: u8;
extern const __relro_end: u8;
extern const __data_start: u8;
extern const __data_end: u8;

/// First address above the user half of the address space.
pub const USER_END: u64 = 0x0000_8000_0000_0000;
/// First address of the kernel half.
pub const KERNEL_BASE: u64 = 0xFFFF_8000_0000_0000;
/// End of the part of user space that may be mapped. The last page stays
/// unmapped for good: a `syscall` instruction at its very end would return
/// to `USER_END`, which is not a canonical address, and `sysretq` to such an
/// address faults in ring 0 on Intel CPUs, on the user's stack pointer.
pub const USER_MAP_END: u64 = USER_END - 4096;

/// Return the 512-entry page table at physical address `phys`, via the HHDM.
fn table(phys: u64) *[512]u64 {
    return @ptrCast(@alignCast(pmm.physToVirt(phys)));
}

/// Ways `map` can fail. Nothing has changed when it does.
pub const MapError = error{
    /// No physical page for a page table.
    OutOfMemory,
    /// The address is already mapped (by a page of either size).
    AlreadyMapped,
};

/// Allocate and zero a page for a new page table. Returns its physical address.
fn allocTable() error{OutOfMemory}!u64 {
    return pmm.allocZeroed() orelse error.OutOfMemory;
}

/// Index into the table of `level` (3 = PML4 ... 0 = PT) for `virt`.
fn index(virt: u64, level: u6) usize {
    return @intCast((virt >> (12 + 9 * level)) & 0x1FF);
}

/// True if no entry of `t` is present.
fn isEmpty(t: *const [512]u64) bool {
    for (t) |e| {
        if (e & PRESENT != 0) return false;
    }
    return true;
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
        map(kernel_root, v, v - k.virtual_base + k.physical_base, flags, false) catch |e|
            panicFmt("vmm: cannot map the kernel image at 0x{x}: {s}", .{ v, @errorName(e) });
    }
}

/// Map one page at `virt` to `phys` in the address space whose PML4 is `root`.
///
/// Maps a 4 KiB page, or a 2 MiB page if `huge` (both addresses must then be
/// 2 MiB aligned). Missing intermediate tables are allocated; their entries
/// are permissive (writable, user), and the final entry decides the actual
/// access rights. `PRESENT` is always added to `flags`, and `GLOBAL` for a
/// kernel address.
///
/// Fails with `error.AlreadyMapped` if `virt` is mapped already, and with
/// `error.OutOfMemory` if a page table cannot be allocated. Either way the
/// address space is exactly as it was: tables added on the way are freed.
/// No TLB flush is needed, since the address was not mapped before.
pub fn map(root: u64, virt: u64, phys: u64, flags: u64, huge: bool) MapError!void {
    const align_mask: u64 = if (huge) MIB2 - 1 else pmm.PAGE_SIZE - 1;
    assert.check(.vmm, virt & align_mask == 0 and phys & align_mask == 0, "misaligned mapping 0x{x} -> 0x{x}", .{ virt, phys });
    const last: u6 = if (huge) 1 else 0;

    // Entries this call filled in with new tables, outermost first.
    var created: [3]*u64 = undefined;
    var created_len: usize = 0;
    errdefer while (created_len > 0) {
        created_len -= 1;
        const entry = created[created_len];
        pmm.free(entry.* & ADDR_MASK);
        entry.* = 0;
    };

    var t = table(root);
    var level: u6 = 3; // 3 = PML4, 2 = PDPT, 1 = PD, 0 = PT
    while (level > last) : (level -= 1) {
        const entry = &t[index(virt, level)];
        if (entry.* & PRESENT == 0) {
            entry.* = (try allocTable()) | PRESENT | WRITABLE | USER;
            created[created_len] = entry;
            created_len += 1;
        } else if (entry.* & HUGE != 0) return error.AlreadyMapped; // inside a 2 MiB page
        t = table(entry.* & ADDR_MASK);
    }
    const leaf = &t[index(virt, last)];
    // For a 2 MiB page this also catches a page table of 4 KiB pages in its place.
    if (leaf.* & PRESENT != 0) return error.AlreadyMapped;
    const global: u64 = if (virt >= KERNEL_BASE) GLOBAL else 0;
    leaf.* = (phys & ADDR_MASK) | (flags & ~GLOBAL) | global | PRESENT | (if (huge) HUGE else 0);
}

/// Remove the 4 KiB mapping of `virt` from the address space whose PML4 is
/// `root` and flush it from this CPU's TLB. Returns the physical address the
/// page was mapped to (the caller decides whether to free it), or null if
/// `virt` was not mapped by a 4 KiB page.
///
/// Page tables left without any entry are freed, up to but not including
/// the tables the kernel half of every address space shares (the ones the
/// PML4 points at for kernel addresses). `invlpg` also drops the CPU's
/// cached pointers to those tables.
///
/// With several CPUs the other ones need a TLB shootdown too.
pub fn unmap(root: u64, virt: u64) ?u64 {
    // tables[level] is the table of that level on the way to `virt`.
    var tables: [4]*[512]u64 = undefined;
    tables[3] = table(root);
    var level: u6 = 3;
    while (level > 0) : (level -= 1) {
        const e = tables[level][index(virt, level)];
        if (e & PRESENT == 0 or e & HUGE != 0) return null;
        tables[level - 1] = table(e & ADDR_MASK);
    }
    const leaf = &tables[0][index(virt, 0)];
    const e = leaf.*;
    if (e & PRESENT == 0) return null;
    leaf.* = 0;

    // Free tables that are empty now: the PT, then the PD, then (for user
    // addresses only) the PDPT.
    const top: u6 = if (virt < USER_END) 3 else 2;
    level = 0;
    while (level < top and isEmpty(tables[level])) : (level += 1) {
        const parent = &tables[level + 1][index(virt, level + 1)];
        pmm.free(parent.* & ADDR_MASK);
        parent.* = 0;
    }

    asm volatile ("invlpg (%[v])"
        :
        : [v] "r" (virt),
        : .{ .memory = true });
    return e & ADDR_MASK;
}

/// Return the leaf page-table entry (PT entry, or PD entry of a 2 MiB page)
/// that maps `virt` in the address space whose PML4 is `root`, or null if
/// `virt` is not mapped. Only reads the page tables, so it is safe to call
/// from fault handlers.
pub fn leafEntry(root: u64, virt: u64) ?u64 {
    var t = table(root);
    var level: u6 = 3;
    while (true) : (level -= 1) {
        const e = t[@intCast((virt >> (12 + 9 * level)) & 0x1FF)];
        if (e & PRESENT == 0) return null;
        if (level == 0 or (level == 1 and e & HUGE != 0)) return e;
        t = table(e & ADDR_MASK);
    }
}

/// Translate `virt` in the address space whose PML4 is `root` to a physical
/// address. Returns null if it is not mapped. Handles 2 MiB pages.
pub fn translate(root: u64, virt: u64) ?u64 {
    const e = leafEntry(root, virt) orelse return null;
    const mask: u64 = if (e & HUGE != 0) MIB2 - 1 else pmm.PAGE_SIZE - 1;
    return ((e & ADDR_MASK) & ~mask) | (virt & mask);
}

/// Create a new address space and return the physical address of its PML4.
///
/// The user half starts empty; the kernel half points at the same tables as
/// `kernel_root`, so kernel mappings are shared with every address space.
/// Fails with `error.OutOfMemory` if there is no page for the PML4.
pub fn createAddressSpace() error{OutOfMemory}!u64 {
    const root = try allocTable();
    @memcpy(table(root)[256..512], table(kernel_root)[256..512]);
    return root;
}

/// Switch to the address space whose PML4 is at physical address `root` by
/// loading CR3. This flushes the TLB entries of user addresses; the kernel's
/// are global and stay. Interrupts must be off, or the caller must otherwise
/// know that no thread switch can happen in between.
pub fn loadRoot(root: u64) void {
    asm volatile ("mov %[r], %%cr3"
        :
        : [r] "r" (root),
        : .{ .memory = true });
    loaded_root = root;
    root_loads += 1;
}

/// The PML4 that is loaded now.
pub fn loadedRoot() u64 {
    return loaded_root;
}

/// CR3 loads since boot. Tests use it to see which switches reload it.
pub fn rootLoads() usize {
    return root_loads;
}

/// Make sure the address space `root` is not the loaded one, by switching
/// to the kernel's own page tables if it is. Must be called before `root`
/// is destroyed: a kernel thread may still be running on the address space
/// of the last process that ran (`thread.zig`). Interrupts must be off.
pub fn unloadRoot(root: u64) void {
    if (loaded_root == root) loadRoot(kernel_root);
}

/// Count the page tables under the table at `phys`, itself included.
/// `level` is as for `freeTable`.
fn countTables(phys: u64, level: u6) usize {
    var n: usize = 1;
    if (level == 0) return n;
    for (table(phys)) |e| {
        if (e & PRESENT != 0) n += countTables(e & ADDR_MASK, level - 1);
    }
    return n;
}

/// Number of pages the address space `root` uses for its own page tables:
/// the PML4 and every table of the user half. The kernel half's tables are
/// shared and not counted.
pub fn userTablePages(root: u64) usize {
    var n: usize = 1; // the PML4
    for (table(root)[0..256]) |e| {
        if (e & PRESENT != 0) n += countTables(e & ADDR_MASK, 2);
    }
    return n;
}

/// Free every page and page table in the user half of `root`, then the PML4
/// itself. The shared kernel half is left alone. `root` must not be the
/// currently loaded address space (`unloadRoot`).
pub fn destroyAddressSpace(root: u64) void {
    assert.check(.vmm, root != loaded_root, "destroying the loaded address space 0x{x}", .{root});
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
/// For drivers during boot: panics if a page table cannot be allocated.
pub fn mapMmio(phys: u64, size: usize) usize {
    const base = phys & ~@as(u64, 0xFFF);
    const end = (phys + size + 0xFFF) & ~@as(u64, 0xFFF);
    const held = mmio_lock.acquire();
    defer mmio_lock.release(held);
    const virt = mmio_next;
    var p = base;
    while (p < end) : (p += pmm.PAGE_SIZE) {
        map(kernel_root, virt + (p - base), p, WRITABLE | NX | PCD | PWT, false) catch |e|
            panicFmt("vmm: cannot map device memory at 0x{x}: {s}", .{ p, @errorName(e) });
    }
    mmio_next += end - base;
    return virt + (phys - base);
}

/// Map the 2 MiB of physical memory starting at `phys` into the direct map
/// at offset `hhdm`: as one 2 MiB page, or, where it holds part of the
/// kernel image's read-only pages (`[ro_start, ro_end)`, physical), in
/// 4 KiB pages, so that exactly those pages are read-only here too. Memory
/// that is already mapped (two regions of the memory map can share a 2 MiB
/// page) is left as it is.
fn mapDirect(phys: u64, hhdm: u64, ro_start: u64, ro_end: u64) void {
    if (phys >= ro_end or phys + MIB2 <= ro_start) {
        return map(kernel_root, hhdm + phys, phys, WRITABLE | NX, true) catch |err| switch (err) {
            error.AlreadyMapped => {},
            error.OutOfMemory => @panic("vmm: no memory for the kernel page tables"),
        };
    }
    var p = phys;
    while (p < phys + MIB2) : (p += pmm.PAGE_SIZE) {
        const flags: u64 = if (p >= ro_start and p < ro_end) NX else WRITABLE | NX;
        map(kernel_root, hhdm + p, p, flags, false) catch |err| switch (err) {
            error.AlreadyMapped => {},
            error.OutOfMemory => @panic("vmm: no memory for the kernel page tables"),
        };
    }
}

/// Build the kernel's page tables and switch to them.
///
/// Enables the NX bit and global pages, preallocates all kernel-half PDPTs
/// (so later address spaces can share them), maps every memory map region
/// into the HHDM at offset `hhdm` with 2 MiB pages (4 KiB ones around the
/// kernel image, see `mapDirect`), maps the kernel's text, read-only data,
/// relocated constants and data with their own permissions, and finally
/// loads the new PML4.
/// Requires `pmm.init` to have run. Panics if memory runs out: there is
/// nothing to fall back to this early.
pub fn init(mm: *const limine.MemmapResponse, k: *const limine.KernelAddressResponse, hhdm: u64) void {
    cpu.wrmsr(0xC0000080, cpu.rdmsr(0xC0000080) | (1 << 11)); // EFER.NXE: allow the NX bit

    kernel_root = allocTable() catch @panic("vmm: no memory for the kernel page tables");

    const kh = table(kernel_root);
    for (256..512) |i| kh[i] = (allocTable() catch @panic("vmm: no memory for the kernel page tables")) | PRESENT | WRITABLE;

    // 1. HHDM: every memory map region, in 2 MiB pages. The image's
    //    read-only part (everything below its data) is read-only here too.
    const ro_start = @intFromPtr(&__text_start) - k.virtual_base + k.physical_base;
    const ro_end = @intFromPtr(&__relro_end) - k.virtual_base + k.physical_base;
    for (mm.entries[0..mm.entry_count]) |e| {
        var p = e.base & ~(MIB2 - 1);
        const end = (e.base + e.length + MIB2 - 1) & ~(MIB2 - 1);
        while (p < end) : (p += MIB2) mapDirect(p, hhdm, ro_start, ro_end);
    }

    // 2. Kernel sections, each with its own permissions.
    mapKernelRange(&__text_start, &__text_end, 0, k);
    mapKernelRange(&__rodata_start, &__rodata_end, NX, k);
    mapKernelRange(&__relro_start, &__relro_end, NX, k); // the bootloader has relocated them
    mapKernelRange(&__data_start, &__data_end, WRITABLE | NX, k);

    // 3. Switch. Global pages go off for the load, so that nothing the
    //    bootloader's page tables left in the TLB survives it (changing
    //    CR4.PGE flushes everything), and on again afterwards.
    cpu.writeCr4(cpu.readCr4() & ~CR4_PGE);
    loadRoot(kernel_root);
    cpu.writeCr4(cpu.readCr4() | CR4_PGE);
}
