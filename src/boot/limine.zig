const COMMON = [2]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

fn Request(comptime a: u64, comptime b: u64, comptime Response: type) type {
    return extern struct {
        id: [4]u64 = .{ COMMON[0], COMMON[1], a, b },
        revision: u64 = 0,
        response: ?*Response = null,
    };
}

pub const Framebuffer = extern struct {
    address: *anyopaque,
    width: u64,
    height: u64,
    pitch: u64, // bytes per row
    bpp: u16,
    // remaining fields not needed yet
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: [*]*Framebuffer,
};

pub const FramebufferRequest = Request(0x9d5827dcd881dd75, 0xa3148604f6fab11b, FramebufferResponse);
pub const MemmapRequest = Request(0x67cf3d9d378a806f, 0xe304acdfc50c3c62, MemmapResponse);
pub const HhdmRequest = Request(0x48dcf1cb8ad2b852, 0x63984e959a98244b, HhdmResponse);

pub const MemmapEntry = extern struct { base: u64, length: u64, type: u64 };
pub const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]*MemmapEntry,
};
pub const HhdmResponse = extern struct { revision: u64, offset: u64 };

pub const MEMMAP_USABLE = 0;
pub const memmap_names = [_][]const u8{
    "usable", "reserved",               "ACPI reclaimable", "ACPI NVS",
    "bad",    "bootloader reclaimable", "kernel+modules",   "framebuffer",
};

pub const KernelAddressRequest = Request(0x71ba76863cc55f63, 0xb2644a48c516a487, KernelAddressResponse);
pub const KernelAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

pub const RsdpRequest = Request(0xc5e77b6b397e7b43, 0x27637845accdcf3c, RsdpResponse);
pub const RsdpResponse = extern struct { revision: u64, address: u64 };

pub const ModuleRequest = Request(0x3e7e279702be32af, 0xca1c4f3bd1280cee, ModuleResponse);
pub const ModuleResponse = extern struct {
    revision: u64,
    module_count: u64,
    modules: [*]*File,
};
pub const File = extern struct {
    revision: u64,
    address: u64, // HHDM virtual address of the file's contents
    size: u64,
    path: [*:0]const u8,
    string: [*:0]const u8,
    // more fields follow; not needed
};
