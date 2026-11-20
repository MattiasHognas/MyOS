const limine = @import("../boot/limine.zig");

pub const PAGE_SIZE = 4096;

var bitmap: []u8 = &.{}; // 1 bit per page, 1 = used
var total_pages: usize = 0;
pub var free_pages: usize = 0;
var hint: usize = 0; // where the next search starts
var hhdm: u64 = 0;

fn isUsed(p: usize) bool {
    return (bitmap[p / 8] & (@as(u8, 1) << @intCast(p % 8))) != 0;
}
fn setUsed(p: usize) void {
    bitmap[p / 8] |= @as(u8, 1) << @intCast(p % 8);
}
fn setFree(p: usize) void {
    bitmap[p / 8] &= ~(@as(u8, 1) << @intCast(p % 8));
}
fn reserve(p: usize) void {
    if (!isUsed(p)) {
        setUsed(p);
        free_pages -= 1;
    }
}

pub fn physToVirt(phys: u64) [*]u8 {
    return @ptrFromInt(phys + hhdm);
}

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

/// Returns the physical address of a free page, or null if memory is exhausted.
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

pub fn free(phys: u64) void {
    const p = phys / PAGE_SIZE;
    if (!isUsed(p)) @panic("PMM: double free");
    setFree(p);
    free_pages += 1;
    if (p < hint) hint = p;
}
