//! Host tests for the rule that decides whether a CPU is affected by
//! Meltdown (`src/arch/x86_64/meltdown_rule.zig`).

const std = @import("std");
const rule = @import("meltdown_rule");
const expect = std.testing.expect;

fn cpu(vendor: *const [12]u8, family: u32, model: u32, caps: u64) rule.CpuInfo {
    return .{ .vendor = vendor.*, .family = family, .model = model, .arch_capabilities = caps };
}

const RDCL_NO = 1;

test "Intel processors without RDCL_NO are affected" {
    try expect(rule.affected(cpu("GenuineIntel", 6, 0x3C, 0))); // Haswell
    try expect(rule.affected(cpu("GenuineIntel", 6, 0x5E, 0))); // Skylake
    try expect(rule.affected(cpu("GenuineIntel", 6, 0x9E, 0))); // Kaby Lake
    try expect(rule.affected(cpu("GenuineIntel", 6, 0x2A, 0))); // Sandy Bridge
    try expect(rule.affected(cpu("GenuineIntel", 15, 0x06, 0))); // Pentium 4
    // Other capability bits do not help.
    try expect(rule.affected(cpu("GenuineIntel", 6, 0x5E, 0xFFFF_FFFE)));
}

test "a CPU that reports RDCL_NO is not affected, whoever made it" {
    try expect(!rule.affected(cpu("GenuineIntel", 6, 0x8C, RDCL_NO))); // Tiger Lake
    try expect(!rule.affected(cpu("GenuineIntel", 6, 0x55, RDCL_NO | 0x28))); // Cascade Lake
    try expect(!rule.affected(cpu("SomethingNew", 1, 1, RDCL_NO)));
}

test "AMD and Hygon processors are not affected" {
    try expect(!rule.affected(cpu("AuthenticAMD", 0x17, 0x01, 0))); // Zen
    try expect(!rule.affected(cpu("AuthenticAMD", 0x19, 0x21, 0))); // Zen 3
    try expect(!rule.affected(cpu("AuthenticAMD", 6, 6, 0))); // what QEMU's emulated CPU reports
    try expect(!rule.affected(cpu("HygonGenuine", 0x18, 0x00, 0)));
}

test "in-order Atoms and pre-P6 Intel processors are not affected" {
    for ([_]u32{ 0x1C, 0x26, 0x27, 0x35, 0x36 }) |model| {
        try expect(!rule.affected(cpu("GenuineIntel", 6, model, 0)));
    }
    try expect(!rule.affected(cpu("GenuineIntel", 5, 0x04, 0))); // Pentium MMX
    // The same model numbers in another family mean nothing.
    try expect(rule.affected(cpu("GenuineIntel", 15, 0x1C, 0)));
    // Out-of-order Atoms are affected.
    try expect(rule.affected(cpu("GenuineIntel", 6, 0x37, 0))); // Silvermont
}

test "Centaur and Zhaoxin: only family 7 is known to be safe" {
    try expect(!rule.affected(cpu("CentaurHauls", 7, 0x1B, 0)));
    try expect(!rule.affected(cpu("  Shanghai  ", 7, 0x3B, 0)));
    try expect(rule.affected(cpu("CentaurHauls", 6, 0x0F, 0)));
}

test "an unknown vendor counts as affected" {
    try expect(rule.affected(cpu("UnknownVendr", 6, 1, 0)));
    try expect(rule.affected(cpu("\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 0, 0, 0)));
}

test "family and model are combined from the base and extended fields" {
    // Skylake: family 6, extended model 5, model E.
    const skylake = rule.familyModel(0x000506E3);
    try std.testing.expectEqual(@as(u32, 6), skylake.family);
    try std.testing.expectEqual(@as(u32, 0x5E), skylake.model);
    // Zen 3: base family F plus extended family A, extended model 2, model 1.
    const zen3 = rule.familyModel(0x00A20F12);
    try std.testing.expectEqual(@as(u32, 0x19), zen3.family);
    try std.testing.expectEqual(@as(u32, 0x21), zen3.model);
    // Family 5: the extended model field is not used.
    const pentium = rule.familyModel(0x000F0543);
    try std.testing.expectEqual(@as(u32, 5), pentium.family);
    try std.testing.expectEqual(@as(u32, 4), pentium.model);
}
