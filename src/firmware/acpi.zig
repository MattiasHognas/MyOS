const std = @import("std");
const root = @import("root");
const pmm = @import("../kernel/pmm.zig");

fn r16(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .little);
}
fn r32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}
fn r64(b: []const u8, o: usize) u64 {
    return std.mem.readInt(u64, b[o..][0..8], .little);
}

fn checksumOk(b: []const u8) bool {
    var sum: u8 = 0;
    for (b) |x| sum +%= x; // wrapping add
    return sum == 0;
}

// Every table starts with a 36-byte header; its length is at offset 4.
fn tableAt(phys: u64) []const u8 {
    const len = r32(pmm.physToVirt(phys)[0..8], 4);
    return pmm.physToVirt(phys)[0..len];
}

var root_table: []const u8 = &.{}; // XSDT (8-byte entries) or RSDT (4-byte)
var entry_size: usize = 8;

pub fn findTable(sig: *const [4]u8) ?[]const u8 {
    var off: usize = 36;
    while (off + entry_size <= root_table.len) : (off += entry_size) {
        const phys = if (entry_size == 8) r64(root_table, off) else r32(root_table, off);
        const t = tableAt(phys);
        if (std.mem.eql(u8, t[0..4], sig) and checksumOk(t)) return t;
    }
    return null;
}

// ---- What the MADT tells us ----
pub const IoApic = struct { id: u8, addr: u32, gsi_base: u32 };
pub const Override = struct { gsi: u32, flags: u16 }; // flags: polarity bits 0-1, trigger bits 2-3

pub var lapic_addr: u64 = 0;
pub var has_8259 = false; // legacy PICs present (mask them in step 9)
pub var cpu_ids: [64]u8 = undefined;
pub var cpu_count: usize = 0;
pub var ioapics: [8]IoApic = undefined;
pub var ioapic_count: usize = 0;
pub var irq_overrides: [16]?Override = @splat(null);

/// Legacy IRQ (keyboard = 1, PIT = 0) -> I/O APIC input (GSI).
pub fn irqToGsi(irq: u8) u32 {
    return if (irq_overrides[irq]) |o| o.gsi else irq;
}

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

    root.print("ACPI {s}:", .{root_table[0..4]});
    var off: usize = 36;
    while (off + entry_size <= root_table.len) : (off += entry_size) {
        const p = if (entry_size == 8) r64(root_table, off) else r32(root_table, off);
        root.print(" {s}", .{tableAt(p)[0..4]});
    }
    root.print("\n", .{});

    parseMadt(findTable("APIC") orelse @panic("ACPI: no MADT"));

    root.print("CPUs: {d}, LAPIC at 0x{x}, legacy PIC: {}\n", .{ cpu_count, lapic_addr, has_8259 });
    for (ioapics[0..ioapic_count]) |io| {
        root.print("I/O APIC {d} at 0x{x}, GSI base {d}\n", .{ io.id, io.addr, io.gsi_base });
    }
    for (irq_overrides, 0..) |o, irq| {
        if (o) |ov| root.print("IRQ {d} -> GSI {d} (flags 0x{x})\n", .{ irq, ov.gsi, ov.flags });
    }
}
