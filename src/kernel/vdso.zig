//! The vDSO, from the kernel's side: the image (`src/vdso/`, built by
//! `build.zig` and embedded here) and the page it reads the clock from
//! (`vvar`), in physical pages that every process maps (`user_memory.zig`,
//! regions of kind `vvar` and `vdso`, page-table entries marked
//! `vmm.SHARED`) just below its mappings, with the image's address in
//! `AT_SYSINFO_EHDR`. A process reads the clock there without a system
//! call; it cannot write either page.
//!
//! `update` writes the clock's state into `vvar` under a sequence count
//! (odd while it writes), which the vDSO reads around: at boot, and if the
//! TSC stops being the clock.

const std = @import("std");

const pmm = @import("pmm.zig");
const clock = @import("clock.zig");

const image = @embedFile("vdso.so");

/// Pages of the image.
pub const TEXT_PAGES = (image.len + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
/// Pages mapped into a process: `vvar`, then the image.
pub const PAGES = 1 + TEXT_PAGES;

comptime {
    if (TEXT_PAGES > 4) @compileError("the vDSO grew: more than 4 pages");
}

/// What `vvar` holds, as `src/vdso/vdso.zig` reads it.
pub const VVar = extern struct {
    seq: u32 = 0,
    tsc: u32 = 0,
    tsc_base: u64 = 0,
    ns_base: u64 = 0,
    mult: u64 = 0,
    shift: u32 = 0,
    _pad: u32 = 0,
    realtime_offset: i64 = 0,
    /// How `getcpu` reads the CPU's number (`percpu.GetcpuMode`).
    getcpu: u32 = 0,
    _pad2: u32 = 0,
};

var pages: [PAGES]u64 = @splat(0);
var ready = false;

/// Make the pages: copy the image, write the clock. After the page
/// allocator and `clock.init`, before the first process.
pub fn init() void {
    for (&pages) |*p| p.* = pmm.allocZeroed() orelse @panic("vdso: no memory for its pages");
    for (0..TEXT_PAGES) |i| {
        const from = i * pmm.PAGE_SIZE;
        const n = @min(pmm.PAGE_SIZE, image.len - from);
        @memcpy(pmm.physToVirt(pages[1 + i])[0..n], image[from..][0..n]);
    }
    ready = true;
    update();
}

/// Whether there is a vDSO to map.
pub fn present() bool {
    return ready;
}

/// The physical page at `index` of what a process maps (0: `vvar`).
pub fn page(index: usize) u64 {
    return pages[index];
}

fn vvar() *volatile VVar {
    return @ptrCast(@alignCast(pmm.physToVirt(pages[0])));
}

/// Write the clock's state into `vvar` (`clock.vdsoState`).
pub fn update() void {
    if (!ready) return;
    const v = vvar();
    const st = clock.vdsoState();
    const seq = v.seq;
    @atomicStore(u32, &v.seq, seq +% 1, .seq_cst); // odd: being written
    v.tsc = @intFromBool(st.tsc);
    v.tsc_base = st.tsc_base;
    v.ns_base = st.ns_base;
    v.mult = st.mult;
    v.shift = st.shift;
    v.realtime_offset = st.realtime_offset;
    v.getcpu = @intFromEnum(@import("../arch/x86_64/percpu.zig").getcpuMode());
    @atomicStore(u32, &v.seq, seq +% 2, .seq_cst);
}
