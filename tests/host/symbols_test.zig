//! Host unit tests for `src/kernel/debug/symbols.zig`, using small ELF images
//! built in memory.

const std = @import("std");

const symbols = @import("symbols");

/// A symbol to place in a fake image.
const FakeSym = struct {
    name: []const u8,
    value: u64,
    size: u64,
    /// ELF symbol type: 0 = NOTYPE, 1 = OBJECT, 2 = FUNC.
    typ: u8 = 2,
    /// Section index; 0 means undefined.
    shndx: u16 = 1,
};

const default_syms = [_]FakeSym{
    .{ .name = "alpha", .value = 0x1000, .size = 0x100 },
    .{ .name = "beta", .value = 0x1100, .size = 0x80 },
    .{ .name = "label", .value = 0x2000, .size = 0, .typ = 0 },
    .{ .name = "undef", .value = 0x3000, .size = 0x10, .shndx = 0 },
    .{ .name = "data_obj", .value = 0x5000, .size = 0x10, .typ = 1 },
};

/// Build a minimal ELF64 image with sections [null, .symtab, .strtab] holding `syms`.
fn buildElf(buf: []u8, syms: []const FakeSym) []u8 {
    @memset(buf, 0);
    const put = struct {
        fn u16_(b: []u8, o: usize, v: u16) void {
            std.mem.writeInt(u16, b[o..][0..2], v, .little);
        }
        fn u32_(b: []u8, o: usize, v: u32) void {
            std.mem.writeInt(u32, b[o..][0..4], v, .little);
        }
        fn u64_(b: []u8, o: usize, v: u64) void {
            std.mem.writeInt(u64, b[o..][0..8], v, .little);
        }
    };

    // String table at 64: "\0" then each name.
    const strtab_off: usize = 64;
    var str_len: usize = 1;
    var name_offs: [16]u32 = undefined;
    for (syms, 0..) |s, i| {
        name_offs[i] = @intCast(str_len);
        @memcpy(buf[strtab_off + str_len ..][0..s.name.len], s.name);
        str_len += s.name.len + 1;
    }

    // Symbol table: null symbol, then `syms`.
    const symtab_off = std.mem.alignForward(usize, strtab_off + str_len, 8);
    const symtab_len = (syms.len + 1) * 24;
    for (syms, 0..) |s, i| {
        const o = symtab_off + (i + 1) * 24;
        put.u32_(buf, o, name_offs[i]);
        buf[o + 4] = s.typ; // binding LOCAL
        put.u16_(buf, o + 6, s.shndx);
        put.u64_(buf, o + 8, s.value);
        put.u64_(buf, o + 16, s.size);
    }

    // Section headers: null, .symtab (links to 2), .strtab.
    const shoff = std.mem.alignForward(usize, symtab_off + symtab_len, 8);
    put.u32_(buf, shoff + 64 + 4, 2); // SHT_SYMTAB
    put.u64_(buf, shoff + 64 + 24, symtab_off);
    put.u64_(buf, shoff + 64 + 32, symtab_len);
    put.u32_(buf, shoff + 64 + 40, 2); // sh_link -> .strtab
    put.u32_(buf, shoff + 128 + 4, 3); // SHT_STRTAB
    put.u64_(buf, shoff + 128 + 24, strtab_off);
    put.u64_(buf, shoff + 128 + 32, str_len);

    // ELF header.
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 2; // ELF64
    buf[5] = 1; // little endian
    put.u64_(buf, 0x28, shoff);
    put.u16_(buf, 0x3A, 64);
    put.u16_(buf, 0x3C, 3);
    return buf[0 .. shoff + 3 * 64];
}

fn expectSym(t: symbols.Table, addr: u64, name: []const u8, offset: u64) !void {
    const s = t.lookup(addr) orelse return error.TestExpectedSymbol;
    try std.testing.expectEqualStrings(name, s.name);
    try std.testing.expectEqual(offset, s.offset);
}

test "symbols: addresses inside sized functions" {
    var buf: [1024]u8 = undefined;
    const t = symbols.Table.init(buildElf(&buf, &default_syms)) orelse return error.TestExpectedTable;
    try expectSym(t, 0x1000, "alpha", 0);
    try expectSym(t, 0x10FF, "alpha", 0xFF);
    try expectSym(t, 0x1100, "beta", 0);
    try expectSym(t, 0x117F, "beta", 0x7F);
}

test "symbols: unsized labels match only nearby addresses" {
    var buf: [1024]u8 = undefined;
    const t = symbols.Table.init(buildElf(&buf, &default_syms)) orelse return error.TestExpectedTable;
    try expectSym(t, 0x2000, "label", 0);
    try expectSym(t, 0x2FFF, "label", 0xFFF);
    try std.testing.expect(t.lookup(0x3001) == null); // too far from label; undef is undefined
}

test "symbols: gaps, data and out-of-range addresses are not symbolized" {
    var buf: [1024]u8 = undefined;
    const t = symbols.Table.init(buildElf(&buf, &default_syms)) orelse return error.TestExpectedTable;
    try std.testing.expect(t.lookup(0x0FFF) == null); // below everything
    try std.testing.expect(t.lookup(0x1180) == null); // just past beta
    try std.testing.expect(t.lookup(0x5008) == null); // data object, not code
    try std.testing.expect(t.lookup(std.math.maxInt(u64)) == null);
}

test "symbols: malformed and stripped images are rejected" {
    var buf: [1024]u8 = undefined;
    const good = buildElf(&buf, &default_syms);

    try std.testing.expect(symbols.Table.init("") == null);
    try std.testing.expect(symbols.Table.init("not an ELF file at all, definitely not one........................") == null);
    try std.testing.expect(symbols.Table.init(good[0..100]) == null); // section headers cut off

    var bad: [1024]u8 = undefined;
    @memcpy(bad[0..good.len], good);
    std.mem.writeInt(u64, bad[0x28..][0..8], 1 << 40, .little); // e_shoff out of range
    try std.testing.expect(symbols.Table.init(bad[0..good.len]) == null);

    @memcpy(bad[0..good.len], good);
    const shoff = std.mem.readInt(u64, good[0x28..][0..8], .little);
    std.mem.writeInt(u64, bad[shoff + 64 + 32 ..][0..8], 1 << 40, .little); // symtab size out of range
    try std.testing.expect(symbols.Table.init(bad[0..good.len]) == null);

    @memcpy(bad[0..good.len], good);
    std.mem.writeInt(u32, bad[shoff + 64 + 40 ..][0..4], 7, .little); // sh_link past shnum
    try std.testing.expect(symbols.Table.init(bad[0..good.len]) == null);

    @memcpy(bad[0..good.len], good);
    std.mem.writeInt(u32, bad[shoff + 64 + 4 ..][0..4], 1, .little); // no SHT_SYMTAB: stripped
    try std.testing.expect(symbols.Table.init(bad[0..good.len]) == null);
}

test "symbols: bad name offsets are skipped, not followed" {
    var buf: [1024]u8 = undefined;
    const img = buildElf(&buf, &default_syms);
    const t0 = symbols.Table.init(img) orelse return error.TestExpectedTable;
    // Point alpha's name past the string table.
    const symtab_start = @intFromPtr(t0.symtab.ptr) - @intFromPtr(img.ptr);
    std.mem.writeInt(u32, img[symtab_start + 24 ..][0..4], 0xFFFF, .little);
    const t = symbols.Table.init(img) orelse return error.TestExpectedTable;
    try std.testing.expect(t.lookup(0x1000) == null);
    try expectSym(t, 0x1100, "beta", 0);
}
