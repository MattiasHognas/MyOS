//! Interrupt Descriptor Table and the common interrupt entry path.
//!
//! Every one of the 256 vectors gets a small generated stub that pushes the
//! vector number (and a dummy error code where the CPU doesn't push one) and
//! jumps to `isr_common`, which saves all registers and calls
//! `interruptHandler`. Hardware interrupts (vector >= 32) are dispatched to
//! handlers installed with `register`; CPU exceptions are reported and either
//! kill the faulting user process or halt the kernel.
//!
//! Double faults, NMIs, debug exceptions and machine checks run on their own emergency
//! stacks (the IST entries set up in `gdt.zig`), so they can be handled even
//! when the interrupted stack is unusable or is still the user's. Double
//! faults, NMIs and machine checks always halt the kernel; a debug exception in ring 3 kills
//! the process like any other fault, and one in ring 0 halts.
//!
//! GS base: an entry from ring 3 arrives with the user's GS base, so
//! `isr_common` runs `swapgs` when the saved CS says ring 3, and again
//! before returning there (see `percpu.zig`). NMIs, double faults, machine
//! checks and debug exceptions can also interrupt ring 0 code that still (or
//! already) has the user's GS base: the first instruction of `syscall_entry`, or the
//! last ones before `sysretq`/`iretq`. For them the saved CS proves nothing,
//! so `isr_paranoid` reads the GS base MSR instead: a kernel address has the
//! top bit set, and a user program cannot make its own base look like one.

const std = @import("std");
const root = @import("root");

const apic = @import("../../arch/x86_64/apic.zig");
const backtrace = @import("../../kernel/debug/backtrace.zig");
const kstack = @import("../../kernel/kstack.zig");
const process = @import("../../kernel/process.zig");
const thread = @import("../../kernel/thread.zig");
const gdt = @import("gdt.zig");
const usercopy = @import("usercopy.zig");

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

/// Point IDT entry `vec` at the code address `handler` as a ring 0 interrupt
/// gate. `ist` is 0 to stay on the current stack (or switch to `rsp0` when
/// coming from ring 3), or an IST index to always switch to that stack.
fn setGate(vec: usize, handler: usize, ist: u3) void {
    idt[vec] = .{
        .offset_low = @truncate(handler),
        .selector = gdt.KERNEL_CODE,
        .ist = ist,
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
    const common = switch (vec) {
        VECTOR_DEBUG, VECTOR_NMI, VECTOR_DOUBLE_FAULT, VECTOR_MACHINE_CHECK => "isr_paranoid",
        else => "isr_common",
    };
    const code = (if (has_err) "" else "pushq $0\n") ++
        std.fmt.comptimePrint("pushq ${d}\njmp {s}", .{ vec, common });
    return struct {
        fn h() callconv(.naked) void {
            asm volatile (code);
        }
    }.h;
}

// Common path for all stubs: switch to the kernel GS base if the interrupt
// came from ring 3 (the saved CS is at 24(%rsp) on entry and before the final
// `add`), save registers, call interruptHandler, restore, switch GS back,
// drop the vector and error code, iretq. With SMAP on, RFLAGS.AC is cleared
// (`clac`, written as bytes) so an interrupt that arrives inside a user copy,
// or from a user program that set AC, cannot run the handler (or a thread it
// switches to) with user-memory access allowed. `iretq` restores the old flags.
comptime {
    asm (
        \\.section .text
        \\.global isr_common
        \\isr_common:
        \\  testb $3, 24(%rsp)
        \\  jz 1f
        \\  swapgs
        \\1:
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
        \\  cmpb $0, smap_enabled(%rip)
        \\  je 2f
        \\  .byte 0x0f, 0x01, 0xca
        \\2:
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
        \\  testb $3, 24(%rsp)
        \\  jz 3f
        \\  swapgs
        \\3:
        \\  add $16, %rsp
        \\  iretq
        \\
        \\# Debug, NMI, double fault, machine check: decide by the GS base MSR
        \\# (0xC0000101), not by the saved CS. EBX (callee-saved, so it
        \\# survives the call) remembers whether GS was switched.
        \\.global isr_paranoid
        \\isr_paranoid:
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
        \\  xor %ebx, %ebx
        \\  mov $0xC0000101, %ecx
        \\  rdmsr
        \\  test %edx, %edx
        \\  js 1f
        \\  swapgs
        \\  mov $1, %ebx
        \\1:
        \\  cmpb $0, smap_enabled(%rip)
        \\  je 2f
        \\  .byte 0x0f, 0x01, 0xca
        \\2:
        \\  mov %rsp, %rdi
        \\  cld
        \\  call interruptHandler
        \\  test %ebx, %ebx
        \\  jz 3f
        \\  swapgs
        \\3:
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

/// The IST index vector `vec` runs on: its own emergency stack for double
/// faults, NMIs, debug exceptions and machine checks, 0 (no stack switch) for
/// everything else.
fn istFor(vec: usize) u3 {
    return switch (vec) {
        VECTOR_DOUBLE_FAULT => gdt.IST_DOUBLE_FAULT,
        VECTOR_NMI => gdt.IST_NMI,
        VECTOR_DEBUG => gdt.IST_DEBUG,
        VECTOR_MACHINE_CHECK => gdt.IST_MACHINE_CHECK,
        else => 0,
    };
}

/// The IST index in the IDT gate of `vector` (0 = none).
pub fn gateIst(vector: u8) u3 {
    return @truncate(idt[vector].ist);
}

/// Change the IST index in the IDT gate of `vector`. Only for tests, which
/// use it to enter a spare vector on an emergency stack.
pub fn setGateIst(vector: u8, ist: u3) void {
    idt[vector].ist = ist;
}

const VECTOR_DEBUG = 1;
const VECTOR_NMI = 2;
const VECTOR_BREAKPOINT = 3;
const VECTOR_DOUBLE_FAULT = 8;
const VECTOR_PAGE_FAULT = 14;
const VECTOR_MACHINE_CHECK = 18;

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
/// - Exceptions from ring 3 print the fault details and terminate the current
///   process with exit code 255. NMIs, double faults and machine checks are
///   never the program's doing, so they are kernel faults wherever they hit.
/// - Page faults on user memory inside a user copy (`usercopy.zig`) resume at
///   the copy's error path: the syscall fails, nothing is killed.
/// - Other exceptions from ring 0 print the register state and a symbolized
///   backtrace, then halt, except breakpoints (`int3`), which resume.
export fn interruptHandler(f: *Frame) callconv(.c) void {
    if (f.vector == apic.SPURIOUS) return; // spurious: no EOI
    if (f.vector >= 32) {
        apic.eoi(); // BEFORE the handler: it may switch threads
        if (handlers[f.vector]) |h| h(f) else root.print("unhandled vector {d}\n", .{f.vector});
        return;
    }
    const name = names[f.vector];
    const from_user = (f.cs & 3) == 3;
    const kernel_fatal = switch (f.vector) {
        VECTOR_NMI, VECTOR_DOUBLE_FAULT, VECTOR_MACHINE_CHECK => true,
        else => false,
    };
    if (from_user and !kernel_fatal) { // kill the process, keep the kernel
        const p = thread.current().process.?;
        root.print("\n*** thread {d} ({s}): {s} in user mode (vector {d}, error 0x{x}), killed\n", .{ thread.id(), p.name, name, f.vector, f.error_code });
        root.print("RIP=0x{x} RSP=0x{x} RFLAGS=0x{x}\n", .{ f.rip, f.rsp, f.rflags });
        if (f.vector == VECTOR_PAGE_FAULT) root.print("CR2=0x{x} (faulting address)\n", .{readCr2()});
        process.exit(process.EXIT_KILLED); // the parent sees exit status 255 for a crash
    }
    if (f.vector == VECTOR_DEBUG) {
        if (handlers[VECTOR_DEBUG]) |h| return h(f); // a test is watching ring 0 debug traps
    }
    if (f.vector == VECTOR_PAGE_FAULT) {
        if (usercopy.fixup(f.rip, readCr2())) |resume_at| { // bad user pointer in a syscall
            f.rip = resume_at;
            return;
        }
    }
    root.print("\n*** {s} (vector {d}, error 0x{x})\n", .{ name, f.vector, f.error_code });
    root.print("RIP=0x{x} CS=0x{x} RFLAGS=0x{x}\n", .{ f.rip, f.cs, f.rflags });
    root.print("RSP=0x{x} RAX=0x{x} RBX=0x{x}\n", .{ f.rsp, f.rax, f.rbx });
    switch (f.vector) {
        VECTOR_PAGE_FAULT => {
            const addr = readCr2();
            root.print("CR2=0x{x} (faulting address)\n", .{addr});
            if (!from_user and kstack.isGuard(addr)) root.print("CR2 is in a kernel stack guard page: kernel stack overflow\n", .{});
        },
        VECTOR_DOUBLE_FAULT => reportDoubleFault(f),
        else => {},
    }
    if (!from_user) backtrace.print(.{ .pc = f.rip }, f.rbp);

    if (f.vector == VECTOR_BREAKPOINT) return; // breakpoint: resume after int3
    root.halt();
}

/// Extra diagnostics for a double fault: the CPU could not deliver an
/// exception, nearly always because the kernel stack it had to push the
/// exception frame on is not writable. CR2 still holds the address of the
/// page fault that failed (if it was one): in a stack guard page, it was a
/// kernel stack overflow. Comparing the interrupted RSP with the current
/// thread's stack tells an overflow from a wild stack pointer too.
fn reportDoubleFault(f: *const Frame) void {
    const addr = readCr2();
    root.print("CR2=0x{x} (last page-fault address)\n", .{addr});
    if (kstack.isGuard(addr)) root.print("CR2 is in a kernel stack guard page: kernel stack overflow\n", .{});
    const t = thread.current();
    const stack = t.stack orelse return; // early boot, still on the bootloader's stack
    const low = @intFromPtr(stack.ptr);
    const high = low + stack.len;
    const verdict = if (f.rsp >= low and f.rsp <= high)
        "RSP is inside it"
    else if (f.rsp < low and low - f.rsp <= stack.len)
        "RSP is below it: stack overflow"
    else
        "RSP is outside it: corrupt stack pointer";
    root.print("thread {d} kernel stack 0x{x}-0x{x}; {s}\n", .{ t.id, low, high, verdict });
}

/// Install `h` as the handler for hardware interrupt `vector` (32-255).
/// Vector 1 is accepted too: its handler gets debug exceptions raised in
/// ring 0, which otherwise halt the kernel (tests use this).
///
/// The handler runs with interrupts disabled after the EOI has been sent, so it
/// may switch threads (e.g. the timer handler calling `thread.tick`).
pub fn register(vector: u8, h: Handler) void {
    handlers[vector] = h;
}

/// Install or remove (null) the handler for `vector`; see `register`.
pub fn setHandler(vector: u8, h: ?Handler) void {
    handlers[vector] = h;
}

/// The handler installed for hardware interrupt `vector`, if any. Tests use
/// it to wrap a handler and put it back.
pub fn registered(vector: u8) ?Handler {
    return handlers[vector];
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
/// Requires `gdt.init` to have run, since the gates use the kernel code
/// selector and the emergency stacks in the TSS.
pub fn init() void {
    // A table built at compile time and a runtime loop: an `inline for` here
    // gives every iteration its own stack slots in Debug builds (over 4 KiB).
    const stubs = comptime blk: {
        @setEvalBranchQuota(100_000); // 256 stubs, each formatting its vector number
        var table: [256]*const fn () callconv(.naked) void = undefined;
        for (&table, 0..) |*entry, i| entry.* = stub(i);
        break :blk table;
    };
    for (stubs, 0..) |entry, i| setGate(i, @intFromPtr(entry), istFor(i));
    const ptr = IdtPtr{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&ptr),
        : .{ .memory = true });
}
