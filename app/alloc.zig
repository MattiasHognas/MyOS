//! A small memory allocator for MyOS's own programs, on top of `mmap`.
//!
//! `Allocator(Pages)` gives a `std.mem.Allocator`, so the standard
//! library's containers work with it. Requests of up to 2048 bytes are
//! rounded up to a power of two (16 at least) and served from a list of
//! free blocks of that size, which is filled 64 KiB at a time; a freed
//! block goes back on its list and is the next one handed out. Larger
//! requests get pages of their own, which go back to the system when
//! they are freed.
//!
//! What it does not do: the memory behind the small blocks is kept until
//! the program ends, and blocks of one size are never joined into a
//! larger one. For one thread only: a program with threads puts a lock
//! around it.
//!
//! `Pages` says where pages come from (`map`, `unmap`), which is `mmap`
//! in a program (`lib.allocator`) and the host's allocator in the host
//! tests.

const std = @import("std");

const PAGE = 4096;
/// Smallest and largest block served from the lists.
const MIN_BLOCK = 16;
const MAX_BLOCK = 2048;
const CLASSES = std.math.log2(MAX_BLOCK) - std.math.log2(MIN_BLOCK) + 1;
/// How much is taken from the system when a list is empty.
const CHUNK = 64 * 1024;

pub fn Allocator(comptime Pages: type) type {
    return struct {
        /// The first free block of each size; a free block's first word
        /// points to the next.
        lists: [CLASSES]?*Block = @splat(null),

        const Self = @This();
        const Block = struct { next: ?*Block };

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }

        /// The list a request of `len` bytes aligned to `alignment` is
        /// served from, or null if it gets pages of its own.
        fn classOf(len: usize, alignment: std.mem.Alignment) ?usize {
            // A block of 2^n bytes starts at a multiple of 2^n, so the
            // alignment is met by a block at least as large as it.
            const need = @max(len, alignment.toByteUnits(), MIN_BLOCK);
            if (need > MAX_BLOCK) return null;
            return std.math.log2_int_ceil(usize, need) - std.math.log2(MIN_BLOCK);
        }

        fn blockSize(class: usize) usize {
            return @as(usize, MIN_BLOCK) << @intCast(class);
        }

        fn pagesFor(len: usize) usize {
            return std.mem.alignForward(usize, len, PAGE);
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const class = classOf(len, alignment) orelse {
                // Pages are aligned to a page; more than that is not offered.
                if (alignment.toByteUnits() > PAGE) return null;
                return Pages.map(pagesFor(len));
            };
            if (self.lists[class] == null) {
                // Cut a chunk into blocks of this size, the first one first.
                const chunk = Pages.map(CHUNK) orelse return null;
                const size = blockSize(class);
                var at: usize = CHUNK;
                while (at != 0) {
                    at -= size;
                    const block: *Block = @ptrCast(@alignCast(chunk + at));
                    block.next = self.lists[class];
                    self.lists[class] = block;
                }
            }
            const block = self.lists[class].?;
            self.lists[class] = block.next;
            return @ptrCast(block);
        }

        /// Whether `memory` can become `new_len` bytes where it is: within
        /// its block, or for pages of its own within the same pages or
        /// fewer (the rest goes back to the system).
        fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) bool {
            const old = classOf(memory.len, alignment);
            const new = classOf(new_len, alignment);
            if (old != null or new != null) return old == new;
            const have = pagesFor(memory.len);
            const want = pagesFor(new_len);
            if (want > have) return false;
            if (want < have) Pages.unmap(memory.ptr + want, have - want);
            return true;
        }

        fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            // Never moved here: the caller allocates anew and copies.
            return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
        }

        fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const class = classOf(memory.len, alignment) orelse return Pages.unmap(memory.ptr, pagesFor(memory.len));
            const block: *Block = @ptrCast(@alignCast(memory.ptr));
            block.next = self.lists[class];
            self.lists[class] = block;
        }
    };
}
