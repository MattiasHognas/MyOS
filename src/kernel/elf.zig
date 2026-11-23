//! Loader for static x86-64 ELF executables.
//!
//! `elf_image.parse` validates the whole image first; `load` then copies each
//! `PT_LOAD` segment into freshly allocated pages of a user address space.
//! Nothing is allocated for an image that fails validation.

const vmm = @import("../arch/x86_64/vmm.zig");
const elf_image = @import("elf_image.zig");
const pmm = @import("pmm.zig");

/// Ways `load` can fail.
pub const Error = elf_image.Error || error{OutOfMemory};

/// What `load` put into the address space.
pub const Loaded = struct {
    /// Entry point of the program.
    entry: u64,
    /// Pages allocated for its segments.
    pages: u64,
};

/// Load the ELF executable `image` into the address space `root` and return
/// its entry point and size. `limits` says where segments may go and how much memory
/// they may take (see `elf_image.parse` for everything that is checked).
///
/// Each page gets user access, plus write access and/or NX according to the
/// segment flags. A segment need not start on a page boundary; bytes of its
/// pages outside the file data (`.bss`, and the parts of the first and last
/// page the segment does not cover) are zero. x86-64 pages are always
/// readable, so a segment without the read flag is readable too. `image` is
/// copied, so it may be freed afterwards.
///
/// Fails with `error.OutOfMemory`, before allocating anything, when the
/// image needs more pages than are free (with some left over for page
/// tables). If memory still runs out part-way (another thread took it), the
/// address space is left partly filled; the caller destroys it.
pub fn load(root: u64, image: []const u8, limits: elf_image.Limits) Error!Loaded {
    const img = try elf_image.parse(image, limits);

    if (img.pages + img.pages / 256 + 128 > pmm.free_pages) return error.OutOfMemory;

    var it = img.segments();
    while (it.next()) |seg| {
        var pte: u64 = vmm.USER;
        if (seg.writable) pte |= vmm.WRITABLE;
        if (!seg.executable) pte |= vmm.NX;

        const data_end = seg.vaddr + seg.filesz;
        var va = seg.start();
        while (va < seg.end()) : (va += pmm.PAGE_SIZE) {
            const phys = pmm.alloc() orelse return error.OutOfMemory;
            const dst = pmm.physToVirt(phys)[0..pmm.PAGE_SIZE];
            @memset(dst, 0);
            // The part of the file data that falls inside this page.
            const lo = @max(va, seg.vaddr);
            const hi = @min(va + pmm.PAGE_SIZE, data_end);
            if (lo < hi) @memcpy(dst[lo - va ..][0 .. hi - lo], image[seg.file_off + (lo - seg.vaddr) ..][0 .. hi - lo]);
            vmm.map(root, va, phys, pte, false) catch |e| {
                pmm.free(phys); // not mapped, so destroying the address space would not free it
                return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.AlreadyMapped => error.Overlap, // something else already lives there
                };
            };
        }
    }
    return .{ .entry = img.entry, .pages = img.pages };
}
