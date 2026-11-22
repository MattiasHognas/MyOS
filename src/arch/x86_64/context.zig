//! Low-level thread context switching and the jump to user mode.
//!
//! Only callee-saved registers are switched: a thread always gives up the CPU
//! from inside a normal function call (`switchTo`), so the compiler has already
//! saved everything else.

// switch_context(old_rsp: *usize, new_rsp: usize)
//   Saves callee-saved registers on the current stack, stores RSP in *old,
//   loads `new` as RSP, restores that thread's registers and returns into it.
//
// thread_trampoline: where a new thread "returns" to the first time.
//   r12 = start function, rbx = its argument (set up by initStack).
comptime {
    asm (
        \\.section .text
        \\.global switch_context
        \\switch_context:
        \\  push %rbx
        \\  push %rbp
        \\  push %r12
        \\  push %r13
        \\  push %r14
        \\  push %r15
        \\  mov %rsp, (%rdi)
        \\  mov %rsi, %rsp
        \\  pop %r15
        \\  pop %r14
        \\  pop %r13
        \\  pop %r12
        \\  pop %rbp
        \\  pop %rbx
        \\  ret
        \\
        \\.global thread_trampoline
        \\thread_trampoline:
        \\  mov %rbx, %rdi
        \\  call *%r12
        \\  ud2
    );
}

/// Assembly context switch defined above. See `switchTo`.
extern fn switch_context(old: *usize, new: usize) callconv(.c) void;
/// Assembly entry point for new threads: calls r12 with rbx as its argument.
extern fn thread_trampoline() callconv(.c) void;

/// Switch from the current thread to another one.
///
/// Saves the current callee-saved registers on the current stack, stores the
/// resulting stack pointer in `old_rsp`, and resumes the thread whose saved
/// stack pointer is `new_rsp`. Returns when some other thread switches back.
pub fn switchTo(old_rsp: *usize, new_rsp: usize) void {
    switch_context(old_rsp, new_rsp);
}

/// Prepare a fresh stack so that the first `switchTo` into it calls `start(arg)`.
///
/// `top` is the highest address of the stack (it is aligned down to 16 bytes).
/// Returns the initial stack pointer to store as the new thread's saved RSP.
pub fn initStack(top: usize, start: usize, arg: usize) usize {
    const t = top & ~@as(usize, 15); // 16-byte aligned
    const s: [*]usize = @ptrFromInt(t - 7 * 8);
    s[0] = 0; // r15
    s[1] = 0; // r14
    s[2] = 0; // r13
    s[3] = start; // r12
    s[4] = 0; // rbp
    s[5] = arg; // rbx
    s[6] = @intFromPtr(&thread_trampoline); // where `ret` goes
    return t - 7 * 8;
}

/// Drop to ring 3 and start executing at `rip` with stack pointer `rsp`.
///
/// Builds the frame `iretq` expects (SS, RSP, RFLAGS, CS, RIP) using the user
/// selectors from the GDT and RFLAGS with interrupts enabled. Never returns;
/// the kernel is re-entered only through interrupts or `syscall`.
pub fn enterUser(rip: u64, rsp: u64) noreturn {
    asm volatile (
        \\ pushq $0x1B
        \\ pushq %[rsp]
        \\ pushq $0x202
        \\ pushq $0x23
        \\ pushq %[rip]
        \\ iretq
        :
        : [rsp] "r" (rsp),
          [rip] "r" (rip),
    );
    unreachable;
}
