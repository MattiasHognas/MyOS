const limine = @import("../boot/limine.zig");

var bitmap: []u8 = &.{}; // 1 bit per page, 1 = used
var total_pages: usize = 0;
var hint: usize = 0; // where the next search starts
var hhdm: u64 = 0;

pub const PAGE_SIZE = 4096;
pub var free_pages: usize = 0;

// Return the number of free pages in the system. This is a rough estimate, as it may change between calls.
fn isUsed(p: usize) bool {
    return (bitmap[p / 8] & (@as(u8, 1) << @intCast(p % 8))) != 0;
}

// Mark a page as used or free. The caller must ensure the page is not already in that state, and must disable interrupts to avoid races with alloc() and free().
fn setUsed(p: usize) void {
    bitmap[p / 8] |= @as(u8, 1) << @intCast(p % 8);
}

// Mark a page as free. The caller must ensure the page is not already free, and must disable interrupts to avoid races with alloc() and free().
fn setFree(p: usize) void {
    bitmap[p / 8] &= ~(@as(u8, 1) << @intCast(p % 8));
}

// Mark a page as reserved, so it will never be allocated. This is used for pages that are in use by the kernel or other critical structures. The caller must ensure the page is not already reserved, and must disable interrupts to avoid races with alloc() and free().
fn reserve(p: usize) void {
    if (!isUsed(p)) {
        setUsed(p);
        free_pages -= 1;
    }
}

// Convert a physical address to a virtual address in the HHDM. The caller must ensure the physical address is valid and mapped in the HHDM.
pub fn physToVirt(phys: u64) [*]u8 {
    return @ptrFromInt(phys + hhdm);
}

// Convert a virtual address in the HHDM to a physical address. The caller must ensure the virtual address is valid and mapped in the HHDM.
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

// Allocate a single page of physical memory. Returns the physical address of the page, or null if no pages are available. The caller must disable interrupts to avoid races with free().
pub fn alloc() ?u64 {
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

// Free a page of physical memory. The caller must ensure the page was previously allocated and not already freed, and must disable interrupts to avoid races with alloc().
pub fn free(phys: u64) void {
    const p = phys / PAGE_SIZE;
    if (!isUsed(p)) @panic("PMM: double free");
    setFree(p);
    free_pages += 1;
    if (p < hint) hint = p;
}
