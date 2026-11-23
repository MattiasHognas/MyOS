//! Meltdown: can a user program read kernel memory through the CPU itself?
//!
//! On affected CPUs (most Intel processors made before about 2019) a
//! program can read any memory that is mapped in its page tables, kernel
//! memory included, whatever the page permissions say: the CPU runs ahead
//! with the forbidden data before the fault is raised, and leaves traces of
//! it in the cache. No check in the kernel can prevent that. The only cure
//! is not to have kernel memory in user page tables at all (kernel
//! page-table isolation), which MyOS does not do: every address space
//! shares the kernel half.
//!
//! The decision (roadmap 2.9): MyOS does not implement page-table
//! isolation. It finds out whether the CPU is affected and **refuses to
//! boot** on one that is, because every secret in the kernel (and with the
//! direct map, all of physical memory) would be readable by any program.
//! Building with `-Dallow-meltdown` turns the refusal into a warning, for
//! running trusted programs on old hardware.
//!
//! `affected` (in `meltdown_rule.zig`) is the rule, as a pure function tested on the host. It
//! follows Linux's: a CPU is safe if it says so itself (the RDCL_NO bit),
//! or is from a vendor or of a kind known not to speculate this way;
//! anything unknown counts as affected.

const std = @import("std");
const build_options = @import("build_options");
const cpu = @import("cpu.zig");
const log = std.log.scoped(.meltdown);

const rule = @import("meltdown_rule.zig");
pub const CpuInfo = rule.CpuInfo;
pub const affected = rule.affected;
pub const familyModel = rule.familyModel;

var is_affected = false;

/// What `init` found.
pub fn cpuAffected() bool {
    return is_affected;
}

/// Read this CPU's identification.
pub fn thisCpu() CpuInfo {
    const leaf0 = cpu.cpuid(0, 0);
    var vendor: [12]u8 = undefined;
    std.mem.writeInt(u32, vendor[0..4], leaf0.ebx, .little);
    std.mem.writeInt(u32, vendor[4..8], leaf0.edx, .little);
    std.mem.writeInt(u32, vendor[8..12], leaf0.ecx, .little);
    const fm = familyModel(cpu.cpuid(1, 0).eax);
    // CPUID.7.0:EDX bit 29 says the ARCH_CAPABILITIES MSR (0x10A) exists.
    const has_msr = leaf0.eax >= 7 and cpu.cpuid(7, 0).edx & (1 << 29) != 0;
    return .{
        .vendor = vendor,
        .family = fm.family,
        .model = fm.model,
        .arch_capabilities = if (has_msr) cpu.rdmsr(0x10A) else 0,
    };
}

/// Check this CPU and refuse to continue on an affected one, unless the
/// kernel was built with `-Dallow-meltdown`. Called once during boot,
/// before any user program can run.
pub fn init() void {
    const info = thisCpu();
    is_affected = affected(info);
    if (!is_affected) {
        log.info("CPU ({s}, family {d} model {d}) is not affected by Meltdown", .{ info.vendor, info.family, info.model });
        return;
    }
    if (build_options.allow_meltdown) {
        log.warn("CPU ({s}, family {d} model {d}) is affected by Meltdown: user programs can read kernel memory. Continuing because of -Dallow-meltdown.", .{ info.vendor, info.family, info.model });
        return;
    }
    @panic("this CPU is affected by Meltdown, and MyOS has no page-table isolation: any program could read all memory. Build with -Dallow-meltdown to run anyway.");
}
