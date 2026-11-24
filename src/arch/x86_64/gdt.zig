//! Global Descriptor Table and Task State Segment.
//!
//! In long mode segmentation is mostly unused, but the CPU still needs code and
//! data descriptors for ring 0 and ring 3, plus a TSS whose `rsp0` field tells
//! the CPU which kernel stack to switch to when an interrupt arrives from ring 3.
//!
//! The TSS also holds the interrupt stack table (IST): stacks the CPU switches
//! to unconditionally for the exceptions that must not depend on the stack
//! they interrupted. A double fault usually means the kernel stack itself is
//! unusable (overflowed or a corrupt RSP); without its own stack the CPU could
//! not even push the exception frame and would triple-fault, resetting the
//! machine with no diagnostics. An NMI can arrive at any instruction,
//! including the few at `syscall` entry that still run on the user's stack.
//! A debug exception (#DB) can be made to arrive at the first of those
//! instructions too, once a program can set a breakpoint or single-step into
//! `syscall` (the "MOV SS" attack, CVE-2018-8897): without its own stack the
//! handler would run in ring 0 on a stack pointer the program chose. A machine
//! check (#MC) is not caused by any instruction and can arrive there as well.

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

/// Size of each emergency stack. Their handlers only print diagnostics and halt.
pub const IST_STACK_SIZE = 16 * 1024;

/// IST index (1-7, as used in IDT gates) of the double-fault stack.
pub const IST_DOUBLE_FAULT = 1;
/// IST index of the NMI stack.
pub const IST_NMI = 2;
/// IST index of the debug-exception stack.
pub const IST_DEBUG = 3;
/// IST index of the machine-check stack.
pub const IST_MACHINE_CHECK = 4;
/// Every IST index in use.
pub const IST_INDEXES = [_]u3{ IST_DOUBLE_FAULT, IST_NMI, IST_DEBUG, IST_MACHINE_CHECK };

// Emergency stacks, in .bss: independent of the heap and of every thread stack.
var double_fault_stack: [IST_STACK_SIZE]u8 align(16) = undefined;
var nmi_stack: [IST_STACK_SIZE]u8 align(16) = undefined;
var debug_stack: [IST_STACK_SIZE]u8 align(16) = undefined;
var machine_check_stack: [IST_STACK_SIZE]u8 align(16) = undefined;

const TSS_SEL = 0x28;

/// 64-bit TSS: 104 bytes, packed with 4-byte alignment.
const Tss = extern struct {
    reserved0: u32 = 0,
    /// Kernel stack used when an interrupt arrives from ring 3.
    rsp0: u64 align(4) = 0,
    rsp1: u64 align(4) = 0,
    rsp2: u64 align(4) = 0,
    reserved1: u64 align(4) = 0,
    /// Interrupt stack table: tops of the emergency stacks; `ist[n - 1]` is IST index n.
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

/// The stack the CPU switches to for interrupts from ring 3 (`setKernelStack`).
pub fn kernelStack() u64 {
    return tss.rsp0;
}

/// The memory of the emergency stack with IST index `index`
/// (one of `IST_INDEXES`); the CPU starts at its end.
pub fn istStack(index: u3) []u8 {
    return switch (index) {
        IST_DOUBLE_FAULT => &double_fault_stack,
        IST_NMI => &nmi_stack,
        IST_DEBUG => &debug_stack,
        IST_MACHINE_CHECK => &machine_check_stack,
        else => unreachable,
    };
}

/// The stack top the TSS holds for IST index `index` (1-7); 0 if unused.
pub fn istTop(index: u3) u64 {
    return tss.ist[index - 1];
}

/// Install the GDT and TSS.
///
/// Points the IST entries at the emergency stacks, fills in the TSS descriptor, loads the GDT with `lgdt`, reloads CS with a
/// far return and the data segment registers with the kernel data selector,
/// then loads the task register with `ltr`. Must run before `idt.init`.
pub fn init() void {
    inline for (IST_INDEXES) |index| {
        const stack = istStack(index);
        tss.ist[index - 1] = @intFromPtr(stack.ptr) + stack.len;
    }

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
