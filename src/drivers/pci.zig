const root = @import("root");
const cpu = @import("../arch/x86_64/cpu.zig");

var devices: [64]Device = undefined;
var count: usize = 0;

// A PCI device, as reported by the PCI configuration space. The caller must ensure that the device is valid (vendor ID != 0xFFFF).
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

// Read a 32-bit value from the given offset in the PCI configuration space of the given device. The caller must ensure that the offset is valid for the device's header type.
fn readRaw(bus: u8, dev: u8, func: u8, off: u8) u32 {
    cpu.outl(0xCF8, 0x8000_0000 | (@as(u32, bus) << 16) | (@as(u32, dev) << 11) |
        (@as(u32, func) << 8) | (off & 0xFC));
    return cpu.inl(0xCFC);
}

// Read a 32-bit value from the given offset in the PCI configuration space of the given device. The caller must ensure that the offset is valid for the device's header type.
pub fn read32(d: Device, off: u8) u32 {
    return readRaw(d.bus, d.dev, d.func, off);
}

// Write a 32-bit value to the given offset in the PCI configuration space of the given device. The caller must ensure that the offset is valid for the device's header type.
pub fn write32(d: Device, off: u8, val: u32) void {
    cpu.outl(0xCF8, 0x8000_0000 | (@as(u32, d.bus) << 16) | (@as(u32, d.dev) << 11) |
        (@as(u32, d.func) << 8) | (off & 0xFC));
    cpu.outl(0xCFC, val);
}

// Scan the PCI bus for devices. Populates `devices` and `count`. This is called once at boot.
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
            root.print("pci {x:0>2}:{x:0>2}.{d} {x:0>4}:{x:0>4} class {x:0>2}.{x:0>2}.{x:0>2}\n", .{ bus, dev, func, x.vendor, x.device, x.class, x.subclass, x.progif });
            count += 1;
        }
        // Function 0 says whether functions 1-7 exist (header type bit 7).
        if (func == 0 and (readRaw(bus, dev, 0, 0x0C) >> 16) & 0x80 == 0) break;
    };
}

// Find the first device with the given class, subclass, and programming interface. Returns null if no such device exists.
pub fn find(class: u8, subclass: u8, progif: u8) ?Device {
    for (devices[0..count]) |d| {
        if (d.class == class and d.subclass == subclass and d.progif == progif) return d;
    }
    return null;
}

// Physical address of a memory BAR (handles 64-bit BARs).
pub fn bar(d: Device, idx: u8) u64 {
    const lo = read32(d, 0x10 + idx * 4);
    const addr: u64 = lo & 0xFFFF_FFF0;
    if ((lo >> 1) & 0b11 == 0b10) return addr | (@as(u64, read32(d, 0x14 + idx * 4)) << 32);
    return addr;
}

// Allow the device to respond to memory accesses and to do DMA.
pub fn enableBusMaster(d: Device) void {
    write32(d, 0x04, read32(d, 0x04) | 0b110);
}
