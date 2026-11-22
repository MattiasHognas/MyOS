//! `/test/entry_regs`: check that every general-purpose register is zero when
//! a program starts, so the kernel leaks none of its own values (pointers
//! into its heap or stacks, say) to user space.
//!
//! Exits with 0 if all registers are zero, 1 otherwise.

/// Program entry point. Naked, so no compiler-generated code touches a
/// register before they are all OR-ed together.
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ or %%rax, %%rdi
        \\ or %%rbx, %%rdi
        \\ or %%rcx, %%rdi
        \\ or %%rdx, %%rdi
        \\ or %%rsi, %%rdi
        \\ or %%rbp, %%rdi
        \\ or %%r8, %%rdi
        \\ or %%r9, %%rdi
        \\ or %%r10, %%rdi
        \\ or %%r11, %%rdi
        \\ or %%r12, %%rdi
        \\ or %%r13, %%rdi
        \\ or %%r14, %%rdi
        \\ or %%r15, %%rdi
        \\ setnz %%dil
        \\ movzbl %%dil, %%edi
        \\ mov $1, %%eax   # exit(rdi)
        \\ syscall
        \\ ud2
    );
}
