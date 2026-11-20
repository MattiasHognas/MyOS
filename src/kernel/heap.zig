const std = @import("std");
const pmm = @import("../kernel/pmm.zig");
const vmm = @import("../arch/x86_64/vmm.zig");
const cpu = @import("../arch/x86_64/cpu.zig");

// Below this: HHDM (covers up to 16 TiB of RAM). Above: kernel image.
const HEAP_START: usize = 0xFFFF_9000_0000_0000;
const HEAP_MAX: usize = 1 << 30; // 1 GiB of virtual space
const MIN = 16; // granularity + max supported alignment

const Chunk = struct { size: usize, next: ?*Chunk }; // lives inside free memory

var free_list: ?*Chunk = null; // sorted by address
var heap_end: usize = HEAP_START;

fn round(n: usize) usize {
    return std.mem.alignForward(usize, @max(n, MIN), MIN);
}

fn insertFree(addr: usize, size: usize) void {
    var prev: ?*Chunk = null;
    var cur = free_list;
    while (cur) |c| : (cur = c.next) {
        if (@intFromPtr(c) > addr) break;
        prev = c;
    }

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

// Map at least `min_bytes` more (minimum 64 KiB) at the end of the heap.
fn grow(min_bytes: usize) bool {
    const want = std.mem.alignForward(usize, @max(min_bytes, 16 * pmm.PAGE_SIZE), pmm.PAGE_SIZE);
    if (heap_end + want > HEAP_START + HEAP_MAX) return false;

    var got: usize = 0;
    while (got < want) : (got += pmm.PAGE_SIZE) {
        const phys = pmm.alloc() orelse break;
        vmm.map(vmm.kernel_root, heap_end + got, phys, vmm.WRITABLE | vmm.NX, false);
    }
    if (got == 0) return false;
    insertFree(heap_end, got);
    heap_end += got;
    return got >= min_bytes;
}

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
            return @ptrCast(c);
        }
        if (!grow(n)) return null; // -> error.OutOfMemory
    }
}

fn resize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const old = round(memory.len);
    const new = round(new_len);
    if (new > old) return false; // can't grow in place; caller reallocates
    if (new < old) insertFree(@intFromPtr(memory.ptr) + new, old - new);
    return true;
}

fn remap(ctx: *anyopaque, memory: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (resize(ctx, memory, a, new_len, ra)) memory.ptr else null;
}

fn free(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    insertFree(@intFromPtr(memory.ptr), round(memory.len));
}

const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

pub const allocator = std.mem.Allocator{ .ptr = undefined, .vtable = &vtable };
