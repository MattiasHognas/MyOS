//! Kernel stacks with guard pages.
//!
//! Every thread's kernel stack lives in its own slot of a dedicated virtual
//! region, away from the heap and the HHDM. A slot is one unmapped guard page
//! followed by the stack's pages:
//!
//!     slot n:   [ guard ][ stack page 0 ] ... [ stack page N-1 ]
//!               ^ low                                          ^ top (initial RSP)
//!
//! A stack that overflows runs into its guard page and faults, instead of
//! silently overwriting whatever lies below it. The CPU cannot push the
//! page-fault frame on the overflowed stack either, so the overflow arrives
//! as a double fault on the emergency stack (`gdt.zig`), which reports it.
//!
//! The guard is one page, so a single stack frame larger than a page could
//! step over it into the stack of the slot below. The build therefore fails
//! if any kernel function has such a frame (`scripts/check-frames.sh`).
//!
//! With `-Dstack-usage` (on in Debug builds and in the test kernel) a new
//! stack is filled with a pattern, and `used` finds how deep the stack ever
//! got by looking for the lowest word that no longer holds it. `record`
//! keeps the largest value seen and warns when a stack came close to full.
//!
//! The region is in the kernel half, which all address spaces share, so a
//! stack is visible whichever process is loaded.

const std = @import("std");
const build_options = @import("build_options");
const log = std.log.scoped(.kstack);
const pmm = @import("pmm.zig");
const vmm = @import("../arch/x86_64/vmm.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const assert = @import("debug/assert.zig");

/// Pages in one kernel stack.
pub const STACK_PAGES = 4;
/// Size of one kernel stack in bytes.
pub const STACK_SIZE = STACK_PAGES * pmm.PAGE_SIZE;
/// Start of the virtual region the stacks live in. Above the MMIO window,
/// below the kernel image.
pub const REGION_START: usize = 0xFFFF_C000_0000_0000;
/// Maximum number of kernel stacks, and so of threads.
pub const MAX_STACKS = 4096;

/// True if stack usage is measured (`-Dstack-usage`).
pub const track_usage = build_options.stack_usage;
/// `record` warns when a stack was used beyond this many bytes (three quarters).
pub const WARN_BYTES = STACK_SIZE / 4 * 3;
/// What every word of a fresh stack holds when usage is measured.
const FILL: u64 = 0x5AFE_57AC_5AFE_57AC;

// Largest stack usage `record` has seen. Guarded by disabling interrupts.
var peak_bytes: usize = 0;

const SLOT_SIZE = STACK_SIZE + pmm.PAGE_SIZE; // the stack plus its guard page
const REGION_END = REGION_START + MAX_STACKS * SLOT_SIZE;

// One bit per slot; a set bit is a free slot. Guarded by disabling interrupts.
var free_slots: [MAX_STACKS / 64]u64 = @splat(~@as(u64, 0));

comptime {
    std.debug.assert(MAX_STACKS % 64 == 0);
}

/// The lowest free slot, or null if all are taken.
fn firstFreeSlot() ?usize {
    for (&free_slots, 0..) |word, i| {
        if (word != 0) return i * 64 + @ctz(word);
    }
    return null;
}

/// True if `slot` is free.
fn slotFree(slot: usize) bool {
    return free_slots[slot / 64] & (@as(u64, 1) << @intCast(slot % 64)) != 0;
}

/// Mark `slot` free or taken.
fn setSlotFree(slot: usize, is_free: bool) void {
    const bit = @as(u64, 1) << @intCast(slot % 64);
    if (is_free) free_slots[slot / 64] |= bit else free_slots[slot / 64] &= ~bit;
}

/// Allocate a kernel stack: reserve a slot and map fresh pages (writable,
/// not executable) above its guard page. Returns the stack's memory; the
/// initial stack pointer is its end. The contents are not zeroed. Returns
/// null if there is no free slot or no physical memory, leaving nothing behind.
pub fn alloc() ?[]u8 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);

    const slot = firstFreeSlot() orelse return null;
    const low = REGION_START + slot * SLOT_SIZE + pmm.PAGE_SIZE;
    for (0..STACK_PAGES) |i| {
        const phys = pmm.alloc() orelse {
            for (0..i) |j| pmm.free(vmm.unmap(vmm.kernel_root, low + j * pmm.PAGE_SIZE).?);
            return null;
        };
        vmm.map(vmm.kernel_root, low + i * pmm.PAGE_SIZE, phys, vmm.WRITABLE | vmm.NX, false);
    }
    setSlotFree(slot, false);
    if (track_usage) @memset(@as([*]u64, @ptrFromInt(low))[0 .. STACK_SIZE / 8], FILL);
    return @as([*]u8, @ptrFromInt(low))[0..STACK_SIZE];
}

/// How many bytes of `stack` (from `alloc`) have ever been used: the
/// distance from its top down to the lowest word that was written. Null if
/// usage is not measured. A deeper frame that wrote nothing is not seen, and
/// a word that happens to be rewritten with the fill pattern counts as unused.
pub fn used(stack: []const u8) ?usize {
    if (!track_usage) return null;
    const words = @as([*]const u64, @ptrCast(@alignCast(stack.ptr)))[0 .. stack.len / 8];
    for (words, 0..) |word, i| {
        if (word != FILL) return stack.len - i * 8;
    }
    return 0;
}

/// Note that the stack of thread `thread_id` has been used up to `bytes`:
/// remember the largest value and warn if it is past `WARN_BYTES`, so a
/// stack that is getting tight shows up before it overflows.
pub fn record(thread_id: usize, bytes: usize) void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    peak_bytes = @max(peak_bytes, bytes);
    if (bytes > WARN_BYTES) log.warn("thread {d} used {d} of {d} bytes of its kernel stack", .{ thread_id, bytes, STACK_SIZE });
}

/// The largest stack usage `record` has seen since boot.
pub fn peak() usize {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    return peak_bytes;
}

/// Free a stack returned by `alloc`: unmap its pages, give them back to the
/// PMM and release the slot for reuse. No thread may be running on it.
pub fn free(stack: []u8) void {
    const low = @intFromPtr(stack.ptr);
    assert.check(.kstack, stack.len == STACK_SIZE and low >= REGION_START and low < REGION_END and
        (low - REGION_START) % SLOT_SIZE == pmm.PAGE_SIZE, "freeing 0x{x}+{d}, which is not a kernel stack", .{ low, stack.len });
    const slot = (low - REGION_START) / SLOT_SIZE;

    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    assert.check(.kstack, !slotFree(slot), "double free of kernel stack 0x{x}", .{low});
    for (0..STACK_PAGES) |i| {
        const phys = vmm.unmap(vmm.kernel_root, low + i * pmm.PAGE_SIZE) orelse
            @panic("kstack: stack page not mapped");
        pmm.free(phys);
    }
    setSlotFree(slot, true);
}

/// True if `addr` is in the guard page of a stack slot. A kernel fault on
/// such an address is a kernel stack overflow. Reads no memory, so it is safe
/// to call from fault handlers.
pub fn isGuard(addr: u64) bool {
    if (addr < REGION_START or addr >= REGION_END) return false;
    return (addr - REGION_START) % SLOT_SIZE < pmm.PAGE_SIZE;
}

/// True if `stack` is a kernel stack handed out by `alloc`.
pub fn owns(stack: []const u8) bool {
    const low = @intFromPtr(stack.ptr);
    return stack.len == STACK_SIZE and low >= REGION_START and low < REGION_END and
        (low - REGION_START) % SLOT_SIZE == pmm.PAGE_SIZE;
}

/// Number of stacks currently allocated.
pub fn inUse() usize {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    var free_count: usize = 0;
    for (free_slots) |word| free_count += @popCount(word);
    return MAX_STACKS - free_count;
}
