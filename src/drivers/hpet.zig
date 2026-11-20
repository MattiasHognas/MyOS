const std = @import("std");
const acpi = @import("../firmware/acpi.zig");
const vmm = @import("../arch/x86_64/vmm.zig");

var base: usize = 0;
var period_fs: u64 = 0; // femtoseconds per counter tick

fn reg(off: usize) *volatile u64 {
    return @ptrFromInt(base + off);
}

pub fn init() void {
    const t = acpi.findTable("HPET") orelse @panic("no HPET");
    const phys = std.mem.readInt(u64, t[44..52], .little); // address field of the table
    base = vmm.mapMmio(phys, 0x400);

    period_fs = reg(0x000).* >> 32; // capabilities: upper 32 bits = period
    reg(0x010).* |= 1; // configuration: bit 0 = start the counter
}

pub fn nanos() u64 {
    // u128 so the multiplication can't overflow after a few hours of uptime
    return @intCast(@as(u128, reg(0x0F0).*) * period_fs / 1_000_000);
}

pub fn sleepNs(ns: u64) void {
    const end = nanos() + ns;
    while (nanos() < end) std.atomic.spinLoopHint();
}
