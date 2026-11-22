//! Interrupt Descriptor Table and the common interrupt entry path.
//!
//! Every one of the 256 vectors gets a small generated stub that pushes the
//! vector number (and a dummy error code where the CPU doesn't push one) and
//! jumps to `isr_common`, which saves all registers and calls
//! `interruptHandler`. Hardware interrupts (vector >= 32) are dispatched to
//! handlers installed with `register`; CPU exceptions are reported and either
//! kill the faulting user process or halt the kernel.

const std = @import("std");
const root = @import("root");
const gdt = @import("gdt.zig");
const apic = @import("../../arch/x86_64/apic.zig");
const thread = @import("../../kernel/thread.zig");
const process = @import("../../kernel/process.zig");
const backtrace = @import("../../kernel/debug/backtrace.zig");

var idt = std.mem.zeroes([256]Entry);
var handlers: [256]?Handler = @splat(null);

/// One 16-byte IDT gate descriptor.
const Entry = extern struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    /// 0x8E = present | ring 0 | 64-bit interrupt gate.
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,
};

/// Human-readable names of the 32 CPU exception vectors.
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

/// Operand for `lidt`: size and linear address of the IDT.
const IdtPtr = extern struct {
    limit: u16,
    base: u64 align(1),
};

/// An interrupt handler. Receives the saved register state of the interrupted code.
pub const Handler = *const fn (*Frame) void;

/// Point IDT entry `vec` at the code address `handler` as a ring 0 interrupt gate.
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

/// Generate the entry stub for vector `vec` at compile time.
///
/// The CPU pushes an error code only for some vectors. The stub pushes a dummy
/// 0 for the others, so every `Frame` has the same layout, then pushes the
/// vector number and jumps to `isr_common`.
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

// Common path for all stubs: save registers, call interruptHandler, restore,
// drop the vector and error code, iretq.
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

/// Read CR2, which holds the faulting linear address after a page fault.
fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

/// Dispatch an interrupt or exception. Called from `isr_common` with the saved frame.
///
/// - Spurious LAPIC interrupts are ignored (no EOI).
/// - Hardware interrupts (vector >= 32) are acknowledged first, then passed to
///   the handler installed with `register`. The handler may switch threads, so
///   the EOI must already have been sent.
/// - Exceptions from ring 3 terminate the current process with exit code 255.
/// - Exceptions from ring 0 print the register state and a symbolized
///   backtrace, then halt, except breakpoints (`int3`), which resume.
export fn interruptHandler(f: *Frame) callconv(.c) void {
    if (f.vector == apic.SPURIOUS) return; // spurious: no EOI
    if (f.vector >= 32) {
        apic.eoi(); // BEFORE the handler: it may switch threads
        if (handlers[f.vector]) |h| h(f) else root.print("unhandled vector {d}\n", .{f.vector});
        return;
    }
    const name = if (f.vector < 32) names[f.vector] else "IRQ";
    if ((f.cs & 3) == 3) { // fault came from ring 3: kill the thread, keep the kernel
        root.print("\n*** thread {d}: {s} in user mode at RIP=0x{x}, killed\n", .{ thread.id(), name, f.rip });
        process.exit(255); // the parent sees exit code 255 for a crash
    }
    root.print("\n*** {s} (vector {d}, error 0x{x})\n", .{ name, f.vector, f.error_code });
    root.print("RIP=0x{x} CS=0x{x} RFLAGS=0x{x}\n", .{ f.rip, f.cs, f.rflags });
    root.print("RSP=0x{x} RAX=0x{x} RBX=0x{x}\n", .{ f.rsp, f.rax, f.rbx });
    if (f.vector == 14) root.print("CR2=0x{x} (faulting address)\n", .{readCr2()});
    backtrace.print(.{ .pc = f.rip }, f.rbp);

    if (f.vector == 3) return; // breakpoint: resume after int3
    root.halt();
}

/// Install `h` as the handler for hardware interrupt `vector` (32-255).
///
/// The handler runs with interrupts disabled after the EOI has been sent, so it
/// may switch threads (e.g. the timer handler calling `thread.tick`).
pub fn register(vector: u8, h: Handler) void {
    handlers[vector] = h;
}

/// The stack as `isr_common` leaves it, lowest address first: the registers it
/// saved, then the vector and error code from the stub, then the interrupt
/// frame pushed by the CPU.
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
    /// Pushed by the stub.
    vector: u64,
    /// Pushed by the CPU, or a dummy 0 pushed by the stub.
    error_code: u64,
    /// Pushed by the CPU from here on.
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// Fill all 256 IDT entries with their stubs and load the IDT with `lidt`.
/// Requires `gdt.init` to have run, since the gates use the kernel code selector.
pub fn init() void {
    inline for (0..256) |i| setGate(i, @intFromPtr(stub(i)));
    const ptr = IdtPtr{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&ptr),
        : .{ .memory = true });
}
