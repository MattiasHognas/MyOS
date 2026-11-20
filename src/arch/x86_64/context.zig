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

extern fn switch_context(old: *usize, new: usize) callconv(.c) void;
extern fn thread_trampoline() callconv(.c) void;

pub fn switchTo(old_rsp: *usize, new_rsp: usize) void {
    switch_context(old_rsp, new_rsp);
}

/// Prepare a fresh stack so that switching to it calls start(arg).
/// Returns the initial RSP for the new thread.
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

/// Jump to ring 3: build the frame iretq expects (SS, RSP, RFLAGS, CS, RIP).
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
