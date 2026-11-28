//! Per-CPU state, reached through the GS segment base.
//!
//! In ring 0 the GS base always points at the running CPU's `PerCpu`; in
//! ring 3 it holds the user's own GS base (0 until programs can set it). The
//! two are exchanged with `swapgs` on every entry from ring 3 and every exit
//! to it: `syscall_entry` (`syscall.zig`), `isr_common` (`idt.zig`) and
//! `enterUser` (`context.zig`). While the kernel runs, the user's value sits
//! in the `KERNEL_GS_BASE` MSR.
//!
//! Every CPU has one `PerCpu`: the boot CPU's is static, the others are
//! allocated when they are started (`smp.zig`). `get` finds them by number.
//!
//! What is here belongs to the CPU and is touched only by it, with
//! interrupts off, so it needs no lock (`docs/locking.md`). Code that can
//! be preempted must not keep the pointer from `current`: the thread may be
//! on another CPU by the time it uses it. The one thing such code reads,
//! the running thread, is read in a single instruction (`currentThread`).

const std = @import("std");

const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const lock_order = @import("../../kernel/sync/lock_order.zig");

/// MSR holding the active GS base.
pub const MSR_GS_BASE = 0xC0000101;
/// MSR holding the inactive GS base; `swapgs` exchanges the two.
pub const MSR_KERNEL_GS_BASE = 0xC0000102;

/// Most CPUs the kernel can run on: one per local APIC ID the xAPIC has.
pub const MAX_CPUS = 256;

/// The control registers and MSRs that must be set the same on every CPU,
/// as a CPU read them back after setting them up (`smp.readSetup`).
pub const Setup = extern struct {
    cr0: u64 = 0,
    cr4: u64 = 0,
    efer: u64 = 0,
    star: u64 = 0,
    lstar: u64 = 0,
    sfmask: u64 = 0,
    xcr0: u64 = 0,
    gs_base: u64 = 0,
    kernel_gs_base: u64 = 0,
};

/// State of one CPU. The assembly entry paths use the first fields by
/// offset (`%gs:8`, `%gs:16`), so their order is fixed; see the checks below.
pub const PerCpu = extern struct {
    /// Address of this struct, so `current` is one load from `%gs:0`.
    self: *PerCpu,
    /// Top of the running thread's kernel stack; `syscall_entry` loads it into RSP.
    kernel_rsp: u64 = 0,
    /// Scratch slot for the user RSP during syscall entry (interrupts are off).
    user_rsp: u64 = 0,
    /// The thread this CPU runs (a `*thread.Thread`; `thread.zig` owns it).
    thread: ?*anyopaque = null,
    /// CPU number, 0 for the boot CPU, then in the order they were started.
    id: u32 = 0,
    /// The CPU's local APIC ID.
    apic_id: u32 = 0,
    /// The spinlocks this CPU holds (`sync/spinlock.zig` keeps it, in
    /// builds with assertions).
    locks: lock_order.Stack = .{},
    /// This CPU's GDT, TSS and emergency stacks.
    tables: ?*gdt.Tables = null,

    // The scheduler's (`thread.zig`).
    /// Timer ticks left of the running thread's time slice.
    slice_left: u32 = 0,
    /// Whether this CPU takes threads from the ready queue. While it does
    /// not, it runs only the thread it started in (`idle_thread`), which
    /// halts between interrupts: the CPU is parked. Changed under the
    /// scheduler lock, by any CPU.
    runs_threads: bool = false,
    /// The CPU has halted because no thread was ready, and no other CPU
    /// has sent it a wake-up since. Guarded by the scheduler lock.
    idle: bool = false,
    /// A thread (a `*thread.Thread`) that only this CPU runs, to halt in
    /// when it is parked or the thread it ran last has exited. Null on the
    /// boot CPU until the other CPUs are started.
    idle_thread: ?*anyopaque = null,
    /// Another CPU has asked this one to switch threads, for a thread it
    /// woke (`thread.wake`). Guarded by the scheduler lock.
    preempt_requested: bool = false,
    /// Times this CPU halted because no thread was ready.
    halts: u64 = 0,
    /// Timer interrupts this CPU has taken.
    ticks: u64 = 0,

    // The VMM's (`vmm.zig`).
    /// The PML4 in this CPU's CR3, as `vmm.loadRoot` last set it.
    loaded_root: u64 = 0,
    /// CR3 loads on this CPU. A statistic, read by tests.
    root_loads: u64 = 0,

    /// The FS and GS base loaded for user code on this CPU: the last
    /// thread's that ran in ring 3 here (`setUserBases`).
    user_fs_base: u64 = 0,
    user_gs_base: u64 = 0,

    /// Set by a CPU that wants this one to do the request in flight, and
    /// cleared by this one when it has (`ipi.zig`).
    ipi_pending: bool = false,

    /// What this CPU's control registers held when it came up.
    setup: Setup = .{},

    /// When the hardware interrupts on this CPU came, folded together, not
    /// yet given to the random generator; and how many there were
    /// (`random.interruptTiming`). Touched only with interrupts off.
    entropy: [4]u64 = @splat(0),
    entropy_count: u32 = 0,

    /// This CPU's counters (`stats.zig`): per system call (a
    /// `*stats.SyscallTable`, made the first time it is needed), and per
    /// lock class the acquisitions that waited and the cycles they waited.
    syscall_stats: ?*anyopaque = null,
    lock_contended: [LOCK_CLASSES]u64 = @splat(0),
    lock_wait_cycles: [LOCK_CLASSES]u64 = @splat(0),
    /// Halted with nothing to run, and so not interrupted for a flush of
    /// the user addresses it has loaded (Linux's lazy TLB): whoever would
    /// have sets `tlb_stale` instead, and the CPU flushes them all when it
    /// wakes (`vmm.enterLazy`, `vmm.leaveLazy`). Both atomic.
    tlb_lazy: bool = false,
    tlb_stale: bool = false,
    /// Spinning for a moment before it halts with nothing to run
    /// (`thread.idleOnce`): whoever gives it something to do need not send
    /// it an interrupt (`thread.wakeCpu`). Atomic.
    polling: bool = false,
    /// Where the timer found this CPU, in kernels that sample
    /// (`profile.zig`; a `*profile.Ring`).
    profile_ring: ?*anyopaque = null,
};

comptime {
    std.debug.assert(@offsetOf(PerCpu, "self") == 0);
    std.debug.assert(@offsetOf(PerCpu, "kernel_rsp") == 8);
    std.debug.assert(@offsetOf(PerCpu, "user_rsp") == 16);
    std.debug.assert(@offsetOf(PerCpu, "thread") == 24);
}

/// Lock classes counted per CPU: one for each rank of the lock order.
pub const LOCK_CLASSES = @as(usize, @intFromEnum(@import("../../kernel/sync/lock_order.zig").Rank.console)) + 1; // the last rank

/// The boot CPU's state.
var boot_cpu: PerCpu = .{ .self = undefined, .runs_threads = true };

/// True once the boot CPU's GS base is set. Until then only the boot CPU
/// runs, and `current` must not be called.
var ready = false;

/// Every CPU that has been started, by number. An entry is written once,
/// before `online_count` is raised past it, and never changes afterwards.
var cpus: [MAX_CPUS]?*PerCpu = @splat(null);
var online_count: std.atomic.Value(u32) = .init(0);

/// Point this CPU's GS base at `c` and clear the user GS base. Must run
/// after the CPU's GDT is loaded (loading a selector into GS resets its
/// base) and before its first entry to ring 3.
pub fn install(c: *PerCpu) void {
    c.self = c;
    if (c.tables) |t| gdt.setIstOwner(t, @intFromPtr(c));
    cpu.wrmsr(MSR_GS_BASE, @intFromPtr(c));
    cpu.wrmsr(MSR_KERNEL_GS_BASE, 0);
}

/// Set up the boot CPU's state. Must run after `gdt.init`.
pub fn init() void {
    boot_cpu.tables = gdt.bootTables();
    install(&boot_cpu);
    ready = true;
    register(&boot_cpu);
}

/// Count `c` as online and give it the next CPU number. Called by each CPU
/// for itself, one at a time (`smp.zig` starts them one after the other).
pub fn register(c: *PerCpu) void {
    const n = online_count.load(.acquire);
    c.id = n;
    cpus[n] = c;
    // The CPU's number where a program can read it without the kernel
    // (`RDPID`, `RDTSCP`: the vDSO's `getcpu`), as Linux keeps it there.
    if (getcpuMode() != .none) cpu.wrmsr(MSR_TSC_AUX, n);
    online_count.store(n + 1, .release);
}

const MSR_TSC_AUX = 0xC000_0103;

/// How a program can learn its CPU's number without a system call
/// (`vdso.zig` tells the vDSO): `RDPID` where the CPU has it, else
/// `RDTSCP`, both reading `TSC_AUX`.
pub const GetcpuMode = enum(u32) { none = 0, rdpid = 1, rdtscp = 2 };

pub fn getcpuMode() GetcpuMode {
    if (cpu.cpuid(7, 0).ecx & (1 << 22) != 0) return .rdpid;
    if (cpu.cpuid(0x8000_0000, 0).eax >= 0x8000_0001 and cpu.cpuid(0x8000_0001, 0).edx & (1 << 27) != 0) return .rdtscp;
    return .none;
}

/// Number of CPUs that are up.
pub fn count() usize {
    return online_count.load(.acquire);
}

/// The state of CPU number `n`, which must be below `count()`. Only its
/// own CPU may change it; others may read what does not change, and
/// statistics.
pub fn get(n: usize) *PerCpu {
    std.debug.assert(n < count());
    return cpus[n].?;
}

/// The running CPU's state, or null this early in boot that there is none
/// yet (before `init`). For code that also runs then, like taking a lock.
pub inline fn currentIfReady() ?*PerCpu {
    return if (ready) current() else null;
}

/// The running CPU's state. Only valid in ring 0 after `init`, and only
/// for as long as the caller cannot be moved to another CPU: with
/// interrupts off.
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

/// The thread the running CPU runs (`PerCpu.thread`), or null before
/// `init`. One instruction, so the answer is right even if the caller is
/// preempted and moved to another CPU around it: it is the caller's own
/// thread either way.
pub inline fn currentThread() ?*anyopaque {
    if (!ready) return null;
    return asm volatile ("mov %%gs:24, %[ret]"
        : [ret] "=r" (-> ?*anyopaque),
    );
}

/// MSR holding the FS base. The kernel does not use FS, so it always holds
/// the running program's.
pub const MSR_FS_BASE = 0xC0000100;

/// Whether programs can change their FS and GS base without the kernel
/// (`wrfsbase`, `wrgsbase`): set by `usercopy.init` on the boot CPU.
pub var fsgsbase = false;

/// The FS and GS base user code on this CPU has now, which with FSGSBASE
/// may not be what the kernel last set. Interrupts must be off; in ring 0,
/// where the user's GS base is the inactive one.
pub fn userBases() struct { fs: u64, gs: u64 } {
    const c = current();
    if (fsgsbase) {
        c.user_fs_base = cpu.rdmsr(MSR_FS_BASE);
        c.user_gs_base = cpu.rdmsr(MSR_KERNEL_GS_BASE);
    }
    return .{ .fs = c.user_fs_base, .gs = c.user_gs_base };
}

/// Make `fs` and `gs` the FS and GS base that user code runs with on this
/// CPU. While the CPU is in the kernel the user's GS base is the inactive
/// one (`KERNEL_GS_BASE`), which the `swapgs` on the way out makes active.
/// Writing these registers is slow, so nothing is written that is already
/// there. Interrupts must be off.
pub fn setUserBases(fs: u64, gs: u64) void {
    const c = current();
    if (c.user_fs_base != fs) {
        cpu.wrmsr(MSR_FS_BASE, fs);
        c.user_fs_base = fs;
    }
    if (c.user_gs_base != gs) {
        cpu.wrmsr(MSR_KERNEL_GS_BASE, gs);
        c.user_gs_base = gs;
    }
}
