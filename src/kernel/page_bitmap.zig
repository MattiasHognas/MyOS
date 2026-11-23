//! The bookkeeping behind the physical memory manager: which pages are free.
//!
//! Two bits per page. `used` says whether a page is taken; `managed` says
//! whether it is memory the allocator owns at all. A page that is not
//! managed (a hole in the memory map, firmware memory, the bitmaps
//! themselves, page 0) is never handed out and can never be freed, so a
//! stray `free` cannot turn device or firmware memory into "free RAM".
//!
//! This module only does arithmetic on the two bitmaps it is given. It has
//! no kernel dependencies and no locking: `pmm.zig` supplies the memory and
//! disables interrupts around each call. It is tested on the host.

const std = @import("std");

/// Why a page cannot be freed.
pub const FreeError = error{
    /// The page number is beyond the memory the bitmap covers.
    OutOfRange,
    /// The page is not memory the allocator hands out.
    NotManaged,
    /// The page is already free: a double free, or it was never allocated.
    NotAllocated,
};

pub const PageBitmap = struct {
    /// One bit per page; 1 = taken (or not managed).
    used: []u8,
    /// One bit per page; 1 = the allocator owns this page.
    managed: []u8,
    /// Number of pages covered.
    total: usize,
    /// Number of pages that are free right now.
    free_count: usize = 0,
    /// Where the next search starts.
    hint: usize = 0,

    /// Bytes each of the two bitmaps needs to cover `total` pages.
    pub fn bytesFor(total: usize) usize {
        return (total + 7) / 8;
    }

    /// Start with every page taken and none managed. Both slices must hold
    /// `bytesFor(total)` bytes.
    pub fn init(used: []u8, managed: []u8, total: usize) PageBitmap {
        std.debug.assert(used.len >= bytesFor(total) and managed.len >= bytesFor(total));
        @memset(used, 0xFF);
        @memset(managed, 0);
        return .{ .used = used, .managed = managed, .total = total };
    }

    fn get(bits: []const u8, page: usize) bool {
        return bits[page / 8] & (@as(u8, 1) << @intCast(page % 8)) != 0;
    }

    fn set(bits: []u8, page: usize, value: bool) void {
        const mask = @as(u8, 1) << @intCast(page % 8);
        if (value) bits[page / 8] |= mask else bits[page / 8] &= ~mask;
    }

    /// Hand `count` pages starting at `first` to the allocator as free
    /// memory. Pages beyond `total`, and pages already managed, are skipped.
    pub fn addRegion(self: *PageBitmap, first: usize, count: usize) void {
        var page = first;
        while (page < self.total and page - first < count) : (page += 1) {
            if (get(self.managed, page)) continue;
            set(self.managed, page, true);
            set(self.used, page, false);
            self.free_count += 1;
        }
    }

    /// Take `page` away from the allocator for good: it is never handed
    /// out, and freeing it is an error. Must be done before the page is
    /// allocated. Does nothing for pages that are not managed.
    pub fn reserve(self: *PageBitmap, page: usize) void {
        if (page >= self.total or !get(self.managed, page)) return;
        if (!get(self.used, page)) self.free_count -= 1;
        set(self.used, page, true);
        set(self.managed, page, false);
    }

    /// Take a free page and return its number, or null if there is none.
    pub fn alloc(self: *PageBitmap) ?usize {
        if (self.free_count == 0) return null;
        var n: usize = 0;
        while (n < self.total) {
            const page = (self.hint + n) % self.total;
            // Skip a whole byte of taken pages at once.
            if (page % 8 == 0 and self.used[page / 8] == 0xFF) {
                n += 8;
                continue;
            }
            if (!get(self.used, page)) {
                set(self.used, page, true);
                self.free_count -= 1;
                self.hint = page + 1;
                return page;
            }
            n += 1;
        }
        return null;
    }

    /// Give `page` back. Nothing changes if it is refused.
    pub fn free(self: *PageBitmap, page: usize) FreeError!void {
        if (page >= self.total) return error.OutOfRange;
        if (!get(self.managed, page)) return error.NotManaged;
        if (!get(self.used, page)) return error.NotAllocated;
        set(self.used, page, false);
        self.free_count += 1;
        if (page < self.hint) self.hint = page;
    }

    /// True if `page` is managed and currently allocated.
    pub fn isAllocated(self: *const PageBitmap, page: usize) bool {
        return page < self.total and get(self.managed, page) and get(self.used, page);
    }

    /// True if `page` is managed and currently free.
    pub fn isFree(self: *const PageBitmap, page: usize) bool {
        return page < self.total and !get(self.used, page);
    }

    /// Count the free pages from the bitmap itself, for checking `free_count`.
    pub fn countFree(self: *const PageBitmap) usize {
        var n: usize = 0;
        for (0..self.total) |page| {
            if (!get(self.used, page)) n += 1;
        }
        return n;
    }

    /// True if the bitmaps and the counter agree: `free_count` matches the
    /// number of clear `used` bits, and every free page is a managed one.
    pub fn consistent(self: *const PageBitmap) bool {
        var n: usize = 0;
        for (0..self.total) |page| {
            if (get(self.used, page)) continue;
            if (!get(self.managed, page)) return false;
            n += 1;
        }
        return n == self.free_count;
    }
};
