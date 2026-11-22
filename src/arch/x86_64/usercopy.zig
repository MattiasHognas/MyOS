//! Fault-tolerant copies between kernel and user memory, and the CPU features
//! that keep the kernel away from user memory everywhere else.
//!
//! - **SMEP** makes the kernel fault when it executes code in a user page.
//! - **SMAP** makes the kernel fault when it reads or writes a user page
//!   while RFLAGS.AC is clear. `user_copy` is the one user-access section: it
//!   sets AC with `stac` around its single copy instruction and clears it
//!   again with `clac`. Interrupt entry and `syscall` entry clear AC too, so
//!   it never leaks into other kernel code.
//!
//! A page fault at the copy instruction (between the `user_copy_start` and
//! `user_copy_end` labels) on a user address is expected: the user passed a
//! bad pointer. The page-fault handler asks `fixup` and resumes at
//! `user_copy_fault`, which makes `copy` return false.
//!
//! Callers go through `kernel/uaccess.zig`, which validates the range first.

const std = @import("std");
const cpu = @import("cpu.zig");
const user_range = @import("../../kernel/user_range.zig");
const log = std.log.scoped(.usercopy);

const CR0_WP: u64 = 1 << 16;
const CR4_SMEP: u64 = 1 << 20;
const CR4_SMAP: u64 = 1 << 21;

/// Nonzero once SMAP is on. Read by the assembly here and in `idt.zig`, which
/// must not execute `stac`/`clac` on CPUs without SMAP (they would be invalid opcodes).
export var smap_enabled: u8 = 0;

/// True once SMEP is on.
pub var smep_enabled = false;

// user_copy(dst: rdi, src: rsi, len: rdx) -> rax: 0 = copied, 1 = faulted.
// stac/clac are written as bytes so the assembler needs no SMAP feature flag.
comptime {
    asm (
        \\.section .text
        \\.global user_copy
        \\.type user_copy, @function
        \\user_copy:
        \\  mov %rdx, %rcx
        \\  cmpb $0, smap_enabled(%rip)
        \\  je user_copy_start
        \\  .byte 0x0f, 0x01, 0xcb   # stac: allow user-memory access
        \\.global user_copy_start
        \\user_copy_start:
        \\  rep movsb
        \\.global user_copy_end
        \\user_copy_end:
        \\  xor %eax, %eax
        \\  jmp 1f
        \\.global user_copy_fault
        \\user_copy_fault:
        \\  mov $1, %eax
        \\1:
        \\  cmpb $0, smap_enabled(%rip)
        \\  je 2f
        \\  .byte 0x0f, 0x01, 0xca   # clac: forbid it again
        \\2:
        \\  ret
        \\.size user_copy, . - user_copy
    );
}

extern fn user_copy(dst: usize, src: usize, len: usize) callconv(.c) u64;
extern const user_copy_start: u8;
extern const user_copy_end: u8;
extern const user_copy_fault: u8;

/// Copy `len` bytes from `src` to `dst`, where one of the two is a user
/// address. Returns false if a user page was not accessible; some bytes may
/// have been copied by then. The caller must have validated the user range.
pub fn copy(dst: usize, src: usize, len: usize) bool {
    return user_copy(dst, src, len) == 0;
}

/// Called by the page-fault handler for a fault in ring 0 at `rip` on
/// address `fault_addr`. If the fault is a user address touched by the copy
/// instruction of `user_copy`, return the address to resume at; otherwise
/// null, and the fault is a genuine kernel fault.
pub fn fixup(rip: u64, fault_addr: u64) ?u64 {
    if (rip < @intFromPtr(&user_copy_start) or rip >= @intFromPtr(&user_copy_end)) return null;
    if (fault_addr >= user_range.USER_END) return null; // a bad kernel buffer is a kernel bug
    return @intFromPtr(&user_copy_fault);
}

/// True once SMAP is on.
pub fn smapEnabled() bool {
    return smap_enabled != 0;
}

/// Turn on write protection for ring 0 (so `copyToUser` faults on read-only
/// user pages) and SMEP and SMAP where the CPU has them. Called once during
/// boot, after the kernel's own page tables are loaded.
pub fn init() void {
    cpu.writeCr0(cpu.readCr0() | CR0_WP);

    var features: u32 = 0;
    if (cpu.cpuid(0, 0).eax >= 7) features = cpu.cpuid(7, 0).ebx;
    var cr4 = cpu.readCr4();
    if (features & (1 << 7) != 0) cr4 |= CR4_SMEP;
    if (features & (1 << 20) != 0) cr4 |= CR4_SMAP;
    cpu.writeCr4(cr4);
    smep_enabled = cr4 & CR4_SMEP != 0;
    smap_enabled = @intFromBool(cr4 & CR4_SMAP != 0);
    log.info("SMEP {s}, SMAP {s}", .{
        if (smep_enabled) "on" else "not supported",
        if (smapEnabled()) "on" else "not supported",
    });
}
