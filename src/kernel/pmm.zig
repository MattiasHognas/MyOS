//! Physical memory manager: a bitmap of 4 KiB pages.
//!
//! One bit per page of physical memory (1 = used), built from the Limine
//! memory map. The bitmap itself is stored in the first usable region that is
//! large enough. Physical page 0 is never handed out, so 0 can mean "none".
//! Physical memory is accessed through the HHDM with `physToVirt`.

const limine = @import("../boot/limine.zig");
const assert = @import("debug/assert.zig");
const cpu = @import("../arch/x86_64/cpu.zig");

var bitmap: []u8 = &.{}; // 1 bit per page, 1 = used
var total_pages: usize = 0;
var hint: usize = 0; // where the next search starts
var hhdm: u64 = 0;

/// Size of a physical page in bytes.
pub const PAGE_SIZE = 4096;
/// Number of pages currently free.
pub var free_pages: usize = 0;

/// Return true if page number `p` is marked as used.
fn isUsed(p: usize) bool {
    return (bitmap[p / 8] & (@as(u8, 1) << @intCast(p % 8))) != 0;
}

/// Mark page number `p` as used. Does not update `free_pages`.
fn setUsed(p: usize) void {
    bitmap[p / 8] |= @as(u8, 1) << @intCast(p % 8);
}

/// Mark page number `p` as free. Does not update `free_pages`.
fn setFree(p: usize) void {
    bitmap[p / 8] &= ~(@as(u8, 1) << @intCast(p % 8));
}

/// Mark page number `p` as used so it is never allocated, adjusting
/// `free_pages` if it was free. Used for the bitmap's own pages and page 0.
fn reserve(p: usize) void {
    if (!isUsed(p)) {
        setUsed(p);
        free_pages -= 1;
    }
}

/// Return a pointer to physical address `phys` through the HHDM. Requires `init`.
pub fn physToVirt(phys: u64) [*]u8 {
    return @ptrFromInt(phys + hhdm);
}

/// Build the page bitmap from the memory map `mm`.
///
/// `hhdm_offset` is the HHDM offset from Limine. Sizes the bitmap to cover the
/// highest usable address, marks only the usable regions as free, then
/// reserves the bitmap's own pages and page 0. Panics if no usable region can
/// hold the bitmap.
pub fn init(mm: *const limine.MemmapResponse, hhdm_offset: u64) void {
    hhdm = hhdm_offset;
    const entries = mm.entries[0..mm.entry_count];

    // 1. Size the bitmap to cover the highest usable address.
    var top: u64 = 0;
    for (entries) |e| {
        if (e.type == limine.MEMMAP_USABLE) top = @max(top, e.base + e.length);
    }
    total_pages = top / PAGE_SIZE;
    const bytes = (total_pages + 7) / 8;

    // 2. Store the bitmap in the first usable region large enough to hold it.
    for (entries) |e| {
        if (e.type == limine.MEMMAP_USABLE and e.length >= bytes) {
            bitmap = physToVirt(e.base)[0..bytes];
            break;
        }
    }
    if (bitmap.len == 0) @panic("no room for the PMM bitmap");

    // 3. Everything starts as used; then free the usable regions.
    //    (Limine guarantees usable entries are page-aligned.)
    @memset(bitmap, 0xFF);
    for (entries) |e| {
        if (e.type != limine.MEMMAP_USABLE) continue;
        var p = e.base / PAGE_SIZE;
        while (p < (e.base + e.length) / PAGE_SIZE) : (p += 1) {
            setFree(p);
            free_pages += 1;
        }
    }

    // 4. Don't hand out the bitmap's own pages, or page 0 (keeps 0 meaning "null").
    const bm_start = (@intFromPtr(bitmap.ptr) - hhdm) / PAGE_SIZE;
    for (bm_start..bm_start + (bytes + PAGE_SIZE - 1) / PAGE_SIZE) |p| reserve(p);
    reserve(0);
}

/// Allocate one physical page and return its physical address, or null if
/// memory is exhausted. The page is not zeroed. Not interrupt safe: callers
/// that may race with other allocations must disable interrupts.
pub fn alloc() ?u64 {
    // Callers may be preemptible (syscalls); a thread switch between finding
    // a free page and marking it used would hand the page out twice.
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    for (0..total_pages) |n| {
        const p = (hint + n) % total_pages;
        if (!isUsed(p)) {
            setUsed(p);
            free_pages -= 1;
            hint = p + 1;
            return p * PAGE_SIZE;
        }
    }
    return null;
}

/// Free the physical page at `phys`, which must have come from `alloc`.
/// Panics on a double free. Not interrupt safe, like `alloc`.
pub fn free(phys: u64) void {
    assert.check(.pmm, phys % PAGE_SIZE == 0, "freeing unaligned address 0x{x}", .{phys});
    assert.check(.pmm, phys != 0 and phys / PAGE_SIZE < total_pages, "freeing address 0x{x} outside managed memory", .{phys});
    const p = phys / PAGE_SIZE;
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    if (!isUsed(p)) @panic("PMM: double free");
    setFree(p);
    free_pages += 1;
    if (p < hint) hint = p;
}
