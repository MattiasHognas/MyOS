//! Host unit tests for `src/kernel/user_range.zig`.

const std = @import("std");
const expect = std.testing.expect;

const user_range = @import("user_range");
const valid = user_range.valid;
const END = user_range.USER_END;

test "user range: ordinary user buffers are valid" {
    try expect(valid(0x40_0000, 4096));
    try expect(valid(0x1000, 1));
    try expect(valid(0, END)); // the whole user half
    try expect(valid(END - 1, 1)); // its last byte
}

test "user range: null is a user address (unmapped, so the copy faults)" {
    try expect(valid(0, 0));
    try expect(valid(0, 16));
}

test "user range: empty ranges" {
    try expect(valid(0x40_0000, 0));
    try expect(valid(END, 0)); // directly at the end
    try expect(!valid(END + 1, 0));
    try expect(!valid(0xFFFF_FFFF_8000_0000, 0));
}

test "user range: kernel and non-canonical addresses are rejected" {
    try expect(!valid(END, 1));
    try expect(!valid(0xFFFF_8000_0000_0000, 1)); // start of the kernel half
    try expect(!valid(0xFFFF_FFFF_8000_0000, 4)); // kernel image
    try expect(!valid(0x0000_8000_0000_0000, 8)); // first non-canonical address
    try expect(!valid(0x1234_5678_0000_0000, 8)); // non-canonical hole
    try expect(!valid(std.math.maxInt(u64), 1));
}

test "user range: ranges crossing the end of user space are rejected" {
    try expect(valid(END - 16, 16));
    try expect(!valid(END - 16, 17));
    try expect(!valid(END - 1, 2));
    try expect(!valid(0x40_0000, END)); // huge length
}

test "user range: address + length overflow is rejected" {
    const max = std.math.maxInt(u64);
    try expect(!valid(max - 3, 8)); // wraps to 4
    try expect(!valid(0x40_0000, max)); // wraps to 0x3f_ffff
    try expect(!valid(1, max)); // wraps to exactly 0
    try expect(!valid(max, max));
    try expect(!valid(0, max));
}
