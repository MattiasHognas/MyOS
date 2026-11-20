const std = @import("std");
const root = @import("root"); // main.zig: print, halt
const gdt = @import("gdt.zig");
const apic = @import("../../apic.zig");

// ---- IDT table ----
const Entry = extern struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8, // 0x8E = present | ring 0 | 64-bit interrupt gate
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,
};

var idt = std.mem.zeroes([256]Entry);

const IdtPtr = extern struct {
    limit: u16,
    base: u64 align(1),
};

pub const Handler = *const fn (*Frame) void;
var handlers: [256]?Handler = @splat(null);

pub fn register(vector: u8, h: Handler) void {
    handlers[vector] = h;
}

fn setGate(vec: usize, handler: usize) void {
    idt[vec] = .{
        .offset_low = @truncate(handler),
        .selector = gdt.KERNEL_CODE,
        .ist = 0,
        .type_attr = 0x8E,
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
        .reserved = 0,
    };
}

// ---- Stubs, generated at compile time ----
// The CPU pushes an error code only for some vectors. The stub pushes a
// dummy 0 for the others, so every frame has the same layout.
fn stub(comptime vec: usize) *const fn () callconv(.naked) void {
    const has_err = switch (vec) {
        8, 10...14, 17, 21, 29, 30 => true,
        else => false,
    };
    const code = (if (has_err) "" else "pushq $0\n") ++
        std.fmt.comptimePrint("pushq ${d}\njmp isr_common", .{vec});
    return struct {
        fn h() callconv(.naked) void {
            asm volatile (code);
        }
    }.h;
}

// ---- Common path: save registers, call Zig, restore, iretq ----
comptime {
    asm (
        \\.section .text
        \\.global isr_common
        \\isr_common:
        \\  push %rax
        \\  push %rbx
        \\  push %rcx
        \\  push %rdx
        \\  push %rsi
        \\  push %rdi
        \\  push %rbp
        \\  push %r8
        \\  push %r9
        \\  push %r10
        \\  push %r11
        \\  push %r12
        \\  push %r13
        \\  push %r14
        \\  push %r15
        \\  mov %rsp, %rdi
        \\  cld
        \\  call interruptHandler
        \\  pop %r15
        \\  pop %r14
        \\  pop %r13
        \\  pop %r12
        \\  pop %r11
        \\  pop %r10
        \\  pop %r9
        \\  pop %r8
        \\  pop %rbp
        \\  pop %rdi
        \\  pop %rsi
        \\  pop %rdx
        \\  pop %rcx
        \\  pop %rbx
        \\  pop %rax
        \\  add $16, %rsp
        \\  iretq
    );
}

// The stack as isr_common leaves it, lowest address first.
pub const Frame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64, // pushed by the stub
    rip: u64,
    cs: u64,
    rflags: u64, // pushed by the CPU
    rsp: u64,
    ss: u64,
};

const names = [32][]const u8{
    "Divide error",         "Debug",               "NMI",            "Breakpoint",
    "Overflow",             "Bound range",         "Invalid opcode", "Device not available",
    "Double fault",         "Coprocessor overrun", "Invalid TSS",    "Segment not present",
    "Stack fault",          "General protection",  "Page fault",     "Reserved",
    "x87 FP",               "Alignment check",     "Machine check",  "SIMD FP",
    "Virtualization",       "Control protection",  "Reserved",       "Reserved",
    "Reserved",             "Reserved",            "Reserved",       "Reserved",
    "Hypervisor injection", "VMM communication",   "Security",       "Reserved",
};

fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

export fn interruptHandler(f: *Frame) callconv(.c) void {
    if (f.vector == apic.SPURIOUS) return; // spurious: no EOI
    if (f.vector >= 32) {
        if (handlers[f.vector]) |h| h(f) else root.print("unhandled vector {d}\n", .{f.vector});
        apic.eoi();
        return;
    }
    const name = if (f.vector < 32) names[f.vector] else "IRQ";
    root.print("\n*** {s} (vector {d}, error 0x{x})\n", .{ name, f.vector, f.error_code });
    root.print("RIP=0x{x} CS=0x{x} RFLAGS=0x{x}\n", .{ f.rip, f.cs, f.rflags });
    root.print("RSP=0x{x} RAX=0x{x} RBX=0x{x}\n", .{ f.rsp, f.rax, f.rbx });
    if (f.vector == 14) root.print("CR2=0x{x} (faulting address)\n", .{readCr2()});

    if (f.vector == 3) return; // breakpoint: resume after int3
    root.halt();
}

pub fn init() void {
    inline for (0..256) |i| setGate(i, @intFromPtr(stub(i)));
    const ptr = IdtPtr{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&ptr),
        : .{ .memory = true });
}
