//! Fault-tolerant copies between kernel and user memory, and the CPU features
//! that keep the kernel away from user memory everywhere else.
//!
//! - **UMIP** makes `sgdt`, `sidt`, `sldt`, `smsw` and `str` fault in ring 3,
//!   so user programs cannot read the addresses of kernel tables.
//! - **SMEP** makes the kernel fault when it executes code in a user page.
//! - **SMAP** makes the kernel fault when it reads or writes a user page
//!   while RFLAGS.AC is clear. `user_copy` is the one user-access section: it
//!   sets AC with `stac` around its single copy instruction and clears it
//!   again with `clac`. Interrupt entry and `syscall` entry clear AC too, so
//!   it never leaks into other kernel code.
//!
//! The copy routines clamp the user address without a branch before they
//! use it: an address in user space is unchanged, any other becomes 0, which
//! is never mapped (`cmp`, `sbb`, `and`, as in `nospec.zig`). Their caller
//! has just checked that the range lies in user space, but that check is a
//! branch the CPU may guess wrong; with the clamp, even then the copy cannot
//! start at a kernel address and leave traces of what it read in the cache
//! (Spectre variant 1). Only the start needs it: the copy runs upwards, and
//! a range that begins in user space reaches the unmapped gap above it long
//! before any kernel address. An `lfence` would close the same gap, but hold
//! up every copy until all earlier instructions had finished.
//!
//! A page fault at the copy instruction (between the `user_copy_start` and
//! `user_copy_end` labels) on a user address is expected: the user passed a
//! bad pointer. The page-fault handler asks `fixup` and resumes at
//! `user_copy_fault`, which makes the copy return false.
//!
//! Callers go through `kernel/uaccess.zig`, which validates the range first.

const std = @import("std");

const user_range = @import("../../kernel/user_range.zig");
const cpu = @import("cpu.zig");

const log = std.log.scoped(.usercopy);

const CR0_WP: u64 = 1 << 16;
const CR4_UMIP: u64 = 1 << 11;
const CR4_SMEP: u64 = 1 << 20;
const CR4_FSGSBASE: u64 = 1 << 16;
const CR4_SMAP: u64 = 1 << 21;

/// Nonzero once SMAP is on. Read by the assembly here and in `idt.zig`, which
/// must not execute `stac`/`clac` on CPUs without SMAP (they would be invalid opcodes).
export var smap_enabled: u8 = 0;

/// True once SMEP is on.
pub var smep_enabled = false;

/// True once UMIP is on.
pub var umip_enabled = false;

// user_copy_from(dst: rdi, src: rsi, len: rdx) and
// user_copy_to(dst: rdi, src: rsi, len: rdx) -> rax: 0 = copied, 1 = faulted.
// `from` clamps the source, `to` the destination; then both run the same copy.
// 0x800000000000 is user_range.USER_END (checked below).
// stac/clac are written as bytes so the assembler needs no SMAP feature flag.
comptime {
    asm (
        \\.section .text
        \\.global user_copy_from
        \\.type user_copy_from, @function
        \\user_copy_from:
        \\  movabs $0x800000000000, %rax
        \\  cmp %rax, %rsi           # carry set exactly when src is below the end of user space
        \\  sbb %rax, %rax           # all ones then, all zeroes otherwise
        \\  and %rax, %rsi
        \\  jmp user_copy
        \\.size user_copy_from, . - user_copy_from
        \\
        \\.global user_copy_to
        \\.type user_copy_to, @function
        \\user_copy_to:
        \\  movabs $0x800000000000, %rax
        \\  cmp %rax, %rdi
        \\  sbb %rax, %rax
        \\  and %rax, %rdi
        \\.size user_copy_to, . - user_copy_to
        \\
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

comptime {
    std.debug.assert(user_range.USER_END == 0x8000_0000_0000); // the constant in the assembly above
}

extern fn user_copy_from(dst: usize, src: usize, len: usize) callconv(.c) u64;
extern fn user_copy_to(dst: usize, src: usize, len: usize) callconv(.c) u64;
extern const user_copy_start: u8;
extern const user_copy_end: u8;
extern const user_copy_fault: u8;

/// Copy `len` bytes from the user address `src` to the kernel address
/// `dst`. Returns false if a user page was not accessible; some bytes may
/// have been copied by then. The caller must have validated the user range;
/// if it has not, an address outside user space reads from address 0
/// instead, which fails.
pub fn copyFromUser(dst: usize, src: usize, len: usize) bool {
    return user_copy_from(dst, src, len) == 0;
}

/// Copy `len` bytes from the kernel address `src` to the user address
/// `dst`. Otherwise as `copyFromUser`.
pub fn copyToUser(dst: usize, src: usize, len: usize) bool {
    return user_copy_to(dst, src, len) == 0;
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

/// True if `rip` is the copy instruction of `user_copy`: a fault there is
/// on the memory a system call was given.
pub fn inCopy(rip: u64) bool {
    return rip >= @intFromPtr(&user_copy_start) and rip < @intFromPtr(&user_copy_end);
}

/// True once SMAP is on.
pub fn smapEnabled() bool {
    return smap_enabled != 0;
}

/// Turn on write protection for ring 0 (so `copyToUser` faults on read-only
/// user pages) and UMIP, SMEP and SMAP where the CPU has them, on this CPU.
/// Returns the CR4 it set. Every CPU runs this as it comes up.
pub fn initCpu() u64 {
    cpu.writeCr0(cpu.readCr0() | CR0_WP);

    var features: u32 = 0; // CPUID leaf 7 EBX
    var features_ecx: u32 = 0;
    if (cpu.cpuid(0, 0).eax >= 7) {
        const leaf7 = cpu.cpuid(7, 0);
        features = leaf7.ebx;
        features_ecx = leaf7.ecx;
    }
    var cr4 = cpu.readCr4();
    if (features_ecx & (1 << 2) != 0) cr4 |= CR4_UMIP;
    if (features & (1 << 7) != 0) cr4 |= CR4_SMEP;
    if (features & (1 << 20) != 0) cr4 |= CR4_SMAP;
    // Programs may read and write their FS and GS base themselves, as on
    // Linux (it tells them through `AT_HWCAP2`). Safe because the kernel
    // keeps its own GS base from them where it cannot rely on `swapgs`
    // (`isr_paranoid`) and reads theirs back when it switches threads.
    if (features & (1 << 0) != 0) cr4 |= CR4_FSGSBASE;
    cpu.writeCr4(cr4);
    return cr4;
}

/// `initCpu` on the boot CPU, and note what it turned on: the entry
/// assembly and the copy routines go by that. Called once during boot,
/// after the kernel's own page tables are loaded. The other CPUs must turn
/// on the same (`smp.zig` checks).
pub fn init() void {
    const cr4 = initCpu();
    smep_enabled = cr4 & CR4_SMEP != 0;
    umip_enabled = cr4 & CR4_UMIP != 0;
    smap_enabled = @intFromBool(cr4 & CR4_SMAP != 0);
    @import("percpu.zig").fsgsbase = cr4 & CR4_FSGSBASE != 0;
    log.info("UMIP {s}, SMEP {s}, SMAP {s}", .{
        if (umip_enabled) "on" else "not supported",
        if (smep_enabled) "on" else "not supported",
        if (smapEnabled()) "on" else "not supported",
    });
}
