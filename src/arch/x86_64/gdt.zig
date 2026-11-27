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
//!
//! Every CPU has its own GDT, TSS and emergency stacks (`Tables`): the TSS
//! holds the kernel stack of the thread that CPU runs, and two CPUs handling
//! a double fault at once cannot share a stack. The boot CPU's are static,
//! so they exist before there is any memory management; the others get
//! theirs from the heap and from `kstack`, guard pages included (`smp.zig`).

const std = @import("std");

const kstack = @import("../../kernel/kstack.zig");
const percpu = @import("percpu.zig");

/// The entries of a GDT: the same on every CPU except for the TSS descriptor.
const gdt_template = [_]u64{
    0x0000000000000000, // 0x00 null
    0x00AF9A000000FFFF, // 0x08 kernel code
    0x00CF92000000FFFF, // 0x10 kernel data
    0x00CFF2000000FFFF, // 0x18 user data
    0x00AFFA000000FFFF, // 0x20 user code
    0, // 0x28 TSS low  (filled in by `prepare`)
    0, // 0x30 TSS high
};

/// Size of each emergency stack, as Linux's. Little runs on them: an
/// exception from ring 3 moves to the thread's own kernel stack before
/// anything else (`isr_paranoid`, as Linux does), and a crash report moves
/// to the one crash stack before it prints (`main.onCrashStack`). What is
/// left is the handler up to that point. Measured (`istPeak`, printed by
/// the tests and by every crash report of a measured build): about 1 KiB
/// in a Debug build.
pub const IST_STACK_SIZE = 4 * 1024;

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

/// One CPU's descriptor tables and emergency stacks.
pub const Tables = struct {
    gdt: [gdt_template.len]u64 = gdt_template,
    tss: Tss = .{},
    /// The emergency stacks, by position in `IST_INDEXES`.
    ist_stacks: [IST_INDEXES.len][]u8 = @splat(&.{}),
};

// The boot CPU's emergency stacks, in .bss: independent of the heap and of
// every thread stack, and there from the first instruction.
var double_fault_stack: [IST_STACK_SIZE]u8 align(16) = undefined;
var nmi_stack: [IST_STACK_SIZE]u8 align(16) = undefined;
var debug_stack: [IST_STACK_SIZE]u8 align(16) = undefined;
var machine_check_stack: [IST_STACK_SIZE]u8 align(16) = undefined;

/// The boot CPU's tables.
var boot_tables: Tables = .{};

const TSS_SEL = 0x28;

/// 64-bit TSS: 104 bytes, packed with 4-byte alignment.
pub const Tss = extern struct {
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

/// The boot CPU's tables, for `percpu.init`.
pub fn bootTables() *Tables {
    return &boot_tables;
}

/// The running CPU's tables. Interrupts must be off, or the thread must
/// otherwise know it stays on this CPU.
fn tables() *Tables {
    const c = percpu.currentIfReady() orelse return &boot_tables;
    return c.tables.?;
}

/// Set the stack this CPU switches to when an interrupt or exception arrives
/// while running in ring 3. `top` is the highest address of that kernel
/// stack. Interrupts must be off.
pub fn setKernelStack(top: u64) void {
    tables().tss.rsp0 = top;
}

/// The stack this CPU switches to for interrupts from ring 3 (`setKernelStack`).
pub fn kernelStack() u64 {
    return tables().tss.rsp0;
}

/// The memory of this CPU's emergency stack with IST index `index`
/// (one of `IST_INDEXES`); the CPU starts at its end.
pub fn istStack(index: u3) []u8 {
    return istStackOf(tables(), index);
}

/// As `istStack`, for the CPU that `t` belongs to.
pub fn istStackOf(t: *const Tables, index: u3) []u8 {
    for (IST_INDEXES, t.ist_stacks) |i, stack| {
        if (i == index) return stack;
    }
    unreachable;
}

/// The most any emergency stack of any CPU has ever been used, in bytes,
/// or null if stack usage is not measured (`-Dstack-usage`). Includes the
/// stack the caller may be running on, as far as it has got.
pub fn istPeak() ?usize {
    if (!kstack.track_usage) return null;
    var peak: usize = 0;
    const n = if (percpu.currentIfReady() != null) percpu.count() else 0;
    if (n == 0) {
        for (boot_tables.ist_stacks) |stack| peak = @max(peak, kstack.used(stack).?);
    } else for (0..n) |i| {
        for (percpu.get(i).tables.?.ist_stacks) |stack| peak = @max(peak, kstack.used(stack).?);
    }
    return peak;
}

/// The stack top this CPU's TSS holds for IST index `index` (1-7); 0 if unused.
pub fn istTop(index: u3) u64 {
    return tables().tss.ist[index - 1];
}

/// Fill in `t` for a CPU whose emergency stacks are `stacks` (by position
/// in `IST_INDEXES`, each `IST_STACK_SIZE` bytes): point the IST entries at
/// them and write the TSS descriptor. `t` must not move afterwards.
pub fn prepare(t: *Tables, stacks: [IST_INDEXES.len][]u8) void {
    t.* = .{ .ist_stacks = stacks };
    for (IST_INDEXES, stacks) |index, stack| {
        std.debug.assert(stack.len == IST_STACK_SIZE);
        t.tss.ist[index - 1] = @intFromPtr(stack.ptr) + stack.len;
    }

    // TSS descriptor: 16 bytes spread over two GDT slots.
    const base: u64 = @intFromPtr(&t.tss);
    const limit: u64 = @sizeOf(Tss) - 1;
    t.gdt[5] = (limit & 0xFFFF) |
        ((base & 0xFFFF) << 16) |
        (((base >> 16) & 0xFF) << 32) |
        (0x89 << 40) | // present, 64-bit TSS (available)
        (((limit >> 16) & 0xF) << 48) |
        (((base >> 24) & 0xFF) << 56);
    t.gdt[6] = base >> 32;
}

/// Make `t` this CPU's GDT and TSS: load the GDT with `lgdt`, reload CS with
/// a far return and the data segment registers with the kernel data
/// selector, then load the task register with `ltr`. Loading GS resets its
/// base, so the per-CPU pointer is set after this (`percpu.zig`).
pub fn load(t: *Tables) void {
    const ptr = GdtPtr{ .limit = @sizeOf(@TypeOf(t.gdt)) - 1, .base = @intFromPtr(&t.gdt) };
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

/// Install the boot CPU's GDT and TSS. Must run before `idt.init`.
pub fn init() void {
    inline for (.{ &double_fault_stack, &nmi_stack, &debug_stack, &machine_check_stack }) |stack| kstack.markUnused(stack);
    prepare(&boot_tables, .{ &double_fault_stack, &nmi_stack, &debug_stack, &machine_check_stack });
    load(&boot_tables);
}
