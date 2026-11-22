//! Global Descriptor Table and Task State Segment.
//!
//! In long mode segmentation is mostly unused, but the CPU still needs code and
//! data descriptors for ring 0 and ring 3, plus a TSS whose `rsp0` field tells
//! the CPU which kernel stack to switch to when an interrupt arrives from ring 3.

const std = @import("std");

var gdt = [_]u64{
    0x0000000000000000, // 0x00 null
    0x00AF9A000000FFFF, // 0x08 kernel code
    0x00CF92000000FFFF, // 0x10 kernel data
    0x00CFF2000000FFFF, // 0x18 user data
    0x00AFFA000000FFFF, // 0x20 user code
    0, // 0x28 TSS low  (filled in init)
    0, // 0x30 TSS high
};
var tss: Tss = .{};

const TSS_SEL = 0x28;

/// 64-bit TSS: 104 bytes, packed with 4-byte alignment.
const Tss = extern struct {
    reserved0: u32 = 0,
    /// Kernel stack used when an interrupt arrives from ring 3.
    rsp0: u64 align(4) = 0,
    rsp1: u64 align(4) = 0,
    rsp2: u64 align(4) = 0,
    reserved1: u64 align(4) = 0,
    /// Interrupt stack table: extra emergency stacks (e.g. for double faults, not used yet).
    ist: [7]u64 align(4) = @splat(0),
    reserved2: u64 align(4) = 0,
    reserved3: u16 = 0,
    /// I/O bitmap offset. Pointing past the end denies all ports to ring 3.
    iopb: u16 = 104,
};

/// Operand for `lgdt`: size and linear address of the GDT.
const GdtPtr = extern struct {
    limit: u16,
    base: u64 align(1),
};

/// Selector for the ring 0 code segment.
pub const KERNEL_CODE = 0x08;
/// Selector for the ring 0 data segment.
pub const KERNEL_DATA = 0x10;
/// Selector for the ring 3 data segment (RPL 3).
pub const USER_DATA = 0x18 | 3;
/// Selector for the ring 3 code segment (RPL 3).
pub const USER_CODE = 0x20 | 3;

// The CPU requires the TSS to be exactly 104 bytes.
comptime {
    std.debug.assert(@sizeOf(Tss) == 104);
}

/// Set the stack the CPU switches to when an interrupt or exception arrives
/// while running in ring 3. `top` is the highest address of that kernel stack.
pub fn setKernelStack(top: u64) void {
    tss.rsp0 = top;
}

/// Install the GDT and TSS.
///
/// Fills in the TSS descriptor, loads the GDT with `lgdt`, reloads CS with a
/// far return and the data segment registers with the kernel data selector,
/// then loads the task register with `ltr`. Must run before `idt.init`.
pub fn init() void {
    // TSS descriptor: 16 bytes spread over two GDT slots.
    const base: u64 = @intFromPtr(&tss);
    const limit: u64 = @sizeOf(Tss) - 1;
    gdt[5] = (limit & 0xFFFF) |
        ((base & 0xFFFF) << 16) |
        (((base >> 16) & 0xFF) << 32) |
        (0x89 << 40) | // present, 64-bit TSS (available)
        (((limit >> 16) & 0xF) << 48) |
        (((base >> 24) & 0xFF) << 56);
    gdt[6] = base >> 32;

    const ptr = GdtPtr{ .limit = @sizeOf(@TypeOf(gdt)) - 1, .base = @intFromPtr(&gdt) };
    asm volatile ("lgdt (%[p])"
        :
        : [p] "r" (&ptr),
        : .{ .memory = true });

    asm volatile (
        \\ pushq $0x08
        \\ leaq 1f(%%rip), %%rax
        \\ pushq %%rax
        \\ lretq
        \\ 1:
        \\ movw $0x10, %%ax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ movw %%ax, %%ss
        \\ movw %%ax, %%fs
        \\ movw %%ax, %%gs
        ::: .{ .rax = true, .memory = true });

    asm volatile ("ltr %[s]"
        :
        : [s] "r" (@as(u16, TSS_SEL)),
    );
}
