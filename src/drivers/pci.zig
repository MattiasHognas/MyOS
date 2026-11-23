//! PCI bus enumeration and configuration space access.
//!
//! Uses the legacy I/O port mechanism (0xCF8 address / 0xCFC data). `scan`
//! records up to 64 devices at boot; drivers then look them up with `find`.

const std = @import("std");

const cpu = @import("../arch/x86_64/cpu.zig");

const log = std.log.scoped(.pci);

var devices: [64]Device = undefined;
var count: usize = 0;

/// A PCI function found by `scan`: its bus address, IDs and class codes.
pub const Device = struct {
    bus: u8,
    dev: u8,
    func: u8,
    vendor: u16,
    device: u16,
    class: u8,
    subclass: u8,
    progif: u8,
};

/// Read the 32-bit configuration register at offset `off` (rounded down to a
/// multiple of 4) of function `bus:dev.func`.
fn readRaw(bus: u8, dev: u8, func: u8, off: u8) u32 {
    cpu.outl(0xCF8, 0x8000_0000 | (@as(u32, bus) << 16) | (@as(u32, dev) << 11) |
        (@as(u32, func) << 8) | (off & 0xFC));
    return cpu.inl(0xCFC);
}

/// Read the 32-bit configuration register at offset `off` (rounded down to a
/// multiple of 4) of device `d`.
pub fn read32(d: Device, off: u8) u32 {
    return readRaw(d.bus, d.dev, d.func, off);
}

/// Write `val` to the 32-bit configuration register at offset `off` (rounded
/// down to a multiple of 4) of device `d`.
pub fn write32(d: Device, off: u8, val: u32) void {
    cpu.outl(0xCF8, 0x8000_0000 | (@as(u32, d.bus) << 16) | (@as(u32, d.dev) << 11) |
        (@as(u32, d.func) << 8) | (off & 0xFC));
    cpu.outl(0xCFC, val);
}

/// Brute-force scan every bus, device and function, print each one found and
/// record up to 64 of them for `find`. Call once at boot.
pub fn scan() void {
    for (0..256) |b| for (0..32) |d| for (0..8) |f| {
        const bus: u8 = @intCast(b);
        const dev: u8 = @intCast(d);
        const func: u8 = @intCast(f);

        const id = readRaw(bus, dev, func, 0x00);
        if (id & 0xFFFF == 0xFFFF) {
            if (func == 0) break; // no device in this slot at all
            continue;
        }
        const class = readRaw(bus, dev, func, 0x08);
        if (count < devices.len) {
            devices[count] = .{
                .bus = bus,
                .dev = dev,
                .func = func,
                .vendor = @truncate(id),
                .device = @truncate(id >> 16),
                .class = @truncate(class >> 24),
                .subclass = @truncate(class >> 16),
                .progif = @truncate(class >> 8),
            };
            const x = devices[count];
            log.info("{x:0>2}:{x:0>2}.{d} {x:0>4}:{x:0>4} class {x:0>2}.{x:0>2}.{x:0>2}", .{ bus, dev, func, x.vendor, x.device, x.class, x.subclass, x.progif });
            count += 1;
        }
        // Function 0 says whether functions 1-7 exist (header type bit 7).
        if (func == 0 and (readRaw(bus, dev, 0, 0x0C) >> 16) & 0x80 == 0) break;
    };
}

/// Return the first scanned device with the given class, subclass and
/// programming interface, or null if there is none. Requires `scan`.
pub fn find(class: u8, subclass: u8, progif: u8) ?Device {
    for (devices[0..count]) |d| {
        if (d.class == class and d.subclass == subclass and d.progif == progif) return d;
    }
    return null;
}

/// Return the physical address of memory BAR `idx` of device `d`.
/// 64-bit BARs are combined with the following BAR register.
pub fn bar(d: Device, idx: u8) u64 {
    const lo = read32(d, 0x10 + idx * 4);
    const addr: u64 = lo & 0xFFFF_FFF0;
    if ((lo >> 1) & 0b11 == 0b10) return addr | (@as(u64, read32(d, 0x14 + idx * 4)) << 32);
    return addr;
}

/// Enable memory space decoding and bus mastering for `d`, so it responds to
/// MMIO accesses and can perform DMA.
pub fn enableBusMaster(d: Device) void {
    write32(d, 0x04, read32(d, 0x04) | 0b110);
}
