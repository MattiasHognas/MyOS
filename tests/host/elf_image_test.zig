//! Host unit tests and a mutation fuzzer for `src/kernel/elf_image.zig`,
//! using ELF images built in memory.

const std = @import("std");
const elf_image = @import("elf_image");

const parse = elf_image.parse;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

/// The limits the kernel uses: from 64 KiB up to the stack's reserved region.
const limits: elf_image.Limits = .{
    .min_addr = 0x1_0000,
    .max_addr = 0x0000_7FFF_FF7F_0000,
    .max_bytes = 256 * 1024 * 1024,
};

/// One program header. Defaults: a read+execute `PT_LOAD` of 16 bytes at
/// 0x400000 with 0x2000 bytes of memory.
const Ph = struct {
    typ: u32 = 1,
    flags: u32 = 5,
    offset: u64 = 0x1000,
    vaddr: u64 = 0x40_0000,
    filesz: u64 = 16,
    memsz: u64 = 0x2000,
    alignment: u64 = 0x1000,
};

/// A read+write `PT_LOAD` segment at `vaddr`.
fn data(vaddr: u64) Ph {
    return .{ .flags = 6, .vaddr = vaddr };
}

/// An image to build. Defaults give a valid executable with one segment.
const Spec = struct {
    class: u8 = 2,
    data: u8 = 1,
    ident_version: u8 = 1,
    typ: u16 = 2,
    machine: u16 = 0x3E,
    version: u32 = 1,
    entry: u64 = 0x40_0000,
    phoff: u64 = 64,
    ehsize: u16 = 64,
    phentsize: u16 = 56,
    /// Program header count in the file header; defaults to `phdrs.len`.
    phnum: ?u16 = null,
    phdrs: []const Ph = &.{.{}},
    /// Length of the returned image.
    len: usize = 0x2000,
};

var image_buf: [0x2000]u8 = undefined;

/// Build an ELF64 image in `image_buf` from `spec`. The program headers
/// start at offset 64 whatever `spec.phoff` says.
fn build(spec: Spec) []const u8 {
    const b = &image_buf;
    @memset(b, 0);
    @memcpy(b[0..4], "\x7fELF");
    b[4] = spec.class;
    b[5] = spec.data;
    b[6] = spec.ident_version;
    std.mem.writeInt(u16, b[16..18], spec.typ, .little);
    std.mem.writeInt(u16, b[18..20], spec.machine, .little);
    std.mem.writeInt(u32, b[20..24], spec.version, .little);
    std.mem.writeInt(u64, b[24..32], spec.entry, .little);
    std.mem.writeInt(u64, b[32..40], spec.phoff, .little);
    std.mem.writeInt(u16, b[52..54], spec.ehsize, .little);
    std.mem.writeInt(u16, b[54..56], spec.phentsize, .little);
    std.mem.writeInt(u16, b[56..58], spec.phnum orelse @intCast(spec.phdrs.len), .little);
    for (spec.phdrs, 0..) |p, i| {
        const ph = b[64 + i * 56 ..][0..56];
        std.mem.writeInt(u32, ph[0..4], p.typ, .little);
        std.mem.writeInt(u32, ph[4..8], p.flags, .little);
        std.mem.writeInt(u64, ph[8..16], p.offset, .little);
        std.mem.writeInt(u64, ph[16..24], p.vaddr, .little);
        std.mem.writeInt(u64, ph[32..40], p.filesz, .little);
        std.mem.writeInt(u64, ph[40..48], p.memsz, .little);
        std.mem.writeInt(u64, ph[48..56], p.alignment, .little);
    }
    return b[0..spec.len];
}

/// Parse the image built from `spec` with the default limits.
fn check(spec: Spec) elf_image.Error!elf_image.Image {
    return parse(build(spec), limits);
}

var segment_buf: [elf_image.MAX_PHDRS]elf_image.Segment = undefined;

/// Collect the segments of `img` into `segment_buf`.
fn loads(img: *const elf_image.Image) []const elf_image.Segment {
    var n: usize = 0;
    var it = img.segments();
    while (it.next()) |seg| : (n += 1) segment_buf[n] = seg;
    return segment_buf[0..n];
}

test "elf image: a valid executable" {
    const img = try check(.{ .phdrs = &.{ .{}, data(0x40_2000) } });
    try expectEqual(0x40_0000, img.entry);
    try expectEqual(2, loads(&img).len);
    try expectEqual(4, img.pages);

    const text = loads(&img)[0];
    try expectEqual(0x40_0000, text.vaddr);
    try expectEqual(0x2000, text.memsz);
    try expectEqual(0x1000, text.file_off);
    try expectEqual(16, text.filesz);
    try expect(text.executable and !text.writable);

    const rw = loads(&img)[1];
    try expectEqual(0x40_2000, rw.start());
    try expectEqual(0x40_4000, rw.end());
    try expect(rw.writable and !rw.executable);
}

test "elf image: header fields" {
    try expectError(error.BadMagic, parse("", limits));
    try expectError(error.BadMagic, parse("not an ELF", limits));
    try expectError(error.BadMagic, check(.{ .len = 63 }));
    try expectError(error.NotX86_64, check(.{ .class = 1 })); // 32-bit
    try expectError(error.NotX86_64, check(.{ .data = 2 })); // big endian
    try expectError(error.NotX86_64, check(.{ .machine = 3 })); // i386
    try expectError(error.NotX86_64, check(.{ .machine = 0xB7 })); // aarch64
    try expectError(error.BadHeader, check(.{ .ident_version = 0 }));
    try expectError(error.BadHeader, check(.{ .version = 2 }));
    try expectError(error.BadHeader, check(.{ .ehsize = 52 }));
    try expectError(error.NotExecutable, check(.{ .typ = 1 })); // ET_REL
    try expectError(error.NotExecutable, check(.{ .typ = 3 })); // ET_DYN
    try expectError(error.NotExecutable, check(.{ .typ = 4 })); // ET_CORE
}

test "elf image: program header table" {
    try expectError(error.BadHeader, check(.{ .phentsize = 55 }));
    try expectError(error.BadHeader, check(.{ .phentsize = 64 }));
    try expectError(error.BadHeader, check(.{ .phnum = 0 }));
    try expectError(error.BadHeader, check(.{ .phnum = elf_image.MAX_PHDRS + 1 }));
    try expectError(error.BadHeader, check(.{ .phnum = 0xFFFF })); // PN_XNUM
    try expectError(error.BadHeader, check(.{ .phoff = 0x2000 })); // at the end of the file
    try expectError(error.BadHeader, check(.{ .phoff = 0x2000 - 55 })); // one byte short
    try expectError(error.BadHeader, check(.{ .phoff = std.math.maxInt(u64) }));
    try expectError(error.BadHeader, check(.{ .len = 64 + 55 })); // table cut off
    try expectError(error.BadHeader, check(.{ .phdrs = &.{.{ .typ = 4 }} })); // no PT_LOAD at all

    // A table that ends exactly at the end of the file is fine.
    _ = try check(.{ .phdrs = &.{.{ .offset = 0, .filesz = 0 }}, .len = 64 + 56 });
    // As many headers as allowed, all but one of another type.
    var many: [elf_image.MAX_PHDRS]Ph = @splat(.{ .typ = 4 });
    many[elf_image.MAX_PHDRS - 1] = .{};
    _ = try check(.{ .phdrs = &many });
}

test "elf image: segment sizes and file bounds" {
    try expectError(error.BadSegment, check(.{ .phdrs = &.{.{ .filesz = 0x2001 }} })); // filesz > memsz
    try expectError(error.BadSegment, check(.{ .phdrs = &.{.{ .filesz = 0x1001 }} })); // past the end of the file
    try expectError(error.BadSegment, check(.{ .phdrs = &.{.{ .offset = 0x3000 }} }));
    try expectError(error.BadSegment, check(.{ .phdrs = &.{.{ .offset = std.math.maxInt(u64) - 0xFFF, .filesz = 0x1000, .vaddr = 0x40_0000 }} })); // offset + filesz wraps
    try expectError(error.BadSegment, check(.{ .phdrs = &.{.{ .vaddr = 0xFFFF_FFFF_FFFF_F000 }} })); // vaddr + memsz wraps
    _ = try check(.{ .phdrs = &.{.{ .filesz = 0x1000 }} }); // data up to the last byte of the file
}

test "elf image: empty and foreign segments are ignored" {
    const img = try check(.{
        .phdrs = &.{
            .{ .typ = 0x6474e551, .flags = 6, .offset = 0, .vaddr = 0, .filesz = 0, .memsz = 0x100_0000, .alignment = 0 }, // GNU_STACK
            .{ .typ = 7, .flags = 4, .vaddr = 0xFFFF_8000_0000_0000 }, // PT_TLS
            .{ .memsz = 0, .filesz = 0, .vaddr = 0, .flags = 7 }, // empty PT_LOAD
            .{},
        },
    });
    try expectEqual(1, loads(&img).len);
    // An empty segment must still not claim more file data than memory.
    try expectError(error.BadSegment, check(.{ .phdrs = &.{ .{}, .{ .memsz = 0, .filesz = 1 } } }));
}

test "elf image: alignment" {
    // The address need not be page aligned, only congruent with the file offset.
    const img = try check(.{ .entry = 0x40_0123, .phdrs = &.{.{ .offset = 0x1123, .vaddr = 0x40_0123, .memsz = 0x1000 }} });
    try expectEqual(0x40_0000, loads(&img)[0].start());
    try expectEqual(0x40_2000, loads(&img)[0].end()); // 0x123 + 0x1000 spills into a second page
    try expectEqual(2, img.pages);

    try expectError(error.BadSegment, check(.{ .phdrs = &.{.{ .vaddr = 0x40_0100 }} })); // offset 0x1000: not congruent
    try expectError(error.BadSegment, check(.{ .phdrs = &.{.{ .alignment = 0x1800 }} })); // not a power of two
    try expectError(error.BadSegment, check(.{ .phdrs = &.{.{ .alignment = 3 }} }));
    try expectError(error.BadSegment, check(.{ .phdrs = &.{.{ .alignment = 0x20_0000 }} })); // 0x400000 vs 0x1000 modulo 2 MiB
    // A small alignment does not excuse a mismatch within the page.
    try expectError(error.BadSegment, check(.{ .entry = 0x40_0010, .phdrs = &.{.{ .vaddr = 0x40_0010, .alignment = 16 }} }));

    _ = try check(.{ .phdrs = &.{.{ .alignment = 0 }} });
    _ = try check(.{ .phdrs = &.{.{ .alignment = 1 }} });
    _ = try check(.{ .phdrs = &.{.{ .offset = 0, .alignment = 0x20_0000 }} });
    try expectError(error.BadSegment, check(.{ .entry = 0x1_1000, .phdrs = &.{.{ .alignment = 1 << 63, .vaddr = 0x1_1000, .memsz = 0x1000 }} })); // huge alignment, not congruent
}

test "elf image: address range" {
    const min = limits.min_addr;
    const max = limits.max_addr;
    try expectError(error.BadSegment, check(.{ .entry = 0, .phdrs = &.{.{ .vaddr = 0 }} })); // page zero
    try expectError(error.BadSegment, check(.{ .entry = min - 0x1000, .phdrs = &.{.{ .vaddr = min - 0x1000 }} }));
    try expectError(error.BadSegment, check(.{ .entry = min - 1, .phdrs = &.{.{ .offset = 0xFFF, .vaddr = min - 1 }} })); // one byte below
    _ = try check(.{ .entry = min, .phdrs = &.{.{ .vaddr = min }} });

    _ = try check(.{ .entry = max - 0x2000, .phdrs = &.{.{ .vaddr = max - 0x2000 }} }); // ends exactly at the limit
    try expectError(error.BadSegment, check(.{ .entry = max - 0x1000, .phdrs = &.{.{ .vaddr = max - 0x1000 }} })); // one page too far
    try expectError(error.BadSegment, check(.{ .entry = max - 0x2000, .phdrs = &.{.{ .vaddr = max - 0x2000, .memsz = 0x2001 }} })); // one byte too far
    try expectError(error.BadSegment, check(.{ .phdrs = &.{.{ .vaddr = 0x0000_7FFF_FFFF_0000 - 0x4000 }} })); // the user stack
    try expectError(error.BadSegment, check(.{ .phdrs = &.{.{ .vaddr = 0x0000_7FFF_FFFF_F000, .memsz = 0x1000 }} })); // the last user page
    try expectError(error.BadSegment, check(.{ .phdrs = &.{.{ .vaddr = 0x0000_8000_0000_0000 }} })); // non-canonical
    try expectError(error.BadSegment, check(.{ .phdrs = &.{.{ .vaddr = 0xFFFF_8000_0000_0000 }} })); // kernel half
    try expectError(error.BadSegment, check(.{ .phdrs = &.{.{ .vaddr = 0xFFFF_FFFF_8000_0000 }} })); // kernel image
    try expectError(error.BadSegment, check(.{ .phdrs = &.{ .{}, data(0xFFFF_8000_0000_0000) } })); // a later segment
}

test "elf image: permissions" {
    try expectError(error.WritableExecutable, check(.{ .phdrs = &.{.{ .flags = 7 }} }));
    try expectError(error.WritableExecutable, check(.{ .phdrs = &.{.{ .flags = 3 }} }));
    try expectError(error.WritableExecutable, check(.{ .phdrs = &.{ .{}, .{ .flags = 7, .vaddr = 0x50_0000 } } }));
    try expectError(error.BadSegment, check(.{ .phdrs = &.{ .{}, .{ .flags = 0, .vaddr = 0x50_0000 } } })); // no access at all
    try expectError(error.BadSegment, check(.{ .phdrs = &.{ .{}, .{ .flags = 0xFFFF_FFF8, .vaddr = 0x50_0000 } } })); // only OS-specific bits

    const img = try check(.{ .phdrs = &.{ .{ .flags = 1 }, .{ .flags = 4, .vaddr = 0x50_0000 }, .{ .flags = 2, .vaddr = 0x60_0000 } } });
    try expect(loads(&img)[0].executable and !loads(&img)[0].writable);
    try expect(!loads(&img)[1].executable and !loads(&img)[1].writable);
    try expect(!loads(&img)[2].executable and loads(&img)[2].writable);
}

test "elf image: overlapping segments" {
    try expectError(error.Overlap, check(.{ .phdrs = &.{ .{}, data(0x40_0000) } })); // the same range
    try expectError(error.Overlap, check(.{ .phdrs = &.{ .{}, data(0x40_1000) } })); // second page of the first
    try expectError(error.Overlap, check(.{ .phdrs = &.{ data(0x40_1000), .{} } })); // either order
    try expectError(error.Overlap, check(.{ .phdrs = &.{ .{}, .{ .flags = 6, .vaddr = 0x3F_F000, .memsz = 0x4000 } } })); // one inside the other
    // Different bytes of one page still overlap: a page has one set of permissions.
    try expectError(error.Overlap, check(.{ .phdrs = &.{
        .{ .memsz = 0x800 },
        .{ .flags = 6, .offset = 0x1800, .vaddr = 0x40_0800, .memsz = 0x800 },
    } }));

    _ = try check(.{ .phdrs = &.{ .{}, data(0x40_2000) } }); // adjacent
    _ = try check(.{ .phdrs = &.{ data(0x3F_E000), .{} } });
}

test "elf image: memory limit" {
    const cap = limits.max_bytes;
    _ = try check(.{ .phdrs = &.{.{ .memsz = cap }} });
    try expectError(error.TooLarge, check(.{ .phdrs = &.{.{ .memsz = cap + 1 }} }));
    try expectError(error.TooLarge, check(.{ .phdrs = &.{.{ .memsz = 1 << 40 }} }));
    // The limit is on the sum, in whole pages.
    try expectError(error.TooLarge, check(.{ .phdrs = &.{ .{ .memsz = cap }, .{ .flags = 6, .vaddr = 0x4000_0000, .filesz = 1, .memsz = 1 } } }));
    _ = try check(.{ .phdrs = &.{ .{ .memsz = cap - 0x1000 }, .{ .flags = 6, .vaddr = 0x4000_0000, .filesz = 1, .memsz = 1 } } });

    // Every program header may be a segment to load.
    var many: [elf_image.MAX_PHDRS]Ph = undefined;
    for (&many, 0..) |*p, i| p.* = .{ .vaddr = 0x40_0000 + i * 0x10_0000 };
    const img = try check(.{ .phdrs = &many });
    try expectEqual(elf_image.MAX_PHDRS, loads(&img).len);
    try expectEqual(elf_image.MAX_PHDRS * 2, img.pages);
}

test "elf image: entry point" {
    _ = try check(.{ .entry = 0x40_1FFF }); // last byte of the segment
    try expectError(error.BadEntry, check(.{ .entry = 0x40_2000 })); // just past it
    try expectError(error.BadEntry, check(.{ .entry = 0x3F_FFFF }));
    try expectError(error.BadEntry, check(.{ .entry = 0 }));
    try expectError(error.BadEntry, check(.{ .entry = 0xFFFF_FFFF_8000_0000 }));
    try expectError(error.BadEntry, check(.{ .phdrs = &.{.{ .flags = 4 }} })); // read-only segment
    try expectError(error.BadEntry, check(.{ .entry = 0x40_2000, .phdrs = &.{ .{}, data(0x40_2000) } })); // in the data segment
    // In the page of an unaligned segment, but before its first byte.
    try expectError(error.BadEntry, check(.{ .entry = 0x40_0000, .phdrs = &.{.{ .offset = 0x1123, .vaddr = 0x40_0123 }} }));
}

test "elf image: dynamically linked executables are refused" {
    try expectError(error.Unsupported, check(.{ .phdrs = &.{ .{}, .{ .typ = 3, .flags = 4, .offset = 0x1000, .vaddr = 0x40_0000, .filesz = 16, .memsz = 16 } } }));
}

/// Check everything `parse` promises about an image it accepted.
fn expectSound(img: *const elf_image.Image, image: []const u8) !void {
    const segs = loads(img);
    try expect(segs.len >= 1);
    var total: u64 = 0;
    var entry_ok = false;
    for (segs, 0..) |*s, i| {
        try expect(s.memsz > 0 and s.filesz <= s.memsz);
        try expect(s.file_off <= image.len and s.filesz <= image.len - s.file_off);
        try expect(s.start() >= limits.min_addr and s.end() <= limits.max_addr);
        try expect(s.start() <= s.vaddr and s.vaddr + s.memsz <= s.end());
        try expect(!(s.writable and s.executable));
        for (segs[0..i]) |*o| try expect(s.end() <= o.start() or o.end() <= s.start());
        total += s.end() - s.start();
        if (s.executable and img.entry >= s.vaddr and img.entry < s.vaddr + s.memsz) entry_ok = true;
    }
    try expect(total <= limits.max_bytes);
    try expectEqual(total / elf_image.PAGE_SIZE, img.pages);
    try expect(entry_ok);
}

test "elf image: fuzz with mutated and random images" {
    // Values that sit on the edges the checks care about.
    const edges = [_]u64{
        0,                        1,                     2,                     0xFFF,                0x1000,               0x1001,
        0x2000,                   0x40_0000,             0x40_1000,             0x40_2000,            limits.min_addr - 1,  limits.min_addr,
        limits.max_addr - 0x1000, limits.max_addr,       limits.max_addr + 1,   limits.max_bytes,     limits.max_bytes + 1, 0x0000_7FFF_FFFF_F000,
        0x0000_8000_0000_0000,    0xFFFF_8000_0000_0000, 0xFFFF_FFFF_FFFF_F000, std.math.maxInt(u64), 1 << 63,              56,
    };
    var prng: std.Random.DefaultPrng = .init(0x4d794f53); // fixed seed: the same images in every run
    const random = prng.random();
    var buf: [0x2000]u8 = undefined;
    var accepted: usize = 0;
    var rejected: usize = 0;

    for (0..200_000) |round| {
        var len: usize = buf.len;
        if (round % 8 == 7) {
            random.bytes(&buf); // pure noise, sometimes behind a valid magic number and class
            if (random.boolean()) @memcpy(buf[0..7], "\x7fELF\x02\x01\x01");
        } else {
            // A valid three-segment image with a few fields overwritten.
            @memcpy(&buf, build(.{ .phdrs = &.{ .{}, data(0x40_2000), .{ .flags = 4, .vaddr = 0x50_0000 } } }));
            for (0..random.intRangeAtMost(usize, 1, 4)) |_| {
                const header_bytes = 64 + 3 * 56;
                switch (random.uintLessThan(u8, 4)) {
                    0 => buf[random.uintLessThan(usize, header_bytes)] = random.int(u8),
                    1 => buf[random.uintLessThan(usize, header_bytes)] ^= @as(u8, 1) << random.int(u3),
                    2 => std.mem.writeInt(u64, buf[random.uintLessThan(usize, header_bytes / 8) * 8 ..][0..8], edges[random.uintLessThan(usize, edges.len)], .little),
                    else => std.mem.writeInt(u64, buf[random.uintLessThan(usize, header_bytes / 8) * 8 ..][0..8], random.int(u64), .little),
                }
            }
        }
        if (random.uintLessThan(u8, 16) == 0) len = random.uintLessThan(usize, buf.len + 1);

        const image = buf[0..len];
        if (parse(image, limits)) |img| {
            try expectSound(&img, image);
            accepted += 1;
        } else |_| rejected += 1;
    }
    // Both outcomes must be common, or the fuzzer is not testing much.
    try expect(accepted > 1000 and rejected > 1000);
}
