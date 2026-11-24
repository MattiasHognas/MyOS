//! Limine boot protocol definitions.
//!
//! The kernel places request structures in the `.limine_requests` section;
//! the bootloader finds them by their magic IDs and fills in `response`
//! before jumping to the kernel. Only the fields the kernel uses are declared.

/// First half of every request ID, shared by all Limine requests.
const COMMON = [2]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

/// Build a request type with the ID `{COMMON, a, b}` whose response is a `*Response`.
fn Request(comptime a: u64, comptime b: u64, comptime Response: type) type {
    return extern struct {
        id: [4]u64 = .{ COMMON[0], COMMON[1], a, b },
        revision: u64 = 0,
        /// Filled in by the bootloader; null if the request was not answered.
        response: ?*Response = null,
    };
}

/// A linear framebuffer set up by the bootloader.
pub const Framebuffer = extern struct {
    /// Virtual address of the first pixel.
    address: *anyopaque,
    width: u64,
    height: u64,
    /// Bytes per row.
    pitch: u64,
    /// Bits per pixel.
    bpp: u16,
    // remaining fields not needed yet
};

/// Response to `FramebufferRequest`: the available framebuffers.
pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: [*]*Framebuffer,
};

/// Ask for a graphical framebuffer.
pub const FramebufferRequest = Request(0x9d5827dcd881dd75, 0xa3148604f6fab11b, FramebufferResponse);
/// Ask for the physical memory map.
pub const MemmapRequest = Request(0x67cf3d9d378a806f, 0xe304acdfc50c3c62, MemmapResponse);
/// Ask for the higher-half direct map (HHDM) offset.
pub const HhdmRequest = Request(0x48dcf1cb8ad2b852, 0x63984e959a98244b, HhdmResponse);

/// One region of the physical memory map. `type` is one of the `MEMMAP_*` values.
pub const MemmapEntry = extern struct { base: u64, length: u64, type: u64 };
/// Response to `MemmapRequest`: the physical memory map, sorted by base address.
pub const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]*MemmapEntry,
};
/// Response to `HhdmRequest`. Physical address `p` is mapped at virtual address `p + offset`.
pub const HhdmResponse = extern struct { revision: u64, offset: u64 };

/// Memory map type for RAM that is free for the kernel to use.
pub const MEMMAP_USABLE = 0;

/// Ask where the kernel image was loaded in physical and virtual memory.
pub const KernelAddressRequest = Request(0x71ba76863cc55f63, 0xb2644a48c516a487, KernelAddressResponse);
/// Response to `KernelAddressRequest`.
pub const KernelAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

/// Ask for the address of the ACPI RSDP.
pub const RsdpRequest = Request(0xc5e77b6b397e7b43, 0x27637845accdcf3c, RsdpResponse);
/// Response to `RsdpRequest`. Depending on the Limine revision, `address` is
/// either physical or an HHDM pointer (see `acpi.init`).
pub const RsdpResponse = extern struct { revision: u64, address: u64 };

/// Ask for the kernel's own ELF file, as loaded from disk (used for symbol lookup).
pub const ExecutableFileRequest = Request(0xad97e90e83f1ed67, 0x31eb5d1c5ff23b69, ExecutableFileResponse);
/// Response to `ExecutableFileRequest`.
pub const ExecutableFileResponse = extern struct {
    revision: u64,
    executable_file: *File,
};

/// Ask for the modules (extra files, such as the initrd) listed in the bootloader config.
pub const ModuleRequest = Request(0x3e7e279702be32af, 0xca1c4f3bd1280cee, ModuleResponse);
/// Response to `ModuleRequest`: the loaded modules.
pub const ModuleResponse = extern struct {
    revision: u64,
    module_count: u64,
    modules: [*]*File,
};
/// A file loaded by the bootloader.
pub const File = extern struct {
    revision: u64,
    /// HHDM virtual address of the file's contents.
    address: u64,
    /// Size of the file in bytes.
    size: u64,
    /// Path the file was loaded from.
    path: [*:0]const u8,
    /// Command line string given for the module in the config.
    string: [*:0]const u8,
    // more fields follow; not needed
};

/// One CPU, as the bootloader found it.
pub const MpInfo = extern struct {
    /// ACPI processor UID from the MADT.
    processor_id: u32,
    /// The CPU's local APIC ID.
    lapic_id: u32,
    /// The bootloader's own; must not be written.
    reserved: u64,
    /// An atomic write of a code address here makes the CPU, which the
    /// bootloader has parked, jump to it: with a pointer to this structure
    /// in RDI, on a 64 KiB stack of the bootloader's, in the state the boot
    /// CPU entered the kernel in (the bootloader's page tables and GDT,
    /// interrupts off). Unused for the boot CPU.
    goto_address: ?*const fn (*MpInfo) callconv(.c) noreturn,
    /// For the kernel's use.
    extra_argument: u64,
};

/// Response to `MpRequest`.
pub const MpResponse = extern struct {
    revision: u64,
    /// Bit 0: the bootloader enabled x2APIC.
    flags: u32,
    /// Local APIC ID of the boot CPU.
    bsp_lapic_id: u32,
    /// Number of CPUs, the boot CPU included.
    cpu_count: u64,
    cpus: [*]*MpInfo,
};

/// Ask the bootloader to start the other CPUs and park them. `flags` bit 0
/// would ask for x2APIC; it stays clear (the kernel drives the xAPIC).
pub const MpRequest = extern struct {
    id: [4]u64 = .{ COMMON[0], COMMON[1], 0x95a67b819a1b857e, 0xa0b61b723b6a73e0 },
    revision: u64 = 0,
    response: ?*MpResponse = null,
    flags: u64 = 0,
};
