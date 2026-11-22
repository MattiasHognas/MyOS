//! `syscall`/`sysretq` entry path.
//!
//! Configures the syscall MSRs and provides the assembly entry point, which
//! switches to the current thread's kernel stack, builds a `Frame` and calls the
//! handler registered with `init`. The kernel-side dispatcher lives in
//! `kernel/syscall.zig`.

const cpu = @import("cpu.zig");

/// Top of the current thread's kernel stack. Loaded into RSP on syscall entry.
export var syscall_kernel_rsp: u64 = 0;
/// Scratch slot for the user RSP during entry. Only touched with interrupts off.
export var syscall_user_rsp: u64 = 0;

var handler: *const fn (*Frame) void = undefined;

/// User register state saved on syscall entry, lowest address first.
///
/// `rax` holds the syscall number on entry and the return value on exit;
/// `rdi`, `rsi`, `rdx`, `r10`, `r8` and `r9` hold the arguments.
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
    /// User RFLAGS (the CPU put it in R11).
    rflags: u64,
    /// User RSP.
    rsp: u64,
};

// Entry: the CPU has cleared IF (via SFMASK), so the scratch global is safe.
comptime {
    asm (
        \\.section .text
        \\.global syscall_entry
        \\syscall_entry:
        \\  mov %rsp, syscall_user_rsp(%rip)
        \\  mov syscall_kernel_rsp(%rip), %rsp
        \\  pushq syscall_user_rsp(%rip)
        \\  push %r11
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
        \\  pop %r9
        \\  pop %r8
        \\  pop %r10
        \\  pop %rdx
        \\  pop %rsi
        \\  pop %rdi
        \\  pop %rax
        \\  pop %rcx
        \\  pop %r11
        \\  pop %rsp
        \\  sysretq
    );
}

/// Assembly entry point defined above; its address is written to LSTAR.
extern fn syscall_entry() callconv(.c) void;

/// Called from `syscall_entry` on the kernel stack with the saved user registers.
///
/// Enables interrupts while the handler runs, so long syscalls can be
/// preempted, and disables them again before the return path touches the
/// scratch globals.
export fn syscall_handler_c(f: *Frame) callconv(.c) void {
    asm volatile ("sti"); // long syscalls may be preempted
    handler(f);
    asm volatile ("cli"); // the exit path must not be interrupted
}

/// Set the kernel stack that `syscall_entry` switches to. Called by the
/// scheduler on every thread switch with the new thread's stack top.
pub fn setKernelStack(top: u64) void {
    syscall_kernel_rsp = top;
}

/// Enable the `syscall` instruction and route it to `h`.
///
/// Sets EFER.SCE, the segment selectors in STAR, the entry point in LSTAR and
/// masks TF, IF and DF in SFMASK. `h` receives the saved user registers and
/// returns its result by writing `f.rax`.
pub fn init(h: *const fn (*Frame) void) void {
    handler = h;
    cpu.wrmsr(0xC0000080, cpu.rdmsr(0xC0000080) | 1); // EFER.SCE: enable syscall
    cpu.wrmsr(0xC0000081, (@as(u64, 0x13) << 48) | (@as(u64, 0x08) << 32)); // STAR: selectors
    cpu.wrmsr(0xC0000082, @intFromPtr(&syscall_entry)); // LSTAR: entry point
    cpu.wrmsr(0xC0000084, 0x700); // SFMASK: clear TF, IF, DF
}
