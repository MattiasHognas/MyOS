const cpu = @import("cpu.zig");

export var syscall_kernel_rsp: u64 = 0; // current thread's kernel stack top
export var syscall_user_rsp: u64 = 0; // scratch, only used with interrupts off

var handler: *const fn (*Frame) void = undefined;

pub const Frame = extern struct {
    r9: u64,
    r8: u64,
    r10: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rax: u64, // syscall number in, return value out
    rip: u64, // user RIP (CPU put it in RCX)
    rflags: u64, // user RFLAGS (CPU put it in R11)
    rsp: u64, // user RSP
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

extern fn syscall_entry() callconv(.c) void;

// The CPU calls this when a syscall occurs. It may switch threads, so it must not return.
export fn syscall_handler_c(f: *Frame) callconv(.c) void {
    asm volatile ("sti"); // long syscalls may be preempted
    handler(f);
    asm volatile ("cli"); // the exit path must not be interrupted
}

// Set the kernel stack pointer for the current thread. This is used when a syscall or interrupt occurs.
pub fn setKernelStack(top: u64) void {
    syscall_kernel_rsp = top;
}

// Initialize the syscall handler. The handler is called with a pointer to a Frame struct, which contains the syscall number and arguments. The handler must set f->rax to the return value.
pub fn init(h: *const fn (*Frame) void) void {
    handler = h;
    cpu.wrmsr(0xC0000080, cpu.rdmsr(0xC0000080) | 1); // EFER.SCE: enable syscall
    cpu.wrmsr(0xC0000081, (@as(u64, 0x13) << 48) | (@as(u64, 0x08) << 32)); // STAR: selectors
    cpu.wrmsr(0xC0000082, @intFromPtr(&syscall_entry)); // LSTAR: entry point
    cpu.wrmsr(0xC0000084, 0x700); // SFMASK: clear TF, IF, DF
}
