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

pub const KERNEL_CODE = 0x08;
pub const KERNEL_DATA = 0x10;
pub const USER_DATA = 0x18 | 3; // | 3 = requested privilege level 3
pub const USER_CODE = 0x20 | 3;
const TSS_SEL = 0x28;

// 64-bit TSS: 104 bytes, packed with 4-byte alignment.
const Tss = extern struct {
    reserved0: u32 = 0,
    rsp0: u64 align(4) = 0, // kernel stack used when an interrupt arrives from ring 3
    rsp1: u64 align(4) = 0,
    rsp2: u64 align(4) = 0,
    reserved1: u64 align(4) = 0,
    ist: [7]u64 align(4) = @splat(0), // extra emergency stacks (double fault, later)
    reserved2: u64 align(4) = 0,
    reserved3: u16 = 0,
    iopb: u16 = 104, // I/O bitmap past the end: all ports denied to ring 3
};
comptime {
    std.debug.assert(@sizeOf(Tss) == 104);
}

var tss: Tss = .{};

pub fn setKernelStack(top: u64) void {
    tss.rsp0 = top;
}

const GdtPtr = extern struct {
    limit: u16,
    base: u64 align(1),
};

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

pub fn readCs() u16 {
    return asm volatile ("movw %%cs, %[ret]"
        : [ret] "=r" (-> u16),
    );
}
