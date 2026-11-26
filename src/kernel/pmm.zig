//! Physical memory manager: hands out 4 KiB pages of RAM.
//!
//! The bookkeeping (two bitmaps with one bit per page, built from the Limine
//! memory map) is `page_bitmap.zig`; this file gives it memory, turns
//! addresses into page numbers and makes every operation safe against
//! preemption, interrupt handlers and (later) other CPUs with a spinlock. The bitmaps are stored in the first
//! usable region that is large enough. Physical page 0 is never handed out,
//! so 0 can mean "none". Physical memory is accessed through the HHDM with
//! `physToVirt`.
//!
//! **Zeroing.** `allocZeroed` is the one place memory is cleared before it
//! reaches a user program or becomes a page table: everything that maps a
//! page into an address space gets the page from it. `alloc` (contents
//! undefined) is for memory only the kernel sees, such as its heap and
//! stacks. So a process can never read what a page held before.
//!
//! **Poisoning** (`-Dpoison`, on in Debug builds and the test kernel): a
//! freed page is filled with `POISON` bytes, so code that keeps using it
//! reads 0xDFDF... instead of plausible old data. As a pointer that is not
//! a canonical address, so following it faults at once.
//!
//! **Per-CPU caches.** Each CPU keeps up to `CACHE_SIZE` free pages of
//! its own, under a lock of its own that no other CPU takes while memory
//! lasts, so allocating and freeing do not meet on one lock. An empty cache
//! is filled from the bitmap `BATCH` pages at a time, and a full one gives
//! `BATCH` back, the way Linux's per-CPU page lists work. A cached page is
//! taken in the bitmap and marked in a third bitmap (`cached`), with an
//! atomic operation, so that a double free is still caught when the page
//! is in a cache. `free_pages` counts cached pages as free. When the bitmap
//! runs out, the other CPUs' caches are emptied too before an allocation
//! fails, so no memory is held back from whoever needs it.
//!
//! A page that is freed must be one `alloc` returned and that has not been
//! freed since. Anything else (a misaligned address, memory the allocator
//! does not manage, a double free) is refused and leaves the allocator
//! untouched: `tryFree` reports it, `free` panics, because the caller has
//! lost track of who owns the page.

const std = @import("std");
const build_options = @import("build_options");

const cpu = @import("../arch/x86_64/cpu.zig");
const limine = @import("../boot/limine.zig");
const panicFmt = @import("debug/panic.zig").panicFmt;
const percpu = @import("../arch/x86_64/percpu.zig");
const page_bitmap = @import("page_bitmap.zig");
const SpinLock = @import("sync/spinlock.zig").SpinLock;

/// Test kernel only: when set, `alloc` succeeds this many more times and
/// then fails as if memory had run out, until it is set to null again. Lets
/// a test make any single allocation inside a larger operation fail.
pub var fail_after: ?usize = null;

/// Test kernel only: called inside the critical section of `alloc` and
/// `tryFree`, after interrupts are off and before the bitmap is touched.
/// A test uses it to stay in there long enough that a missing lock would
/// let another thread in.
pub var critical_hook: ?*const fn () void = null;

/// Run `critical_hook`, in the test kernel only.
inline fn inCriticalSection() void {
    if (comptime build_options.is_test) {
        if (critical_hook) |hook| hook();
    }
}

/// Protects `pages`.
var lock: SpinLock = .{ .rank = .page_allocator };
var pages: page_bitmap.PageBitmap = .{ .used = &.{}, .managed = &.{}, .total = 0 };
var hhdm: u64 = 0;

/// One bit per page: the page sits in a CPU's cache. Changed atomically,
/// by whoever puts the page in or takes it out.
var cached: []u64 = &.{};

/// Pages a CPU's cache holds at most, and how many move between it and the
/// bitmap at a time.
pub const CACHE_SIZE = 64;
pub const BATCH = 32;

const Cache = struct {
    lock: SpinLock = .{ .rank = .page_cache },
    len: usize = 0,
    pages: [CACHE_SIZE]u32 = undefined,
};

/// Each CPU's cache, by CPU number, made on its first use (in a page of its
/// own, taken from the bitmap for good).
var caches: [percpu.MAX_CPUS]?*Cache = @splat(null);

/// True if freed pages are filled with `POISON` (`-Dpoison`).
pub const poison = build_options.poison;
/// The byte freed pages are filled with.
pub const POISON: u8 = 0xDF;

/// Size of a physical page in bytes.
pub const PAGE_SIZE = 4096;
/// Number of pages currently free, cached ones included. Changed
/// atomically; read it as it is.
pub var free_pages: usize = 0;

fn addFree(n: isize) void {
    if (n >= 0) {
        _ = @atomicRmw(usize, &free_pages, .Add, @intCast(n), .monotonic);
    } else {
        _ = @atomicRmw(usize, &free_pages, .Sub, @intCast(-n), .monotonic);
    }
}

fn cachedWord(page: usize) *u64 {
    return &cached[page / 64];
}

fn cachedMask(page: usize) u64 {
    return @as(u64, 1) << @intCast(page % 64);
}

/// Mark `page` as cached; false if it was already.
fn markCached(page: usize) bool {
    const old = @atomicRmw(u64, cachedWord(page), .Or, cachedMask(page), .seq_cst);
    return old & cachedMask(page) == 0;
}

fn unmarkCached(page: usize) void {
    _ = @atomicRmw(u64, cachedWord(page), .And, ~cachedMask(page), .seq_cst);
}

fn isCached(page: usize) bool {
    return @atomicLoad(u64, cachedWord(page), .seq_cst) & cachedMask(page) != 0;
}

/// Why `tryFree` refused an address.
pub const FreeError = page_bitmap.FreeError || error{
    /// The address is not the start of a page.
    Misaligned,
};

/// Return a pointer to physical address `phys` through the HHDM. Requires `init`.
/// The physical address behind an address `physToVirt` gave.
pub fn virtToPhys(virt: u64) u64 {
    return virt - hhdm;
}

pub fn physToVirt(phys: u64) [*]u8 {
    return @ptrFromInt(phys + hhdm);
}

/// Build the page bitmaps from the memory map `mm`.
///
/// `hhdm_offset` is the HHDM offset from Limine. Sizes the bitmaps to cover the
/// highest usable address, hands only the usable regions to the allocator, then
/// takes the bitmaps' own pages and page 0 away again. Panics if no usable
/// region can hold the bitmaps.
pub fn init(mm: *const limine.MemmapResponse, hhdm_offset: u64) void {
    hhdm = hhdm_offset;
    const entries = mm.entries[0..mm.entry_count];

    // 1. Size the bitmaps to cover the highest usable address.
    var top: u64 = 0;
    for (entries) |e| {
        if (e.type == limine.MEMMAP_USABLE) top = @max(top, e.base + e.length);
    }
    const total: usize = top / PAGE_SIZE;
    const bytes = page_bitmap.PageBitmap.bytesFor(total);

    // 2. Store the three in the first usable region large enough.
    var storage: []u8 = &.{};
    for (entries) |e| {
        if (e.type == limine.MEMMAP_USABLE and e.length >= 3 * bytes) {
            storage = physToVirt(e.base)[0 .. 3 * bytes];
            break;
        }
    }
    if (storage.len == 0) @panic("no room for the PMM bitmaps");
    pages = .init(storage[0..bytes], storage[bytes .. 2 * bytes], total);
    const cached_bytes = storage[2 * bytes ..];
    @memset(cached_bytes, 0);
    cached = @as([*]u64, @ptrCast(@alignCast(cached_bytes.ptr)))[0 .. bytes / 8];

    // 3. Only usable regions are memory to hand out.
    //    (Limine guarantees usable entries are page-aligned.)
    for (entries) |e| {
        if (e.type == limine.MEMMAP_USABLE) pages.addRegion(e.base / PAGE_SIZE, e.length / PAGE_SIZE);
    }

    // 4. Never hand out the bitmaps' own pages, or page 0 (keeps 0 meaning "null").
    const first = (@intFromPtr(storage.ptr) - hhdm) / PAGE_SIZE;
    for (first..first + (storage.len + PAGE_SIZE - 1) / PAGE_SIZE) |p| pages.reserve(p);
    pages.reserve(0);
    free_pages = pages.free_count;
}

/// Allocate one physical page and return its physical address, or null if
/// memory is exhausted. The page is not zeroed. Safe to call from
/// preemptible code and from interrupt handlers.
pub fn alloc() ?u64 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    if (comptime build_options.is_test) {
        if (fail_after) |*left| {
            if (left.* == 0) return null;
            left.* -= 1;
        }
    }
    const c = ownCache() orelse return allocFromBitmap();
    if (takeCached(c, true)) |page| return page;
    // Memory has run out except in caches: empty the others' too.
    for (0..percpu.count()) |n| {
        const other = caches[n] orelse continue;
        if (other == c) continue;
        if (takeCached(other, false)) |page| return page;
    }
    return null;
}

/// A page from `c`, filled from the bitmap first if it is empty and
/// `refill`; null if there is none to be had.
fn takeCached(c: *Cache, refill: bool) ?u64 {
    c.lock.take();
    defer c.lock.drop();
    inCriticalSection();
    if (c.len == 0 and refill) {
        lock.take();
        while (c.len < BATCH) {
            const page = pages.alloc() orelse break;
            _ = markCached(page);
            c.pages[c.len] = @intCast(page);
            c.len += 1;
        }
        lock.drop();
    }
    if (c.len == 0) return null;
    c.len -= 1;
    const page: usize = c.pages[c.len];
    unmarkCached(page);
    addFree(-1);
    return @as(u64, page) * PAGE_SIZE;
}

/// Straight from the bitmap: before the CPU has a cache.
fn allocFromBitmap() ?u64 {
    lock.take();
    defer lock.drop();
    inCriticalSection();
    const page = pages.alloc() orelse return null;
    addFree(-1);
    return @as(u64, page) * PAGE_SIZE;
}

/// This CPU's cache, made if it has none yet; null this early in boot
/// that CPUs have no numbers, or if there is no page to make it in.
/// Interrupts must be off.
fn ownCache() ?*Cache {
    const me = percpu.currentIfReady() orelse return null;
    if (caches[me.id]) |c| return c;
    const phys = allocFromBitmap() orelse return null;
    const c: *Cache = @ptrCast(@alignCast(physToVirt(phys)));
    c.* = .{};
    lock.take();
    pages.reserve(phys / PAGE_SIZE); // never freed: reserved, not allocated
    lock.drop();
    caches[me.id] = c;
    return c;
}

/// Make the running CPU's cache now, when it comes up, rather than at its
/// first allocation (which would look like a page gone to whoever is
/// counting then).
pub fn initCpu() void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    _ = ownCache();
}

/// Allocate one physical page filled with zeroes, or null if memory is
/// exhausted. Every page that is mapped into a user address space, and
/// every page table, comes from here.
pub fn allocZeroed() ?u64 {
    const phys = alloc() orelse return null;
    @memset(physToVirt(phys)[0..PAGE_SIZE], 0);
    return phys;
}

/// Free the physical page at `phys`, or say why it cannot be freed. On an
/// error nothing has changed. As safe to call as `alloc`.
pub fn tryFree(phys: u64) FreeError!void {
    if (phys % PAGE_SIZE != 0) return error.Misaligned;
    const page: usize = @intCast(phys / PAGE_SIZE);
    if (page >= pages.total) return error.OutOfRange;
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const c = ownCache() orelse {
        lock.take();
        defer lock.drop();
        inCriticalSection();
        try pages.free(page);
        addFree(1);
        if (poison) @memset(physToVirt(phys)[0..PAGE_SIZE], POISON);
        return;
    };
    // Mark it cached first, then look whether it is taken: a cache giving
    // the page back to the bitmap meanwhile frees it there before it
    // unmarks it, so one of the two looks sees it is not ours to free.
    if (!markCached(page)) return error.NotAllocated; // in a cache already
    {
        lock.take();
        defer lock.drop();
        const ok = pages.isAllocated(page);
        const managed = pages.isAllocated(page) or pages.isFree(page);
        if (!ok) {
            unmarkCached(page);
            return if (managed) error.NotAllocated else error.NotManaged;
        }
    }
    if (poison) @memset(physToVirt(phys)[0..PAGE_SIZE], POISON);
    c.lock.take();
    defer c.lock.drop();
    inCriticalSection();
    if (c.len == CACHE_SIZE) {
        // Full: the oldest half goes back to the bitmap.
        lock.take();
        for (c.pages[0..BATCH]) |p| {
            pages.free(p) catch unreachable; // taken, while it was cached
            unmarkCached(p);
        }
        lock.drop();
        std.mem.copyForwards(u32, c.pages[0 .. CACHE_SIZE - BATCH], c.pages[BATCH..]);
        c.len -= BATCH;
    }
    c.pages[c.len] = @intCast(page);
    c.len += 1;
    addFree(1);
}

/// Free the physical page at `phys`, which must have come from `alloc` and
/// not have been freed since. Panics otherwise, in every build mode: the
/// caller's bookkeeping is wrong, and carrying on would hand one page to
/// two owners sooner or later.
pub fn free(phys: u64) void {
    tryFree(phys) catch |e| panicFmt("PMM: bad free of 0x{x}: {s}", .{ phys, @errorName(e) });
}

/// True if the page at `phys` is currently allocated.
pub fn isAllocated(phys: u64) bool {
    const held = lock.acquire();
    defer lock.release(held);
    const page = phys / PAGE_SIZE;
    return phys % PAGE_SIZE == 0 and pages.isAllocated(page) and !isCached(page);
}

/// Recount the free pages from the bitmaps and compare with `free_pages`;
/// also checks that no unmanaged page is marked free. Walks every page, so
/// it is for tests and debugging.
pub fn consistent() bool {
    // The caches, one at a time; then the bitmap. Exact while nothing
    // allocates or frees meanwhile, which is when tests ask.
    var in_caches: usize = 0;
    var marks_ok = true;
    for (0..percpu.count()) |n| {
        const c = caches[n] orelse continue;
        const held = c.lock.acquire();
        defer c.lock.release(held);
        in_caches += c.len;
        for (c.pages[0..c.len]) |p| marks_ok = marks_ok and isCached(p) and pages.isAllocated(p);
    }
    const held = lock.acquire();
    defer lock.release(held);
    var marked: usize = 0;
    for (cached) |w| marked += @popCount(w);
    return marks_ok and marked == in_caches and pages.consistent() and
        pages.free_count + in_caches == @atomicLoad(usize, &free_pages, .monotonic);
}

/// Number of pages the bitmaps cover (the highest usable address).
pub fn totalPages() usize {
    return pages.total;
}
