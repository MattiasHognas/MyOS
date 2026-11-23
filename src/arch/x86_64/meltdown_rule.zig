//! The rule that says whether a CPU is affected by Meltdown, as pure
//! functions of its identification. No kernel dependencies: tested on the
//! host. `meltdown.zig` reads the CPU and applies the policy.

const std = @import("std");

/// What `affected` decides from.
pub const CpuInfo = struct {
    /// CPUID vendor string, e.g. "GenuineIntel".
    vendor: [12]u8,
    /// Family and model after combining the extended fields.
    family: u32,
    model: u32,
    /// IA32_ARCH_CAPABILITIES, or 0 if the CPU does not have the MSR.
    arch_capabilities: u64,
};

/// IA32_ARCH_CAPABILITIES bit 0: not susceptible to rogue data cache load.
const RDCL_NO: u64 = 1 << 0;

/// Intel family 6 models that never were affected: the in-order Atoms
/// (Bonnell and Saltwell cores), which do not execute out of order.
const safe_intel_models = [_]u32{ 0x1C, 0x26, 0x27, 0x35, 0x36 };

/// True if a CPU described by `info` lets user programs read kernel memory
/// that is mapped in their page tables.
pub fn affected(info: CpuInfo) bool {
    if (info.arch_capabilities & RDCL_NO != 0) return false; // it says it is not
    if (std.mem.eql(u8, &info.vendor, "AuthenticAMD")) return false;
    if (std.mem.eql(u8, &info.vendor, "HygonGenuine")) return false;
    if (std.mem.eql(u8, &info.vendor, "GenuineIntel")) {
        if (info.family < 6) return false; // Pentium and older: no such speculation
        if (info.family == 6) {
            for (safe_intel_models) |model| {
                if (info.model == model) return false;
            }
        }
        return true;
    }
    // Centaur and Zhaoxin family 7 are documented as unaffected.
    if (std.mem.eql(u8, &info.vendor, "CentaurHauls") or std.mem.eql(u8, &info.vendor, "  Shanghai  ")) {
        return info.family != 7;
    }
    return true; // unknown vendor: assume the worst
}

/// Split CPUID leaf 1 EAX into family and model, combining the base and
/// extended fields as the manuals describe.
pub fn familyModel(eax: u32) struct { family: u32, model: u32 } {
    const base_family = (eax >> 8) & 0xF;
    const base_model = (eax >> 4) & 0xF;
    const ext_family = (eax >> 20) & 0xFF;
    const ext_model = (eax >> 16) & 0xF;
    const family = if (base_family == 0xF) base_family + ext_family else base_family;
    const model = if (base_family == 6 or base_family == 0xF) (ext_model << 4) | base_model else base_model;
    return .{ .family = family, .model = model };
}
