//! Loader for static x86-64 ELF executables.
//!
//! Copies each `PT_LOAD` segment into freshly allocated pages of a user address
//! space. The image is treated as untrusted: every offset and address is
//! checked against the file size and the user half of the address space.

const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("../arch/x86_64/vmm.zig");

/// Ways `load` can fail.
pub const Error = error{ BadMagic, NotX86_64, NotExecutable, BadSegment, OutOfMemory };

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

/// Load the ELF executable `image` into the address space `root` and return
/// its entry point.
///
/// Segments must be page aligned. Each page gets user access, plus write
/// access and/or NX according to the segment flags; memory past the file data
/// (`.bss`) is zeroed. `image` is copied, so it may be freed afterwards. On
/// error the address space may be partly filled; the caller destroys it.
pub fn load(root: u64, image: []const u8) Error!u64 {
    if (image.len < 64 or !std.mem.eql(u8, image[0..4], "\x7fELF")) return error.BadMagic;
    if (image[4] != 2 or image[5] != 1 or r16(image, 18) != 0x3E) return error.NotX86_64; // 64-bit, little endian, x86-64
    if (r16(image, 16) != 2) return error.NotExecutable; // ET_EXEC

    const entry = r64(image, 24);
    const phoff = r64(image, 32);
    const phentsize = r16(image, 54);
    const phnum = r16(image, 56);

    if (phnum != 0 and phentsize < 56) return error.BadSegment; // entries would overlap

    for (0..phnum) |i| {
        // All arithmetic on values from the file is overflow checked.
        const off = add(phoff, @as(u64, i) * phentsize) orelse return error.BadSegment;
        if (off > image.len or image.len - off < 56) return error.BadSegment;
        const ph = image[@intCast(off)..][0..56];
        if (r32(ph, 0) != 1) continue; // only PT_LOAD

        const flags = r32(ph, 4); // 1 = X, 2 = W, 4 = R
        const file_off = r64(ph, 8);
        const vaddr = r64(ph, 16);
        const filesz = r64(ph, 32);
        const memsz = r64(ph, 40);

        // Never trust the file: everything must stay inside it and inside user space.
        const file_end = add(file_off, filesz) orelse return error.BadSegment;
        const mem_end = add(vaddr, memsz) orelse return error.BadSegment;
        if (vaddr % pmm.PAGE_SIZE != 0 or filesz > memsz or file_end > image.len or
            mem_end > vmm.USER_END) return error.BadSegment;

        var pte: u64 = vmm.USER;
        if (flags & 2 != 0) pte |= vmm.WRITABLE;
        if (flags & 1 == 0) pte |= vmm.NX;

        var page: u64 = 0;
        while (page < memsz) : (page += pmm.PAGE_SIZE) {
            const phys = pmm.alloc() orelse return error.OutOfMemory;
            const dst = pmm.physToVirt(phys)[0..pmm.PAGE_SIZE];
            @memset(dst, 0); // covers .bss and the tail of the last page
            if (page < filesz) {
                const n = @min(pmm.PAGE_SIZE, filesz - page);
                @memcpy(dst[0..n], image[file_off + page ..][0..n]);
            }
            vmm.map(root, vaddr + page, phys, pte, false);
        }
    }
    if (entry >= vmm.USER_END) return error.NotExecutable;
    return entry;
}
