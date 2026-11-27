const std = @import("std");
const cpuinfo = @import("cpuinfo");

fn regs(s: *const [16]u8) cpuinfo.Leaf {
    return .{
        .eax = std.mem.readInt(u32, s[0..4], .little),
        .ebx = std.mem.readInt(u32, s[4..8], .little),
        .ecx = std.mem.readInt(u32, s[8..12], .little),
        .edx = std.mem.readInt(u32, s[12..16], .little),
    };
}

test "family, model and stepping as Linux works them out" {
    // An Intel Core of family 6 with an extended model: 0x000906EA is
    // family 6, model 158, stepping 10.
    const a = cpuinfo.signature(0x000906EA);
    try std.testing.expectEqual(@as(u32, 6), a.family);
    try std.testing.expectEqual(@as(u32, 158), a.model);
    try std.testing.expectEqual(@as(u32, 10), a.stepping);
    // AMD Zen 2: 0x00830F10 is family 23 (15 + 8), model 49.
    const b = cpuinfo.signature(0x00830F10);
    try std.testing.expectEqual(@as(u32, 23), b.family);
    try std.testing.expectEqual(@as(u32, 49), b.model);
    // Below family 6 the extended model is not used.
    try std.testing.expectEqual(@as(u32, 2), cpuinfo.signature(0x000F0520).model & 0xF);
    try std.testing.expectEqual(@as(u32, 2), cpuinfo.signature(0x00010520).model);
}

test "one block per CPU, with vendor, name and Linux's flag names" {
    var leaves: cpuinfo.Leaves = .{
        // "GenuineIntel": ebx, edx, ecx.
        .l0 = .{ .eax = 0x16, .ebx = 0x756e6547, .edx = 0x49656e69, .ecx = 0x6c65746e },
        .l1 = .{ .eax = 0x000906EA, .edx = (1 << 0) | (1 << 25) | (1 << 26), .ecx = (1 << 20) | (1 << 28) },
        .l7 = .{ .ebx = (1 << 5) | (1 << 18) },
        .e1 = .{ .edx = 1 << 29 },
    };
    const name = "  Test CPU @ 3.00GHz\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    for (&leaves.brand, 0..) |*b, i| b.* = regs(name[i * 16 ..][0..16]);
    const cpus = [_]cpuinfo.Cpu{ .{ .number = 0, .apic_id = 0 }, .{ .number = 1, .apic_id = 2 } };
    const text = try cpuinfo.format(std.testing.allocator, leaves, &cpus, 2_995_200_000);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "processor\t: "));
    try std.testing.expect(std.mem.indexOf(u8, text, "processor\t: 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "vendor_id\t: GenuineIntel\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "model name\t: Test CPU @ 3.00GHz\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cpu family\t: 6\nmodel\t\t: 158\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cpu MHz\t\t: 2995.200\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "apicid\t\t: 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "siblings\t: 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "flags\t\t: fpu sse sse2 lm sse4_2 avx avx2 rdseed\n") != null);
    // Blocks end in an empty line, as Linux's do.
    try std.testing.expect(std.mem.endsWith(u8, text, "\n\n"));
}

test "no clock rate when the TSC gives none, and no name when there is none" {
    const cpus = [_]cpuinfo.Cpu{.{ .number = 0, .apic_id = 0 }};
    const text = try cpuinfo.format(std.testing.allocator, .{}, &cpus, 0);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "cpu MHz") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "model name\t: unknown\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "flags\t\t: \n") != null);
}

test "the CPU lists of /sys/devices/system/cpu" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0\n", cpuinfo.rangeList(&buf, 1));
    try std.testing.expectEqualStrings("0-3\n", cpuinfo.rangeList(&buf, 4));
}

test "a cache from cpuid's cache leaf, and its size as /sys says it" {
    // A 32 KiB data cache of level 1: 64-byte lines, 8 ways, 64 sets.
    const l1d = cpuinfo.cacheFromLeaf(.{ .eax = 0x21, .ebx = (7 << 22) | 63, .ecx = 63 }).?;
    try std.testing.expectEqual(@as(u32, 1), l1d.level);
    try std.testing.expectEqual(.data, l1d.kind);
    try std.testing.expectEqual(@as(u64, 32 * 1024), l1d.size);
    // A 32 MiB unified level 3: 64-byte lines, 16 ways, 32768 sets.
    const l3 = cpuinfo.cacheFromLeaf(.{ .eax = 0x63, .ebx = (15 << 22) | 63, .ecx = 32767 }).?;
    try std.testing.expectEqual(@as(u32, 3), l3.level);
    try std.testing.expectEqual(.unified, l3.kind);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("32768K\n", cpuinfo.cacheSizeText(&buf, l3.size));
    try std.testing.expectEqual(@as(?cpuinfo.Cache, null), cpuinfo.cacheFromLeaf(.{ .eax = 0 }));
}
