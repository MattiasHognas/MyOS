//! A syscall wrapper for tests that checks what the kernel does to the
//! caller's registers. Shared by the ring 3 test programs.
//!
//! `call` loads known values into every register the ABI says a syscall
//! preserves, makes the call, and compares afterwards:
//!
//! - RDI, RSI, RDX, R10, R8, R9 (the arguments) and RBX, RBP, R12-R15 come
//!   back unchanged;
//! - RSP is unchanged, whatever its alignment was;
//! - the arithmetic flags and the direction flag are unchanged;
//! - RCX holds the address after the `syscall` instruction and R11 the
//!   flags, as on Linux, so neither can carry a kernel value.

const std = @import("std");

/// Arithmetic flags plus DF: the flags a program can set freely.
pub const FLAGS_MASK: u64 = 0x1 | 0x4 | 0x10 | 0x40 | 0x80 | 0x400 | 0x800;

/// Values loaded into RBX, RBP and R12-R15 before the call.
const PATTERNS = [6]u64{
    0x1111_2222_3333_4444, 0x5555_6666_7777_8888, 0x9999_AAAA_BBBB_CCCC,
    0xDDDD_EEEE_FFFF_0001, 0x0123_4567_89AB_CDEF, 0xFEDC_BA98_7654_3210,
};

/// Input of `abi_syscall`: number, six arguments, flags to load, and how
/// far to move RSP down first (to test odd stack alignments).
const In = extern struct { nr: u64, args: [6]u64, flags: u64, misalign: u64 };

/// Registers as `abi_syscall` found them after the call.
const Out = extern struct {
    rax: u64,
    args: [6]u64, // rdi, rsi, rdx, r10, r8, r9
    saved: [6]u64, // rbx, rbp, r12, r13, r14, r15
    rcx: u64,
    r11: u64,
    rsp_after: u64,
    rsp_before: u64,
    caller_rsp: u64,
    flags: u64,
};

comptime {
    std.debug.assert(@offsetOf(In, "flags") == 56 and @offsetOf(In, "misalign") == 64);
    std.debug.assert(@offsetOf(Out, "saved") == 56 and @offsetOf(Out, "rcx") == 104);
    std.debug.assert(@offsetOf(Out, "rsp_after") == 120 and @offsetOf(Out, "flags") == 144);
}

// abi_syscall(in: rdi, out: rsi). The pointer to `out` waits on the stack
// during the call and is swapped with the result afterwards (`xchg` and
// `mov` leave the flags alone).
comptime {
    asm (
        \\.section .text
        \\.global abi_syscall
        \\.global abi_syscall_return
        \\.type abi_syscall, @function
        \\abi_syscall:
        \\  push %rbx
        \\  push %rbp
        \\  push %r12
        \\  push %r13
        \\  push %r14
        \\  push %r15
        \\  mov %rsp, 136(%rsi)
        \\  sub 64(%rdi), %rsp
        \\  push %rsi
        \\  mov %rsp, 128(%rsi)
        \\  pushq 56(%rdi)
        \\  popfq
        \\  movabs $0x1111222233334444, %rbx
        \\  movabs $0x5555666677778888, %rbp
        \\  movabs $0x9999AAAABBBBCCCC, %r12
        \\  movabs $0xDDDDEEEEFFFF0001, %r13
        \\  movabs $0x0123456789ABCDEF, %r14
        \\  movabs $0xFEDCBA9876543210, %r15
        \\  mov 0(%rdi), %rax
        \\  mov 16(%rdi), %rsi
        \\  mov 24(%rdi), %rdx
        \\  mov 32(%rdi), %r10
        \\  mov 40(%rdi), %r8
        \\  mov 48(%rdi), %r9
        \\  mov 8(%rdi), %rdi
        \\  syscall
        \\abi_syscall_return:
        \\  xchg %rax, (%rsp)
        \\  mov %rdi, 8(%rax)
        \\  mov %rsi, 16(%rax)
        \\  mov %rdx, 24(%rax)
        \\  mov %r10, 32(%rax)
        \\  mov %r8, 40(%rax)
        \\  mov %r9, 48(%rax)
        \\  mov %rbx, 56(%rax)
        \\  mov %rbp, 64(%rax)
        \\  mov %r12, 72(%rax)
        \\  mov %r13, 80(%rax)
        \\  mov %r14, 88(%rax)
        \\  mov %r15, 96(%rax)
        \\  mov %rcx, 104(%rax)
        \\  mov %r11, 112(%rax)
        \\  mov %rsp, 120(%rax)
        \\  pushfq
        \\  pop %rcx
        \\  mov %rcx, 144(%rax)
        \\  pop %rcx
        \\  mov %rcx, 0(%rax)
        \\  pushq $0x202
        \\  popfq
        \\  mov 136(%rax), %rsp
        \\  pop %r15
        \\  pop %r14
        \\  pop %r13
        \\  pop %r12
        \\  pop %rbp
        \\  pop %rbx
        \\  ret
        \\.size abi_syscall, . - abi_syscall
    );
}

extern fn abi_syscall(in: *const In, out: *Out) callconv(.c) void;
extern const abi_syscall_return: u8;

/// How the caller's state is set up for one call.
pub const Setup = struct {
    /// Flags to load before the call (only `FLAGS_MASK` bits are used).
    flags: u64 = 0,
    /// Bytes to move RSP down before the call.
    misalign: u64 = 0,
};

/// Make syscall `nr` with `args` and return its result, or null if the
/// kernel changed anything it must preserve.
pub fn call(nr: u64, args: [6]u64, setup: Setup) ?u64 {
    const flags = (setup.flags & FLAGS_MASK) | 0x202;
    const in: In = .{ .nr = nr, .args = args, .flags = flags, .misalign = setup.misalign };
    var out: Out = undefined;
    abi_syscall(&in, &out);
    if (!std.mem.eql(u64, &out.args, &args)) return null;
    if (!std.mem.eql(u64, &out.saved, &PATTERNS)) return null;
    if (out.rsp_after != out.rsp_before) return null;
    if (out.flags & FLAGS_MASK != flags & FLAGS_MASK) return null;
    if (out.rcx != @intFromPtr(&abi_syscall_return)) return null;
    if (out.r11 & FLAGS_MASK != flags & FLAGS_MASK) return null;
    return out.rax;
}

/// `call` with three arguments; the unused argument registers get marker
/// values, which must come back too.
pub fn call3(nr: u64, a1: u64, a2: u64, a3: u64, setup: Setup) ?u64 {
    return call(nr, .{ a1, a2, a3, 0xA4A4_A4A4_A4A4_A4A4, 0xA5A5_A5A5_A5A5_A5A5, 0xA6A6_A6A6_A6A6_A6A6 }, setup);
}
