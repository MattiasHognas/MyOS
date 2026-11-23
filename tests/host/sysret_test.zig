//! Host tests for the decision how a syscall returns to user mode
//! (`src/arch/x86_64/sysret.zig`).

const std = @import("std");

const sysret = @import("sysret");
const CS = sysret.USER_CS;
const SS = sysret.USER_SS;

const FLAGS: u64 = 0x202; // interrupts on, nothing else

test "an ordinary return uses sysretq" {
    try std.testing.expectEqual(.sysret, sysret.classify(0x40_1000, FLAGS, CS, SS));
    try std.testing.expectEqual(.sysret, sysret.classify(0, FLAGS, CS, SS)); // faults in ring 3, which is fine
    try std.testing.expectEqual(.sysret, sysret.classify(0x40_1000, FLAGS | 0xCD5 | (1 << 18) | (1 << 21), CS, SS));
}

test "the last user address is returnable, the first one beyond is not" {
    try std.testing.expectEqual(.sysret, sysret.classify(0x0000_7FFF_FFFF_FFFF, FLAGS, CS, SS));
    try std.testing.expectEqual(.invalid, sysret.classify(0x0000_8000_0000_0000, FLAGS, CS, SS));
}

test "non-canonical and kernel return addresses are invalid" {
    for ([_]u64{
        0x0000_8000_0000_0000, 0x0001_0000_0000_0000, 0x8000_0000_0000_0000,
        0xFFFF_7FFF_FFFF_FFFF, 0xFFFF_8000_0000_0000, 0xFFFF_FFFF_8000_0000,
        0xFFFF_FFFF_FFFF_FFFF,
    }) |rip| {
        try std.testing.expectEqual(.invalid, sysret.classify(rip, FLAGS, CS, SS));
        // ...whatever the flags say: iretq would fault on them too.
        try std.testing.expectEqual(.invalid, sysret.classify(rip, FLAGS | sysret.FLAG_TF, CS, SS));
    }
}

test "selectors other than ring 3's are invalid" {
    try std.testing.expectEqual(.invalid, sysret.classify(0x40_1000, FLAGS, 0x08, SS)); // kernel code
    try std.testing.expectEqual(.invalid, sysret.classify(0x40_1000, FLAGS, 0x20, SS)); // user code, RPL 0
    try std.testing.expectEqual(.invalid, sysret.classify(0x40_1000, FLAGS, CS, 0x10)); // kernel data
    try std.testing.expectEqual(.invalid, sysret.classify(0x40_1000, FLAGS, CS, 0));
    try std.testing.expectEqual(.invalid, sysret.classify(0x40_1000, FLAGS, SS, CS)); // swapped
}

test "TF and RF need iretq" {
    try std.testing.expectEqual(.iret, sysret.classify(0x40_1000, FLAGS | sysret.FLAG_TF, CS, SS));
    try std.testing.expectEqual(.iret, sysret.classify(0x40_1000, FLAGS | sysret.FLAG_RF, CS, SS));
    try std.testing.expectEqual(.iret, sysret.classify(0x40_1000, FLAGS | sysret.FLAG_RF | sysret.FLAG_TF, CS, SS));
}

test "sanitizeFlags keeps what a program may set" {
    const user_bits: u64 = 0x1 | 0x4 | 0x10 | 0x40 | 0x80 | 0x100 | 0x400 | 0x800 | (1 << 16) | (1 << 18) | (1 << 21);
    try std.testing.expectEqual(user_bits | 0x202, sysret.sanitizeFlags(user_bits));
    try std.testing.expectEqual(@as(u64, 0x202), sysret.sanitizeFlags(0x202));
}

test "sanitizeFlags forces interrupts on and drops privileged bits" {
    try std.testing.expectEqual(@as(u64, 0x202), sysret.sanitizeFlags(0)); // IF and bit 1
    try std.testing.expectEqual(@as(u64, 0x202), sysret.sanitizeFlags(0x3000)); // IOPL 3
    try std.testing.expectEqual(@as(u64, 0x202), sysret.sanitizeFlags(0x4000)); // NT
    try std.testing.expectEqual(@as(u64, 0x202), sysret.sanitizeFlags(1 << 17)); // VM
    try std.testing.expectEqual(@as(u64, 0x202), sysret.sanitizeFlags((1 << 19) | (1 << 20))); // VIF, VIP
    try std.testing.expectEqual(@as(u64, 0x202), sysret.sanitizeFlags(0xFFFF_FFFF_0000_0000 | 0x8028)); // reserved
    // Every bit at once: only the user-settable ones survive.
    const all = sysret.sanitizeFlags(~@as(u64, 0));
    try std.testing.expectEqual(sysret.USER_FLAGS | 0x202, all);
    try std.testing.expect(all & 0x3000 == 0 and all & 0x4000 == 0 and all & (1 << 17) == 0);
}

test "random states: sysretq is only chosen when it is safe" {
    var prng = std.Random.DefaultPrng.init(0x5359_5352_4554); // fixed seed
    const random = prng.random();
    for (0..100_000) |_| {
        // Mix arbitrary values with ones near the interesting boundaries.
        const rip = switch (random.uintLessThan(u8, 4)) {
            0 => random.int(u64),
            1 => random.int(u64) & 0x0000_7FFF_FFFF_FFFF,
            2 => 0x0000_8000_0000_0000 -% random.uintLessThan(u64, 4) +% random.uintLessThan(u64, 4),
            else => random.int(u64) | 0xFFFF_8000_0000_0000,
        };
        const flags = sysret.sanitizeFlags(random.int(u64));
        const cs = if (random.boolean()) CS else random.int(u64) & 0xFFFF;
        const ss = if (random.boolean()) SS else random.int(u64) & 0xFFFF;
        const how = sysret.classify(rip, flags, cs, ss);
        const returnable = rip < sysret.USER_END and cs == CS and ss == SS;
        try std.testing.expectEqual(!returnable, how == .invalid);
        if (how == .sysret) try std.testing.expect(flags & (sysret.FLAG_TF | sysret.FLAG_RF) == 0);
        // Whatever was asked for, the flags that get loaded are safe.
        try std.testing.expect(flags & sysret.FLAG_IF != 0 and flags & 0x3000 == 0 and flags & 0x4000 == 0);
    }
}
