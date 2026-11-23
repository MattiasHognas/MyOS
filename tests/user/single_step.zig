//! `/test/single_step`: set the trap flag (TF) in ring 3 and make a syscall
//! as the very next instruction, so the single-step trap is pending when the
//! CPU enters the kernel. The kernel masks TF on entry and gives it back on
//! return (through `iretq`), so the debug exception is delivered in ring 3,
//! after the instruction that follows the syscall, and kills this process
//! (exit status 255) like any other fault: there are no debuggers yet. It
//! must never be delivered in ring 0, where it would stop the kernel.
//!
//! Exits with 0 if no trap arrives at all.

const lib = @import("lib");
pub const panic = lib.panic;

/// Program entry point.
export fn _start() callconv(.c) noreturn {
    asm volatile (
        \\ pushfq
        \\ orq $0x100, (%%rsp)
        \\ mov $186, %%eax       # gettid
        \\ popfq                 # TF takes effect after the next instruction
        \\ syscall
        \\ nop
        \\ nop
        ::: .{ .rax = true, .rcx = true, .r11 = true, .memory = true });
    lib.exit(0);
}
