//! `/test/alloc`: the program heap of the user library (`lib.allocator`,
//! `app/alloc.zig`) under the standard library's containers: a list that
//! grows, a hash map, strings made and thrown away, and a large block
//! whose pages go back to the kernel when it is freed.
//!
//! Exits with 0, or with the number of the first failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}

fn expect(ok: bool, check: u64) void {
    if (!ok) lib.exit(check);
}

pub fn main() noreturn {
    const a = lib.allocator;

    // A list that grows by reallocation, from a few bytes to a megabyte.
    var list: std.ArrayList(u64) = .empty;
    for (0..150_000) |i| list.append(a, i * i) catch lib.exit(1);
    for (list.items, 0..) |v, i| expect(v == i * i, 2);

    // A hash map with a few thousand entries, half of them removed again.
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (0..4000) |i| map.put(a, @intCast(i), @intCast(i + 7)) catch lib.exit(3);
    for (0..4000) |i| {
        if (i % 2 == 0) expect(map.remove(@intCast(i)), 4);
    }
    expect(map.count() == 2000 and map.get(1001).? == 1008 and map.get(1000) == null, 5);

    // Many small strings: what is freed is used again, so the heap stays
    // where it is. A block freed last is the next one given.
    const first = a.alloc(u8, 100) catch lib.exit(6);
    a.free(first);
    for (0..50_000) |i| {
        const s = std.fmt.allocPrint(a, "string number {d}", .{i}) catch lib.exit(7);
        expect(std.mem.startsWith(u8, s, "string number "), 8);
        a.free(s);
    }
    const again = a.alloc(u8, 100) catch lib.exit(9);
    expect(again.ptr == first.ptr, 10);

    // A large block has pages of its own: freed, they are unmapped, which
    // `mprotect` shows (it fails for memory that is not there).
    const big = a.alloc(u8, 8 << 20) catch lib.exit(11);
    @memset(big, 0x5A);
    expect(big[big.len - 1] == 0x5A and @intFromPtr(big.ptr) % 4096 == 0, 12);
    const at = @intFromPtr(big.ptr);
    expect(lib.mprotect(at, 4096, lib.abi.PROT.READ | lib.abi.PROT.WRITE) == 0, 13);
    a.free(big);
    expect(lib.mprotect(at, 4096, lib.abi.PROT.READ) == lib.err(.NOMEM), 14);

    // More than an address space holds: an error to handle, not a crash.
    // (Less than that is granted, since memory is only there once it is
    // touched; a program that then touches all of it meets its limit.)
    expect(a.alloc(u8, 1 << 48) == error.OutOfMemory, 15);

    list.deinit(a);
    map.deinit(a);
    lib.exit(0);
}
