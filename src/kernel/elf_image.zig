//! Validation of untrusted ELF64 executables.
//!
//! `parse` checks a whole image before anything is mapped and returns the
//! segments to load. An image that passes cannot ask for memory outside the
//! range the caller allows, for two segments in one page, for a writable and
//! executable page, or for more memory than the caller's limit. This module
//! has no kernel dependencies, so it is tested and fuzzed on the host;
//! `elf.zig` does the mapping.

const std = @import("std");

/// Page size the segments are mapped with.
pub const PAGE_SIZE: u64 = 4096;
/// Most program headers an image may have (of any type).
pub const MAX_PHDRS = 64;

const EHDR_SIZE = 64;
/// Size of one program header.
pub const PHDR_SIZE = 56;
const PT_LOAD = 1;
const PT_INTERP = 3;
const PF_X = 1;
const PF_W = 2;
const PF_R = 4;

/// Ways `parse` can reject an image.
pub const Error = error{
    /// Too short for an ELF header, or the magic number is wrong.
    BadMagic,
    /// Not a 64-bit little-endian x86-64 file.
    NotX86_64,
    /// Not a statically linked executable (`ET_EXEC`).
    NotExecutable,
    /// Wrong version or header sizes, or a program header table that is
    /// empty, too long or outside the file.
    BadHeader,
    /// A `PT_LOAD` segment with sizes, offsets, alignment, addresses or
    /// permissions that cannot be loaded.
    BadSegment,
    /// Two `PT_LOAD` segments share a page.
    Overlap,
    /// The segments together need more memory than the limit.
    TooLarge,
    /// The entry point is not inside an executable segment.
    BadEntry,
    /// A segment is both writable and executable.
    WritableExecutable,
    /// A valid file that needs something the loader does not do: an ELF
    /// interpreter (dynamic linking).
    Unsupported,
};

/// What an image is allowed to ask for.
pub const Limits = struct {
    /// Lowest address a segment may start at. Page aligned.
    min_addr: u64,
    /// First address past the range segments may use. Page aligned.
    max_addr: u64,
    /// Most memory all segments together may take, counted in whole pages.
    max_bytes: u64,
};

/// One `PT_LOAD` segment of a validated image.
pub const Segment = struct {
    /// Address of the first byte; need not be page aligned.
    vaddr: u64,
    /// Size in memory. Bytes past `filesz` are zero.
    memsz: u64,
    /// Offset of the segment's data in the image.
    file_off: u64,
    /// Number of bytes to copy from the image.
    filesz: u64,
    writable: bool,
    executable: bool,

    /// Address of the first page the segment occupies.
    pub fn start(s: *const Segment) u64 {
        return s.vaddr & ~(PAGE_SIZE - 1);
    }

    /// Address just past the last page the segment occupies.
    pub fn end(s: *const Segment) u64 {
        return (s.vaddr + s.memsz + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    }
};

/// A validated executable. It refers to the image bytes it was parsed from
/// instead of holding a copy of the segment table (which would be large for
/// a kernel stack), so those bytes must stay unchanged while it is in use.
pub const Image = struct {
    /// Address of the first instruction to run.
    entry: u64,
    /// Number of pages all segments occupy together.
    pages: u64,
    bytes: []const u8,
    phoff: usize,
    phnum: usize,
    /// Address the program header table has once the segments are loaded,
    /// or 0 if no segment contains it. A C library finds its thread-local
    /// data through it (`AT_PHDR`).
    phdr_vaddr: u64 = 0,

    /// Iterate over the segments to load, in file order.
    pub fn segments(self: *const Image) Iterator {
        return .{ .image = self };
    }
};

/// Iterator over the segments of an `Image`.
pub const Iterator = struct {
    image: *const Image,
    index: usize = 0,

    /// Return the next segment to load, or null after the last one.
    pub fn next(it: *Iterator) ?Segment {
        while (it.index < it.image.phnum) {
            defer it.index += 1;
            if (loadSegment(it.image.bytes, it.image.phoff, it.index)) |seg| return seg;
        }
        return null;
    }
};

/// Read a little-endian u16 from `b` at byte offset `o`.
fn r16(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .little);
}

/// Read a little-endian u32 from `b` at byte offset `o`.
fn r32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}

/// Read a little-endian u64 from `b` at byte offset `o`.
fn r64(b: []const u8, o: usize) u64 {
    return std.mem.readInt(u64, b[o..][0..8], .little);
}

/// Return `a + b`, or null if the sum overflows.
fn add(a: u64, b: u64) ?u64 {
    const sum, const overflow = @addWithOverflow(a, b);
    return if (overflow == 0) sum else null;
}

/// Return program header `index` of the table at `phoff` in `image`. The
/// table must already be known to lie inside the image.
fn phdr(image: []const u8, phoff: usize, index: usize) *const [PHDR_SIZE]u8 {
    return image[phoff + index * PHDR_SIZE ..][0..PHDR_SIZE];
}

/// Decode program header `index` as a segment to load. Returns null if it is
/// not a `PT_LOAD` header or takes no memory. Does not validate anything.
fn loadSegment(image: []const u8, phoff: usize, index: usize) ?Segment {
    const ph = phdr(image, phoff, index);
    if (r32(ph, 0) != PT_LOAD or r64(ph, 40) == 0) return null;
    const flags = r32(ph, 4);
    return .{
        .file_off = r64(ph, 8),
        .vaddr = r64(ph, 16),
        .filesz = r64(ph, 32),
        .memsz = r64(ph, 40),
        .writable = flags & PF_W != 0,
        .executable = flags & PF_X != 0,
    };
}

/// Validate the ELF executable `image` against `limits` and return what to
/// load. Nothing in the file is trusted, and all arithmetic on its values is
/// overflow checked.
///
/// Accepted: a 64-bit little-endian x86-64 `ET_EXEC` file, version 1, with
/// standard header sizes and 1 to `MAX_PHDRS` program headers inside the
/// file. Every non-empty `PT_LOAD` segment must
/// - have its data inside the file and `filesz <= memsz`;
/// - have an alignment that is zero or a power of two, with the address and
///   the file offset equal modulo that alignment and modulo the page size
///   (the address itself need not be page aligned);
/// - lie inside `[limits.min_addr, limits.max_addr)`;
/// - have at least one permission, and not be writable and executable at
///   once;
/// - share no page with another segment.
///
/// The pages of all segments together may not exceed `limits.max_bytes`, and
/// the entry point must be inside an executable segment. `PT_LOAD` segments
/// with `memsz` 0 and other segment types are ignored, except `PT_INTERP`,
/// which is rejected.
pub fn parse(image: []const u8, limits: Limits) Error!Image {
    if (image.len < EHDR_SIZE or r32(image, 0) != 0x464C_457F) return error.BadMagic; // "\x7fELF"
    if (image[4] != 2 or image[5] != 1 or r16(image, 18) != 0x3E) return error.NotX86_64; // 64-bit, little endian, x86-64
    if (image[6] != 1 or r32(image, 20) != 1 or r16(image, 52) != EHDR_SIZE) return error.BadHeader; // both versions, e_ehsize
    if (r16(image, 16) != 2) return error.NotExecutable; // ET_EXEC

    const phentsize = r16(image, 54);
    const phnum: usize = r16(image, 56);
    if (phentsize != PHDR_SIZE or phnum == 0 or phnum > MAX_PHDRS) return error.BadHeader;
    if (r64(image, 32) > image.len or image.len - r64(image, 32) < phnum * PHDR_SIZE) return error.BadHeader;
    const phoff: usize = @intCast(r64(image, 32));

    const entry = r64(image, 24);
    var entry_ok = false;
    var total: u64 = 0;
    for (0..phnum) |i| {
        const ph = phdr(image, phoff, i);
        switch (r32(ph, 0)) {
            PT_LOAD => {},
            PT_INTERP => return error.Unsupported,
            else => continue,
        }
        if (r64(ph, 32) > r64(ph, 40)) return error.BadSegment; // filesz > memsz
        const seg = loadSegment(image, phoff, i) orelse continue; // empty
        const flags = r32(ph, 4);
        const alignment = r64(ph, 48);

        const file_end = add(seg.file_off, seg.filesz) orelse return error.BadSegment;
        const mem_end = add(seg.vaddr, seg.memsz) orelse return error.BadSegment;
        if (file_end > image.len) return error.BadSegment;
        if (seg.vaddr < limits.min_addr or mem_end > limits.max_addr) return error.BadSegment;

        if (alignment & (alignment -% 1) != 0) return error.BadSegment; // zero or a power of two
        if (alignment > 1 and (seg.vaddr ^ seg.file_off) & (alignment - 1) != 0) return error.BadSegment;
        if ((seg.vaddr ^ seg.file_off) & (PAGE_SIZE - 1) != 0) return error.BadSegment;

        if (flags & (PF_R | PF_W | PF_X) == 0) return error.BadSegment;
        if (seg.writable and seg.executable) return error.WritableExecutable;

        // Against every earlier segment; those have already passed the checks above.
        for (0..i) |j| {
            const other = loadSegment(image, phoff, j) orelse continue;
            if (seg.start() < other.end() and other.start() < seg.end()) return error.Overlap;
        }
        total += seg.end() - seg.start(); // each is below 2^48, and there are at most MAX_PHDRS
        if (total > limits.max_bytes) return error.TooLarge;

        if (seg.executable and entry >= seg.vaddr and entry - seg.vaddr < seg.memsz) entry_ok = true;
    }
    if (total == 0) return error.BadHeader; // nothing to load
    if (!entry_ok) return error.BadEntry;

    // Where the program headers end up in memory: inside the segment that
    // covers their place in the file, if one does.
    var phdr_vaddr: u64 = 0;
    const table_end = phoff + phnum * PHDR_SIZE;
    for (0..phnum) |i| {
        const seg = loadSegment(image, phoff, i) orelse continue;
        if (phoff >= seg.file_off and table_end <= seg.file_off + seg.filesz) {
            phdr_vaddr = seg.vaddr + (phoff - seg.file_off);
            break;
        }
    }
    return .{ .entry = entry, .pages = total / PAGE_SIZE, .bytes = image, .phoff = phoff, .phnum = phnum, .phdr_vaddr = phdr_vaddr };
}
