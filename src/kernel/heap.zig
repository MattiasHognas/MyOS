//! Kernel heap: a first-fit free-list allocator exposed as a `std.mem.Allocator`.
//!
//! The heap lives in its own 1 GiB virtual region and grows on demand by
//! mapping pages from the PMM. Free chunks are kept in an address-sorted list
//! and merged with their neighbours when freed. All sizes are rounded up to 16
//! bytes, which is also the maximum supported alignment; use the PMM directly
//! for page-aligned memory. Every operation disables interrupts, so the heap
//! is safe to use from threads and interrupt handlers.
//!
//! Usage counters are always kept (see `stats`). Building with
//! `-Dalloc-debug=true` additionally logs every allocation and free at debug
//! level in the `heap` scope.

const std = @import("std");
const build_options = @import("build_options");

const cpu = @import("../arch/x86_64/cpu.zig");
const vmm = @import("../arch/x86_64/vmm.zig");
const pmm = @import("../kernel/pmm.zig");
const assert = @import("debug/assert.zig");

const log = std.log.scoped(.heap);
// Below this: HHDM (covers up to 16 TiB of RAM). Above: kernel image.
const HEAP_START: usize = 0xFFFF_9000_0000_0000;
const HEAP_MAX: usize = 1 << 30; // 1 GiB of virtual space
const MIN = 16; // granularity + max supported alignment

/// Header of a free chunk, stored inside the free memory itself.
const Chunk = struct { size: usize, next: ?*Chunk };

const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

/// The kernel heap allocator.
pub const allocator = std.mem.Allocator{ .ptr = undefined, .vtable = &vtable };

var free_list: ?*Chunk = null; // sorted by address
var heap_end: usize = HEAP_START;

/// Heap usage counters, as returned by `stats`. Byte counts include the
/// rounding of every block to 16 bytes.
pub const Stats = struct {
    /// Successful allocations since boot.
    allocs: usize = 0,
    /// Frees since boot.
    frees: usize = 0,
    /// Bytes currently handed out.
    bytes_in_use: usize = 0,
    /// Highest value `bytes_in_use` has reached.
    peak_bytes: usize = 0,
    /// Bytes of virtual memory mapped for the heap so far.
    bytes_mapped: usize = 0,
};

var counters: Stats = .{};

/// Return a snapshot of the heap usage counters.
pub fn stats() Stats {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    return counters;
}

/// Record `n` more bytes in use and update the peak.
fn addInUse(n: usize) void {
    counters.bytes_in_use += n;
    counters.peak_bytes = @max(counters.peak_bytes, counters.bytes_in_use);
}

/// Record `n` fewer bytes in use.
fn subInUse(n: usize) void {
    assert.check(.heap, n <= counters.bytes_in_use, "freeing {d} bytes but only {d} in use", .{ n, counters.bytes_in_use });
    counters.bytes_in_use -= n;
}

/// Round `n` up to a multiple of `MIN` (and at least `MIN`), so every chunk can hold a `Chunk` header.
fn round(n: usize) usize {
    return std.mem.alignForward(usize, @max(n, MIN), MIN);
}

/// Return `size` bytes at `addr` to the free list, keeping it sorted by
/// address and merging with adjacent free chunks. The range must not overlap
/// any free chunk. Callers must have interrupts disabled.
fn insertFree(addr: usize, size: usize) void {
    assert.check(.heap, addr % MIN == 0 and size % MIN == 0 and size >= MIN, "bad free range 0x{x}+{d}", .{ addr, size });
    assert.check(.heap, addr >= HEAP_START and addr + size <= heap_end, "free range 0x{x}+{d} outside the heap", .{ addr, size });
    var prev: ?*Chunk = null;
    var cur = free_list;
    while (cur) |c| : (cur = c.next) {
        if (@intFromPtr(c) > addr) break;
        prev = c;
    }

    if (cur) |c| assert.check(.heap, addr + size <= @intFromPtr(c), "free range 0x{x}+{d} overlaps a free chunk (double free?)", .{ addr, size });
    if (prev) |p| assert.check(.heap, @intFromPtr(p) + p.size <= addr, "free range 0x{x}+{d} overlaps a free chunk (double free?)", .{ addr, size });

    const new: *Chunk = @ptrFromInt(addr);
    new.* = .{ .size = size, .next = cur };

    if (cur) |c| { // merge with the following chunk
        if (addr + size == @intFromPtr(c)) {
            new.size += c.size;
            new.next = c.next;
        }
    }
    if (prev) |p| { // merge with the preceding chunk
        if (@intFromPtr(p) + p.size == addr) {
            p.size += new.size;
            p.next = new.next;
        } else p.next = new;
    } else free_list = new;
}

/// Map at least `min_bytes` more (minimum 64 KiB) at the end of the heap and
/// add it to the free list. Returns false if the heap region is exhausted or
/// fewer than `min_bytes` could be mapped. Callers must have interrupts disabled.
fn grow(min_bytes: usize) bool {
    const want = std.mem.alignForward(usize, @max(min_bytes, 16 * pmm.PAGE_SIZE), pmm.PAGE_SIZE);
    if (heap_end + want > HEAP_START + HEAP_MAX) return false;

    var got: usize = 0;
    while (got < want) : (got += pmm.PAGE_SIZE) {
        const phys = pmm.alloc() orelse break;
        vmm.map(vmm.kernel_root, heap_end + got, phys, vmm.WRITABLE | vmm.NX, false) catch {
            pmm.free(phys); // no page table for it: stop here
            break;
        };
    }
    if (got == 0) return false;
    heap_end += got;
    counters.bytes_mapped += got;
    insertFree(heap_end - got, got);
    return got >= min_bytes;
}

/// `Allocator.alloc` implementation: take the first free chunk that fits,
/// splitting off the remainder, and grow the heap if none does. Returns null
/// when out of memory. Panics if `alignment` is larger than 16 bytes.
fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);

    if (alignment.toByteUnits() > MIN) @panic("heap: alignment > 16 unsupported; use pmm for pages");
    const n = round(len);

    while (true) {
        var prev: ?*Chunk = null;
        var cur = free_list;
        while (cur) |c| : ({
            prev = c;
            cur = c.next;
        }) {
            if (c.size < n) continue;
            const rest = c.size - n; // always 0 or a multiple of 16
            const next: ?*Chunk = if (rest > 0) blk: {
                const r: *Chunk = @ptrFromInt(@intFromPtr(c) + n);
                r.* = .{ .size = rest, .next = c.next };
                break :blk r;
            } else c.next;
            if (prev) |p| p.next = next else free_list = next;
            counters.allocs += 1;
            addInUse(n);
            if (build_options.alloc_debug) log.debug("alloc {d} bytes -> 0x{x} (in use: {d})", .{ len, @intFromPtr(c), counters.bytes_in_use });
            return @ptrCast(c);
        }
        if (!grow(n)) {
            if (build_options.alloc_debug) log.debug("alloc {d} bytes failed: out of memory", .{len});
            return null; // -> error.OutOfMemory
        }
    }
}

/// `Allocator.resize` implementation: shrink `memory` in place to `new_len`,
/// returning the tail to the free list. Returns false if `new_len` needs more
/// space, since blocks never grow in place; the caller then reallocates.
fn resize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const old = round(memory.len);
    const new = round(new_len);
    if (new > old) return false; // can't grow in place; caller reallocates
    if (new < old) {
        insertFree(@intFromPtr(memory.ptr) + new, old - new);
        subInUse(old - new);
    }
    return true;
}

/// `Allocator.remap` implementation: same as `resize`, returning the
/// unchanged pointer on success or null if the block would have to move.
fn remap(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (resize(ctx, memory, a, new_len, ra)) memory.ptr else null;
}

/// `Allocator.free` implementation: return `memory` to the free list.
/// Heap pages are never unmapped or given back to the PMM.
fn free(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    insertFree(@intFromPtr(memory.ptr), round(memory.len));
    counters.frees += 1;
    subInUse(round(memory.len));
    if (build_options.alloc_debug) log.debug("free {d} bytes at 0x{x} (in use: {d})", .{ memory.len, @intFromPtr(memory.ptr), counters.bytes_in_use });
}
