//! The text of `/proc/cpuinfo`, in Linux's format, from what `cpuid` says.
//!
//! One block per CPU that is up, with the fields programs read: the
//! vendor, family, model and stepping, the model name, the clock rate
//! where the TSC gives one, the topology (one package, one thread per
//! core), and the `flags` line with Linux's names for the features. A
//! program that looks for `avx2` or `sse4_2` there finds it if the CPU
//! has it.
//!
//! Pure: the caller hands over the `cpuid` leaves, so this is tested on
//! the host.

const std = @import("std");

/// One `cpuid` result.
pub const Leaf = struct { eax: u32 = 0, ebx: u32 = 0, ecx: u32 = 0, edx: u32 = 0 };

/// The leaves the text is made from. A leaf the CPU does not have is
/// left at zero.
pub const Leaves = struct {
    /// Leaf 0: the highest standard leaf and the vendor.
    l0: Leaf = .{},
    /// Leaf 1: family, model, stepping and the first feature words.
    l1: Leaf = .{},
    /// Leaf 7, subleaf 0: the extended features.
    l7: Leaf = .{},
    /// Leaf 0x80000001: the AMD-defined features (`lm`, `syscall`, ...).
    e1: Leaf = .{},
    /// Leaves 0x80000002 to 0x80000004: the brand string.
    brand: [3]Leaf = @splat(.{}),
};

/// What differs between the CPUs.
pub const Cpu = struct { number: u32, apic_id: u32 };

const Flag = struct { name: []const u8, word: enum { l1_edx, l1_ecx, l7_ebx, l7_ecx, l7_edx, e1_edx, e1_ecx }, bit: u5 };

/// Linux's names, in the order of its `cpufeatures.h` words.
const flags = [_]Flag{
    .{ .name = "fpu", .word = .l1_edx, .bit = 0 },
    .{ .name = "vme", .word = .l1_edx, .bit = 1 },
    .{ .name = "de", .word = .l1_edx, .bit = 2 },
    .{ .name = "pse", .word = .l1_edx, .bit = 3 },
    .{ .name = "tsc", .word = .l1_edx, .bit = 4 },
    .{ .name = "msr", .word = .l1_edx, .bit = 5 },
    .{ .name = "pae", .word = .l1_edx, .bit = 6 },
    .{ .name = "mce", .word = .l1_edx, .bit = 7 },
    .{ .name = "cx8", .word = .l1_edx, .bit = 8 },
    .{ .name = "apic", .word = .l1_edx, .bit = 9 },
    .{ .name = "sep", .word = .l1_edx, .bit = 11 },
    .{ .name = "mtrr", .word = .l1_edx, .bit = 12 },
    .{ .name = "pge", .word = .l1_edx, .bit = 13 },
    .{ .name = "mca", .word = .l1_edx, .bit = 14 },
    .{ .name = "cmov", .word = .l1_edx, .bit = 15 },
    .{ .name = "pat", .word = .l1_edx, .bit = 16 },
    .{ .name = "pse36", .word = .l1_edx, .bit = 17 },
    .{ .name = "clflush", .word = .l1_edx, .bit = 19 },
    .{ .name = "mmx", .word = .l1_edx, .bit = 23 },
    .{ .name = "fxsr", .word = .l1_edx, .bit = 24 },
    .{ .name = "sse", .word = .l1_edx, .bit = 25 },
    .{ .name = "sse2", .word = .l1_edx, .bit = 26 },
    .{ .name = "ht", .word = .l1_edx, .bit = 28 },
    .{ .name = "syscall", .word = .e1_edx, .bit = 11 },
    .{ .name = "nx", .word = .e1_edx, .bit = 20 },
    .{ .name = "mmxext", .word = .e1_edx, .bit = 22 },
    .{ .name = "fxsr_opt", .word = .e1_edx, .bit = 25 },
    .{ .name = "pdpe1gb", .word = .e1_edx, .bit = 26 },
    .{ .name = "rdtscp", .word = .e1_edx, .bit = 27 },
    .{ .name = "lm", .word = .e1_edx, .bit = 29 },
    .{ .name = "pni", .word = .l1_ecx, .bit = 0 },
    .{ .name = "pclmulqdq", .word = .l1_ecx, .bit = 1 },
    .{ .name = "monitor", .word = .l1_ecx, .bit = 3 },
    .{ .name = "ssse3", .word = .l1_ecx, .bit = 9 },
    .{ .name = "fma", .word = .l1_ecx, .bit = 12 },
    .{ .name = "cx16", .word = .l1_ecx, .bit = 13 },
    .{ .name = "pcid", .word = .l1_ecx, .bit = 17 },
    .{ .name = "sse4_1", .word = .l1_ecx, .bit = 19 },
    .{ .name = "sse4_2", .word = .l1_ecx, .bit = 20 },
    .{ .name = "x2apic", .word = .l1_ecx, .bit = 21 },
    .{ .name = "movbe", .word = .l1_ecx, .bit = 22 },
    .{ .name = "popcnt", .word = .l1_ecx, .bit = 23 },
    .{ .name = "aes", .word = .l1_ecx, .bit = 25 },
    .{ .name = "xsave", .word = .l1_ecx, .bit = 26 },
    .{ .name = "avx", .word = .l1_ecx, .bit = 28 },
    .{ .name = "f16c", .word = .l1_ecx, .bit = 29 },
    .{ .name = "rdrand", .word = .l1_ecx, .bit = 30 },
    .{ .name = "hypervisor", .word = .l1_ecx, .bit = 31 },
    .{ .name = "lahf_lm", .word = .e1_ecx, .bit = 0 },
    .{ .name = "abm", .word = .e1_ecx, .bit = 5 },
    .{ .name = "sse4a", .word = .e1_ecx, .bit = 6 },
    .{ .name = "3dnowprefetch", .word = .e1_ecx, .bit = 8 },
    .{ .name = "fsgsbase", .word = .l7_ebx, .bit = 0 },
    .{ .name = "bmi1", .word = .l7_ebx, .bit = 3 },
    .{ .name = "avx2", .word = .l7_ebx, .bit = 5 },
    .{ .name = "smep", .word = .l7_ebx, .bit = 7 },
    .{ .name = "bmi2", .word = .l7_ebx, .bit = 8 },
    .{ .name = "erms", .word = .l7_ebx, .bit = 9 },
    .{ .name = "invpcid", .word = .l7_ebx, .bit = 10 },
    .{ .name = "avx512f", .word = .l7_ebx, .bit = 16 },
    .{ .name = "avx512dq", .word = .l7_ebx, .bit = 17 },
    .{ .name = "rdseed", .word = .l7_ebx, .bit = 18 },
    .{ .name = "adx", .word = .l7_ebx, .bit = 19 },
    .{ .name = "smap", .word = .l7_ebx, .bit = 20 },
    .{ .name = "clflushopt", .word = .l7_ebx, .bit = 23 },
    .{ .name = "clwb", .word = .l7_ebx, .bit = 24 },
    .{ .name = "avx512cd", .word = .l7_ebx, .bit = 28 },
    .{ .name = "sha_ni", .word = .l7_ebx, .bit = 29 },
    .{ .name = "avx512bw", .word = .l7_ebx, .bit = 30 },
    .{ .name = "avx512vl", .word = .l7_ebx, .bit = 31 },
    .{ .name = "umip", .word = .l7_ecx, .bit = 2 },
    .{ .name = "pku", .word = .l7_ecx, .bit = 3 },
    .{ .name = "vaes", .word = .l7_ecx, .bit = 9 },
    .{ .name = "vpclmulqdq", .word = .l7_ecx, .bit = 10 },
    .{ .name = "rdpid", .word = .l7_ecx, .bit = 22 },
    .{ .name = "fsrm", .word = .l7_edx, .bit = 4 },
};

fn word(l: *const Leaves, w: @FieldType(Flag, "word")) u32 {
    return switch (w) {
        .l1_edx => l.l1.edx,
        .l1_ecx => l.l1.ecx,
        .l7_ebx => l.l7.ebx,
        .l7_ecx => l.l7.ecx,
        .l7_edx => l.l7.edx,
        .e1_edx => l.e1.edx,
        .e1_ecx => l.e1.ecx,
    };
}

/// The family, model and stepping as Linux reports them: the extended
/// family is added for family 15, the extended model taken for 6 and 15.
pub fn signature(eax: u32) struct { family: u32, model: u32, stepping: u32 } {
    const base_family = (eax >> 8) & 0xF;
    const family = if (base_family == 0xF) base_family + ((eax >> 20) & 0xFF) else base_family;
    var model = (eax >> 4) & 0xF;
    if (base_family >= 6) model |= ((eax >> 16) & 0xF) << 4;
    return .{ .family = family, .model = model, .stepping = eax & 0xF };
}

/// `/proc/cpuinfo` for `cpus`, all of them like the one `leaves` came
/// from. `tsc_hz` is 0 if the rate is not known. In memory from
/// `allocator`, which the caller frees.
pub fn format(allocator: std.mem.Allocator, leaves: Leaves, cpus: []const Cpu, tsc_hz: u64) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var vendor: [12]u8 = undefined;
    std.mem.writeInt(u32, vendor[0..4], leaves.l0.ebx, .little);
    std.mem.writeInt(u32, vendor[4..8], leaves.l0.edx, .little);
    std.mem.writeInt(u32, vendor[8..12], leaves.l0.ecx, .little);
    var brand_buf: [48]u8 = undefined;
    for (leaves.brand, 0..) |b, i| {
        for ([_]u32{ b.eax, b.ebx, b.ecx, b.edx }, 0..) |r, j| std.mem.writeInt(u32, brand_buf[i * 16 + j * 4 ..][0..4], r, .little);
    }
    const brand_end = std.mem.indexOfScalar(u8, &brand_buf, 0) orelse brand_buf.len;
    const brand = std.mem.trim(u8, brand_buf[0..brand_end], " ");
    const sig = signature(leaves.l1.eax);

    var flag_line: std.ArrayList(u8) = .empty;
    defer flag_line.deinit(allocator);
    for (flags) |f| {
        if (word(&leaves, f.word) & (@as(u32, 1) << f.bit) == 0) continue;
        if (flag_line.items.len != 0) try flag_line.append(allocator, ' ');
        try flag_line.appendSlice(allocator, f.name);
    }

    for (cpus) |c| {
        try out.print(allocator, "processor\t: {d}\nvendor_id\t: {s}\ncpu family\t: {d}\nmodel\t\t: {d}\nmodel name\t: {s}\nstepping\t: {d}\n", .{ c.number, vendor, sig.family, sig.model, if (brand.len == 0) "unknown" else brand, sig.stepping });
        if (tsc_hz != 0) try out.print(allocator, "cpu MHz\t\t: {d}.{d:0>3}\n", .{ tsc_hz / 1_000_000, tsc_hz / 1000 % 1000 });
        try out.print(allocator, "physical id\t: 0\nsiblings\t: {d}\ncore id\t\t: {d}\ncpu cores\t: {d}\napicid\t\t: {d}\n", .{ cpus.len, c.number, cpus.len, c.apic_id });
        try out.print(allocator, "fpu\t\t: yes\nfpu_exception\t: yes\ncpuid level\t: {d}\nwp\t\t: yes\nflags\t\t: {s}\n", .{ leaves.l0.eax, flag_line.items });
        try out.appendSlice(allocator, "clflush size\t: 64\ncache_alignment\t: 64\naddress sizes\t: 48 bits virtual\n\n");
    }
    return out.toOwnedSlice(allocator);
}

/// The text of `/sys/devices/system/cpu/online` (and `possible`,
/// `present`) for `n` CPUs numbered from 0: "0" or "0-3".
pub fn rangeList(buf: []u8, n: usize) []const u8 {
    if (n <= 1) return std.fmt.bufPrint(buf, "0\n", .{}) catch unreachable;
    return std.fmt.bufPrint(buf, "0-{d}\n", .{n - 1}) catch unreachable;
}
