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
//! A page that is freed must be one `alloc` returned and that has not been
//! freed since. Anything else (a misaligned address, memory the allocator
//! does not manage, a double free) is refused and leaves the allocator
//! untouched: `tryFree` reports it, `free` panics, because the caller has
//! lost track of who owns the page.

const build_options = @import("build_options");

const cpu = @import("../arch/x86_64/cpu.zig");
const limine = @import("../boot/limine.zig");
const panicFmt = @import("debug/panic.zig").panicFmt;
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

/// Protects `pages` and `free_pages`.
var lock: SpinLock = .{ .rank = .page_allocator };
var pages: page_bitmap.PageBitmap = .{ .used = &.{}, .managed = &.{}, .total = 0 };
var hhdm: u64 = 0;

/// True if freed pages are filled with `POISON` (`-Dpoison`).
pub const poison = build_options.poison;
/// The byte freed pages are filled with.
pub const POISON: u8 = 0xDF;

/// Size of a physical page in bytes.
pub const PAGE_SIZE = 4096;
/// Number of pages currently free.
pub var free_pages: usize = 0;

/// Why `tryFree` refused an address.
pub const FreeError = page_bitmap.FreeError || error{
    /// The address is not the start of a page.
    Misaligned,
};

/// Return a pointer to physical address `phys` through the HHDM. Requires `init`.
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

    // 2. Store both in the first usable region large enough to hold them.
    var storage: []u8 = &.{};
    for (entries) |e| {
        if (e.type == limine.MEMMAP_USABLE and e.length >= 2 * bytes) {
            storage = physToVirt(e.base)[0 .. 2 * bytes];
            break;
        }
    }
    if (storage.len == 0) @panic("no room for the PMM bitmaps");
    pages = .init(storage[0..bytes], storage[bytes..], total);

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
    // A thread switch between finding a free page and marking it used
    // would hand the page out twice.
    const held = lock.acquire();
    defer lock.release(held);
    inCriticalSection();
    if (comptime build_options.is_test) {
        if (fail_after) |*left| {
            if (left.* == 0) return null;
            left.* -= 1;
        }
    }
    const page = pages.alloc() orelse return null;
    free_pages = pages.free_count;
    return @as(u64, page) * PAGE_SIZE;
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
    const held = lock.acquire();
    defer lock.release(held);
    inCriticalSection();
    try pages.free(phys / PAGE_SIZE);
    free_pages = pages.free_count;
    // Under the lock: nobody can be handed the page while it is filled.
    if (poison) @memset(physToVirt(phys)[0..PAGE_SIZE], POISON);
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
    return phys % PAGE_SIZE == 0 and pages.isAllocated(phys / PAGE_SIZE);
}

/// Recount the free pages from the bitmaps and compare with `free_pages`;
/// also checks that no unmanaged page is marked free. Walks every page, so
/// it is for tests and debugging.
pub fn consistent() bool {
    const held = lock.acquire();
    defer lock.release(held);
    return pages.consistent() and pages.free_count == free_pages;
}

/// Number of pages the bitmaps cover (the highest usable address).
pub fn totalPages() usize {
    return pages.total;
}
