//! ACPI table discovery and MADT parsing.
//!
//! `init` validates the RSDP, locates the XSDT (or RSDT on ACPI 1.0) and parses
//! the MADT to learn about CPUs, the local APIC, I/O APICs and legacy IRQ
//! overrides. Other drivers look up their own tables with `findTable`.

const std = @import("std");

const pmm = @import("../kernel/pmm.zig");

const log = std.log.scoped(.acpi);

var root_table: []const u8 = &.{}; // XSDT (8-byte entries) or RSDT (4-byte)
var entry_size: usize = 8;

/// An I/O APIC described by the MADT.
pub const IoApic = struct { id: u8, addr: u32, gsi_base: u32 };
/// An MADT interrupt source override: legacy IRQ is wired to `gsi` instead.
/// `flags` holds polarity in bits 0-1 and trigger mode in bits 2-3.
pub const Override = struct { gsi: u32, flags: u16 };

/// Physical address of the local APIC registers.
pub var lapic_addr: u64 = 0;
/// True if legacy 8259 PICs are present and must be disabled.
pub var has_8259 = false;
/// Local APIC IDs of the usable CPUs. The first `cpu_count` entries are valid.
pub var cpu_ids: [64]u8 = undefined;
/// Number of usable CPUs found in the MADT.
pub var cpu_count: usize = 0;
/// I/O APICs found in the MADT. The first `ioapic_count` entries are valid.
pub var ioapics: [8]IoApic = undefined;
/// Number of I/O APICs found in the MADT.
pub var ioapic_count: usize = 0;
/// Interrupt source overrides, indexed by legacy IRQ (0-15). Null = identity mapped.
pub var irq_overrides: [16]?Override = @splat(null);

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

/// Return true if the bytes in `b` sum to 0 modulo 256, as every ACPI checksum requires.
fn checksumOk(b: []const u8) bool {
    var sum: u8 = 0;
    for (b) |x| sum +%= x; // wrapping add
    return sum == 0;
}

/// Return the whole ACPI table at physical address `phys`, using the length
/// from its 36-byte standard header (offset 4).
fn tableAt(phys: u64) []const u8 {
    const len = r32(pmm.physToVirt(phys)[0..8], 4);
    return pmm.physToVirt(phys)[0..len];
}

/// Return the first table listed in the XSDT/RSDT with signature `sig` (e.g.
/// "HPET") and a valid checksum, or null if there is none. Requires `init`.
pub fn findTable(sig: *const [4]u8) ?[]const u8 {
    var off: usize = 36;
    while (off + entry_size <= root_table.len) : (off += entry_size) {
        const phys = if (entry_size == 8) r64(root_table, off) else r32(root_table, off);
        const t = tableAt(phys);
        if (std.mem.eql(u8, t[0..4], sig) and checksumOk(t)) return t;
    }
    return null;
}

/// Translate a legacy ISA IRQ (e.g. keyboard = 1, PIT = 0) to the global
/// system interrupt (I/O APIC input) it is wired to, applying any override.
pub fn irqToGsi(irq: u8) u32 {
    return if (irq_overrides[irq]) |o| o.gsi else irq;
}

/// Parse the MADT `m` and fill in `lapic_addr`, `has_8259`, `cpu_ids`,
/// `cpu_count`, `ioapics`, `ioapic_count` and `irq_overrides`. Entries that
/// do not fit in the fixed-size arrays are ignored.
fn parseMadt(m: []const u8) void {
    lapic_addr = r32(m, 36);
    has_8259 = (r32(m, 40) & 1) != 0;

    var off: usize = 44;
    while (off + 2 <= m.len) {
        const len = m[off + 1];
        if (len < 2) break; // malformed entry; don't loop forever
        const e = m[off .. off + len];
        switch (m[off]) {
            0 => if ((r32(e, 4) & 0b11) != 0 and cpu_count < cpu_ids.len) { // enabled or can be onlined
                cpu_ids[cpu_count] = e[3];
                cpu_count += 1;
            },
            1 => if (ioapic_count < ioapics.len) {
                ioapics[ioapic_count] = .{ .id = e[2], .addr = r32(e, 4), .gsi_base = r32(e, 8) };
                ioapic_count += 1;
            },
            2 => if (e[3] < 16) {
                irq_overrides[e[3]] = .{ .gsi = r32(e, 4), .flags = r16(e, 8) };
            },
            5 => lapic_addr = r64(e, 4), // 64-bit LAPIC address override
            else => {},
        }
        off += len;
    }
}

/// Locate and validate the ACPI tables, then parse the MADT and print a summary.
///
/// `rsdp_addr` is the RSDP address from Limine (physical, or an HHDM pointer on
/// older revisions) and `hhdm` is the HHDM offset. Requires `pmm.init`. Panics
/// if the RSDP or root table is invalid, or if there is no MADT.
pub fn init(rsdp_addr: u64, hhdm: u64) void {
    // Newer Limine revisions give a physical address; older ones an HHDM pointer.
    const phys = if (rsdp_addr >= hhdm) rsdp_addr - hhdm else rsdp_addr;
    const rsdp = pmm.physToVirt(phys)[0..36];

    if (!std.mem.eql(u8, rsdp[0..8], "RSD PTR ")) @panic("ACPI: bad RSDP signature");
    if (!checksumOk(rsdp[0..20])) @panic("ACPI: bad RSDP checksum");

    if (rsdp[15] >= 2) {
        root_table = tableAt(r64(rsdp, 24));
        entry_size = 8;
    } else {
        root_table = tableAt(r32(rsdp, 16));
        entry_size = 4;
    }
    if (!checksumOk(root_table)) @panic("ACPI: bad root table checksum");

    var off: usize = 36;
    while (off + entry_size <= root_table.len) : (off += entry_size) {
        const p = if (entry_size == 8) r64(root_table, off) else r32(root_table, off);
        log.debug("{s} lists table {s}", .{ root_table[0..4], tableAt(p)[0..4] });
    }

    parseMadt(findTable("APIC") orelse @panic("ACPI: no MADT"));

    log.info("CPUs: {d}, LAPIC at 0x{x}, legacy PIC: {}", .{ cpu_count, lapic_addr, has_8259 });
    for (ioapics[0..ioapic_count]) |io| {
        log.info("I/O APIC {d} at 0x{x}, GSI base {d}", .{ io.id, io.addr, io.gsi_base });
    }
    for (irq_overrides, 0..) |o, irq| {
        if (o) |ov| log.debug("IRQ {d} -> GSI {d} (flags 0x{x})", .{ irq, ov.gsi, ov.flags });
    }
}
