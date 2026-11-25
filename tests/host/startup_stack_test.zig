//! Host tests for the initial stack of a program
//! (`src/kernel/startup_stack.zig`): the block is read back the way a C
//! library's startup code reads it.

const std = @import("std");
const startup_stack = @import("startup_stack");
const abi = @import("abi");
const AT = abi.AT;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const TOP: u64 = 0x7FFF_1234_5000;

fn sample(argv: []const []const u8, envp: []const []const u8) startup_stack.Args {
    return .{
        .argv = argv,
        .envp = envp,
        .execfn = "/bin/prog",
        .random = "0123456789abcdef".*,
        .phdr = 0x400040,
        .phent = 56,
        .phnum = 6,
        .entry = 0x401000,
        .hwcap = 0x178bfbff,
        .clktck = 100,
    };
}

/// The block as a program sees it: memory by address.
const View = struct {
    mem: []const u8,
    top: u64,

    fn word(v: View, addr: u64) u64 {
        const off: usize = @intCast(addr - (v.top - v.mem.len));
        return std.mem.readInt(u64, v.mem[off..][0..8], .little);
    }

    fn string(v: View, addr: u64) []const u8 {
        const off: usize = @intCast(addr - (v.top - v.mem.len));
        return std.mem.sliceTo(v.mem[off..], 0);
    }

    fn bytes(v: View, addr: u64, len: usize) []const u8 {
        const off: usize = @intCast(addr - (v.top - v.mem.len));
        return v.mem[off..][0..len];
    }

    /// The value for `key` in the auxiliary vector starting at `aux`.
    fn auxValue(v: View, aux: u64, key: u64) ?u64 {
        var at = aux;
        while (v.word(at) != AT.NULL) : (at += 16) {
            if (v.word(at) == key) return v.word(at + 8);
        }
        return null;
    }
};

test "arguments, environment and auxiliary vector read back as written" {
    var mem: [2048]u8 = @splat(0xAA);
    const argv = [_][]const u8{ "/bin/prog", "one", "two words", "" };
    const envp = [_][]const u8{ "HOME=/", "TERM=myos" };
    const rsp = try startup_stack.build(&mem, TOP, sample(&argv, &envp));
    const v = View{ .mem = &mem, .top = TOP };

    try expectEqual(0, rsp % 16);
    try expect(rsp >= TOP - mem.len and rsp < TOP);
    try expectEqual(argv.len, v.word(rsp));
    for (argv, 0..) |want, i| try expectEqualStrings(want, v.string(v.word(rsp + 8 + 8 * i)));
    try expectEqual(0, v.word(rsp + 8 + 8 * argv.len));
    const env_at = rsp + 8 + 8 * (argv.len + 1);
    for (envp, 0..) |want, i| try expectEqualStrings(want, v.string(v.word(env_at + 8 * i)));
    try expectEqual(0, v.word(env_at + 8 * envp.len));

    const aux = env_at + 8 * (envp.len + 1);
    try expectEqual(0x400040, v.auxValue(aux, AT.PHDR).?);
    try expectEqual(56, v.auxValue(aux, AT.PHENT).?);
    try expectEqual(6, v.auxValue(aux, AT.PHNUM).?);
    try expectEqual(4096, v.auxValue(aux, AT.PAGESZ).?);
    try expectEqual(0x401000, v.auxValue(aux, AT.ENTRY).?);
    try expectEqual(0, v.auxValue(aux, AT.BASE).?);
    try expectEqual(0x178bfbff, v.auxValue(aux, AT.HWCAP).?);
    try expectEqual(100, v.auxValue(aux, AT.CLKTCK).?);
    try expectEqual(0, v.auxValue(aux, AT.UID).?);
    try expectEqual(0, v.auxValue(aux, AT.SECURE).?);
    try expectEqualStrings("0123456789abcdef", v.bytes(v.auxValue(aux, AT.RANDOM).?, 16));
    try expectEqualStrings("/bin/prog", v.string(v.auxValue(aux, AT.EXECFN).?));
    try expectEqualStrings("x86_64", v.string(v.auxValue(aux, AT.PLATFORM).?));
    try expect(v.auxValue(aux, 33) == null); // no vDSO (AT_SYSINFO_EHDR)

    // The arguments are in order of address, as on Linux, and every
    // pointer is inside the block.
    try expect(v.word(rsp + 8) < v.word(rsp + 16));
    for (0..argv.len) |i| {
        const p = v.word(rsp + 8 + 8 * i);
        try expect(p > rsp and p < TOP);
    }
}

test "the stack pointer is on a 16-byte boundary for every number of strings" {
    var mem: [4096]u8 = undefined;
    var storage: [12][]const u8 = @splat("x");
    for (0..7) |argc| {
        for (0..6) |envc| {
            const rsp = try startup_stack.build(&mem, TOP, sample(storage[0..argc], storage[argc..][0..envc]));
            try expectEqual(0, rsp % 16);
            const v = View{ .mem = &mem, .top = TOP };
            try expectEqual(argc, v.word(rsp));
            try expectEqual(0, v.word(rsp + 8 + 8 * argc)); // argv ends
            try expectEqual(0, v.word(rsp + 8 + 8 * (argc + 1 + envc))); // envp ends
        }
    }
}

test "no arguments and no environment" {
    var mem: [1024]u8 = undefined;
    const rsp = try startup_stack.build(&mem, TOP, sample(&.{}, &.{}));
    const v = View{ .mem = &mem, .top = TOP };
    try expectEqual(0, v.word(rsp));
    try expectEqual(0, v.word(rsp + 8));
    try expectEqual(0, v.word(rsp + 16));
    try expect(v.auxValue(rsp + 24, AT.PAGESZ).? == 4096);
}

test "what does not fit is refused, and exactly the size asked for is enough" {
    const long: [300]u8 = @splat('a');
    const argv = [_][]const u8{ "prog", &long };
    const args = sample(&argv, &.{"E=1"});
    const need = try startup_stack.size(args);
    var mem: [2048]u8 = undefined;
    try expect(need < mem.len and need % 16 == 0);
    _ = try startup_stack.build(mem[0..need], TOP, args);
    try std.testing.expectError(error.TooBig, startup_stack.build(mem[0 .. need - 1], TOP, args));
    try std.testing.expectError(error.TooBig, startup_stack.build(mem[0..0], TOP, args));
}

test "too many strings are refused" {
    var mem: [64 * 1024]u8 = undefined;
    const many: [abi.ARG_COUNT_MAX + 1][]const u8 = @splat("x");
    try std.testing.expectError(error.TooBig, startup_stack.build(&mem, TOP, sample(&many, &.{})));
    try std.testing.expectError(error.TooBig, startup_stack.build(&mem, TOP, sample(many[0..200], many[0..57])));
    _ = try startup_stack.build(&mem, TOP, sample(many[0..abi.ARG_COUNT_MAX], &.{}));
}

test "nothing below the stack pointer is written" {
    var mem: [2048]u8 = @splat(0x5A);
    const rsp = try startup_stack.build(&mem, TOP, sample(&.{"p"}, &.{}));
    const used: usize = @intCast(TOP - rsp);
    for (mem[0 .. mem.len - used]) |b| try expectEqual(0x5A, b);
}
