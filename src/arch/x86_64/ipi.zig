//! Work one CPU asks the others to do: interrupts between processors.
//!
//! Three things are sent:
//!
//! - **A request** (`broadcast`): something every other CPU must have done
//!   before the sender goes on. Flushing addresses from its TLB after a
//!   mapping was removed, and letting go of an address space that is about
//!   to be freed (`docs/locking.md`, "Address spaces and the TLB").
//! - **A wake-up** (`wake`): an interrupt with nothing to do, which ends
//!   the halt of a CPU that had no thread to run.
//! - **Stop** (`stopOthers`): a CPU that reports a panic or a kernel fault
//!   halts the others first, with an NMI, so that nothing runs or prints
//!   while it reports.
//!
//! ## Requests cannot deadlock
//!
//! One request is in flight at a time (a lock of its own, outside the lock
//! order: it may be taken while holding anything, and nothing is taken
//! while holding it). The sender waits, with interrupts off, until every
//! other CPU has done the work.
//!
//! A CPU that has interrupts off does not take the interrupt. That is
//! harmless while it is in a short critical section, and a deadlock if it
//! is itself waiting for the sender: spinning on a spinlock the sender
//! holds, or waiting to send a request of its own. So the work is not tied
//! to the interrupt: **every loop that waits with interrupts off calls
//! `poll`**, which does a pending request on the spot. Those loops are the
//! spinlock's (`sync/spinlock.zig`) and the two here. The work must
//! therefore be safe anywhere in the kernel with interrupts off, whatever
//! locks the CPU holds, and it is: it touches only this CPU's TLB and CR3.

const std = @import("std");

const RawSpinLock = @import("../../kernel/sync/raw_spinlock.zig").RawSpinLock;
const apic = @import("apic.zig");
const cpu = @import("cpu.zig");
const idt = @import("idt.zig");
const percpu = @import("percpu.zig");
const vmm = @import("vmm.zig");

/// Interrupt vector that tells a CPU to look for a request.
pub const CALL_VECTOR: u8 = 49;
/// Interrupt vector that only wakes a halted CPU.
pub const WAKE_VECTOR: u8 = 50;
/// Interrupt vector that asks a CPU to switch threads (`thread.zig`).
pub const PREEMPT_VECTOR: u8 = 51;

/// What the other CPUs are asked to do.
pub const Request = union(enum) {
    /// Forget the translations of `pages` pages of kernel addresses from `start`.
    flush_kernel: struct { start: u64, pages: u64 },
    /// The same for user addresses of the address space `root`, on the
    /// CPUs that have it loaded.
    flush_user: struct { root: u64, start: u64, pages: u64 },
    /// Stop using the address space `root`: a CPU that has it loaded
    /// switches to the kernel's own page tables.
    unload_root: u64,
    /// Nothing but to have been interrupted: taking the interrupt and
    /// returning from it is a full memory barrier on that CPU, which is
    /// what `membarrier` promises a program.
    barrier,
};

/// Held by the CPU whose request is in flight.
var call_lock: RawSpinLock = .{};
/// The request in flight. Written under `call_lock`, before any CPU is
/// told to look.
var request: Request = undefined;
/// Requests sent since boot. A statistic, read by tests.
var requests_sent: std.atomic.Value(usize) = .init(0);

/// Number of the CPU that is stopping the others, or -1.
var stopper: std.atomic.Value(i32) = .init(-1);
/// CPUs that have halted because of it.
var stopped: std.atomic.Value(u32) = .init(0);

/// Install the handlers. Called once on the boot CPU, before any other CPU
/// is started.
pub fn init() void {
    idt.register(CALL_VECTOR, onCall);
    idt.register(WAKE_VECTOR, onWake);
    idt.register(PREEMPT_VECTOR, onPreempt);
}

fn onPreempt(_: *idt.Frame) void {
    @import("../../kernel/thread.zig").preemptRequested();
}

/// Ask CPU `c` to switch threads.
pub fn preempt(c: *const percpu.PerCpu) void {
    apic.sendIpi(c.apic_id, PREEMPT_VECTOR);
}

fn onCall(_: *idt.Frame) void {
    poll();
}

/// The interrupt itself was the point: the CPU is out of its halt.
fn onWake(_: *idt.Frame) void {}

/// Do the pending request, if this CPU has been asked and has not done it
/// yet; halt for good if the CPUs are being stopped. Interrupts must be
/// off. Called from the request interrupt and from every loop that waits
/// with interrupts off (see the top of the file).
pub fn poll() void {
    if (stopper.load(.acquire) >= 0) haltIfStopped();
    const c = percpu.currentIfReady() orelse return;
    if (!@atomicLoad(bool, &c.ipi_pending, .acquire)) return;
    switch (request) {
        .flush_kernel => |r| vmm.flushLocal(r.start, r.pages),
        .flush_user => |r| if (c.loaded_root == r.root) vmm.flushLocal(r.start, r.pages),
        .unload_root => |root| if (c.loaded_root == root) vmm.loadRoot(vmm.kernel_root),
        .barrier => {},
    }
    @atomicStore(bool, &c.ipi_pending, false, .release); // last: the sender goes on
}

/// Have every other CPU do `r`, and return when all of them have. With one
/// CPU there is nothing to do. May be called with interrupts on or off and
/// with any locks held. The caller does its own part itself.
pub fn broadcast(r: Request) void {
    send(r, null);
}

/// `broadcast` to the CPUs that have the address space `root` loaded, for
/// work only those can have (a flush of its user addresses, letting go of
/// it). The caller has made the change the work is for before calling, so
/// that a CPU that loads `root` after this looked has the change already
/// (`vmm.loadRoot`).
pub fn broadcastTo(r: Request, root: u64) void {
    send(r, root);
}

fn send(r: Request, only_root: ?u64) void {
    if (percpu.count() < 2) return;
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    while (!call_lock.tryLock()) {
        poll(); // the holder may be waiting for this CPU
        std.atomic.spinLoopHint();
    }
    defer call_lock.unlock();

    request = r;
    _ = requests_sent.fetchAdd(1, .monotonic);
    const me = percpu.current();
    const n = percpu.count();
    // The change the request is for is made; read where `root` is loaded
    // only after every CPU can see it (a store, then a load: x86 may
    // reorder those without a fence).
    if (only_root != null) asm volatile ("mfence" ::: .{ .memory = true });
    var asked: [percpu.MAX_CPUS / 64]u64 = @splat(0);
    for (0..n) |i| {
        const c = percpu.get(i);
        if (c == me) continue;
        if (only_root) |root| {
            if (@atomicLoad(u64, &c.loaded_root, .seq_cst) != root) continue;
            // A flush of user addresses passes a halted CPU by: it is
            // marked stale (first, see `vmm.leaveLazy`) and flushes when
            // it wakes. Waking a halted CPU, a virtual one above all, costs
            // far more. An address space being let go of is another matter:
            // nothing may keep it loaded.
            if (r == .flush_user) {
                @atomicStore(bool, &c.tlb_stale, true, .seq_cst);
                if (@atomicLoad(bool, &c.tlb_lazy, .seq_cst)) continue;
            }
        }
        asked[i / 64] |= @as(u64, 1) << @intCast(i % 64);
        @atomicStore(bool, &c.ipi_pending, true, .release);
        apic.sendIpi(c.apic_id, CALL_VECTOR);
    }
    for (0..n) |i| {
        const c = percpu.get(i);
        if (asked[i / 64] & (@as(u64, 1) << @intCast(i % 64)) == 0) continue;
        while (@atomicLoad(bool, &c.ipi_pending, .acquire)) {
            if (stopper.load(.acquire) >= 0) haltIfStopped(); // it may never answer
            std.atomic.spinLoopHint();
        }
    }
}

/// Requests sent since boot.
pub fn requestsSent() usize {
    return requests_sent.load(.monotonic);
}

/// End the halt of the CPU `c`, which has nothing to run. Interrupts must be off.
pub fn wake(c: *const percpu.PerCpu) void {
    apic.sendIpi(c.apic_id, WAKE_VECTOR);
}

/// Halt every other CPU, for good, and return once they have halted (or
/// after a short while, if one does not answer). For the CPU that is about
/// to report a panic or a kernel fault. Returns false if another CPU is
/// already doing this: then the caller is one of the CPUs to be stopped,
/// and must not report anything (`haltIfStopped`). Calling it again on the
/// CPU that did it returns true. Interrupts must be off.
pub fn stopOthers() bool {
    const me: i32 = if (percpu.currentIfReady()) |c| @intCast(c.id) else 0;
    if (stopper.cmpxchgStrong(-1, me, .acq_rel, .acquire)) |holder| return holder == me;
    if (!apic.ready()) return true; // this early there are no others
    const n = percpu.count();
    for (0..n) |i| {
        const c = percpu.get(i);
        if (c.id != me) apic.sendNmi(c.apic_id);
    }
    var patience: usize = 0;
    while (stopped.load(.acquire) + 1 < n and patience < 50_000_000) : (patience += 1) std.atomic.spinLoopHint();
    return true;
}

/// True if a CPU is stopping the others.
pub fn stopping() bool {
    return stopper.load(.acquire) >= 0;
}

/// If the CPUs are being stopped and this is not the CPU doing it: halt,
/// with interrupts off, and never return.
pub fn haltIfStopped() void {
    haltIfStoppedAt(null);
}

/// Where a stopped CPU was when it stopped, for the report of the CPU that
/// stopped it (`stoppedAt`): what each CPU was doing is often the cause of
/// a panic on another (a lock it holds, a request it does not answer).
pub const StoppedAt = struct {
    /// The instruction it was interrupted at, and its frame pointer.
    rip: u64 = 0,
    rbp: u64 = 0,
    /// It was running a program, not the kernel.
    user: bool = false,
    /// Recorded (it stopped from the NMI, not from a loop that polls).
    known: bool = false,
    /// Its flags (interrupts on or off), and its local APIC: interrupts in
    /// service and requested of vectors 32 to 63 (the timer's and the
    /// IPIs'), the timer's LVT entry and count, the task priority. A CPU
    /// that has stopped taking interrupts shows here.
    rflags: u64 = 0,
    isr1: u32 = 0,
    irr1: u32 = 0,
    lvt_timer: u32 = 0,
    timer_count: u32 = 0,
    tpr: u32 = 0,
};

var stopped_at: [percpu.MAX_CPUS]StoppedAt = @splat(.{});

/// `haltIfStopped` for the NMI handler, which knows where the CPU was
/// interrupted (`at`): recorded first.
pub fn haltIfStoppedAt(at: ?StoppedAt) void {
    const holder = stopper.load(.acquire);
    if (holder < 0) return;
    const me: i32 = if (percpu.currentIfReady()) |c| @intCast(c.id) else 0;
    if (holder == me) return;
    if (at) |where| {
        const s = &stopped_at[@intCast(me)];
        s.* = where;
        s.known = true;
        s.isr1 = apic.readReg(0x110);
        s.irr1 = apic.readReg(0x210);
        s.lvt_timer = apic.readReg(0x320);
        s.timer_count = apic.readReg(0x390);
        s.tpr = apic.readReg(0x80);
    }
    _ = stopped.fetchAdd(1, .acq_rel); // after the record: the stopper reads it then
    while (true) asm volatile ("cli; hlt");
}

/// Where CPU `id` was when `stopOthers` stopped it, if it said.
pub fn stoppedAt(id: usize) StoppedAt {
    return stopped_at[id];
}
