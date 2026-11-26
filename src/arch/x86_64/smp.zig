//! Starting the other CPUs.
//!
//! The bootloader has already started every CPU and parked it (the Limine
//! MP request); `init`, on the boot CPU, hands each one an entry point. A
//! CPU that is started gets, before it runs a single instruction of the
//! kernel: its `PerCpu`, its own GDT and TSS, four emergency stacks and a
//! kernel stack, each with a guard page below it (`kstack`), and a thread
//! for the context it starts in. They are started one after the other, so
//! a CPU's number is its place in that order.
//!
//! A CPU comes up in `apEntry`, on a stack of the bootloader's and on the
//! bootloader's page tables, and makes itself like the boot CPU step by
//! step: the kernel's page tables, its GDT and TSS, its GS base, the IDT,
//! its own stack; then the settings every CPU must have before a program
//! may run on it (write protection, SMEP, SMAP, UMIP, the `syscall` MSRs,
//! extended state), its local APIC and its timer. What it set is compared
//! with the boot CPU's: a CPU that came out different would be a hole in
//! exactly the protections that are checked once at boot, so the kernel
//! refuses to go on.
//!
//! Once it is up, a CPU takes threads from the ready queue like the boot
//! CPU (`thread.zig`); the context it started in retires and is where it
//! idles first.
//!
//! Time is kept by the boot CPU alone: its timer interrupt advances the
//! tick count and runs the timers. The other CPUs' timer interrupts only
//! drive their own time slices.

const std = @import("std");

const limine = @import("../../boot/limine.zig");
const hpet = @import("../../drivers/hpet.zig");
const heap = @import("../../kernel/heap.zig");
const pmm = @import("../../kernel/pmm.zig");
const kstack = @import("../../kernel/kstack.zig");
const thread = @import("../../kernel/thread.zig");
const timer = @import("../../kernel/timer.zig");
const panicFmt = @import("../../kernel/debug/panic.zig").panicFmt;
const apic = @import("apic.zig");
const context = @import("context.zig");
const cpu = @import("cpu.zig");
const fpu = @import("fpu.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const meltdown = @import("meltdown.zig");
const percpu = @import("percpu.zig");
const PerCpu = percpu.PerCpu;
const syscall = @import("syscall.zig");
const usercopy = @import("usercopy.zig");
const vmm = @import("vmm.zig");

const log = std.log.scoped(.smp);

/// Pages in an emergency stack, which is a small kernel stack slot.
const IST_PAGES = gdt.IST_STACK_SIZE / 4096;
comptime {
    std.debug.assert(gdt.IST_STACK_SIZE % 4096 == 0 and IST_PAGES <= kstack.STACK_PAGES);
}

/// How long a CPU gets to come up before it is given up on.
const START_TIMEOUT_NS = 1_000_000_000;

/// CPUs the bootloader reported, the boot CPU included. 1 until `init`.
var detected: usize = 1;

/// Number of CPUs the machine has, as the bootloader reported it. Compare
/// `percpu.count()`: the ones that are up.
pub fn detectedCount() usize {
    return detected;
}

/// Read the registers every CPU must have set the same, on this CPU.
pub fn readSetup() percpu.Setup {
    return .{
        .cr0 = cpu.readCr0(),
        .cr4 = cpu.readCr4(),
        .efer = cpu.rdmsr(0xC0000080),
        .star = cpu.rdmsr(0xC0000081),
        .lstar = cpu.rdmsr(0xC0000082),
        .sfmask = cpu.rdmsr(0xC0000084),
        .xcr0 = if (fpu.currentMode() == .xsave) fpu.readXcr0() else 0,
        .gs_base = cpu.rdmsr(percpu.MSR_GS_BASE),
        .kernel_gs_base = cpu.rdmsr(percpu.MSR_KERNEL_GS_BASE),
    };
}

/// True if `a` and `b` agree in everything that must be the same on every
/// CPU: all of it but the GS base, which is each CPU's own.
pub fn sameSetup(a: percpu.Setup, b: percpu.Setup) bool {
    return a.cr0 == b.cr0 and a.cr4 == b.cr4 and a.efer == b.efer and a.star == b.star and
        a.lstar == b.lstar and a.sfmask == b.sfmask and a.xcr0 == b.xcr0 and
        a.kernel_gs_base == b.kernel_gs_base;
}

/// Start every CPU the bootloader found, one at a time, and report how
/// many are up. `response` is the answer to the Limine MP request, or null
/// if there was none (then there is the boot CPU only). A CPU that cannot
/// be given its memory, or does not come up in time, is left out with an
/// error message; the kernel runs on the rest.
///
/// Requires the heap, `kstack`, the local APIC with its timer calibrated
/// and the timer handler installed, and everything a CPU sets up for user
/// programs to have been set up on the boot CPU.
pub fn init(response: ?*limine.MpResponse) void {
    const boot = percpu.current();
    boot.apic_id = apic.id();
    boot.setup = readSetup();
    thread.createIdle(boot) catch @panic("smp: no memory for the boot CPU's idle thread");

    if (response) |r| {
        detected = r.cpu_count;
        for (r.cpus[0..r.cpu_count]) |info| {
            if (info.lapic_id == r.bsp_lapic_id) continue;
            start(info) catch |e| log.err("CPU with APIC ID {d} not started: {s}", .{ info.lapic_id, @errorName(e) });
        }
    } else log.warn("the bootloader did not report the CPUs: running on one", .{});
    log.info("{d} of {d} CPUs online", .{ percpu.count(), detected });
}

/// Give the parked CPU `info` describes everything it needs and let it
/// run `apEntry`; return when it has counted itself online.
fn start(info: *limine.MpInfo) !void {
    if (percpu.count() == percpu.MAX_CPUS) return error.TooManyCpus;
    if (info.lapic_id > std.math.maxInt(u8)) return error.ApicIdOutOfRange; // needs x2APIC

    const c = try heap.allocator.create(PerCpu);
    errdefer heap.allocator.destroy(c);
    const tables = try heap.allocator.create(gdt.Tables);
    errdefer heap.allocator.destroy(tables);

    var stacks: [gdt.IST_INDEXES.len][]u8 = undefined;
    var allocated: usize = 0;
    errdefer for (stacks[0..allocated]) |s| kstack.free(s);
    for (&stacks) |*s| {
        s.* = kstack.allocSized(IST_PAGES) orelse return error.OutOfMemory;
        allocated += 1;
    }
    const stack = kstack.alloc() orelse return error.OutOfMemory;
    errdefer kstack.free(stack);

    gdt.prepare(tables, stacks);
    c.* = .{ .self = c, .apic_id = info.lapic_id, .tables = tables };
    _ = try thread.adoptCpu(c, stack);

    // From here on the CPU owns all of the above, also if it is slow.
    const before = percpu.count();
    info.extra_argument = @intFromPtr(c);
    @atomicStore(@TypeOf(info.goto_address), &info.goto_address, &apEntry, .seq_cst);

    const deadline = hpet.nanos() + START_TIMEOUT_NS;
    while (percpu.count() == before) {
        if (hpet.nanos() > deadline) {
            log.err("CPU with APIC ID {d} did not come up within {d} ms", .{ info.lapic_id, START_TIMEOUT_NS / 1_000_000 });
            return;
        }
        std.atomic.spinLoopHint();
    }
}

/// First kernel code of a CPU other than the boot CPU, jumped to by the
/// bootloader's parking loop with interrupts off. Nothing here may take a
/// lock, print or ask for the current thread until the GS base is set: all
/// of those go through it.
fn apEntry(info: *limine.MpInfo) callconv(.c) noreturn {
    const address = info.extra_argument; // the bootloader's memory: read it first
    vmm.enterKernelTables(); // the `PerCpu` is on the kernel heap
    const c: *PerCpu = @ptrFromInt(address);
    gdt.load(c.tables.?);
    percpu.install(c);
    vmm.noteKernelTables();
    idt.load();
    // Off the bootloader's stack, which has no guard page.
    context.runOnStack(c.kernel_rsp, &apMain);
}

/// The rest of a CPU's bring-up, on its own kernel stack, as its own thread.
fn apMain() callconv(.c) noreturn {
    const c = percpu.current();
    _ = usercopy.initCpu();
    if (!fpu.initCpu()) panicFmt("smp: CPU with APIC ID {d} lays out extended state differently from the boot CPU", .{c.apic_id});
    syscall.initCpu();
    meltdown.checkCpu();
    apic.initCpu();
    if (apic.id() != c.apic_id) panicFmt("smp: CPU says its APIC ID is {d}, the bootloader said {d}", .{ apic.id(), c.apic_id });

    c.setup = readSetup();
    const boot = percpu.get(0).setup;
    if (!sameSetup(c.setup, boot)) {
        panicFmt("smp: CPU with APIC ID {d} differs from the boot CPU: CR0 {x}/{x} CR4 {x}/{x} EFER {x}/{x} XCR0 {x}/{x}", .{
            c.apic_id,    c.setup.cr0, boot.cr0,     c.setup.cr4, boot.cr4,
            c.setup.efer, boot.efer,   c.setup.xcr0, boot.xcr0,
        });
    }

    apic.timerStart(timer.HZ);
    c.runs_threads = true;
    percpu.register(c); // online: the boot CPU goes on to the next one
    pmm.initCpu(); // its caches of free pages and heap blocks
    heap.initCpu();
    log.debug("CPU {d} (APIC ID {d}) is up", .{ c.id, c.apic_id });

    // This context has nothing left to do: the CPU takes threads from the
    // ready queue from here on, and idles in this thread until there is one.
    thread.retire();
}
