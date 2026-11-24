//! Per-CPU state, reached through the GS segment base.
//!
//! In ring 0 the GS base always points at the running CPU's `PerCpu`; in
//! ring 3 it holds the user's own GS base (0 until programs can set it). The
//! two are exchanged with `swapgs` on every entry from ring 3 and every exit
//! to it: `syscall_entry` (`syscall.zig`), `isr_common` (`idt.zig`) and
//! `enterUser` (`context.zig`). While the kernel runs, the user's value sits
//! in the `KERNEL_GS_BASE` MSR.
//!
//! There is one CPU today, but the entry assembly already has its final
//! shape; SMP (milestone 3) adds one `PerCpu` per CPU and moves the
//! scheduler's per-CPU variables here.
//!
//! What is here belongs to the CPU and is touched only by it, with
//! interrupts off, so it needs no lock (`docs/locking.md`).

const std = @import("std");

const cpu = @import("cpu.zig");
const lock_order = @import("../../kernel/sync/lock_order.zig");

/// MSR holding the active GS base.
pub const MSR_GS_BASE = 0xC0000101;
/// MSR holding the inactive GS base; `swapgs` exchanges the two.
pub const MSR_KERNEL_GS_BASE = 0xC0000102;

/// State of one CPU. The assembly entry paths use the first fields by
/// offset (`%gs:8`, `%gs:16`), so their order is fixed; see the checks below.
pub const PerCpu = extern struct {
    /// Address of this struct, so `current` is one load from `%gs:0`.
    self: *PerCpu,
    /// Top of the running thread's kernel stack; `syscall_entry` loads it into RSP.
    kernel_rsp: u64 = 0,
    /// Scratch slot for the user RSP during syscall entry (interrupts are off).
    user_rsp: u64 = 0,
    /// CPU number, 0 for the boot CPU.
    id: u32 = 0,
    /// The spinlocks this CPU holds (`sync/spinlock.zig` keeps it, in
    /// builds with assertions).
    locks: lock_order.Stack = .{},
};

comptime {
    std.debug.assert(@offsetOf(PerCpu, "self") == 0);
    std.debug.assert(@offsetOf(PerCpu, "kernel_rsp") == 8);
    std.debug.assert(@offsetOf(PerCpu, "user_rsp") == 16);
}

/// The boot CPU's state.
var boot_cpu: PerCpu = .{ .self = undefined };

/// True once the boot CPU's GS base is set. Until then only the boot CPU
/// runs, and `current` must not be called.
var ready = false;

/// Point GS at the boot CPU's `PerCpu` and clear the user GS base.
///
/// Must run after `gdt.init` (loading a selector into GS resets its base)
/// and before the first entry to ring 3.
pub fn init() void {
    boot_cpu.self = &boot_cpu;
    cpu.wrmsr(MSR_GS_BASE, @intFromPtr(&boot_cpu));
    cpu.wrmsr(MSR_KERNEL_GS_BASE, 0);
    ready = true;
}

/// The running CPU's state, or null this early in boot that there is none
/// yet (before `init`). For code that also runs then, like taking a lock.
pub inline fn currentIfReady() ?*PerCpu {
    return if (ready) current() else null;
}

/// The running CPU's state. Only valid in ring 0 after `init`.
pub inline fn current() *PerCpu {
    return asm volatile ("mov %%gs:0, %[ret]"
        : [ret] "=r" (-> *PerCpu),
    );
}

/// Set the stack `syscall_entry` switches to on this CPU. Called by the
/// scheduler on every thread switch with the new thread's stack top.
pub fn setKernelStack(top: u64) void {
    current().kernel_rsp = top;
}
