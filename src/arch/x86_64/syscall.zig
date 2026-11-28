//! `syscall`/`sysretq` entry path.
//!
//! Configures the syscall MSRs and provides the assembly entry point, which
//! switches to the kernel GS base and the current thread's kernel stack,
//! builds a `Frame` and calls the dispatcher in `kernel/syscall.zig`.
//! `docs/syscalls.md` describes the ABI a program sees.
//!
//! The call to the dispatcher is a direct one. Only the test kernel goes
//! through a pointer (`setHandler`), so that tests can watch and alter
//! syscalls; the normal kernel has no such pointer for a stray write to
//! redirect, and no indirect branch on the way.
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
//! 3. The user state is pushed as a `Frame` (20 words, so RSP is 16-byte
//!    aligned at the `call`, as the C ABI requires): every general-purpose
//!    register, so the frame is the thread's whole user state.
//! 4. `syscall_handler_c` turns interrupts on, runs the handler, turns them
//!    off again and decides how to return (`sysret.zig`).
//! 5. The registers are restored from the frame, so a program gets every
//!    register back except RAX (the result), and RCX and R11, which hold
//!    RIP and RFLAGS as `syscall` left them. No register holds a kernel
//!    value on exit. After `rt_sigreturn` the frame is a context the
//!    thread had anywhere, RCX and R11 included, and `iretq` restores it.
//! 6. `swapgs`, then `sysretq`, or `iretq` when `sysretq` cannot restore the
//!    state (RF or TF set).
//!
//! An NMI can arrive between steps 1 and 2 or late in step 6, with the user's
//! GS base in ring 0; it runs on its own stack and checks the GS base itself
//! (`isr_paranoid` in `idt.zig`).

const std = @import("std");
const build_options = @import("build_options");
const root = @import("root");

const assert = @import("../../kernel/debug/assert.zig");
const dispatcher = @import("../../kernel/syscall.zig");
const process = @import("../../kernel/process.zig");
const signal = @import("../../kernel/signal.zig");
const thread = @import("../../kernel/thread.zig");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const sysret = @import("sysret.zig");

/// RFLAGS bits the CPU clears on `syscall` entry: TF, IF, DF, IOPL, NT, AC.
pub const SFMASK: u64 = 0x100 | 0x200 | 0x400 | 0x3000 | 0x4000 | 0x40000;

/// Syscalls that returned with `iretq` instead of `sysretq` since boot. A
/// statistic: read by tests to see which path a return took.
pub var iret_returns: usize = 0;

/// True if syscalls go through a replaceable pointer: in the test kernel only.
pub const replaceable = build_options.is_test;

// The handler in use, in the test kernel. The normal kernel has no such variable.
var handler: if (replaceable) Handler else void = if (replaceable) &dispatcher.dispatch else {};

/// A syscall handler: reads the arguments from the frame and writes the
/// result to `f.rax`.
pub const Handler = *const fn (*Frame) void;

/// User register state saved on syscall entry, lowest address first.
///
/// `rax` holds the syscall number on entry and the return value on exit;
/// `rdi`, `rsi`, `rdx`, `r10`, `r8` and `r9` hold the arguments. The last
/// five fields are laid out as `iretq` expects them.
pub const Frame = extern struct {
    // The registers a function call preserves. The handler does not change
    // them either, but they are saved so that the whole user state is in
    // one place: a new thread starts with a copy of its creator's
    // (`clone`), and a signal handler's return puts a saved one back.
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    /// RFLAGS and RIP as the `syscall` instruction left them in R11 and
    /// RCX, which is what a program finds there after a system call. A
    /// return with `iretq` restores these two as they are here: after
    /// `rt_sigreturn` they are whatever the thread had when the signal
    /// came, which may have been in the middle of anything.
    r11: u64,
    rcx: u64,
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
    std.debug.assert(@sizeOf(Frame) == 20 * 8);
    std.debug.assert(@sizeOf(Frame) % 16 == 0);
    std.debug.assert(@offsetOf(Frame, "rip") == 15 * 8);
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
        \\  push %rcx               # RCX and R11 again, as registers of their own
        \\  push %r11
        \\  push %rbx
        \\  push %rbp
        \\  push %r12
        \\  push %r13
        \\  push %r14
        \\  push %r15
        \\  mov %rsp, %rdi
        \\  call syscall_handler_c
        \\  test %eax, %eax        # 0 = sysretq, otherwise iretq; pops keep the flags
        \\  pop %r15
        \\  pop %r14
        \\  pop %r13
        \\  pop %r12
        \\  pop %rbp
        \\  pop %rbx
        \\  pop %r11
        \\  pop %rcx
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
        \\  swapgs                 # RCX and R11 as the frame has them
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
/// dispatcher's `badReturn` instead, which kills the process.
export fn syscall_handler_c(f: *Frame) callconv(.c) u64 {
    assert.check(.syscall, @intFromPtr(f) % 16 == 0, "syscall frame at 0x{x} is not 16-byte aligned", .{@intFromPtr(f)});
    asm volatile ("sti"); // long syscalls may be preempted
    const number = f.rax;
    if (comptime replaceable) handler(f) else dispatcher.dispatch(f);
    return leave(f, number);
}

/// The way back from a system call: what is to be done before the program
/// runs again, and how to return to it. A function of its own, not
/// inlined, so that its stack frame is not under the system call's (a
/// frame is made whole when a function is entered).
noinline fn leave(f: *Frame, number: u64) u64 {
    // A signal to deliver, or an interrupted call to make again: either
    // rewrites the registers, which `iretq` then restores whole. Looked
    // for only if there may be something (one look at the thread).
    var rewritten = false;
    if (signal.returnWorkPending(thread.current(), f, number)) rewritten = returnWork(f, number);
    {
        const me = thread.current();
        if (me.return_by_iret) {
            me.return_by_iret = false;
            rewritten = true;
        }
    }
    f.rflags = sysret.sanitizeFlags(f.rflags);
    var how = sysret.classify(f.rip, f.rflags, f.cs, f.ss);
    if (rewritten and how == .sysret) how = .iret;
    if (how == .invalid) dispatcher.badReturn(f);
    asm volatile ("cli"); // the exit path must not be interrupted
    if (how == .iret) iret_returns += 1;
    return @backingInt(how);
}

/// What the way back from a system call has to do when there is anything
/// (`signal.returnWorkPending`): end the thread if its process is ending,
/// deliver a signal, make an interrupted call again. Not inlined: its
/// frame would otherwise be on the stack of every system call.
noinline fn returnWork(f: *Frame, number: u64) bool {
    process.dieIfKilled(); // its process is ending: no return to the program
    return signal.atSyscallReturn(f, number);
}

/// Replace the syscall handler and return the previous one. For tests,
/// which wrap the real handler to observe or alter syscalls; it does not
/// compile into the normal kernel.
pub fn setHandler(h: Handler) Handler {
    if (comptime !replaceable) @compileError("syscall.setHandler exists in the test kernel only");
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

/// Enable the `syscall` instruction on the boot CPU. Called once during boot.
pub fn init() void {
    initCpu();
}

// enter_user_frame(frame: rdi): leave the kernel for ring 3 with the user
// state in `frame`, for a thread that starts in the middle of a system
// call its creator made (`clone`). Interrupts go off before the GS base
// is the user's. Always `iretq`: it restores anything.
comptime {
    asm (
        \\.section .text
        \\.global enter_user_frame
        \\.type enter_user_frame, @function
        \\enter_user_frame:
        \\  cli
        \\  mov %rdi, %rsp
        \\  pop %r15
        \\  pop %r14
        \\  pop %r13
        \\  pop %r12
        \\  pop %rbp
        \\  pop %rbx
        \\  pop %r11
        \\  pop %rcx
        \\  pop %r9
        \\  pop %r8
        \\  pop %r10
        \\  pop %rdx
        \\  pop %rsi
        \\  pop %rdi
        \\  pop %rax
        \\  swapgs
        \\  iretq
        \\.size enter_user_frame, . - enter_user_frame
    );
}

extern fn enter_user_frame(frame: *const Frame) callconv(.c) noreturn;

/// Start running user code with the registers in `frame`: for a thread
/// that begins as a copy of another one in the middle of a system call
/// (`clone`). The frame is read where it is, as the stack for a moment
/// with interrupts off, so it must be kernel memory that stays; the
/// caller keeps it on its own kernel stack. Never returns.
pub fn enterUserFrame(frame: *const Frame) noreturn {
    enter_user_frame(frame);
}
