//! Kernel heap, exposed as a `std.mem.Allocator`.
//!
//! The heap lives in its own 1 GiB virtual region and grows on demand by
//! mapping pages from the PMM. All sizes are rounded up to 16 bytes, which
//! is also the maximum supported alignment; use the PMM directly for
//! page-aligned memory. Safe to use from threads and interrupt handlers.
//!
//! **Small blocks** (up to `SMALL_MAX` bytes) come in size classes, as in
//! Bonwick's magazines and Linux's slab caches. Each CPU keeps a short
//! stack of free blocks of every class (`MAG_SIZE`), under a lock of its
//! own that other CPUs take only when memory runs out, so most allocations
//! and frees touch no shared lock. Behind them, blocks of a class are cut
//! from 32 KiB slabs, aligned to their size, so a block's slab is found
//! from its address; a slab whose blocks are all free again goes back to
//! the general free list (one is kept per class, against back and forth).
//!
//! **Large blocks** and slabs come from a first-fit list of free chunks,
//! sorted by address and merged with their neighbours when freed, under
//! the heap lock.
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
const panicFmt = @import("debug/panic.zig").panicFmt;
const SpinLock = @import("sync/spinlock.zig").SpinLock;
const percpu = @import("../arch/x86_64/percpu.zig");

const log = std.log.scoped(.heap);
// Below this: HHDM (covers up to 16 TiB of RAM). Above: kernel image.
const HEAP_START: usize = 0xFFFF_9000_0000_0000;
const HEAP_MAX: usize = 1 << 30; // 1 GiB of virtual space
const MIN = 16; // granularity + max supported alignment

/// The size classes of small blocks.
const CLASS_SIZES = [_]u16{ 16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048 };
const CLASSES = CLASS_SIZES.len;
/// The largest small block.
pub const SMALL_MAX: usize = CLASS_SIZES[CLASSES - 1];
/// The class of every rounded size up to `SMALL_MAX`, by size / 16.
const class_of: [SMALL_MAX / MIN + 1]u8 = blk: {
    var t: [SMALL_MAX / MIN + 1]u8 = undefined;
    var c: u8 = 0;
    for (&t, 0..) |*e, i| {
        while (CLASS_SIZES[c] < i * MIN) c += 1;
        e.* = c;
    }
    break :blk t;
};

fn classOf(n: usize) usize {
    return class_of[n / MIN];
}

/// Size and alignment of a slab.
const SLAB_SIZE = 32 * 1024;
/// Free blocks a CPU keeps per class at most, and how many move between
/// it and the slabs at a time.
pub const MAG_SIZE = 16;
const MAG_BATCH = 8;

/// The start of a slab.
const Slab = struct {
    class: u8,
    /// Blocks on `free`, and blocks the slab has.
    free_count: u32,
    total: u32,
    free: ?*FreeBlock,
    /// In its class's list of slabs with free blocks while `free_count > 0`.
    prev: ?*Slab = null,
    next: ?*Slab = null,
};
const FreeBlock = struct { next: ?*FreeBlock };
const SLAB_FIRST = std.mem.alignForward(usize, @sizeOf(Slab), MIN);

/// Per class: slabs with free blocks, and how many. Under the heap lock.
var partial: [CLASSES]?*Slab = @splat(null);
var partial_count: [CLASSES]usize = @splat(0);

/// One CPU's free blocks.
const Cache = struct {
    lock: SpinLock = .{ .rank = .heap_cache },
    len: [CLASSES]u8 = @splat(0),
    blocks: [CLASSES][MAG_SIZE]usize = undefined,
};
/// Each CPU's, by CPU number, made on its first use.
var caches: [percpu.MAX_CPUS]?*Cache = @splat(null);

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

/// Protects the free list, the slabs, the end of the heap and `bytes_mapped`.
var lock: SpinLock = .{ .rank = .kernel_region };
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

/// Return a snapshot of the heap usage counters. (Each counter is read
/// atomically; together they are exact while nothing allocates.)
pub fn stats() Stats {
    const held = lock.acquire();
    defer lock.release(held);
    return .{
        .allocs = @atomicLoad(usize, &counters.allocs, .monotonic),
        .frees = @atomicLoad(usize, &counters.frees, .monotonic),
        .bytes_in_use = @atomicLoad(usize, &counters.bytes_in_use, .monotonic),
        .peak_bytes = @atomicLoad(usize, &counters.peak_bytes, .monotonic),
        .bytes_mapped = counters.bytes_mapped,
    };
}

/// Count an allocation of `n` bytes, and update the peak.
fn addInUse(n: usize) void {
    _ = @atomicRmw(usize, &counters.allocs, .Add, 1, .monotonic);
    const now = @atomicRmw(usize, &counters.bytes_in_use, .Add, n, .monotonic) + n;
    _ = @atomicRmw(usize, &counters.peak_bytes, .Max, now, .monotonic);
}

/// Count a free of `n` bytes.
fn subInUse(n: usize) void {
    const old = @atomicRmw(usize, &counters.bytes_in_use, .Sub, n, .monotonic);
    assert.check(.heap, n <= old, "freeing {d} bytes but only {d} in use", .{ n, old });
}

/// Round `n` up to a multiple of `MIN` (and at least `MIN`), so every chunk can hold a `Chunk` header.
fn round(n: usize) usize {
    return std.mem.alignForward(usize, @max(n, MIN), MIN);
}

/// True if free heap memory is filled with `POISON` and checked when it is
/// handed out again (`-Dpoison`).
pub const poison = build_options.poison;
/// The byte free heap memory is filled with.
pub const POISON: u8 = 0xDD;

/// Fill `len` bytes at `addr` with the poison byte.
fn poisonRange(addr: usize, len: usize) void {
    @memset(@as([*]u8, @ptrFromInt(addr))[0..len], POISON);
}

/// With poisoning on, check that the `size` bytes of free memory at `addr`
/// still hold the poison byte after their `Chunk` header. If not, something
/// wrote to the memory after it was freed: panic, naming the first byte.
fn checkPoison(addr: usize, size: usize) void {
    if (!poison or size <= @sizeOf(Chunk)) return;
    const bytes = @as([*]const u8, @ptrFromInt(addr))[0..size];
    for (bytes[@sizeOf(Chunk)..], @sizeOf(Chunk)..) |b, i| {
        if (b != POISON) panicFmt("heap: freed memory at 0x{x} was written to (0x{x} at offset {d} of a {d}-byte block)", .{ addr + i, b, i, size });
    }
}

/// Return `size` bytes at `addr` to the free list, keeping it sorted by
/// address and merging with adjacent free chunks. The range must not overlap
/// any free chunk. Callers must have interrupts disabled.
///
/// With poisoning on, everything in a free chunk after its header holds the
/// poison byte: the range is filled here, and so are the headers that
/// disappear when chunks merge.
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

    if (poison) poisonRange(addr, size);
    const new: *Chunk = @ptrFromInt(addr);
    new.* = .{ .size = size, .next = cur };

    if (cur) |c| { // merge with the following chunk
        if (addr + size == @intFromPtr(c)) {
            new.size += c.size;
            new.next = c.next;
            if (poison) poisonRange(@intFromPtr(c), @sizeOf(Chunk)); // its header is inside the chunk now
        }
    }
    if (prev) |p| { // merge with the preceding chunk
        if (@intFromPtr(p) + p.size == addr) {
            p.size += new.size;
            p.next = new.next;
            if (poison) poisonRange(addr, @sizeOf(Chunk));
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

/// Take `n` bytes, aligned to `alignment`, from the first free chunk with
/// room for them, growing the heap if none has. Null when out of memory.
/// The heap lock must be held.
fn takeChunk(n: usize, alignment: usize) ?usize {
    while (true) {
        var prev: ?*Chunk = null;
        var cur = free_list;
        while (cur) |c| : ({
            prev = c;
            cur = c.next;
        }) {
            const at = @intFromPtr(c);
            const start = std.mem.alignForward(usize, at, alignment);
            if (start + n > at + c.size) continue;
            checkPoison(start, n); // the part about to be handed out
            const end = at + c.size;
            const next = c.next;
            // Take the chunk off the list, and give the parts around the
            // block back (always multiples of 16).
            if (prev) |p| p.next = next else free_list = next;
            if (start > at) insertFree(at, start - at);
            if (end > start + n) insertFree(start + n, end - start - n);
            return start;
        }
        if (!grow(n + alignment)) return null;
    }
}

/// `Allocator.alloc` implementation. Returns null when out of memory.
/// Panics if `alignment` is larger than 16 bytes.
fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (alignment.toByteUnits() > MIN) @panic("heap: alignment > 16 unsupported; use pmm for pages");
    const n = round(len);
    const addr = if (n <= SMALL_MAX) allocSmall(classOf(n)) else allocLarge(n);
    const a = addr orelse {
        if (build_options.alloc_debug) log.debug("alloc {d} bytes failed: out of memory", .{len});
        return null; // -> error.OutOfMemory
    };
    addInUse(blockSize(n));
    if (build_options.alloc_debug) log.debug("alloc {d} bytes -> 0x{x}", .{ len, a });
    return @ptrFromInt(a);
}

/// What a block of `n` rounded bytes really takes.
fn blockSize(n: usize) usize {
    return if (n <= SMALL_MAX) CLASS_SIZES[classOf(n)] else n;
}

fn allocLarge(n: usize) ?usize {
    const held = lock.acquire();
    defer lock.release(held);
    if (takeChunk(n, MIN)) |a| return a;
    lock.drop();
    reclaim();
    lock.take();
    return takeChunk(n, MIN);
}

fn allocSmall(class: usize) ?usize {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const c = ownCache() orelse {
        // This early in boot: no CPU numbers yet, so no cache.
        lock.take();
        defer lock.drop();
        var one: [1]usize = undefined;
        if (refill(class, &one, 1) == 0) return null;
        checkPoison(one[0], CLASS_SIZES[class]);
        return one[0];
    };
    for (0..2) |attempt| {
        c.lock.take();
        if (c.len[class] == 0) {
            lock.take();
            c.len[class] = @intCast(refill(class, &c.blocks[class], MAG_BATCH));
            lock.drop();
        }
        if (c.len[class] > 0) {
            c.len[class] -= 1;
            const a = c.blocks[class][c.len[class]];
            c.lock.drop();
            checkPoison(a, CLASS_SIZES[class]);
            return a;
        }
        c.lock.drop();
        if (attempt == 0) reclaim(); // out of memory: what the CPUs keep, back first
    }
    return null;
}

/// Put up to `want` free blocks of `class` in `out`, from slabs with free
/// blocks or a new slab. Returns how many. The heap lock must be held.
fn refill(class: usize, out: []usize, want: usize) usize {
    var got: usize = 0;
    while (got < want) {
        const slab = partial[class] orelse newSlab(class) orelse break;
        const b = slab.free.?;
        slab.free = b.next;
        slab.free_count -= 1;
        if (slab.free_count == 0) unlinkSlab(slab);
        out[got] = @intFromPtr(b);
        got += 1;
    }
    return got;
}

/// A new slab for `class`, in the list of slabs with free blocks; null when
/// out of memory. The heap lock must be held.
fn newSlab(class: usize) ?*Slab {
    const at = takeChunk(SLAB_SIZE, SLAB_SIZE) orelse return null;
    if (poison) poisonRange(at, SLAB_SIZE);
    const size = CLASS_SIZES[class];
    const slab: *Slab = @ptrFromInt(at);
    const total = (SLAB_SIZE - SLAB_FIRST) / size;
    slab.* = .{ .class = @intCast(class), .free_count = @intCast(total), .total = @intCast(total), .free = null };
    var i = total;
    while (i > 0) {
        i -= 1;
        const b: *FreeBlock = @ptrFromInt(at + SLAB_FIRST + i * size);
        b.* = .{ .next = slab.free };
        slab.free = b;
    }
    linkSlab(slab);
    return slab;
}

fn linkSlab(slab: *Slab) void {
    const class = slab.class;
    slab.prev = null;
    slab.next = partial[class];
    if (partial[class]) |n| n.prev = slab;
    partial[class] = slab;
    partial_count[class] += 1;
}

fn unlinkSlab(slab: *Slab) void {
    const class = slab.class;
    if (slab.prev) |p| p.next = slab.next else partial[class] = slab.next;
    if (slab.next) |n| n.prev = slab.prev;
    slab.prev = null;
    slab.next = null;
    partial_count[class] -= 1;
}

/// Give free blocks back to their slabs; a slab that is all free goes back
/// to the free list, unless it is the last of its class with free blocks.
/// The heap lock must be held.
fn release(blocks: []const usize) void {
    for (blocks) |a| {
        const slab: *Slab = @ptrFromInt(a & ~@as(usize, SLAB_SIZE - 1));
        assert.check(.heap, slab.free_count < slab.total, "heap: block 0x{x} freed into a slab with every block free (double free?)", .{a});
        const b: *FreeBlock = @ptrFromInt(a);
        b.* = .{ .next = slab.free };
        slab.free = b;
        slab.free_count += 1;
        if (slab.free_count == 1) linkSlab(slab);
        if (slab.free_count == slab.total and partial_count[slab.class] > 1) {
            unlinkSlab(slab);
            insertFree(@intFromPtr(slab), SLAB_SIZE);
        }
    }
}

/// Give every CPU's free blocks back, so that slabs all free return to the
/// free list: when memory runs out. No lock may be held.
fn reclaim() void {
    for (0..percpu.count()) |n| {
        const c = caches[n] orelse continue;
        const held = c.lock.acquire();
        defer c.lock.release(held);
        lock.take();
        defer lock.drop();
        for (0..CLASSES) |class| {
            release(c.blocks[class][0..c.len[class]]);
            c.len[class] = 0;
        }
    }
}

/// This CPU's cache, made if it has none yet; null this early in boot
/// that CPUs have no numbers, or if there is no memory for it. Interrupts
/// must be off.
fn ownCache() ?*Cache {
    const me = percpu.currentIfReady() orelse return null;
    if (caches[me.id]) |c| return c;
    lock.take();
    const at = takeChunk(round(@sizeOf(Cache)), MIN);
    lock.drop();
    const c: *Cache = @ptrFromInt(at orelse return null);
    c.* = .{};
    caches[me.id] = c;
    return c;
}

/// Make the running CPU's cache now, when it comes up (see `pmm.initCpu`).
pub fn initCpu() void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    _ = ownCache();
}

fn freeSmall(a: usize, class: usize) void {
    if (poison) poisonRange(a, CLASS_SIZES[class]);
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const c = ownCache() orelse {
        lock.take();
        defer lock.drop();
        release(&.{a});
        return;
    };
    c.lock.take();
    defer c.lock.drop();
    const mag = c.blocks[class][0..c.len[class]];
    if (assert.enabled) {
        for (mag) |other| assert.check(.heap, other != a, "heap: double free of 0x{x} (a {d}-byte block)", .{ a, CLASS_SIZES[class] });
    }
    if (c.len[class] == MAG_SIZE) {
        // Full: the oldest half goes back to the slabs.
        lock.take();
        release(c.blocks[class][0..MAG_BATCH]);
        lock.drop();
        std.mem.copyForwards(usize, c.blocks[class][0 .. MAG_SIZE - MAG_BATCH], c.blocks[class][MAG_BATCH..]);
        c.len[class] -= MAG_BATCH;
    }
    c.blocks[class][c.len[class]] = a;
    c.len[class] += 1;
}

/// `Allocator.resize` implementation: in place when the block stays in its
/// size class, or stays large and does not grow (the tail goes back to the
/// free list). Otherwise false, and the caller moves it.
fn resize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    const old = round(memory.len);
    const new = round(new_len);
    if (old <= SMALL_MAX or new <= SMALL_MAX) {
        return old <= SMALL_MAX and new <= SMALL_MAX and classOf(old) == classOf(new);
    }
    if (new > old) return false; // can't grow in place; caller reallocates
    if (new < old) {
        const held = lock.acquire();
        defer lock.release(held);
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

/// `Allocator.free` implementation. Heap pages are never unmapped or given
/// back to the PMM.
fn free(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    const n = round(memory.len);
    const a = @intFromPtr(memory.ptr);
    if (n <= SMALL_MAX) {
        freeSmall(a, classOf(n));
    } else {
        const held = lock.acquire();
        defer lock.release(held);
        insertFree(a, n);
    }
    _ = @atomicRmw(usize, &counters.frees, .Add, 1, .monotonic);
    subInUse(blockSize(n));
    if (build_options.alloc_debug) log.debug("free {d} bytes at 0x{x}", .{ memory.len, a });
}
