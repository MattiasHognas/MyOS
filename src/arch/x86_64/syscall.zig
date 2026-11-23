//! `syscall`/`sysretq` entry path.
//!
//! Configures the syscall MSRs and provides the assembly entry point, which
//! switches to the kernel GS base and the current thread's kernel stack,
//! builds a `Frame` and calls the handler registered with `init`. The
//! kernel-side dispatcher lives in `kernel/syscall.zig`; `docs/syscalls.md`
//! describes the ABI a program sees.
//!
//! Entry and exit, step by step (interrupts are off wherever the GS base or
//! the stack pointer is not the kernel's):
//!
//! 1. The CPU jumps here in ring 0 with the user's RSP and GS base still
//!    loaded, RIP saved in RCX, RFLAGS saved in R11, and TF, IF, DF, IOPL,
//!    NT and AC cleared by SFMASK.
//! 2. `swapgs` makes the per-CPU area reachable; the user RSP is parked in
//!    it and RSP becomes the top of the thread's kernel stack. Nothing is
//!    ever pushed on the user's stack.
//! 3. The user state is pushed as a `Frame` (12 words, so RSP is 16-byte
//!    aligned at the `call`, as the C ABI requires).
//! 4. `syscall_handler_c` turns interrupts on, runs the handler, turns them
//!    off again and decides how to return (`sysret.zig`).
//! 5. The registers are restored from the frame. RBX, RBP and R12-R15 are
//!    never touched by this code and are preserved by the handler (C ABI),
//!    so a program gets every register back except RAX (the result), RCX
//!    and R11. No register holds a kernel value on exit.
//! 6. `swapgs`, then `sysretq`, or `iretq` when `sysretq` cannot restore the
//!    state (RF or TF set).
//!
//! An NMI can arrive between steps 1 and 2 or late in step 6, with the user's
//! GS base in ring 0; it runs on its own stack and checks the GS base itself
//! (`isr_paranoid` in `idt.zig`).

const std = @import("std");
const root = @import("root");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const sysret = @import("sysret.zig");
const assert = @import("../../kernel/debug/assert.zig");

/// RFLAGS bits the CPU clears on `syscall` entry: TF, IF, DF, IOPL, NT, AC.
pub const SFMASK: u64 = 0x100 | 0x200 | 0x400 | 0x3000 | 0x4000 | 0x40000;

/// Syscalls that returned with `iretq` instead of `sysretq` since boot. A
/// statistic: read by tests to see which path a return took.
pub var iret_returns: usize = 0;

var handler: Handler = undefined;

/// A syscall handler: reads the arguments from the frame and writes the
/// result to `f.rax`.
pub const Handler = *const fn (*Frame) void;

/// Called when a syscall would return to a state no instruction can return
/// to (see `sysret.classify`). Must not return.
pub const BadReturn = *const fn (*const Frame) noreturn;
var bad_return: BadReturn = undefined;

/// User register state saved on syscall entry, lowest address first.
///
/// `rax` holds the syscall number on entry and the return value on exit;
/// `rdi`, `rsi`, `rdx`, `r10`, `r8` and `r9` hold the arguments. The last
/// five fields are laid out as `iretq` expects them.
pub const Frame = extern struct {
    r9: u64,
    r8: u64,
    r10: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    /// Syscall number in, return value out.
    rax: u64,
    /// User RIP (the CPU put it in RCX).
    rip: u64,
    /// User code selector.
    cs: u64,
    /// User RFLAGS (the CPU put it in R11).
    rflags: u64,
    /// User RSP.
    rsp: u64,
    /// User stack selector.
    ss: u64,
};

comptime {
    // The entry code pushes exactly this, and the stack must stay 16-byte aligned.
    std.debug.assert(@sizeOf(Frame) == 12 * 8);
    std.debug.assert(@sizeOf(Frame) % 16 == 0);
    std.debug.assert(@offsetOf(Frame, "rip") == 7 * 8);
    std.debug.assert(sysret.USER_CS == gdt.USER_CODE and sysret.USER_SS == gdt.USER_DATA);
}

// %gs:8 = PerCpu.kernel_rsp, %gs:16 = PerCpu.user_rsp (percpu.zig).
// 0x1B = gdt.USER_DATA, 0x23 = gdt.USER_CODE.
comptime {
    asm (
        \\.section .text
        \\.global syscall_entry
        \\.type syscall_entry, @function
        \\syscall_entry:
        \\  swapgs
        \\  mov %rsp, %gs:16
        \\  mov %gs:8, %rsp
        \\  pushq $0x1B
        \\  pushq %gs:16
        \\  push %r11
        \\  pushq $0x23
        \\  push %rcx
        \\  push %rax
        \\  push %rdi
        \\  push %rsi
        \\  push %rdx
        \\  push %r10
        \\  push %r8
        \\  push %r9
        \\  mov %rsp, %rdi
        \\  call syscall_handler_c
        \\  test %eax, %eax        # 0 = sysretq, otherwise iretq; pops keep the flags
        \\  pop %r9
        \\  pop %r8
        \\  pop %r10
        \\  pop %rdx
        \\  pop %rsi
        \\  pop %rdi
        \\  pop %rax
        \\  jnz 1f
        \\  pop %rcx               # RIP
        \\  add $8, %rsp           # CS
        \\  pop %r11               # RFLAGS
        \\  pop %rsp               # user RSP; SS is set by sysretq
        \\  swapgs
        \\  sysretq
        \\1:
        \\  mov 0(%rsp), %rcx      # same RCX and R11 as the sysretq path
        \\  mov 16(%rsp), %r11
        \\  swapgs
        \\  iretq
        \\.size syscall_entry, . - syscall_entry
    );
}

/// Assembly entry point defined above; its address is written to LSTAR.
extern fn syscall_entry() callconv(.c) void;

/// Called from `syscall_entry` on the kernel stack with the saved user registers.
///
/// Enables interrupts while the handler runs, so long syscalls can be
/// preempted, and disables them again for the exit path, which runs with
/// the user's stack pointer and GS base. Returns how to leave: 0 for
/// `sysretq`, 1 for `iretq`. A state neither can return to goes to the
/// `BadReturn` handler instead.
export fn syscall_handler_c(f: *Frame) callconv(.c) u64 {
    assert.check(.syscall, @intFromPtr(f) % 16 == 0, "syscall frame at 0x{x} is not 16-byte aligned", .{@intFromPtr(f)});
    asm volatile ("sti"); // long syscalls may be preempted
    handler(f);
    f.rflags = sysret.sanitizeFlags(f.rflags);
    const how = sysret.classify(f.rip, f.rflags, f.cs, f.ss);
    if (how == .invalid) bad_return(f);
    asm volatile ("cli"); // the exit path must not be interrupted
    if (how == .iret) iret_returns += 1;
    return @backingInt(how);
}

/// Replace the syscall handler and return the previous one. For tests,
/// which wrap the real handler to observe or alter syscalls.
pub fn setHandler(h: Handler) Handler {
    const old = handler;
    handler = h;
    return old;
}

/// Program the `syscall` MSRs of this CPU: EFER.SCE, the segment selectors
/// in STAR, the entry point in LSTAR, and SFMASK to clear TF, IF, DF, IOPL,
/// NT and AC on entry: AC so a user program cannot enter the kernel with
/// SMAP's user-access override set, NT because a program can set it and an
/// `iretq` in ring 0 with NT set faults.
pub fn initCpu() void {
    cpu.wrmsr(0xC0000080, cpu.rdmsr(0xC0000080) | 1); // EFER.SCE: enable syscall
    cpu.wrmsr(0xC0000081, (@as(u64, 0x13) << 48) | (@as(u64, 0x08) << 32)); // STAR: selectors
    cpu.wrmsr(0xC0000082, @intFromPtr(&syscall_entry)); // LSTAR: entry point
    cpu.wrmsr(0xC0000084, SFMASK);
}

/// Enable the `syscall` instruction and route it to `h`, which receives the
/// saved user registers and returns its result by writing `f.rax`. `bad` is
/// called instead of returning to user mode when the saved state is one the
/// CPU cannot return to.
pub fn init(h: Handler, bad: BadReturn) void {
    handler = h;
    bad_return = bad;
    initCpu();
}
