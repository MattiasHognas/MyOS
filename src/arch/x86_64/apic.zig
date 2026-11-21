const cpu = @import("cpu.zig");
const vmm = @import("vmm.zig");
const acpi = @import("../../firmware/acpi.zig");
const hpet = @import("../../drivers/hpet.zig");

pub const IRQ_BASE: u8 = 32; // legacy IRQ n -> vector 32 + n
pub const SPURIOUS: u8 = 0xFF;
pub const TIMER_VECTOR: u8 = 48; // just past the legacy IRQ range (32-47)

pub var ticks_per_ms: u32 = 0;

var lapic: usize = 0;
var ioapic: usize = 0;
var ioapic_gsi_base: u32 = 0;
var ioapic_entries: u32 = 0;

// Local APIC
fn lapicReg(off: usize) *volatile u32 {
    return @ptrFromInt(lapic + off);
}

// I/O APIC: select a register at +0x00, access it at +0x10
fn ioRead(reg: u32) u32 {
    @as(*volatile u32, @ptrFromInt(ioapic)).* = reg;
    return @as(*volatile u32, @ptrFromInt(ioapic + 0x10)).*;
}

// Write a register to the I/O APIC.
fn ioWrite(reg: u32, val: u32) void {
    @as(*volatile u32, @ptrFromInt(ioapic)).* = reg;
    @as(*volatile u32, @ptrFromInt(ioapic + 0x10)).* = val;
}

// Legacy PIC: move it off the exception vectors, then mask everything
fn disablePic() void {
    const seq = [_][2]u16{
        .{ 0x20, 0x11 }, .{ 0xA0, 0x11 }, // start init
        .{ 0x21, 0x20 }, .{ 0xA1, 0x28 }, // vector offsets 0x20 / 0x28
        .{ 0x21, 0x04 }, .{ 0xA1, 0x02 }, // master/slave wiring
        .{ 0x21, 0x01 }, .{ 0xA1, 0x01 }, // 8086 mode
        .{ 0x21, 0xFF }, .{ 0xA1, 0xFF }, // mask all lines
    };
    for (seq) |s| {
        cpu.outb(s[0], @intCast(s[1]));
        cpu.outb(0x80, 0); // short delay for old hardware
    }
}

// Send an EOI to the local APIC.
pub fn eoi() void {
    lapicReg(0xB0).* = 0;
}

// Return the local APIC ID of this CPU.
pub fn id() u8 {
    return @truncate(lapicReg(0x20).* >> 24);
}

// Initialize the APIC subsystem. Disables the legacy PIC, enables the local APIC, and sets up the I/O APIC. Panics if no I/O APIC is found.
pub fn init() void {
    if (acpi.has_8259) disablePic();

    // Local APIC: enable globally (MSR), map, accept all priorities, software-enable.
    cpu.wrmsr(0x1B, cpu.rdmsr(0x1B) | (1 << 11));
    lapic = vmm.mapMmio(acpi.lapic_addr, 0x1000);
    lapicReg(0x80).* = 0; // task priority: accept everything
    lapicReg(0xF0).* = 0x100 | @as(u32, SPURIOUS); // bit 8 = enable

    // I/O APIC: map, read how many inputs it has, start with all masked.
    if (acpi.ioapic_count == 0) @panic("no I/O APIC");
    const io = acpi.ioapics[0];
    ioapic = vmm.mapMmio(io.addr, 0x20);
    ioapic_gsi_base = io.gsi_base;
    ioapic_entries = ((ioRead(0x01) >> 16) & 0xFF) + 1;

    var i: u32 = 0;
    while (i < ioapic_entries) : (i += 1) {
        ioWrite(0x10 + 2 * i, 1 << 16); // bit 16 = masked
        ioWrite(0x11 + 2 * i, 0);
    }
}

// Deliver legacy IRQ `irq` as `vector` to this CPU.
pub fn route(irq: u8, vector: u8) void {
    const gsi = acpi.irqToGsi(irq);
    if (gsi < ioapic_gsi_base or gsi >= ioapic_gsi_base + ioapic_entries)
        @panic("GSI is not on the first I/O APIC");

    const flags: u16 = if (acpi.irq_overrides[irq]) |o| o.flags else 0;
    var low: u32 = vector; // fixed delivery, physical destination, unmasked
    if ((flags & 0b11) == 0b11) low |= 1 << 13; // active low
    if (((flags >> 2) & 0b11) == 0b11) low |= 1 << 15; // level triggered

    const idx = gsi - ioapic_gsi_base;
    ioWrite(0x11 + 2 * idx, @as(u32, id()) << 24); // destination LAPIC
    ioWrite(0x10 + 2 * idx, low); // write low last: unmasks it
}

// Initialize the APIC subsystem. Disables the legacy PIC, enables the local APIC, and sets up the I/O APIC. Panics if no I/O APIC is found.
pub fn timerInit(hz: u32) void {
    lapicReg(0x3E0).* = 0x3; // divide the bus clock by 16
    lapicReg(0x320).* = 1 << 16; // masked, one-shot: measure only
    lapicReg(0x380).* = 0xFFFF_FFFF; // start counting down

    hpet.sleepNs(10_000_000); // 10 ms

    const elapsed = 0xFFFF_FFFF - lapicReg(0x390).*;
    ticks_per_ms = elapsed / 10;

    lapicReg(0x320).* = @as(u32, TIMER_VECTOR) | (1 << 17); // periodic, unmasked
    lapicReg(0x380).* = @intCast(@as(u64, ticks_per_ms) * 1000 / hz);
}
