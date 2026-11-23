//! Host tests for the deterministic part of the kernel's random-number
//! generator (`src/kernel/random_core.zig`).

const std = @import("std");
const core = @import("random_core");
const expect = std.testing.expect;

fn seedOf(byte: u8) [core.SEED_LENGTH]u8 {
    return @splat(byte);
}

test "the same seed gives the same output" {
    var a = core.Generator.init(seedOf(1));
    var b = core.Generator.init(seedOf(1));
    var out_a: [200]u8 = undefined;
    var out_b: [200]u8 = undefined;
    a.fill(&out_a);
    b.fill(&out_b);
    try std.testing.expectEqualSlices(u8, &out_a, &out_b);
}

test "seeds that differ in one bit give unrelated output" {
    var seed = seedOf(0);
    var a = core.Generator.init(seed);
    seed[31] ^= 0x80;
    var b = core.Generator.init(seed);
    var out_a: [256]u8 = undefined;
    var out_b: [256]u8 = undefined;
    a.fill(&out_a);
    b.fill(&out_b);
    // About half of the 2048 bits differ.
    var differing: usize = 0;
    for (out_a, out_b) |x, y| differing += @popCount(x ^ y);
    try expect(differing > 900 and differing < 1150);
}

test "output does not repeat" {
    var g = core.Generator.init(seedOf(7));
    var first: [64]u8 = undefined;
    var second: [64]u8 = undefined;
    g.fill(&first);
    g.fill(&second);
    try expect(!std.mem.eql(u8, &first, &second));
    try std.testing.expectEqual(@as(u64, 128), g.produced);
}

test "filling in pieces gives the same stream as filling at once" {
    var whole = core.Generator.init(seedOf(9));
    var pieces = core.Generator.init(seedOf(9));
    var a: [300]u8 = undefined;
    var b: [300]u8 = undefined;
    whole.fill(&a);
    var at: usize = 0;
    for ([_]usize{ 1, 7, 64, 100, 128 }) |n| {
        pieces.fill(b[at..][0..n]);
        at += n;
    }
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "mixing changes the output, and depends on every byte mixed in" {
    var plain = core.Generator.init(seedOf(3));
    var mixed = core.Generator.init(seedOf(3));
    var other = core.Generator.init(seedOf(3));
    var input: [100]u8 = @splat(0x55);
    mixed.mix(&input);
    input[99] ^= 1; // the last byte, in a partial block
    other.mix(&input);
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    var c: [64]u8 = undefined;
    plain.fill(&a);
    mixed.fill(&b);
    other.fill(&c);
    try expect(!std.mem.eql(u8, &a, &b));
    try expect(!std.mem.eql(u8, &b, &c));
    try std.testing.expectEqual(@as(u64, 64), mixed.produced); // counted from the mix
}

test "a known input cannot make the output known" {
    // Two generators with different secrets are given the same public
    // input: they still disagree.
    var a = core.Generator.init(seedOf(1));
    var b = core.Generator.init(seedOf(2));
    const public: [64]u8 = @splat(0xAB);
    a.mix(&public);
    b.mix(&public);
    var out_a: [64]u8 = undefined;
    var out_b: [64]u8 = undefined;
    a.fill(&out_a);
    b.fill(&out_b);
    try expect(!std.mem.eql(u8, &out_a, &out_b));
}

test "an all-zero seed still gives balanced output" {
    var g = core.Generator.init(seedOf(0));
    var out: [8192]u8 = undefined;
    g.fill(&out);
    var ones: usize = 0;
    for (out) |byte| ones += @popCount(byte);
    // 65536 bits: expect 32768, standard deviation 128.
    try expect(ones > 32768 - 1000 and ones < 32768 + 1000);
    // Every byte value turns up.
    var seen: [256]bool = @splat(false);
    for (out) |byte| seen[byte] = true;
    try expect(std.mem.allEqual(bool, &seen, true));
}
