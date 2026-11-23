//! Kernel backtraces and code-address symbolization.
//!
//! Walks the RBP frame-pointer chain (the kernel is built with frame pointers)
//! and names each return address using the kernel's own `.symtab`, which
//! Limine hands over through the executable-file request. Every frame pointer
//! is checked against the kernel page tables before it is dereferenced, so a
//! corrupt stack ends the walk instead of causing a nested fault.

const std = @import("std");
const root = @import("root");

const vmm = @import("../../arch/x86_64/vmm.zig");
const symbols = @import("symbols.zig");

/// Maximum number of frames `print` shows.
pub const max_frames = 32;

/// Start of the kernel (higher) half; frame pointers below this are rejected.
const KERNEL_HALF: u64 = 0xFFFF_8000_0000_0000;

var table: ?symbols.Table = null;

/// Load the symbol table from the kernel's ELF image `elf`. Without this (or
/// if the image is stripped), backtraces show bare addresses. Returns true if
/// symbols were found.
pub fn init(elf: []const u8) bool {
    table = symbols.Table.init(elf);
    return table != null;
}

/// Return the function containing code address `addr`, or null if it is unknown.
pub fn symbolize(addr: u64) ?symbols.Symbol {
    const t = table orelse return null;
    return t.lookup(addr);
}

/// Return true if the 16-byte frame record at `rbp` is mapped in the kernel half.
fn frameReadable(rbp: u64) bool {
    if (vmm.kernel_root == 0) return false; // our page tables are not set up yet
    if (rbp < KERNEL_HALF or rbp % 8 != 0) return false;
    return vmm.translate(vmm.kernel_root, rbp) != null and
        vmm.translate(vmm.kernel_root, rbp + 15) != null;
}

/// Walk the frame chain starting at frame pointer `rbp` and store up to
/// `out.len` return addresses in `out`, innermost first. Returns how many were
/// stored. Stops at a null or invalid frame pointer, a null return address, or
/// a chain that does not move up the stack.
pub fn capture(rbp_start: u64, out: []u64) usize {
    var rbp = rbp_start;
    var n: usize = 0;
    while (n < out.len and frameReadable(rbp)) {
        const frame: *const [2]u64 = @ptrFromInt(rbp);
        const ret = frame[1];
        if (ret == 0) break;
        out[n] = ret;
        n += 1;
        if (frame[0] <= rbp) break; // the stack grows down, so callers are above
        rbp = frame[0];
    }
    return n;
}

/// Print one code address as `  #<index> 0x<addr> <symbol>+0x<offset>`.
///
/// For return addresses (`is_return`), the symbol is looked up at `addr - 1`,
/// so a call at the very end of a function is attributed to that function.
pub fn printFrame(index: usize, addr: u64, is_return: bool) void {
    const lookup_addr = if (is_return and addr > 0) addr - 1 else addr;
    if (symbolize(lookup_addr)) |s| {
        const off = s.offset + (addr - lookup_addr);
        root.print("  #{d} 0x{x:0>16} {s}+0x{x}\n", .{ index, addr, s.name, off });
    } else {
        root.print("  #{d} 0x{x:0>16} ???\n", .{ index, addr });
    }
}

/// Where a backtrace starts.
pub const Start = union(enum) {
    /// The instruction that faulted (e.g. RIP from an exception frame).
    pc: u64,
    /// A return address, e.g. the caller of the panic handler.
    return_address: u64,
    /// Only the frame chain.
    none,
};

/// Print a symbolized backtrace: first the starting address (if known), then
/// the return addresses found from frame pointer `rbp`.
///
/// If a starting return address also appears in the frame chain (as it does
/// for a panic, where `rbp` is the panic handler's own frame), the frames up
/// to and including it are skipped, so the panic machinery is not shown.
pub fn print(start: Start, rbp: u64) void {
    root.print("backtrace:\n", .{});
    var index: usize = 0;
    switch (start) {
        .pc => |pc| printFrame(index, pc, false),
        .return_address => |ret| printFrame(index, ret, true),
        .none => {},
    }
    if (start != .none) index += 1;

    var frames: [max_frames]u64 = undefined;
    const n = capture(rbp, &frames);
    var first: usize = 0;
    if (start == .return_address) {
        if (std.mem.indexOfScalar(u64, frames[0..n], start.return_address)) |i| first = i + 1;
    }
    for (frames[first..n]) |ret| {
        printFrame(index, ret, true);
        index += 1;
    }
    if (table == null) root.print("  (no kernel symbols loaded)\n", .{});
}
