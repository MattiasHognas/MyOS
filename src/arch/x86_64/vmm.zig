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
//! - `unmap` flushes the page from the TLB of every CPU that may have it,
//!   and gives page tables that became empty back to the PMM afterwards.
//! - Running out of memory is an error to the caller, never a panic, once
//!   boot is over.

const std = @import("std");

const limine = @import("../../boot/limine.zig");
const cpu = @import("cpu.zig");
const assert = @import("../../kernel/debug/assert.zig");
const panicFmt = @import("../../kernel/debug/panic.zig").panicFmt;
const pmm = @import("../../kernel/pmm.zig");
const percpu = @import("percpu.zig");
const ipi = @import("ipi.zig");
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
/// A user page that is not the address space's own but shared by all of
/// them (the vDSO's, `kernel/vdso.zig`): never freed with a mapping, never
/// copied by `fork`, never made writable. A bit the CPU leaves to software.
pub const SHARED: u64 = 1 << 9;
/// A user page of a writable region shared copy-on-write with other
/// address spaces (`fork`): mapped read-only; the first write to it
/// faults, and gets a copy of its own (`user_memory.handleFault`), or the
/// page itself if nobody else has it any more. A shared page of a region
/// that cannot be written is only read-only, and gets this bit if the
/// region is made writable (`protect`). Another bit for software.
pub const COW: u64 = 1 << 10;
/// A page of a shared mapping of a memory object (`memfd.zig`): the same
/// page in every mapping of it, each entry one of its owners. `fork` maps
/// it into the child as it is, writable or not, never copy-on-write.
/// Another bit for software.
pub const SHARED_MAP: u64 = 1 << 11;
/// Page table entry flag: instruction fetches are not allowed (requires EFER.NXE).
pub const NX: u64 = 1 << 63;
/// Page table entry flag: write-through caching.
pub const PWT: u64 = 1 << 3;
/// Page table entry flag: caching disabled.
pub const PCD: u64 = 1 << 4;

// Separate from the HHDM, so these 4 KiB mappings never collide with its 2 MiB pages.
var mmio_next: usize = 0xFFFF_A000_0000_0000;
/// Page tables added to the kernel half since `init`, minus those freed
/// again: what the heap, the kernel stacks and the device window have had
/// to add to map their memory. For accounting (tests compare memory use
/// before and after; the heap never gives its tables back).
var kernel_table_pages: std.atomic.Value(usize) = .init(0);

/// See `kernel_table_pages`.
pub fn kernelTablePages() usize {
    return kernel_table_pages.load(.monotonic);
}

/// Protects the device window: `mmio_next` and the page tables under it.
var mmio_lock: SpinLock = .{ .rank = .kernel_region };

/// Physical address of the kernel's PML4. Set by `init`.
pub var kernel_root: u64 = 0;

// The PML4 in a CPU's CR3 and its count of CR3 loads are that CPU's
// (`PerCpu.loaded_root`, `root_loads`).

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
        if (level == 0) {
            if (e & SHARED == 0) pmm.release(e & ADDR_MASK); // freed if nobody else has it (`fork`)
        } else if (level == 1 and e & HUGE != 0) {
            freeHugePages(e & ADDR_MASK);
        } else freeTable(e & ADDR_MASK, level - 1);
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
    const kernel_half = virt >= KERNEL_BASE and kernel_root != 0 and root == kernel_root;
    errdefer {
        // Out of the tree first, innermost first; then a flush, since a
        // CPU may have walked into them meanwhile; then freed (see `unmap`).
        var gone: [3]u64 = undefined;
        const n = created_len;
        while (created_len > 0) {
            created_len -= 1;
            const entry = created[created_len];
            gone[created_len] = entry.* & ADDR_MASK;
            entry.* = 0;
            if (kernel_half and counting_tables) _ = kernel_table_pages.fetchSub(1, .monotonic);
        }
        if (n > 0) {
            flushEverywhere(root, virt, 1);
            for (gone[0..n]) |t| pmm.free(t);
        }
    }

    var t = table(root);
    var level: u6 = 3; // 3 = PML4, 2 = PDPT, 1 = PD, 0 = PT
    while (level > last) : (level -= 1) {
        const entry = &t[index(virt, level)];
        if (entry.* & PRESENT == 0) {
            entry.* = (try allocTable()) | PRESENT | WRITABLE | USER;
            created[created_len] = entry;
            created_len += 1;
            if (kernel_half and counting_tables) _ = kernel_table_pages.fetchAdd(1, .monotonic);
        } else if (entry.* & HUGE != 0) return error.AlreadyMapped; // inside a 2 MiB page
        t = table(entry.* & ADDR_MASK);
    }
    const leaf = &t[index(virt, last)];
    // For a 2 MiB page this also catches a page table of 4 KiB pages in its place.
    if (leaf.* & PRESENT != 0) return error.AlreadyMapped;
    const global: u64 = if (virt >= KERNEL_BASE) GLOBAL else 0;
    leaf.* = (phys & ADDR_MASK) | (flags & ~GLOBAL) | global | PRESENT | (if (huge) HUGE else 0);
}

/// Clear the 4 KiB mapping of `virt` in the address space `root` and
/// return the physical address it had, or null if there was none. Nothing
/// is flushed and no table is freed: the first step of an unmap.
fn clearLeaf(root: u64, virt: u64) ?u64 {
    var t = table(root);
    var level: u6 = 3;
    while (level > 0) : (level -= 1) {
        const e = t[index(virt, level)];
        if (e & PRESENT == 0 or e & HUGE != 0) return null;
        t = table(e & ADDR_MASK);
    }
    const leaf = &t[index(virt, 0)];
    const e = leaf.*;
    if (e & PRESENT == 0) return null;
    leaf.* = 0;
    return e & ADDR_MASK;
}

/// Take the page tables on the way to `virt` that have become empty out of
/// the tree: the PT, then the PD, then (for user addresses only) the PDPT,
/// but never the tables the kernel half of every address space shares.
/// Their pages are put in `out` (at most 3; returns how many), for the
/// caller to free once every CPU has flushed: until then a CPU may still
/// hold a pointer to them from a walk it made, and a page freed sooner
/// could be handed out again and read as a page table.
fn detachTables(root: u64, virt: u64, out: *[3]u64) usize {
    var tables: [4]*[512]u64 = undefined;
    tables[3] = table(root);
    var level: u6 = 3;
    while (level > 0) : (level -= 1) {
        const e = tables[level][index(virt, level)];
        if (e & PRESENT == 0 or e & HUGE != 0) return 0; // detached already, with a neighbour
        tables[level - 1] = table(e & ADDR_MASK);
    }
    const top: u6 = if (virt < USER_END) 3 else 2;
    var n: usize = 0;
    level = 0;
    while (level < top and isEmpty(tables[level])) : (level += 1) {
        const parent = &tables[level + 1][index(virt, level + 1)];
        out[n] = parent.* & ADDR_MASK;
        n += 1;
        parent.* = 0;
        if (virt >= KERNEL_BASE and root == kernel_root) _ = kernel_table_pages.fetchSub(1, .monotonic);
    }
    return n;
}

/// Flush `pages` pages from `start` out of this CPU's TLB, together with
/// its cached pointers to the page tables on the way to them. For many
/// pages everything is flushed instead, global entries included.
pub fn flushLocal(start: u64, pages: u64) void {
    if (pages > 32) {
        const cr4 = cpu.readCr4();
        cpu.writeCr4(cr4 & ~CR4_PGE);
        cpu.writeCr4(cr4);
        return;
    }
    for (0..pages) |i| {
        asm volatile ("invlpg (%[v])"
            :
            : [v] "r" (start + i * pmm.PAGE_SIZE),
            : .{ .memory = true });
    }
}

/// Flush `pages` pages from `start` in the address space `root` out of
/// the TLB of every CPU that may hold them: all of them for kernel
/// addresses, the ones that have `root` loaded for user addresses. Returns
/// when every CPU has done it.
fn flushEverywhere(root: u64, start: u64, pages: u64) void {
    // On one CPU from start to end: a thread moved to another CPU between
    // the local flush and the request would leave the new CPU, which the
    // request skips as the sender's, with the old translation.
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    if (start >= KERNEL_BASE) {
        flushLocal(start, pages);
        ipi.broadcast(.{ .flush_kernel = .{ .start = start, .pages = pages } });
    } else {
        if (loadedRoot() == root) flushLocal(start, pages);
        // Only the CPUs that have `root` loaded can hold its translations
        // (see `loadRoot` for why reading that is enough): a process's
        // `munmap` interrupts none but the CPUs its threads ran on.
        ipi.broadcastTo(.{ .flush_user = .{ .root = root, .start = start, .pages = pages } }, root);
    }
}

/// Remove the 4 KiB mapping of `virt` from the address space whose PML4 is
/// `root`. Returns the physical address the page was mapped to (the caller
/// decides whether to free it), or null if `virt` was not mapped by a
/// 4 KiB page.
///
/// The order is what makes this safe with several CPUs: the entry is
/// cleared, and page tables that became empty are taken out of the tree;
/// then the address is flushed from the TLB of every CPU that may have
/// it, which also drops their cached pointers to the page tables; and
/// only then are those tables' pages freed, and the page handed to the
/// caller. Until the flush another CPU can still use the page through its
/// TLB, or walk the tables: so nothing a walk can reach is freed before
/// it, and nothing can be reached anew after it. (Freeing the tables
/// after the flush but detaching them only then, as this did at first,
/// let a CPU walk into a table between the two and keep the pointer.)
pub fn unmap(root: u64, virt: u64) ?u64 {
    const phys = clearLeaf(root, virt) orelse return null;
    var tables: [3]u64 = undefined;
    const n = detachTables(root, virt, &tables);
    flushEverywhere(root, virt, 1);
    for (tables[0..n]) |t| pmm.free(t);
    return phys;
}

/// Remove the 4 KiB mappings of the `phys.len` pages from `virt` on, with
/// one flush for all of them. `phys[i]` is set to what page `i` was mapped
/// to, or null if it was not mapped. Otherwise as `unmap`.
pub fn unmapRange(root: u64, virt: u64, phys: []?u64) void {
    for (phys, 0..) |*p, i| p.* = clearLeaf(root, virt + i * pmm.PAGE_SIZE);
    // Detached tables wait in `pending` for the flush; when it is full,
    // there is a flush in between.
    var pending: [48]u64 = undefined;
    var n: usize = 0;
    for (0..phys.len) |i| {
        if (n + 3 > pending.len) {
            flushEverywhere(root, virt, phys.len);
            for (pending[0..n]) |t| pmm.free(t);
            n = 0;
        }
        n += detachTables(root, virt + i * pmm.PAGE_SIZE, pending[n..][0..3]);
    }
    flushEverywhere(root, virt, phys.len);
    for (pending[0..n]) |t| pmm.free(t);
}

/// `map` for a page a running program is given, which also says how many
/// page tables had to be added for it (0 to 3): they are memory the
/// process takes, like the page.
pub fn mapCounting(root: u64, virt: u64, phys: u64, flags: u64, tables_added: *usize) MapError!void {
    const before = userTablePagesOnPath(root, virt);
    try map(root, virt, phys, flags, false);
    tables_added.* = userTablePagesOnPath(root, virt) - before;
}

/// Move the 4 KiB user page mapped at `from` to `to`, with its permission
/// and accessed/dirty bits, adding page tables for `to` if needed (counted
/// in `tables_added`). Returns false if nothing is mapped at `from`.
/// `from` is cleared but not flushed: the caller flushes the old range
/// once, when it has moved everything (`flushUserRange`). On an error
/// nothing has changed.
pub fn moveUserPage(root: u64, from: u64, to: u64, tables_added: *usize) MapError!bool {
    const e = leafEntry(root, from) orelse return false;
    const flags = e & ~ADDR_MASK & ~PRESENT;
    try mapCounting(root, to, e & ADDR_MASK, flags, tables_added);
    _ = clearLeaf(root, from);
    return true;
}

/// Map the 2 MiB page at `phys` (512 pages from `pmm.allocHugeZeroed`) at
/// `virt`, both 2 MiB aligned, counting the page tables added. Fails with
/// `error.AlreadyMapped` if anything is mapped in those 2 MiB, or a page
/// table is there for them.
pub fn mapHugeCounting(root: u64, virt: u64, phys: u64, flags: u64, tables_added: *usize) MapError!void {
    const before = userTablePagesOnPath(root, virt);
    try map(root, virt, phys, flags, true);
    tables_added.* = userTablePagesOnPath(root, virt) - before;
    _ = huge_mapped.fetchAdd(1, .monotonic);
}

/// 2 MiB user pages mapped now, in all address spaces (`AnonHugePages`
/// of `/proc/meminfo`).
pub var huge_mapped: std.atomic.Value(usize) = .init(0);

/// Whether nothing is mapped in the 2 MiB at `virt` (aligned) under
/// `root`, and no page table is there for them: where a 2 MiB page can go.
pub fn blockEmpty(root: u64, virt: u64) bool {
    var t = table(root);
    var level: u6 = 3;
    while (level > 1) : (level -= 1) {
        const e = t[index(virt, level)];
        if (e & PRESENT == 0) return true;
        if (e & HUGE != 0) return false;
        t = table(e & ADDR_MASK);
    }
    return t[index(virt, 1)] & PRESENT == 0;
}

/// Free the 512 pages of a 2 MiB page, one by one.
fn freeHugePages(phys: u64) void {
    freeWholeHuge(phys);
}

/// Give a 2 MiB page that is still whole back to the page allocator in
/// one step, and count it gone.
fn freeWholeHuge(phys: u64) void {
    pmm.freeHuge(phys);
    _ = huge_mapped.fetchSub(1, .monotonic);
}

/// If a 2 MiB page maps `virt` in `root`, put a page table of 512 small
/// entries for the same memory, with the same permissions, in its place,
/// so that part of it can be unmapped or protected. The translations do not
/// change, so nothing needs flushing. Returns the page tables added (0 or
/// 1); `error.OutOfMemory` if there is no page for the table, and then
/// nothing has changed.
pub fn splitHugeAt(root: u64, virt: u64) error{OutOfMemory}!usize {
    var t = table(root);
    var level: u6 = 3;
    while (level > 1) : (level -= 1) {
        const e = t[index(virt, level)];
        if (e & PRESENT == 0 or e & HUGE != 0) return 0;
        t = table(e & ADDR_MASK);
    }
    const pde = &t[index(virt, 1)];
    const e = pde.*;
    if (e & PRESENT == 0 or e & HUGE == 0) return 0;
    const pt = try allocTable();
    const flags = e & ~ADDR_MASK & ~HUGE;
    const small = table(pt);
    for (small, 0..) |*entry, k| entry.* = ((e & ADDR_MASK) + k * pmm.PAGE_SIZE) | flags;
    @atomicStore(u64, pde, pt | PRESENT | WRITABLE | USER, .release);
    _ = huge_mapped.fetchSub(1, .monotonic);
    return 1;
}

/// Split the 2 MiB pages that `[start, end)` covers only partly (at most
/// the two at its ends), so that an operation on the range need not split
/// any (`walkUserRange`). With `all`, every 2 MiB page in it (for moving
/// it page by page). Returns the page tables added.
pub fn splitHugeIn(root: u64, start: u64, end: u64, all: bool) error{OutOfMemory}!usize {
    var added: usize = 0;
    if (all) {
        var v = start & ~(MIB2 - 1);
        while (v < end) : (v += MIB2) added += try splitHugeAt(root, v);
        return added;
    }
    if (start % MIB2 != 0) added += try splitHugeAt(root, start);
    if (end % MIB2 != 0 and end > start) added += try splitHugeAt(root, end - 1);
    return added;
}

/// Copy every user page of the address space `from` into the empty address
/// space `to`: a new page with the same contents and the same entry bits
/// for each one (`fork`, without copy-on-write). Returns how many pages
/// and page tables `to` took. On `error.OutOfMemory`, what was copied so
/// far stays in `to`, for the caller to destroy with it. Whoever holds the
/// lock of `from`'s mappings must hold it throughout.
pub fn copyUserSpace(from: u64, to: u64) MapError!usize {
    var taken: usize = 0;
    defer flushAllUser(from); // its pages are read-only now, copy-on-write
    try copyLevel(table(from), to, 3, 0, &taken);
    return taken;
}

/// Forget every user translation of `root` on every CPU that has it
/// loaded: after its entries lost write permission all over (`fork`).
pub fn flushAllUser(root: u64) void {
    flushEverywhere(root, 0, USER_END / pmm.PAGE_SIZE);
}

fn copyLevel(t: *[512]u64, to: u64, level: u6, base: u64, taken: *usize) MapError!void {
    const n: usize = if (level == 3) 256 else 512; // the user half only
    for (t[0..n], 0..) |e, i| {
        if (e & PRESENT == 0) continue;
        const virt = base + i * span(level);
        if (level == 0 and e & SHARED != 0) {
            // A page all address spaces share: the same page, not a copy.
            var tables: usize = 0;
            try mapCounting(to, virt, e & ADDR_MASK, e & ~ADDR_MASK & ~PRESENT, &tables);
            taken.* += tables;
        } else if (level == 0 and e & SHARED_MAP != 0) {
            // A page of a shared mapping: the child's mapping is the same
            // page, one more owner of it (copied only if it has as many
            // as can be counted, which no program reaches).
            if (!pmm.share(e & ADDR_MASK)) return error.OutOfMemory;
            var tables: usize = 0;
            mapCounting(to, virt, e & ADDR_MASK, e & ~ADDR_MASK & ~PRESENT, &tables) catch |err| {
                pmm.release(e & ADDR_MASK);
                return err;
            };
            taken.* += 1 + tables;
        } else if (level == 0) {
            // Shared, read-only in both and marked copy-on-write: copied
            // only when one of them writes to it. A page with as many
            // owners as can be counted is copied now.
            if (pmm.share(e & ADDR_MASK)) {
                const ro = if (e & (WRITABLE | COW) != 0) (e & ~WRITABLE) | COW else e;
                var tables: usize = 0;
                mapCounting(to, virt, e & ADDR_MASK, ro & ~ADDR_MASK & ~PRESENT, &tables) catch |err| {
                    pmm.release(e & ADDR_MASK);
                    return err;
                };
                t[i] = ro; // the caller flushes the old, writable entries
                taken.* += 1 + tables;
                continue;
            }
            const page = pmm.alloc() orelse return error.OutOfMemory;
            @memcpy(pmm.physToVirt(page)[0..pmm.PAGE_SIZE], pmm.physToVirt(e & ADDR_MASK)[0..pmm.PAGE_SIZE]);
            var tables: usize = 0;
            // (A copy-on-write page copied is the child's own: writable.)
            const own = if (e & COW != 0) (e & ~COW) | WRITABLE else e;
            mapCounting(to, virt, page, own & ~ADDR_MASK & ~PRESENT, &tables) catch |err| {
                pmm.free(page);
                return err;
            };
            taken.* += 1 + tables;
        } else if (e & HUGE == 0) {
            try copyLevel(table(e & ADDR_MASK), to, level - 1, virt, taken);
        } else if (level == 1) {
            // A 2 MiB page, copied as 512 small ones: the copy need not find
            // 2 MiB in one piece, and is the same memory to the program.
            const flags = e & ~ADDR_MASK & ~PRESENT & ~HUGE;
            for (0..512) |k| {
                const page = pmm.alloc() orelse return error.OutOfMemory;
                @memcpy(pmm.physToVirt(page)[0..pmm.PAGE_SIZE], pmm.physToVirt((e & ADDR_MASK) + k * pmm.PAGE_SIZE)[0..pmm.PAGE_SIZE]);
                var tables: usize = 0;
                mapCounting(to, virt + k * pmm.PAGE_SIZE, page, flags, &tables) catch |err| {
                    pmm.free(page);
                    return err;
                };
                taken.* += 1 + tables;
            }
        }
    }
}

/// Flush the user range `[start, start + pages * 4 KiB)` of `root` from
/// every CPU that has it loaded.
pub fn flushUserRange(root: u64, start: u64, pages: u64) void {
    flushEverywhere(root, start, pages);
}

/// Number of page tables below the PML4 on the way to `virt` that exist.
fn userTablePagesOnPath(root: u64, virt: u64) usize {
    var t = table(root);
    var n: usize = 0;
    var level: u6 = 3;
    while (level > 0) : (level -= 1) {
        const e = t[index(virt, level)];
        if (e & PRESENT == 0 or e & HUGE != 0) break;
        n += 1;
        t = table(e & ADDR_MASK);
    }
    return n;
}

/// Bytes one entry of the table at `level` covers (0 = PT ... 3 = PML4).
fn span(level: u6) u64 {
    return @as(u64, 1) << (12 + 9 * level);
}

/// What `walkUserRange` does to each mapped page.
const RangeAction = union(enum) {
    /// Remove the mapping; the page, and tables left empty, go to the
    /// gatherer, which frees them once every CPU has flushed.
    unmap: *Gather,
    /// Replace the permission bits of the entry (`USER`, `WRITABLE`, `NX`).
    protect: u64,
};

/// Pages taken out of an address space that wait to be freed until every
/// CPU that may know them has flushed (Linux calls this `mmu_gather`). No
/// page, and no page table, is freed while a CPU can still reach it
/// through its TLB or through a pointer to a table it walked; and once
/// they are out of the tree and flushed, none can be reached anew.
const Gather = struct {
    root: u64,
    start: u64,
    pages: u64,
    buf: []u64,
    n: usize = 0,
    /// Entries were cleared that free nothing (`SHARED` pages): the range
    /// is flushed all the same.
    cleared: bool = false,

    fn add(g: *Gather, phys: u64) void {
        if (g.n == g.buf.len) g.flush();
        g.buf[g.n] = phys;
        g.n += 1;
    }

    fn flush(g: *Gather) void {
        if (g.n == 0 and !g.cleared) return;
        g.cleared = false;
        flushEverywhere(g.root, g.start, g.pages);
        for (g.buf[0..g.n]) |entry| {
            // Bit 0 (never set in a page's address) marks a 2 MiB page.
            // A small page may be shared copy-on-write: let go of, freed if
            // it was the last owner's.
            if (entry & 1 != 0) freeWholeHuge(entry & ~@as(u64, 1)) else pmm.release(entry);
        }
        g.n = 0;
    }
};

/// Apply `action` to every mapped 4 KiB page of `[start, end)` under the
/// table at `phys` of `level`, whose first entry maps `base`. Tables that
/// have nothing in the range are skipped whole, so a range of gigabytes
/// with little in it costs little. Returns the number of pages and page
/// tables freed, or for `protect` the number of pages changed. When unmapping, a table that ends up empty is freed too
/// (its entry in the parent is cleared by the caller, who is told through
/// `emptied`).
fn walkUserRange(phys: u64, level: u6, base: u64, start: u64, end: u64, action: RangeAction, emptied: *bool) usize {
    const t = table(phys);
    var freed: usize = 0;
    const step = span(level);
    const first: usize = if (start > base) @intCast((start - base) / step) else 0;
    var i = first;
    while (i < 512) : (i += 1) {
        const entry_base = base + i * step;
        if (entry_base >= end) break;
        const e = t[i];
        if (e & PRESENT == 0) continue;
        if (e & HUGE != 0) {
            // A 2 MiB page: wholly in the range, since the callers split the
            // ones it only partly covers first (`splitHugeAt`).
            if (level != 1 or entry_base < start or entry_base + step > end) continue;
            switch (action) {
                .unmap => |g| {
                    t[i] = 0;
                    g.add((e & ADDR_MASK) | 1); // freed whole, after the flush
                    freed += 512;
                },
                .protect => |bits| {
                    t[i] = (e & ~(USER | WRITABLE | NX)) | bits;
                    freed += 512;
                },
            }
            continue;
        }
        if (level == 0) {
            switch (action) {
                .unmap => |g| {
                    t[i] = 0;
                    if (e & SHARED != 0) {
                        g.cleared = true; // not the address space's: not freed or counted
                    } else {
                        g.add(e & ADDR_MASK);
                        freed += 1;
                    }
                },
                .protect => |bits| {
                    // A page shared by every process is never made
                    // writable; one shared with other processes since a
                    // `fork` is made copy-on-write instead, and gets that on
                    // its first write fault.
                    const keep = e & ~(USER | WRITABLE | NX | COW);
                    t[i] = if (e & SHARED != 0)
                        keep | (bits & ~WRITABLE)
                    else if (e & SHARED_MAP != 0)
                        keep | bits // a shared mapping's page: as asked
                    else if (bits & WRITABLE != 0 and (e & COW != 0 or pmm.isShared(e & ADDR_MASK)))
                        keep | (bits & ~WRITABLE) | COW
                    else
                        keep | bits;
                    freed += 1; // counted, though nothing is freed: see the callers
                },
            }
        } else {
            var child_empty = false;
            freed += walkUserRange(e & ADDR_MASK, level - 1, entry_base, start, end, action, &child_empty);
            if (child_empty) {
                t[i] = 0;
                action.unmap.add(e & ADDR_MASK);
                freed += 1;
            }
        }
    }
    emptied.* = action == .unmap and level < 3 and isEmpty(t);
    return freed;
}

/// Remove every mapping in the user range `[start, end)` of the address
/// space `root`, free the pages, and free the page tables that are left
/// empty. Returns how many pages and page tables were freed. The pages are
/// flushed from every CPU that has `root` loaded before any of them is
/// reused: the order `unmap` keeps, for a whole range. Unlike `unmap`, the
/// pages are freed here: they are the address space's own.
pub fn unmapUserRange(root: u64, start: u64, end: u64) usize {
    assert.check(.vmm, start <= end and end <= USER_END and start % pmm.PAGE_SIZE == 0 and end % pmm.PAGE_SIZE == 0, "unmapping the user range 0x{x}-0x{x}", .{ start, end });
    if (start == end) return 0;
    // Entries are cleared and empty tables taken out of the tree as the
    // walk goes; what they pointed to is gathered, and freed in batches,
    // each after a flush. The batch is a page if there is one to be had
    // (512 at a time), a few on the stack otherwise.
    var small: [16]u64 = undefined;
    const batch_page = pmm.alloc();
    defer if (batch_page) |b| pmm.free(b);
    var gather: Gather = .{
        .root = root,
        .start = start,
        .pages = (end - start) / pmm.PAGE_SIZE,
        .buf = if (batch_page) |b| @as([*]u64, @ptrCast(@alignCast(pmm.physToVirt(b))))[0 .. pmm.PAGE_SIZE / 8] else &small,
    };
    var unused = false;
    const freed = walkUserRange(root, 3, 0, start, end, .{ .unmap = &gather }, &unused);
    gather.flush();
    return freed;
}

/// Give every mapped page of the user range `[start, end)` the permission
/// bits `flags` (`USER`, `WRITABLE`, `NX`; without `USER` the program
/// cannot touch the page at all), and flush them from every CPU that has
/// `root` loaded.
pub fn protectUserRange(root: u64, start: u64, end: u64, flags: u64) void {
    assert.check(.vmm, start <= end and end <= USER_END and start % pmm.PAGE_SIZE == 0 and end % pmm.PAGE_SIZE == 0, "protecting the user range 0x{x}-0x{x}", .{ start, end });
    if (start == end) return;
    var unused = false;
    const changed = walkUserRange(root, 3, 0, start, end, .{ .protect = flags & (USER | WRITABLE | NX) }, &unused);
    if (changed != 0) flushEverywhere(root, start, (end - start) / pmm.PAGE_SIZE);
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

/// Give the copy-on-write page mapped at `virt` under `root` (`COW`) to that
/// address space alone, writable: the page itself if nobody else has it
/// any more, else a copy. False if there is no such page there. Out of
/// memory if a copy is needed and there is no page for it. The caller holds
/// the address space's lock; a copy is flushed from every CPU that has
/// `root` loaded, so that none of them reads the old page after the new
/// one was written to.
pub fn breakCow(root: u64, virt: u64) error{OutOfMemory}!bool {
    const slot = leafEntryPtr(root, virt) orelse return false;
    const e = slot.*;
    if (e & PRESENT == 0 or e & COW == 0) return false;
    const old = e & ADDR_MASK;
    if (!pmm.isShared(old)) {
        // Only this address space has it: the same page, writable now. A
        // CPU that still has the read-only entry faults once more, and
        // finds it right (`user_memory.handleFault`).
        @atomicStore(u64, slot, (e & ~COW) | WRITABLE, .release);
        flushLocal(virt & ~@as(u64, pmm.PAGE_SIZE - 1), 1);
        return true;
    }
    const page = pmm.alloc() orelse return error.OutOfMemory;
    @memcpy(pmm.physToVirt(page)[0..pmm.PAGE_SIZE], pmm.physToVirt(old)[0..pmm.PAGE_SIZE]);
    @atomicStore(u64, slot, page | (e & ~ADDR_MASK & ~COW) | WRITABLE, .release);
    flushEverywhere(root, virt & ~@as(u64, pmm.PAGE_SIZE - 1), 1);
    pmm.release(old);
    return true;
}

/// The 4 KiB leaf entry of `virt` under `root`, to change in place, or null
/// if there is none. For tests that need a translation the TLB has not
/// caught up with: nothing is flushed.
pub fn leafEntryPtr(root: u64, virt: u64) ?*u64 {
    var t = table(root);
    var level: u6 = 3;
    while (true) : (level -= 1) {
        const e = &t[@intCast((virt >> (12 + 9 * level)) & 0x1FF)];
        if (level == 0) return e;
        if (e.* & PRESENT == 0 or e.* & HUGE != 0) return null;
        t = table(e.* & ADDR_MASK);
    }
}

/// Whether the page tables under `root` let ring 0 make this access to
/// `virt` now: every level present, writable for a write, not NX for an
/// instruction fetch. For telling a spurious page fault from a real one.
pub fn permits(root: u64, virt: u64, write: bool, exec: bool) bool {
    var t = table(root);
    var level: u6 = 3;
    while (true) : (level -= 1) {
        const e = t[@intCast((virt >> (12 + 9 * level)) & 0x1FF)];
        if (e & PRESENT == 0) return false;
        if (write and e & WRITABLE == 0) return false;
        if (exec and e & NX != 0) return false;
        if (level == 0 or (level <= 2 and e & HUGE != 0)) return true;
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

/// Switch this CPU to the address space whose PML4 is at physical address
/// `root` by loading CR3. This flushes the TLB entries of user addresses;
/// the kernel's are global and stay. Interrupts must be off.
pub fn loadRoot(root: u64) void {
    const c = percpu.current();
    // Said before it is done: a CPU that changes a mapping of `root` and
    // then reads this (`flushEverywhere`) either sees it and asks this one
    // to flush, or wrote the mapping before this CPU loads CR3, which it
    // then walks afresh. Loading CR3 is serializing: the store is visible
    // to every CPU before any translation through the new tables is made.
    @atomicStore(u64, &c.loaded_root, root, .seq_cst);
    asm volatile ("mov %[r], %%cr3"
        :
        : [r] "r" (root),
        : .{ .memory = true });
    c.root_loads += 1;
}

/// This CPU is about to halt with nothing to run: from now on a flush of
/// the user addresses it has loaded need not interrupt it (`ipi.send`
/// marks it stale instead). Interrupts are off.
pub fn enterLazy() void {
    @atomicStore(bool, &percpu.current().tlb_lazy, true, .seq_cst);
}

/// This CPU has woken: if a flush passed it by while it halted, forget
/// every user translation now, before anything can use one. Against a
/// sender: it marks the CPU stale before it looks whether the CPU is lazy,
/// and the CPU says it is not before it looks whether it is stale, so one
/// of them sees the other. Interrupts are off.
pub fn leaveLazy() void {
    const c = percpu.current();
    @atomicStore(bool, &c.tlb_lazy, false, .seq_cst);
    if (@atomicRmw(bool, &c.tlb_stale, .Xchg, false, .seq_cst)) {
        // Reloading CR3 drops every user translation; the kernel's are global.
        asm volatile ("mov %[r], %%cr3"
            :
            : [r] "r" (c.loaded_root),
            : .{ .memory = true });
    }
}

/// The PML4 that is loaded on this CPU now.
pub fn loadedRoot() u64 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    return percpu.current().loaded_root;
}

/// CR3 loads on this CPU since boot. Tests use it to see which switches reload it.
pub fn rootLoads() usize {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    return percpu.current().root_loads;
}

/// Make sure the address space `root` is loaded on no CPU, by switching
/// every CPU that has it to the kernel's own page tables. Must be called
/// before `root` is destroyed: a CPU that ran one of its threads keeps it
/// loaded for as long as it runs only kernel threads afterwards
/// (`thread.zig`). Nothing may load `root` again: its threads are gone.
pub fn unloadRoot(root: u64) void {
    // On one CPU throughout, as in `flushEverywhere`: moved in between, the
    // thread would be on a CPU the request skips, which may have `root`.
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    if (percpu.current().loaded_root == root) loadRoot(kernel_root);
    ipi.broadcastTo(.{ .unload_root = root }, root);
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
    assert.check(.vmm, root != loadedRoot(), "destroying the loaded address space 0x{x}", .{root});
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

    enterKernelTables();
    noteKernelTables();
    counting_tables = true; // the tables built here are the baseline
}

/// False while `init` builds the kernel's first page tables.
var counting_tables = false;

/// Move this CPU from the bootloader's page tables to the kernel's: allow
/// the NX bit, which they use, and load them. Global pages go off for the
/// load, so that nothing the bootloader's page tables left in the TLB
/// survives it (changing CR4.PGE flushes everything), and on again
/// afterwards. Uses nothing that is mapped only in the kernel's tables, so
/// a CPU can run it as its first step, before its `PerCpu` is reachable;
/// `noteKernelTables` follows once it is.
pub fn enterKernelTables() void {
    cpu.wrmsr(0xC0000080, cpu.rdmsr(0xC0000080) | (1 << 11)); // EFER.NXE
    cpu.writeCr4(cpu.readCr4() & ~CR4_PGE);
    asm volatile ("mov %[r], %%cr3"
        :
        : [r] "r" (kernel_root),
        : .{ .memory = true });
    cpu.writeCr4(cpu.readCr4() | CR4_PGE);
}

/// Record in this CPU's `PerCpu` what `enterKernelTables` loaded.
pub fn noteKernelTables() void {
    const c = percpu.current();
    c.loaded_root = kernel_root;
    c.root_loads += 1;
}
