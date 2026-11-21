const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("../arch/x86_64/vmm.zig");

pub const Error = error{ BadMagic, NotX86_64, NotExecutable, BadSegment, OutOfMemory };

// Read a little-endian integer from a byte slice. The caller must ensure that the slice is large enough.
fn r16(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .little);
}

// Read a little-endian integer from a byte slice. The caller must ensure that the slice is large enough.
fn r32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}

// Read a little-endian integer from a byte slice. The caller must ensure that the slice is large enough.
fn r64(b: []const u8, o: usize) u64 {
    return std.mem.readInt(u64, b[o..][0..8], .little);
}

// Load `image` into address space `root`. Returns the entry point.
// On error the caller destroys the address space (it may be partly filled).
pub fn load(root: u64, image: []const u8) Error!u64 {
    if (image.len < 64 or !std.mem.eql(u8, image[0..4], "\x7fELF")) return error.BadMagic;
    if (image[4] != 2 or image[5] != 1 or r16(image, 18) != 0x3E) return error.NotX86_64; // 64-bit, little endian, x86-64
    if (r16(image, 16) != 2) return error.NotExecutable; // ET_EXEC

    const entry = r64(image, 24);
    const phoff = r64(image, 32);
    const phentsize = r16(image, 54);
    const phnum = r16(image, 56);

    for (0..phnum) |i| {
        const off = phoff + i * phentsize;
        if (off + 56 > image.len) return error.BadSegment;
        const ph = image[off..][0..56];
        if (r32(ph, 0) != 1) continue; // only PT_LOAD

        const flags = r32(ph, 4); // 1 = X, 2 = W, 4 = R
        const file_off = r64(ph, 8);
        const vaddr = r64(ph, 16);
        const filesz = r64(ph, 32);
        const memsz = r64(ph, 40);

        // Never trust the file: everything must stay inside it and inside user space.
        if (vaddr % pmm.PAGE_SIZE != 0 or filesz > memsz or file_off + filesz > image.len or
            vaddr + memsz < vaddr or vaddr + memsz > vmm.USER_END) return error.BadSegment;

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
