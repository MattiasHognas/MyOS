//! Local APIC and I/O APIC driver.
//!
//! Replaces the legacy 8259 PIC: `init` masks the PIC, enables this CPU's local
//! APIC and masks every I/O APIC input. `route` then unmasks individual legacy
//! IRQs, and `timerInit` calibrates the LAPIC timer against the HPET and starts
//! it in periodic mode.
//!
//! **x2APIC.** Where the CPU has it, every local APIC runs in x2APIC mode,
//! with its registers as MSRs instead of a page of memory, as Linux runs
//! them: an interrupt to another CPU is one write instead of two writes and
//! a polled read, and under a hypervisor each of those memory accesses can
//! be an exit from the guest, where the MSRs have a fast path. The end of
//! every interrupt is a register write too. `x2apic` says which mode; the
//! register functions below pick the access.

const hpet = @import("../../drivers/hpet.zig");
const acpi = @import("../../firmware/acpi.zig");
const cpu = @import("cpu.zig");
const vmm = @import("vmm.zig");

/// First interrupt vector used for legacy IRQs: IRQ n is delivered as vector `IRQ_BASE + n`.
pub const IRQ_BASE: u8 = 32;
/// Vector the local APIC raises for spurious interrupts. These must not be acknowledged with an EOI.
pub const SPURIOUS: u8 = 0xFF;
/// Vector used by the LAPIC timer, just past the legacy IRQ range (32-47).
pub const TIMER_VECTOR: u8 = 48;

/// LAPIC timer ticks per millisecond, measured by `timerInit`. Zero until then.
pub var ticks_per_ms: u32 = 0;

var lapic: usize = 0;
var ioapic: usize = 0;
var ioapic_gsi_base: u32 = 0;
var ioapic_entries: u32 = 0;

/// Whether the local APICs run in x2APIC mode (decided on the boot CPU,
/// before any other is up, from `cpuid`).
pub var x2apic = false;

/// Return a pointer to the local APIC register at byte offset `off`
/// (xAPIC mode).
fn lapicReg(off: usize) *volatile u32 {
    return @ptrFromInt(lapic + off);
}

/// The MSR of the register at byte offset `off`, in x2APIC mode.
fn msrOf(off: usize) u32 {
    return 0x800 + @as(u32, @intCast(off >> 4));
}

pub fn readReg(off: usize) u32 {
    return if (x2apic) @truncate(cpu.rdmsr(msrOf(off))) else lapicReg(off).*;
}

fn writeReg(off: usize, value: u32) void {
    if (x2apic) cpu.wrmsr(msrOf(off), value) else lapicReg(off).* = value;
}

/// Read I/O APIC register `reg`. The register index is selected through
/// IOREGSEL (+0x00) and the value is read from IOWIN (+0x10).
fn ioRead(reg: u32) u32 {
    @as(*volatile u32, @ptrFromInt(ioapic)).* = reg;
    return @as(*volatile u32, @ptrFromInt(ioapic + 0x10)).*;
}

/// Write `val` to I/O APIC register `reg`, using the same IOREGSEL/IOWIN pair as `ioRead`.
fn ioWrite(reg: u32, val: u32) void {
    @as(*volatile u32, @ptrFromInt(ioapic)).* = reg;
    @as(*volatile u32, @ptrFromInt(ioapic + 0x10)).* = val;
}

/// Reprogram the legacy 8259 PICs so their vectors no longer overlap the CPU
/// exception vectors, then mask every line so they never fire.
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

/// Signal end-of-interrupt to the local APIC so it can deliver the next interrupt.
pub fn eoi() void {
    writeReg(0xB0, 0);
}

/// True once the local APIC is mapped and enabled on the boot CPU.
pub fn ready() bool {
    return lapic != 0;
}

/// Send interrupt `vector` to the CPU whose local APIC ID is `apic_id`.
/// Interrupts must be off: the command takes two register writes.
pub fn sendIpi(apic_id: u32, vector: u8) void {
    sendCommand(apic_id, vector); // fixed delivery, edge, physical destination
}

/// Send a non-maskable interrupt to the CPU whose local APIC ID is
/// `apic_id`: it arrives even while that CPU has interrupts off.
pub fn sendNmi(apic_id: u32) void {
    sendCommand(apic_id, 0x400); // delivery mode NMI; the vector is ignored
}

/// Write the interrupt command register and wait until the local APIC has
/// sent the interrupt.
fn sendCommand(apic_id: u32, low: u32) void {
    if (x2apic) {
        // One write of both halves; x2APIC has no delivery status to wait on.
        cpu.wrmsr(0x830, (@as(u64, apic_id) << 32) | low);
        return;
    }
    lapicReg(0x310).* = apic_id << 24;
    lapicReg(0x300).* = low;
    while (lapicReg(0x300).* & (1 << 12) != 0) {} // delivery status: pending
}

/// Return the local APIC ID of the calling CPU (32 bits in x2APIC mode).
pub fn id() u32 {
    if (x2apic) return @truncate(cpu.rdmsr(0x802));
    return lapicReg(0x20).* >> 24;
}

/// Enable this CPU's local APIC: globally (MSR), accepting all priorities,
/// software-enabled with the spurious vector. Every CPU runs this as it
/// comes up; the boot CPU from `init`.
pub fn initCpu() void {
    // Bit 11 enables the APIC, bit 10 (with it) puts it in x2APIC mode.
    cpu.wrmsr(0x1B, cpu.rdmsr(0x1B) | (1 << 11) | (if (x2apic) @as(u64, 1 << 10) else 0));
    writeReg(0x80, 0); // task priority: accept everything
    writeReg(0xF0, 0x100 | @as(u32, SPURIOUS)); // bit 8 = enable
}

/// Initialize the interrupt controllers.
///
/// Disables the legacy PIC (if ACPI reports one), enables and maps the local
/// APIC, maps the first I/O APIC and masks all of its inputs. Requires
/// `acpi.init` and `vmm.init` to have run. Panics if no I/O APIC is present.
pub fn init() void {
    if (acpi.has_8259) disablePic();

    // Local APIC: map it (every CPU reaches its own at the same address),
    // enable, in x2APIC mode where the CPU has it (CPUID.1:ECX bit 21).
    lapic = vmm.mapMmio(acpi.lapic_addr, 0x1000);
    x2apic = cpu.cpuid(1, 0).ecx & (1 << 21) != 0;
    initCpu();

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

/// Route legacy IRQ `irq` to interrupt `vector` on this CPU and unmask it.
///
/// Applies any MADT interrupt source override (GSI, polarity, trigger mode).
/// Panics if the resulting GSI is not handled by the first I/O APIC.
pub fn route(irq: u8, vector: u8) void {
    const gsi = acpi.irqToGsi(irq);
    if (gsi < ioapic_gsi_base or gsi >= ioapic_gsi_base + ioapic_entries)
        @panic("GSI is not on the first I/O APIC");

    const flags: u16 = if (acpi.irq_overrides[irq]) |o| o.flags else 0;
    var low: u32 = vector; // fixed delivery, physical destination, unmasked
    if ((flags & 0b11) == 0b11) low |= 1 << 13; // active low
    if (((flags >> 2) & 0b11) == 0b11) low |= 1 << 15; // level triggered

    const idx = gsi - ioapic_gsi_base;
    ioWrite(0x11 + 2 * idx, (id() & 0xFF) << 24); // destination LAPIC (8 bits: the I/O APIC's)
    ioWrite(0x10 + 2 * idx, low); // write low last: unmasks it
}

/// Calibrate the LAPIC timer and start it firing `TIMER_VECTOR` `hz` times per second.
///
/// Measures the timer rate by letting it count down for 10 ms of HPET time,
/// stores the result in `ticks_per_ms`, then switches it to periodic mode.
/// Requires `init` and `hpet.init` to have run.
pub fn timerInit(hz: u32) void {
    writeReg(0x3E0, 0x3); // divide the bus clock by 16
    writeReg(0x320, 1 << 16); // masked, one-shot: measure only
    writeReg(0x380, 0xFFFF_FFFF); // start counting down

    hpet.sleepNs(10_000_000); // 10 ms

    const elapsed = 0xFFFF_FFFF - readReg(0x390);
    ticks_per_ms = elapsed / 10;

    timerStart(hz);
}

/// Start this CPU's LAPIC timer firing `TIMER_VECTOR` `hz` times per second,
/// at the rate `timerInit` measured on the boot CPU: the timers of all CPUs
/// count the same clock.
pub fn timerStart(hz: u32) void {
    writeReg(0x3E0, 0x3); // divide the bus clock by 16
    writeReg(0x320, @as(u32, TIMER_VECTOR) | (1 << 17)); // periodic, unmasked
    writeReg(0x380, @intCast(@as(u64, ticks_per_ms) * 1000 / hz));
}
