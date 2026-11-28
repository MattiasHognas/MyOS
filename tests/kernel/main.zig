//! In-kernel integration tests, run inside QEMU by the test kernel.
//!
//! `kmain` calls `run` in the test kernel. The tests reach the kernel through
//! `@import("root")` (see `helpers.zig`), so they use the kernel's own module
//! instances. `run` picks the scenario the host asked for: the test cases
//! below, or a deliberate panic or fault. Results are logged to serial as
//! `[PASS]`/`[FAIL]` lines followed by `MYOS_TEST_PASS` or `MYOS_TEST_FAIL`,
//! then QEMU is exited.

const std = @import("std");
/// The longest a test case may take before it counts as hung (`watchdog`).
const WATCHDOG_NS: u64 = 90 * std.time.ns_per_s;
const root = @import("root");
const pmm = root.kernel.pmm;
const process = root.kernel.process;
const serial = root.drivers.serial;
const assert = root.kernel.debug.assert;
const panicFmt = root.kernel.debug.panic.panicFmt;

const qemu_exit = @import("qemu_exit");

const fw_cfg = @import("fw_cfg.zig");
const helpers = @import("helpers.zig");

const log = std.log.scoped(.tests);

/// x86-64 page-table entry bits, for checking `ElfProbe.pte`.
const PTE_PRESENT: u64 = 1 << 0;
const PTE_WRITABLE: u64 = 1 << 1;
const PTE_USER: u64 = 1 << 2;
const PTE_NX: u64 = 1 << 63;

const TestError = error{ Failed, OutOfMemory };

/// Turn a boolean condition into `error.Failed`.
fn check(ok: bool) TestError!void {
    if (!ok) return error.Failed;
}

/// Allocating a page returns an aligned, non-zero, usable page and decrements the free count.
fn pageAccounting() TestError!void {
    const before = pmm.free_pages;
    const page = pmm.alloc() orelse
        return error.OutOfMemory;
    defer pmm.free(page);

    try check(page != 0 and page % 4096 == 0);
    try check(pmm.free_pages + 1 == before);
    try check(helpers.pageRw(page));
}

/// Consecutive allocations return distinct pages and are all accounted for.
fn multiplePages() TestError!void {
    const before = pmm.free_pages;

    var pages: [8]u64 = undefined;
    var used: usize = 0;

    defer {
        for (pages[0..used]) |page| {
            pmm.free(page);
        }
    }

    while (used < pages.len) {
        const p = pmm.alloc() orelse
            return error.OutOfMemory;

        for (pages[0..used]) |other| {
            try check(p != other);
        }

        try check(p != 0 and p % 4096 == 0);
        pages[used] = p;
        used += 1;
    }

    try check(pmm.free_pages + pages.len == before);
}

/// Frees of addresses that are not allocated pages are refused and change nothing.
fn pmmBadFrees() TestError!void {
    const failed = helpers.pmmRejectsBadFrees();
    if (failed != 0) report("PMM free check", failed);
    try check(failed == 0);
    try check(pmm.consistent());
}

/// The allocator's critical sections keep other threads out, shown by
/// holding a thread inside one for longer than a time slice.
fn pmmLock() TestError!void {
    const failed = helpers.pmmLockHolds();
    if (failed != 0) report("PMM lock check", failed);
    try check(failed == 0);
}

/// Mapping over an existing mapping is an error, for both page sizes.
fn vmmMapConflicts() TestError!void {
    const failed = helpers.vmmMapConflicts();
    if (failed != 0) report("map conflict check", failed);
    try check(failed == 0);
}

/// Unmapping removes the translation and frees page tables that became empty.
fn vmmUnmap() TestError!void {
    const failed = helpers.vmmUnmap();
    if (failed != 0) report("unmap check", failed);
    try check(failed == 0);
}

/// An unmapped or remapped page is never reached through a stale TLB entry.
fn vmmTlbFlush() TestError!void {
    const failed = helpers.vmmTlbFlush();
    if (failed != 0) report("TLB check", failed);
    try check(failed == 0);
}

/// With physical memory used up, every allocation fails with an error,
/// half-built page tables are taken down again, and nothing is lost.
fn memoryExhaustion() TestError!void {
    const failed = helpers.memoryExhaustion();
    if (failed != 0) report("memory exhaustion check", failed);
    try check(failed == 0);
    try expectProgram("/bin/hello"); // the kernel is fine afterwards
}

/// True if `e` is `error.TooLarge`.
fn tooLarge(e: ?anyerror) bool {
    return if (e) |err| err == error.TooLarge else false;
}

/// Starting a process fails cleanly at every single allocation it makes,
/// and so do allocating a kernel stack and growing the heap.
fn spawnAllocationFailures() TestError!void {
    try expectProgram("/bin/hello"); // warm up: the heap may grow
    var failures: usize = 0;
    const failed = helpers.spawnAllocationFailures(&failures);
    if (failed != 0) {
        report("allocation failure check", failed);
        report("after failing allocation number", failures);
    }
    try check(failed == 0);
    try check(pmm.consistent());
    const stack_failed = helpers.kstackAllocationFailures();
    if (stack_failed != 0) report("kernel stack allocation failure check", stack_failed);
    try check(stack_failed == 0);
    const heap_failed = helpers.heapGrowthFailures();
    if (heap_failed != 0) report("heap growth failure check", heap_failed);
    try check(heap_failed == 0);
}

/// Per-process limits: a program larger than its memory limit is not
/// started, descriptors stop at the limit, and a chain of processes stops
/// at the descendant limit; in each case with an error, not a crash, and
/// with nothing left behind.
fn processLimits() TestError!void {
    try expectProgram("/bin/hello"); // warm up: the heap may grow
    const before = helpers.footprint();

    // Memory: 4 pages are the stack alone, so no program fits; with room
    // for one page of program, a real one still does not.
    try check(tooLarge(helpers.spawnError("/bin/hello", .{ .max_pages = 4 })));
    try check(tooLarge(helpers.spawnError("/bin/hello", .{ .max_pages = 0 })));
    try check(tooLarge(helpers.spawnError("/bin/hello", .{ .max_pages = 5 })));
    try check(helpers.runProgramLimited("/bin/hello", .{ .max_pages = 4096 }) == 0);
    // The charge is everything the process takes: program, stack, page
    // tables and kernel stack. It is what the allocator really handed out,
    // and the limit is exact: that many pages are enough, one less is not.
    // (With the stack at a fixed address: at a random one it sometimes
    // crosses into another page table, which is one page more.)
    helpers.randomize_layout = false;
    defer helpers.randomize_layout = true;
    const charged = helpers.chargedPages("/bin/hello") orelse return error.Failed;
    try check(charged > 4 + 4 + 7); // more than the two stacks and the smallest set of page tables
    try check(helpers.runProgramLimited("/bin/hello", .{ .max_pages = charged }) == 0);
    try check(tooLarge(helpers.spawnError("/bin/hello", .{ .max_pages = charged - 1 })));
    // Too little even for the stacks: refused before anything is allocated.
    try check(tooLarge(helpers.spawnError("/bin/hello", .{ .max_pages = 8 })));

    // Open files: as many as the limit says less the three that are open
    // already, none at 3; by default more than a hundred, with a table
    // that grows as they are opened, up to 1024 and not one more.
    try check(helpers.runProgramLimited("/test/open_count", .{ .max_files = 16 }) == 13);
    try check(helpers.runProgram("/test/open_count") == 201);
    try check(helpers.runProgramArgs("/test/open_count", &.{ "open_count", "all" }, &.{}) == 0);
    try check(helpers.runProgramLimited("/test/open_count", .{ .max_files = 5 }) == 2);
    try check(helpers.runProgramLimited("/test/open_count", .{ .max_files = 3 }) == 0);
    try check(helpers.runProgramLimited("/test/open_count", .{ .max_files = 0 }) == 0);
    try check(helpers.runProgramLimited("/test/open_count", .{ .max_files = 100_000 }) == 201); // no more than the default for it
    try check(helpers.runProgramLimitedArgs("/test/open_count", &.{ "open_count", "all" }, .{ .max_files = 100_000 }) == 0);

    // Descendants: the chain stops exactly at the limit, with EAGAIN (100
    // plus the depth reached; see tests/user/recurse.zig).
    inline for (.{ 0, 1, 5, 12 }) |limit| {
        const code = helpers.runProgramLimited("/test/recurse", .{ .max_descendants = limit }) orelse return error.Failed;
        if (code != 100 + limit) report("/test/recurse exit status", code);
        try check(code == 100 + limit);
    }
    // The counts were given back: the same limit works again.
    try check(helpers.runProgramLimited("/test/recurse", .{ .max_descendants = 5 }) == 105);
    // A child that has exited no longer counts: eight in a row with a limit of one.
    try check(helpers.runProgramLimited("/test/run_many", .{ .max_descendants = 1 }) == 8);
    try check(helpers.runProgramLimited("/test/run_many", .{ .max_descendants = 0 }) == 0);

    helpers.quiesce(); // the processes that nobody waited for
    const after = helpers.footprint();
    try check(after.eql(before));
    try check(pmm.consistent());
}

/// A program that starts itself again and again until memory runs out gets
/// `ENOMEM` from `run`; every process in the chain exits normally, the
/// kernel keeps working and no memory is lost.
fn recursionUntilOutOfMemory() TestError!void {
    try expectProgram("/bin/hello"); // warm up: the heap may grow
    const before = helpers.footprint();
    // Leave 4 MiB, so the chain is dozens of processes rather than thousands.
    if (helpers.drainMemory(1024) != 1024) return error.Failed;
    const code = helpers.runProgram("/test/recurse");
    helpers.quiesce(); // the chain's last threads
    const low_water = pmm.free_pages;
    helpers.releaseDrained();
    const status = code orelse return error.Failed;
    // 200 + depth: stopped by ENOMEM, at least a few processes deep.
    if (status < 203 or status > 290) report("/test/recurse exit status", status);
    try check(status >= 203 and status <= 290);
    try check(low_water == 1024); // every process of the chain is gone again
    const after = helpers.footprint();
    if (!after.eql(before)) report("pages lost:", before.pages -% after.pages);
    try check(after.eql(before));
    try check(pmm.consistent());
    try expectProgram("/bin/hello");
}

/// Run `checks` and report the number of the first one that failed.
fn expectChecks(comptime what: []const u8, failed: u32) TestError!void {
    if (failed != 0) report(what ++ " check", failed);
    try check(failed == 0);
}

/// Spinlocks turn interrupts off and restore them, nest, and exclude.
fn spinlocks() TestError!void {
    const irq = helpers.enableInterrupts();
    defer helpers.restoreInterrupts(irq);
    try expectChecks("spinlock", helpers.spinlockChecks());
}

/// What the locking model promises, as far as one CPU can show it.
fn lockingModel() TestError!void {
    const irq = helpers.enableInterrupts();
    defer helpers.restoreInterrupts(irq);
    try expectChecks("locking model", helpers.lockingModelChecks());
}

/// Several waiters on one queue, woken in order; conditions rechecked;
/// wake-ups with nobody waiting are not kept; waits with a timeout.
fn waitQueues() TestError!void {
    try expectChecks("wait queue", helpers.waitQueueChecks());
}

/// Timers fire on their tick, in order; cancelling; sleeping.
fn idleWithPreemptRequest() TestError!void {
    try expectChecks("idle with a switch request", helpers.idleWithPreemptRequest());
}

fn timers() TestError!void {
    const irq = helpers.enableInterrupts();
    defer helpers.restoreInterrupts(irq);
    try expectChecks("timer", helpers.timerChecks());
}

/// A mutex excludes while its holder is preempted, yields and sleeps, and
/// is handed to the longest waiter.
fn mutexes() TestError!void {
    const irq = helpers.enableInterrupts();
    defer helpers.restoreInterrupts(irq);
    try expectChecks("mutex", helpers.mutexChecks());
}

/// Programs waiting for a key each get one, in the order they waited.
fn keyboardReaders() TestError!void {
    try expectChecks("keyboard reader", helpers.keyboardReaders());
}

/// A process's exit status outlives it; its resources do not.
fn processWaiting() TestError!void {
    _ = helpers.runProgram("/test/open_count"); // warm up: the heap may grow
    const irq = helpers.enableInterrupts();
    defer helpers.restoreInterrupts(irq);
    try expectChecks("process wait", helpers.processWaiting());
}

/// A child whose parent exits first is handed to its grandparent.
fn orphanedChild() TestError!void {
    const irq = helpers.enableInterrupts();
    defer helpers.restoreInterrupts(irq);
    try expectChecks("orphan", helpers.orphanedChild());
}

/// Hundreds of processes started and ended in every way leave nothing behind.
fn lifecycleStress() TestError!void {
    const irq = helpers.enableInterrupts();
    defer helpers.restoreInterrupts(irq);
    try expectChecks("lifecycle stress warm-up", helpers.lifecycleStress(1));
    try expectChecks("lifecycle stress", helpers.lifecycleStress(40));
}

/// The random-number generator is seeded, balanced, does not repeat, and
/// takes in the timing of interrupts.
fn randomNumbers() TestError!void {
    try expectChecks("random", helpers.randomChecks());
}

/// Freed heap blocks and pages are poisoned; pages for users are zeroed.
fn poisonAndZero() TestError!void {
    try expectChecks("poison and zero", helpers.poisonAndZero());
}

/// The kernel holds exactly the memory it held at `before`: free pages,
/// heap bytes in use, kernel stacks. Says what differs if not.
fn expectFootprint(before: helpers.Footprint) TestError!void {
    const now = helpers.footprint();
    if (now.eql(before)) return;
    root.print("  memory not as before: pages {d} -> {d}, heap bytes {d} -> {d}, kernel stacks {d} -> {d}\n", .{
        before.pages,      now.pages,
        before.heap_bytes, now.heap_bytes,
        before.stacks,     now.stacks,
    });
    return error.Failed;
}

/// A new process finds only zeroes in memory it has not written, even
/// when every free page was full of something else beforehand.
fn userMemoryIsZeroed() TestError!void {
    helpers.dirtyFreeMemory();
    const code = helpers.runProgram("/test/zero_pages") orelse return error.Failed;
    if (code != 0) report("/test/zero_pages found leftovers in area", code);
    try check(code == 0);
    // The same with the stack at its fixed address, which reuses other pages.
    helpers.dirtyFreeMemory();
    helpers.randomize_layout = false;
    defer helpers.randomize_layout = true;
    try check(helpers.runProgram("/test/zero_pages") == 0);
}

/// Index clamping without a branch, and the same for user addresses in the copy routines.
fn speculationGuards() TestError!void {
    try expectChecks("speculation guard", helpers.speculationGuards());
}

/// A ready thread never waits behind an idle CPU; with nothing ready, the CPU sleeps.
fn idleOnlyWhenNothingIsReady() TestError!void {
    try expectChecks("idle", helpers.idleChecks());
}

/// Kernel mappings are global, user mappings are not.
fn globalMappings() TestError!void {
    try expectChecks("global mapping", helpers.globalMappings());
}

/// Unmapping a kernel address flushes its global TLB entry.
fn kernelTlbFlush() TestError!void {
    try expectChecks("kernel TLB", helpers.kernelTlbFlush());
}

/// A kernel thread keeps the loaded address space; teardown switches away first.
fn kernelThreadAddressSpace() TestError!void {
    try expectChecks("kernel thread address space", helpers.kernelThreadAddressSpace());
}

/// Kernel code, constants and relocated tables are read-only under every address.
fn kernelWriteProtection() TestError!void {
    try expectChecks("kernel write protection", helpers.kernelWriteProtection());
}

/// Only the test kernel can replace the syscall handler.
fn syscallHandlerReplaceable() TestError!void {
    try check(helpers.syscallHandlerReplaceable());
}

/// Integration-test scenario "relro": write to a table of function pointers
/// that the bootloader relocated. It is read-only once the kernel runs.
noinline fn scenarioRelro() void {
    helpers.writeRelocatedTable();
    @panic("relro scenario: the write to a relocated table was not caught");
}

/// Integration-test scenario "text_alias": write to kernel code through the
/// direct map of physical memory. It is read-only there too.
noinline fn scenarioTextAlias() void {
    helpers.writeTextThroughDirectMap();
    @panic("text_alias scenario: the write to kernel code was not caught");
}

/// The CPU is not one that lets programs read kernel memory (Meltdown).
fn meltdownDecision() TestError!void {
    try expectChecks("Meltdown", helpers.meltdownDecision());
}

/// Every process gets its stack at a different random address.
fn stackRandomization() TestError!void {
    try expectChecks("stack randomization", helpers.stackRandomization());
}

/// The kernel works at the address the bootloader chose for it.
fn kernelRelocation() TestError!void {
    try expectChecks("kernel relocation", helpers.kernelRelocation());
}

/// Write to freed heap memory: the next allocation must panic.
noinline fn scenarioUseAfterFree() void {
    helpers.writeAfterFree();
    serial.puts("use after free was not caught\n");
}

/// The kernel heap can allocate, fill and free a block.
fn heapTest() TestError!void {
    try check(helpers.heapRoundtrip());
}

/// Creating and destroying an address space does not leak pages.
fn addressSpaceTest() TestError!void {
    try check(helpers.addressSpaceRoundtrip());
}

/// Heap usage counters follow allocations, shrinks and frees.
fn heapStats() TestError!void {
    try check(helpers.heapStats());
}

/// A mapped page translates back to its physical address; unmapped pages don't.
fn vmmMapTranslate() TestError!void {
    try check(helpers.vmmMapTranslate());
}

/// The kernel's own functions are symbolized from its ELF symbol table.
fn symbolizeKnownFunctions() TestError!void {
    const name = helpers.symbolize(@intFromPtr(&symbolTarget)) orelse return error.Failed;
    try check(std.mem.endsWith(u8, name, "symbolTarget"));
    const run_name = helpers.symbolize(@intFromPtr(&run) + 1) orelse return error.Failed;
    try check(std.mem.endsWith(u8, run_name, "run"));
    try check(helpers.symbolize(0) == null);
}

/// Target for the symbolization test; never called.
noinline fn symbolTarget() callconv(.c) void {
    asm volatile ("");
}

/// Backtraces follow the frame chain through named functions.
fn backtraceThroughFrames() TestError!void {
    try backtraceOuter();
}

/// Outer frame of the backtrace test.
noinline fn backtraceOuter() TestError!void {
    try backtraceInner();
    asm volatile (""); // keep this from being a tail call
}

/// Inner frame of the backtrace test: capture and check the chain.
noinline fn backtraceInner() TestError!void {
    var frames: [16]u64 = undefined;
    const n = helpers.captureBacktrace(&frames);
    try check(n >= 3);
    const inner = helpers.symbolize(frames[0] - 1) orelse return error.Failed;
    const outer = helpers.symbolize(frames[1] - 1) orelse return error.Failed;
    try check(std.mem.endsWith(u8, inner, "backtraceInner"));
    try check(std.mem.endsWith(u8, outer, "backtraceOuter"));
    asm volatile ("");
}

/// The host passed the scenario name through QEMU's fw_cfg device.
fn fwCfgScenario() TestError!void {
    var buf: [32]u8 = undefined;
    const scenario = fw_cfg.readFile("opt/myos/scenario", &buf) orelse return error.Failed;
    const want = if (expect_fxsave) "tests_fxsave" else if (expect_cpus > 1) "tests_smp" else "tests";
    try check(std.mem.eql(u8, scenario, want));
    try check(fw_cfg.readFile("opt/myos/does-not-exist", &buf) == null);
}

// ---------------------------------------------------------------------------
// ELF loading

/// Scratch buffer for ELF images built by the tests (kept off the stack).
var elf_buf: [0x3000]u8 align(8) = undefined;

// One page of scratch space for tests that read a whole page or sector run.
// Static, not a local: a 4 KiB stack frame would not fit the frame limit
// (scripts/check-frames.sh). The tests run one at a time.
var page_buf: [4096]u8 = undefined;

/// Options for `buildElf`. Defaults give a valid executable with one
/// read+execute segment of 16 bytes (0xAA) at 0x400000 and 0x2000 bytes of memory.
const ElfSpec = struct {
    class: u8 = 2,
    data: u8 = 1,
    typ: u16 = 2,
    machine: u16 = 0x3E,
    version: u32 = 1,
    entry: u64 = 0x40_0000,
    phoff: u64 = 64,
    ehsize: u16 = 64,
    phentsize: u16 = 56,
    phnum: u16 = 1,
    /// Fields of the first program header.
    flags: u32 = 5, // R + X
    offset: u64 = 0x1000,
    vaddr: u64 = 0x40_0000,
    filesz: u64 = 16,
    memsz: u64 = 0x2000,
    /// Optional second segment: 16 bytes of file data and one page of
    /// memory at this address (set `phnum` to 2 as well).
    second_vaddr: ?u64 = null,
    second_type: u32 = 1, // PT_LOAD
    second_flags: u32 = 6, // R + W
    /// A `PT_INTERP` header as the second one instead (set `phnum` to 2
    /// as well), naming this path.
    interp: ?[]const u8 = null,
    /// Length of the returned image.
    len: usize = 0x1010,
};

/// Build an ELF64 image in `elf_buf` from `spec`.
fn buildElf(spec: ElfSpec) []const u8 {
    const b = &elf_buf;
    @memset(b, 0);
    @memcpy(b[0..4], "\x7fELF");
    b[4] = spec.class;
    b[5] = spec.data;
    b[6] = 1;
    std.mem.writeInt(u16, b[16..18], spec.typ, .little);
    std.mem.writeInt(u16, b[18..20], spec.machine, .little);
    std.mem.writeInt(u32, b[20..24], spec.version, .little);
    std.mem.writeInt(u64, b[24..32], spec.entry, .little);
    std.mem.writeInt(u64, b[32..40], spec.phoff, .little);
    std.mem.writeInt(u16, b[52..54], spec.ehsize, .little);
    std.mem.writeInt(u16, b[54..56], spec.phentsize, .little);
    std.mem.writeInt(u16, b[56..58], spec.phnum, .little);

    const ph = b[64..120];
    std.mem.writeInt(u32, ph[0..4], 1, .little); // PT_LOAD
    std.mem.writeInt(u32, ph[4..8], spec.flags, .little);
    std.mem.writeInt(u64, ph[8..16], spec.offset, .little);
    std.mem.writeInt(u64, ph[16..24], spec.vaddr, .little);
    std.mem.writeInt(u64, ph[32..40], spec.filesz, .little);
    std.mem.writeInt(u64, ph[40..48], spec.memsz, .little);
    if (spec.second_vaddr) |v| {
        const ph2 = b[120..176];
        std.mem.writeInt(u32, ph2[0..4], spec.second_type, .little);
        std.mem.writeInt(u32, ph2[4..8], spec.second_flags, .little);
        std.mem.writeInt(u64, ph2[8..16], 0x1000, .little);
        std.mem.writeInt(u64, ph2[16..24], v, .little);
        std.mem.writeInt(u64, ph2[32..40], 16, .little);
        std.mem.writeInt(u64, ph2[40..48], 0x1000, .little);
    }
    @memset(b[0x1000..0x1010], 0xAA);
    if (spec.interp) |path| {
        const ph2 = b[120..176];
        std.mem.writeInt(u32, ph2[0..4], 3, .little); // PT_INTERP
        std.mem.writeInt(u32, ph2[4..8], 4, .little);
        std.mem.writeInt(u64, ph2[8..16], 0x1010, .little);
        std.mem.writeInt(u64, ph2[16..24], spec.vaddr + 0x10, .little);
        std.mem.writeInt(u64, ph2[32..40], path.len + 1, .little);
        std.mem.writeInt(u64, ph2[40..48], path.len + 1, .little);
        @memcpy(b[0x1010..][0..path.len], path);
        return b[0 .. 0x1010 + path.len + 1];
    }
    return b[0..spec.len];
}

/// A valid image loads: entry point, contents, zeroed .bss, and no leaked pages.
fn elfLoadValid() TestError!void {
    const before = pmm.free_pages;
    var out: [32]u8 = undefined;

    const p = helpers.elfProbe(buildElf(.{}), 0x40_0000, &out) orelse return error.Failed;
    try check(p.entry == 0x40_0000);
    try check(std.mem.allEqual(u8, out[0..16], 0xAA)); // file contents
    try check(std.mem.allEqual(u8, out[16..32], 0)); // .bss tail of the first page

    _ = helpers.elfProbe(buildElf(.{}), 0x40_1000, &out) orelse return error.Failed;
    try check(std.mem.allEqual(u8, &out, 0)); // second page: all .bss

    // The lowest and the highest place a program may be loaded.
    const low = helpers.image_limits.min_addr;
    const bottom = helpers.elfProbe(buildElf(.{ .vaddr = low, .entry = low }), low, &out) orelse return error.Failed;
    try check(bottom.pte & PTE_PRESENT != 0);
    const high = helpers.image_limits.max_addr - 0x2000;
    const top = helpers.elfProbe(buildElf(.{ .vaddr = high, .entry = high }), high + 0x1000, &out) orelse return error.Failed;
    try check(top.pte & PTE_PRESENT != 0);

    try check(pmm.free_pages == before);
}

/// A segment that does not start on a page boundary: its data lands at the
/// right offset in the page, everything around it is zero, and only the
/// pages it touches are mapped.
fn elfLoadUnaligned() TestError!void {
    const before = pmm.free_pages;
    var out: [32]u8 = undefined;

    // 8 bytes of data at 0x400004. The file has 0xAA in the four bytes before
    // them too; those belong to no segment and must not show up.
    const spec: ElfSpec = .{ .offset = 0x1004, .vaddr = 0x40_0004, .filesz = 8, .memsz = 0x1800, .entry = 0x40_0004 };
    const first = helpers.elfProbe(buildElf(spec), 0x40_0000, &out) orelse return error.Failed;
    try check(first.entry == 0x40_0004 and first.pte & PTE_PRESENT != 0);
    try check(std.mem.allEqual(u8, out[0..4], 0)); // before the segment
    try check(std.mem.allEqual(u8, out[4..12], 0xAA)); // its data
    try check(std.mem.allEqual(u8, out[12..32], 0)); // .bss

    // 0x400004 + 0x1800 ends in the second page; the third is not mapped.
    const second = helpers.elfProbe(buildElf(spec), 0x40_1000, &out) orelse return error.Failed;
    try check(second.pte & PTE_PRESENT != 0 and std.mem.allEqual(u8, &out, 0));
    const third = helpers.elfProbe(buildElf(spec), 0x40_2000, &out) orelse return error.Failed;
    try check(third.pte == 0);

    // 16 bytes of data across a page boundary: 8 at the end of one page, 8 at
    // the start of the next, followed by .bss.
    const image = buildElf(.{ .offset = 0x1FF8, .vaddr = 0x40_0FF8, .filesz = 16, .memsz = 0x20, .entry = 0x40_0FF8, .len = 0x2008 });
    @memset(elf_buf[0x1FF8..0x2000], 0xCC);
    @memset(elf_buf[0x2000..0x2008], 0xDD);
    _ = helpers.elfProbe(image, 0x40_0FF8, &out) orelse return error.Failed;
    try check(std.mem.allEqual(u8, out[0..8], 0xCC)); // elfProbe copies up to the end of the page
    _ = helpers.elfProbe(image, 0x40_0FF0, &out) orelse return error.Failed;
    try check(std.mem.allEqual(u8, out[0..8], 0)); // just before the segment
    _ = helpers.elfProbe(image, 0x40_1000, &out) orelse return error.Failed;
    try check(std.mem.allEqual(u8, out[0..8], 0xDD) and std.mem.allEqual(u8, out[8..32], 0));

    try check(pmm.free_pages == before);
}

/// Segment flags become page permissions: user, writable only if W, NX unless X.
fn elfLoadPermissions() TestError!void {
    var out: [8]u8 = undefined;
    const rx = helpers.elfProbe(buildElf(.{ .flags = 5 }), 0x40_0000, &out) orelse return error.Failed;
    try check(rx.pte & PTE_PRESENT != 0 and rx.pte & PTE_USER != 0);
    try check(rx.pte & PTE_WRITABLE == 0 and rx.pte & PTE_NX == 0);

    // Execute-only is not possible on x86-64: the page is readable anyway.
    const x = helpers.elfProbe(buildElf(.{ .flags = 1 }), 0x40_0000, &out) orelse return error.Failed;
    try check(x.pte & PTE_USER != 0 and x.pte & PTE_WRITABLE == 0 and x.pte & PTE_NX == 0);

    // The entry point needs an executable segment, so the others are tested on a second one.
    const rw = helpers.elfProbe(buildElf(.{ .phnum = 2, .second_vaddr = 0x50_0000, .second_flags = 6 }), 0x50_0000, &out) orelse return error.Failed;
    try check(rw.pte & PTE_USER != 0 and rw.pte & PTE_WRITABLE != 0 and rw.pte & PTE_NX != 0);

    const r = helpers.elfProbe(buildElf(.{ .phnum = 2, .second_vaddr = 0x50_0000, .second_flags = 4 }), 0x50_0000, &out) orelse return error.Failed;
    try check(r.pte & PTE_USER != 0 and r.pte & PTE_WRITABLE == 0 and r.pte & PTE_NX != 0);
}

/// The real /bin/hello: every PT_LOAD segment from its program headers is
/// mapped for user mode with exactly the permissions its flags ask for
/// (writable only if W, non-executable unless X), and page 0 stays unmapped.
fn elfLoadHelloPermissions() TestError!void {
    const hdr = &page_buf;
    const n = helpers.readFileAt("/bin/hello", 0, hdr) orelse return error.Failed;
    try check(n >= 64);
    const phoff = std.mem.readInt(u64, hdr[32..40], .little);
    const phnum = std.mem.readInt(u16, hdr[56..58], .little);
    try check(phoff + @as(u64, phnum) * 56 <= n);

    var out: [8]u8 = undefined;
    var loads: usize = 0;
    var executable: usize = 0;
    for (0..phnum) |i| {
        const ph = hdr[@intCast(phoff + i * 56)..][0..56];
        if (std.mem.readInt(u32, ph[0..4], .little) != 1) continue; // PT_LOAD only
        const flags = std.mem.readInt(u32, ph[4..8], .little);
        const vaddr = std.mem.readInt(u64, ph[16..24], .little);
        const p = helpers.elfProbePath("/bin/hello", vaddr, &out) orelse return error.Failed;
        try check(p.pte & PTE_PRESENT != 0 and p.pte & PTE_USER != 0);
        try check((p.pte & PTE_WRITABLE != 0) == (flags & 2 != 0));
        try check((p.pte & PTE_NX == 0) == (flags & 1 != 0));
        loads += 1;
        if (flags & 1 != 0) executable += 1;
    }
    try check(loads >= 2 and executable >= 1);

    const zero = helpers.elfProbePath("/bin/hello", 0, &out) orelse return error.Failed;
    try check(zero.pte == 0);
}

/// Malformed or unsupported images are rejected without leaking pages. The
/// host tests check each rule and its error; this checks the loader as a
/// whole refuses them.
fn elfRejectMalformed() TestError!void {
    const before = pmm.free_pages;
    var out: [8]u8 = undefined;
    const limit = helpers.image_limits.max_addr;
    const bad = [_]ElfSpec{
        .{ .len = 63 }, // shorter than the ELF header
        .{ .class = 1 }, // 32-bit
        .{ .data = 2 }, // big endian
        .{ .machine = 3 }, // i386
        .{ .typ = 1 }, // ET_REL: an object file
        .{ .typ = 4 }, // ET_CORE
        .{ .version = 2 }, // unknown ELF version
        .{ .ehsize = 52 }, // wrong ELF header size
        .{ .phentsize = 64 }, // wrong program header size
        .{ .phnum = 0 }, // nothing to load
        .{ .phoff = 0x2FFF }, // program header table past the end of the file
        .{ .phnum = 200 }, // program header table runs past the end
        .{ .vaddr = 0xFFFF_8000_0000_0000 }, // kernel half
        .{ .vaddr = 0x7FFF_FFFF_F000 }, // ends past the user half
        .{ .vaddr = 0x7FFF_FFFF_E000 }, // fits, but covers the last user page (never mapped: sysret)
        .{ .vaddr = 0x7FFF_FFFF_F000, .memsz = 0x1000 }, // exactly the last user page
        .{ .entry = 0x7FFF_FFFF_F000 }, // entry point in the last user page
        .{ .vaddr = 0x7FFF_FFFE_C000, .entry = 0x7FFF_FFFE_C000 }, // on top of the user stack
        .{ .vaddr = limit - 0x1000, .entry = limit - 0x1000 }, // ends inside the region reserved for the stack
        .{ .vaddr = 0, .entry = 0 }, // page zero
        .{ .vaddr = 0xF000, .entry = 0xF000 }, // below the lowest loadable address
        .{ .vaddr = 0xFFFF_FFFF_FFFF_F000 }, // vaddr + memsz wraps around
        .{ .vaddr = 0x40_0100 }, // not congruent with the file offset
        .{ .filesz = 0x3000 }, // filesz > memsz
        .{ .offset = 0x1000, .filesz = 0x100 }, // file data past the end of the image
        .{ .flags = 7 }, // writable and executable
        .{ .flags = 4 }, // entry point in a segment that is not executable
        .{ .entry = 0x40_2000 }, // entry point just past the segment
        .{ .entry = 0xFFFF_FFFF_8000_0000 }, // entry point in the kernel
        .{ .phnum = 2, .second_vaddr = 0x40_1000 }, // second segment on a page of the first
        .{ .phnum = 2, .second_vaddr = 0x50_0000, .second_flags = 7 }, // second segment writable and executable
        .{ .phnum = 2, .second_vaddr = 0x50_0000, .second_type = 3 }, // PT_INTERP that names no path
        .{ .memsz = 1 << 40 }, // a terabyte of .bss
        .{ .memsz = helpers.image_limits.max_bytes + 1 }, // one byte over the memory limit
    };
    for (bad) |spec| try check(helpers.elfProbe(buildElf(spec), 0x40_0000, &out) == null);
    try check(pmm.free_pages == before);
}

/// A program that cannot be loaded leaves nothing behind in `process.spawn`:
/// no pages, no page tables and no heap memory.
fn elfSpawnRollback() TestError!void {
    // The first segment is fine, the second is not.
    try check(helpers.spawnFailsCleanly(buildElf(.{ .phnum = 2, .second_vaddr = 0xFFFF_8000_0000_0000 })));
    try check(helpers.spawnFailsCleanly(buildElf(.{ .phnum = 2, .second_vaddr = 0x40_0123 })));
    try check(helpers.spawnFailsCleanly(buildElf(.{ .phnum = 2, .second_vaddr = 0x40_1000 })));
    try check(helpers.spawnFailsCleanly(buildElf(.{ .machine = 3 })));
    try check(helpers.spawnFailsCleanly("not an ELF"));
    // A program whose interpreter is missing, is no program, or is linked
    // for the addresses the program itself is at.
    try check(helpers.spawnFailsCleanly(buildElf(.{ .phnum = 2, .interp = "/lib/ld-does-not-exist.so.1" })));
    try check(helpers.spawnFailsCleanly(buildElf(.{ .phnum = 2, .interp = "/etc/motd" })));
    // (A real program as the interpreter, if the image has the fixtures.)
    if (helpers.fileExists("/fixtures/musl-hello-static")) {
        try check(helpers.spawnFailsCleanly(buildElf(.{ .phnum = 2, .interp = "/fixtures/musl-hello-static", .vaddr = 0x100_0000, .entry = 0x100_0000 })));
    }

    // An image within the limit that needs more pages than are free is
    // refused before anything is allocated (skipped on a machine with more
    // free memory than the limit).
    const want = (@as(u64, pmm.free_pages) + 1) * pmm.PAGE_SIZE;
    if (want <= helpers.image_limits.max_bytes) {
        try check(helpers.spawnFailsCleanly(buildElf(.{ .memsz = want })));
        const no_memory = helpers.elfLoadError(buildElf(.{ .memsz = want })) orelse return error.Failed;
        try check(no_memory == error.OutOfMemory);
    }
    const too_large = helpers.elfLoadError(buildElf(.{ .memsz = 1 << 40 })) orelse return error.Failed;
    try check(too_large == error.TooLarge);
    try check(helpers.elfLoadError(buildElf(.{})) == null);
}

// ---------------------------------------------------------------------------
// User mode: syscalls, isolation, process lifecycle

/// Syscall buffer and descriptor validation, checked from ring 3.
fn userSyscalls() TestError!void {
    // (With 16 descriptors: it fills the table to see what happens then.)
    const code = helpers.runProgramLimited("/test/syscalls", .{ .max_files = 16 }) orelse return error.Failed;
    if (code != 0) {
        var buf: [64]u8 = undefined;
        serial.puts(std.fmt.bufPrint(&buf, "  /test/syscalls failed check {d}\n", .{code}) catch "");
    }
    try check(code == 0);
}

/// Bad user pointers (unmapped, partly mapped, read-only) fail the syscall
/// and nothing else, checked from ring 3; no memory is leaked.
fn userPointers() TestError!void {
    _ = helpers.runProgram("/test/user_pointers"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/user_pointers") orelse return error.Failed;
    if (code != 0) {
        var buf: [64]u8 = undefined;
        serial.puts(std.fmt.bufPrint(&buf, "  /test/user_pointers failed check {d}\n", .{code}) catch "");
    }
    try check(code == 0);
    try expectFootprint(memory);
}

/// `copyFromUser`/`copyToUser` against mapped, unmapped, partly mapped and
/// read-only pages, kernel pointers and overflowing ranges.
fn userCopy() TestError!void {
    const failed = helpers.userCopyChecks();
    if (failed != 0) {
        var buf: [64]u8 = undefined;
        serial.puts(std.fmt.bufPrint(&buf, "  user copy failed check {d}\n", .{failed}) catch "");
    }
    try check(failed == 0);
}

/// Ring 0 write protection, UMIP, SMEP and SMAP are on (QEMU's `-cpu max` has them all).
fn userProtectionOn() TestError!void {
    try check(helpers.userProtectionOn());
}

/// RFLAGS.AC is cleared on interrupt entry and masked on syscall entry.
fn acClearedOnKernelEntry() TestError!void {
    const failed = helpers.acClearedOnKernelEntry();
    if (failed != 0) {
        var buf: [64]u8 = undefined;
        serial.puts(std.fmt.bufPrint(&buf, "  AC check {d} failed\n", .{failed}) catch "");
    }
    try check(failed == 0);
}

/// Print `<what> <number>` as a detail line under a failing test.
fn report(comptime what: []const u8, number: u64) void {
    var buf: [96]u8 = undefined;
    serial.puts(std.fmt.bufPrint(&buf, "  " ++ what ++ " {d}\n", .{number}) catch "");
}

/// Run `/test/<name>` and require exit status 0, reporting the status otherwise.
fn expectProgram(comptime path: []const u8) TestError!void {
    const code = helpers.runProgram(path) orelse return error.Failed;
    if (code != 0) report(path ++ " failed check", code);
    try check(code == 0);
}

/// A syscall returns every register except RAX, RCX and R11 unchanged, with
/// the flags and the stack pointer, whatever the call did.
fn syscallRegisters() TestError!void {
    try expectProgram("/test/syscall_abi");
}

/// Interrupts are on during a syscall and off on the way in and out; the
/// kernel stack, the GS base and the address space are the calling
/// process's at every syscall and every timer interrupt, including timer
/// interrupts that preempt a syscall halfway. Two processes making long
/// syscalls run until the timer has hit both ring 3 and a running syscall.
fn kernelEntryInvariants() TestError!void {
    helpers.installProbes(.noncanonical_rip);
    defer helpers.removeProbes();
    // Until the timer has hit both places often enough. How many runs that
    // takes depends on how fast the machine is: under QEMU's emulation a
    // run spans several ticks, on a real CPU (KVM) it is over in a
    // fraction of one, so the bound is time, not a number of runs.
    const give_up = helpers.nanos() + 10 * std.time.ns_per_s;
    while (helpers.nanos() < give_up) {
        try check(helpers.runPair("/test/preempt"));
        if (helpers.probes.syscall_ticks >= 3 and helpers.probes.user_ticks >= 3) break;
    }
    const seen = helpers.probes;
    if (seen.violation != 0) report("kernel entry invariant", seen.violation);
    try check(seen.violation == 0);
    try check(seen.syscalls > 0);
    if (seen.syscall_ticks < 3) report("timer interrupts inside syscalls:", seen.syscall_ticks);
    try check(seen.syscall_ticks >= 3 and seen.user_ticks >= 3);
}

/// The exit path of a syscall validates the state it returns to: `iretq`
/// when `sysretq` cannot restore it, no privileged flags, and a process
/// whose state cannot be returned to at all is killed, with nothing leaked.
fn syscallReturnStates() TestError!void {
    // Without the probe the test numbers are unknown syscalls.
    try check(helpers.runProgram("/test/bad_return") == 90);
    const iret_before = helpers.iretReturns();
    var via_iret: usize = 0;
    const memory = helpers.footprint();
    defer helpers.removeProbes();
    inline for (.{ .noncanonical_rip, .kernel_rip, .kernel_cs, .kernel_ss }) |state| {
        helpers.installProbes(state);
        const code = helpers.runProgram("/test/bad_return") orelse return error.Failed;
        if (code != 255) report("/test/bad_return (" ++ @tagName(state) ++ ") exit status", code);
        try check(code == 255);
        try check(helpers.probes.violation == 0);
        via_iret += helpers.probes.via_iret;
    }
    helpers.removeProbes();
    // Exactly the returns with RF set went through iretq; all others (the
    // one with privileged flags included) used sysretq.
    try check(via_iret == 16 and helpers.iretReturns() - iret_before == via_iret);
    try expectProgram("/bin/hello"); // the kernel is fine
    try expectFootprint(memory);
}

/// The kernel's GS base never reaches ring 3, and is back after every entry.
fn gsBaseSwitching() TestError!void {
    var failed = helpers.gsBases();
    if (failed != 0) report("GS base check", failed);
    try check(failed == 0);
    try check(helpers.runProgram("/test/gs_base") == 255); // faults on a user address
    failed = helpers.gsBases();
    if (failed != 0) report("GS base check after a process", failed);
    try check(failed == 0);
}

/// A debug exception that hits ring 0 code running with the user's GS base
/// (as at the first instruction of `syscall_entry`) is handled on its own
/// stack with the kernel's GS base.
/// New processes: `fork`, `vfork`, `clone` without `CLONE_THREAD`, and
/// `wait4` collecting them, from ring 3; nothing left behind.
fn forkWait() TestError!void {
    _ = helpers.runProgram("/test/fork"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const processes = helpers.processCount();
    const code = helpers.runProgram("/test/fork") orelse return error.Failed;
    if (code != 0) report("/test/fork failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/fork"));
    try check(helpers.processCount() == processes);
    try expectFootprint(memory);
}

/// 2 MiB pages for anonymous memory from ring 3: given, split for part of
/// one unmapped, protected, given back or moved, copied by fork; their
/// memory back afterwards.
fn hugePages() TestError!void {
    _ = helpers.runProgram("/test/hugepages"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/hugepages") orelse return error.Failed;
    if (code != 0) report("/test/hugepages failed check", code);
    try check(code == 0);
    try expectFootprint(memory);
}

/// Memory files and shared mappings from ring 3 (two mappings of one
/// file, code run from one written through the other, `fork`, seals),
/// two copies at once; nothing left behind.
fn memoryFiles() TestError!void {
    _ = helpers.runProgram("/test/memfd"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/memfd") orelse return error.Failed;
    if (code != 0) report("/test/memfd failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/memfd"));
    try expectFootprint(memory);
}

/// inotify from ring 3 (a directory's and a file's watches, renames,
/// removal, a read that waits), two copies at once; no instance left.
fn fileWatches() TestError!void {
    _ = helpers.runProgram("/test/inotify"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/inotify") orelse return error.Failed;
    if (code != 0) report("/test/inotify failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/inotify"));
    try check(root.kernel.inotify.count() == 0);
    try expectFootprint(memory);
}

/// FIFOs from ring 3 (made in `/tmp`, opened end by end with and without
/// waiting, a wait ended by a signal), two copies at once; no FIFO's
/// pipe and nothing else left behind.
fn namedPipes() TestError!void {
    _ = helpers.runProgram("/test/fifo"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/fifo") orelse return error.Failed;
    if (code != 0) report("/test/fifo failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/fifo"));
    try check(root.kernel.fifo.count() == 0);
    try expectFootprint(memory);
}

/// Restartable sequences from ring 3 (the CPU kept in the area, a
/// critical section aborted by a signal, a forked child's registration),
/// two copies at once; nothing left behind.
fn restartableSequences() TestError!void {
    _ = helpers.runProgram("/test/rseq"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/rseq") orelse return error.Failed;
    if (code != 0) report("/test/rseq failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/rseq"));
    try expectFootprint(memory);
}

/// Advisory file locks from ring 3, two copies at once; none left behind.
fn fileLocks() TestError!void {
    _ = helpers.runProgram("/test/flock"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/flock") orelse return error.Failed;
    if (code != 0) report("/test/flock failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/flock"));
    try check(root.kernel.flock.count() == 0);
    try check(root.kernel.reclock.count() == 0);
    try expectFootprint(memory);
}

/// Real-time signals queued with their values, `rt_sigtimedwait`,
/// `signalfd`, from ring 3; nothing left behind.
fn queuedSignals() TestError!void {
    _ = helpers.runProgram("/test/sigqueue"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/sigqueue") orelse return error.Failed;
    if (code != 0) report("/test/sigqueue failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/sigqueue"));
    try expectFootprint(memory);
}

/// Every system call from ring 3 with arguments whose result Linux
/// documents: mostly the error numbers.
fn documentedErrors() TestError!void {
    const code = helpers.runProgram("/test/errors") orelse return error.Failed;
    if (code != 0) report("/test/errors failed row", code);
    try check(code == 0);
}

/// Job control from ring 3: stopping and continuing children, what
/// `wait4` and `SIGCHLD` say of it, the terminal's background rules.
/// Not run in pairs: the terminal's foreground group is one for all.
fn jobControl() TestError!void {
    _ = helpers.runProgram("/test/jobs"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const processes = helpers.processCount();
    const code = helpers.runProgram("/test/jobs") orelse return error.Failed;
    if (code != 0) report("/test/jobs failed check", code);
    try check(code == 0);
    try check(helpers.processCount() == processes);
    try expectFootprint(memory);
}

/// The clocks: in the kernel, the monotonic clock against the HPET and in
/// step on every CPU; from ring 3, sleeps and the wall clock.
fn clocks() TestError!void {
    const failed = helpers.clockChecks();
    if (failed != 0) report("clock check", failed);
    try check(failed == 0);
    const code = helpers.runProgram("/test/clock") orelse return error.Failed;
    if (code != 0) report("/test/clock failed check", code);
    try check(code == 0);
}

/// `execve`: arguments, environment, descriptors and signal actions across
/// it; failures that keep the program; `vfork` with it; scripts; a
/// process with several threads. Nothing left behind.
fn execProgram() TestError!void {
    _ = helpers.runProgram("/test/exec"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const processes = helpers.processCount();
    const code = helpers.runProgram("/test/exec") orelse return error.Failed;
    if (code != 0) report("/test/exec failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/exec"));
    try check(helpers.processCount() == processes);
    try expectFootprint(memory);
}

/// Programs that set their own FS and GS base (`wrfsbase`, `wrgsbase`):
/// kept across switches and reported by `arch_prctl`; and a kernel-looking
/// GS base at a debug exception in the syscall entry does not fool the
/// kernel. Where the CPU has no FSGSBASE, there is nothing to run.
fn fsgsbase() TestError!void {
    const code = helpers.runProgram("/test/fsgsbase") orelse return error.Failed;
    if (code == 1) return; // not offered here
    if (code != 0) report("/test/fsgsbase failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/fsgsbase"));
    // The trap kills it (or there is none); the kernel carries on.
    const trapped = helpers.runProgramArgs("/test/fsgsbase", &.{ "fsgsbase", "kernel_gs" }, &.{}) orelse return error.Failed;
    if (trapped != 0 and trapped != 255 and trapped != 128 + 5) report("/test/fsgsbase kernel_gs exit status", trapped);
    try check(trapped == 0 or trapped == 255 or trapped == 128 + 5);
}

fn debugTrapEntry() TestError!void {
    const failed = helpers.debugTrapEntry();
    if (failed != 0) report("debug trap check", failed);
    try check(failed == 0);
}

/// True in the `tests_fxsave` scenario, where QEMU hides XSAVE from the kernel.
var expect_fxsave = false;
/// CPUs the scenario's machine has.
var expect_cpus: usize = 1;

/// Every CPU of the machine is up, with state of its own, set up alike.
fn cpus() TestError!void {
    const irq = helpers.enableInterrupts();
    defer helpers.restoreInterrupts(irq);
    try expectChecks("CPU", helpers.cpuChecks(expect_cpus));
}

/// What a Linux program relies on at startup and in its first calls: the
/// initial stack, the FS and GS base (kept apart for two programs running
/// at once), `writev`, `ioctl`, `set_tid_address`, `exit_group`.
fn linuxStartup() TestError!void {
    const code = helpers.runProgramArgs("/test/linux_abi", &.{ "abi", "x y", "" }, &.{"A=1"}) orelse return error.Failed;
    if (code != 0) report("/test/linux_abi failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/linux_abi"));
    // Arguments that do not fit are refused, and nothing is started.
    const memory = helpers.footprint();
    try check(helpers.argumentsTooLong());
    try expectFootprint(memory);
}

/// Memory on demand: `mmap`, `munmap`, `mprotect`, `madvise`, `brk`, a
/// multi-gigabyte reservation committed piece by piece, a stack that
/// grows; faults that kill only the program; and nothing left behind.
fn userMemory() TestError!void {
    _ = helpers.runProgram("/test/vm"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/vm") orelse return error.Failed;
    if (code != 0) report("/test/vm failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/vm")); // two address spaces at once
    try check(helpers.runProgramArgs("/test/vm", &.{ "vm", "deep" }, &.{}) == 0);
    // What a program is killed for.
    inline for (.{ "none", "readonly", "unmapped", "stack", "pasteof", "filereadonly" }) |mode| {
        const status = helpers.runProgramArgs("/test/vm", &.{ "vm", mode }, &.{}) orelse return error.Failed;
        if (status != 255) report("/test/vm " ++ mode ++ " exit status", status);
        try check(status == 255);
    }
    // A process that uses up its memory limit is the only casualty: it
    // asks for 1 GiB and may have 16 MiB.
    const oom = helpers.runProgramLimitedArgs("/test/vm", &.{ "vm", "oom" }, .{ .max_pages = 4096 }) orelse return error.Failed;
    if (oom != 255) report("/test/vm oom exit status", oom);
    try check(oom == 255);
    try check(helpers.runProgram("/bin/hello") == 0); // the kernel is fine
    try expectFootprint(memory);
    try check(pmm.consistent());
}

/// A C program built for Linux and linked against musl, with nothing of
/// MyOS in it, runs: it finds its arguments and environment, prints them
/// through its own `printf`, and exits with its number of arguments. The
/// host script checks what it printed.
fn muslHello() TestError!void {
    if (!helpers.haveFixtures(&.{"musl-hello-static"})) return;
    const memory = helpers.footprint();
    const code = helpers.runProgramArgs(
        "/fixtures/musl-hello-static",
        &.{ "musl-hello", "one", "two words" },
        &.{ "GREETING=hi", "EMPTY=" },
    ) orelse return error.Failed;
    if (code != 3) report("musl hello exit status", code);
    try check(code == 3);
    // With no arguments given it gets its path as the only one.
    try check(helpers.runProgram("/fixtures/musl-hello-static") == 1);
    try expectFootprint(memory);
}

/// Position-independent programs built for Linux run (a C program and a
/// Rust program, each a static PIE that relocates itself), at an address
/// that is different every time unless the layout is fixed.
fn positionIndependent() TestError!void {
    if (!helpers.haveFixtures(&.{"musl-hello-static-pie"})) return;
    const memory = helpers.footprint();
    const c = helpers.runProgramArgs("/fixtures/musl-hello-static-pie", &.{ "musl-hello-pie", "one", "two words" }, &.{"GREETING=hi pie"}) orelse return error.Failed;
    if (c != 3) report("musl static-pie exit status", c);
    try check(c == 3);
    if (helpers.haveFixtures(&.{"rust-hello-static-pie"})) {
        const r = helpers.runProgramArgs("/fixtures/rust-hello-static-pie", &.{ "rust-hello-pie", "from", "MyOS" }, &.{"GREETING=hi rust pie"}) orelse return error.Failed;
        if (r != 3) report("rust static-pie exit status", r);
        try check(r == 3);
    }

    // Where it is put: the same place with the layout fixed, another one
    // each time otherwise, always on a page boundary within the range.
    const path = "/fixtures/musl-hello-static-pie";
    const fixed = helpers.entryOf(path, false) orelse return error.Failed;
    try check(helpers.entryOf(path, false) == fixed);
    try check(fixed >= helpers.PIE_BASE and fixed - helpers.PIE_BASE < 0x10_0000);
    var seen: [4]u64 = undefined;
    for (&seen, 0..) |*s, i| {
        s.* = helpers.entryOf(path, true) orelse return error.Failed;
        try check(s.* >= fixed and (s.* - fixed) % 4096 == 0);
        try check((s.* - fixed) / 4096 < helpers.PIE_RANDOM_PAGES);
        for (seen[0..i]) |other| try check(other != s.*);
    }
    try expectFootprint(memory);
}

/// A program that names an interpreter is not run itself: the
/// interpreter is loaded beside it and started. Here the "interpreter"
/// is a C program that prints its arguments and exits with their number,
/// first as a position-independent one, then as one for fixed addresses;
/// the program that names it is never run, but its headers are mapped, as
/// a real program's are: a C library reads them (`AT_PHDR`).
fn elfInterpreter() TestError!void {
    if (!helpers.haveFixtures(&.{ "musl-hello-static", "musl-hello-static-pie" })) return;
    _ = helpers.runImage(buildElf(.{ .offset = 0, .filesz = 0x1000, .phnum = 2, .interp = "/fixtures/musl-hello-static-pie" })); // warm up
    const memory = helpers.footprint();
    try check(helpers.runImage(buildElf(.{ .offset = 0, .filesz = 0x1000, .phnum = 2, .interp = "/fixtures/musl-hello-static-pie" })) == 1);
    try check(helpers.runImage(buildElf(.{ .offset = 0, .filesz = 0x1000, .phnum = 2, .interp = "/fixtures/musl-hello-static" })) == 1);
    // And a position-independent program with an interpreter.
    try check(helpers.runImage(buildElf(.{ .typ = 3, .vaddr = 0, .entry = 0, .offset = 0, .filesz = 0x1000, .phnum = 2, .interp = "/fixtures/musl-hello-static-pie" })) == 1);
    try expectFootprint(memory);
}

/// A dynamically linked C program runs: the kernel loads the dynamic
/// loader the program names, and the loader maps the C library from its
/// file and starts the program. The loader and the library are glibc's
/// (`scripts/fetch-sysroot.sh`); an image built without them has nothing
/// to load the program with, and the test says so.
fn dynamicHello() TestError!void {
    if (!helpers.haveFixtures(&.{"glibc-hello-dynamic"})) return;
    const path = "/fixtures/glibc-hello-dynamic";
    if (!helpers.fileExists("/lib64/ld-linux-x86-64.so.2")) {
        root.print("  skipped: the image has no C library (scripts/fetch-sysroot.sh)\n", .{});
        return;
    }
    _ = helpers.runProgram(path); // warm up: the heap may grow
    const memory = helpers.footprint();
    helpers.traceUnknownSyscalls(true);
    defer helpers.traceUnknownSyscalls(false);
    const code = helpers.runProgramArgs(path, &.{ "hello-dynamic", "linked", "at run time" }, &.{"GREETING=hi dynamic"}) orelse return error.Failed;
    if (code != 3) report("dynamically linked hello exit status", code);
    try check(code == 3);
    try check(helpers.runPairExpect(path, 1)); // two at once
    try expectFootprint(memory);
}

/// A .NET program published the ordinary way for Linux, ahead of time
/// (`dotnet publish -r linux-x64 -p:PublishAot=true`): dynamically
/// linked against glibc, position independent. Nothing of MyOS went into
/// building it.
fn dotnetAot() TestError!void {
    if (!helpers.haveFixtures(&.{"dotnet-hello-aot"})) return;
    const path = "/fixtures/dotnet-hello-aot";
    if (!helpers.fileExists("/lib64/ld-linux-x86-64.so.2")) {
        root.print("  skipped: the image has no C library (scripts/fetch-sysroot.sh)\n", .{});
        return;
    }
    _ = helpers.runProgramArgs(path, &.{"dotnet-hello-aot"}, &.{}); // warm up: the heap may grow
    const memory = helpers.footprint();
    helpers.traceUnknownSyscalls(true);
    defer helpers.traceUnknownSyscalls(false);
    const code = helpers.runProgramArgs(path, &.{ "dotnet-hello-aot", "stock", "build" }, &.{"GREETING=hi dotnet aot"}) orelse return error.Failed;
    if (code != 2) report("dotnet aot exit status", code);
    try check(code == 2);
    try check(helpers.runPairExpect(path, 0)); // two runtimes at once
    try expectFootprint(memory);
}

/// A .NET program as `dotnet publish -r linux-x64 --self-contained`
/// leaves it: a folder with a small host program, the runtime with its
/// JIT compiler as shared libraries, and the program as an assembly.
///
/// The host finds its own file through `/proc/self/exe` and the folder it
/// is in, loads `libhostfxr.so`, `libhostpolicy.so` and `libcoreclr.so`
/// from it; the runtime maps the assemblies, compiles the program's code
/// with `libclrjit.so` into memory it then runs, and collects garbage
/// with eight managed threads running.
fn dotnetSelfContained() TestError!void {
    if (!helpers.haveFixtures(&.{"dotnet-hello-app/hello"})) return;
    const path = "/fixtures/dotnet-hello-app/hello";
    if (!helpers.fileExists("/lib64/ld-linux-x86-64.so.2")) {
        root.print("  skipped: the image has no C library (scripts/fetch-sysroot.sh)\n", .{});
        return;
    }
    _ = helpers.runProgramArgs(path, &.{path}, &.{}); // warm up: the heap may grow
    const memory = helpers.footprint();
    helpers.traceUnknownSyscalls(true);
    defer helpers.traceUnknownSyscalls(false);
    const code = helpers.runProgramArgs(path, &.{ path, "self", "contained" }, &.{"GREETING=hi dotnet jit"}) orelse return error.Failed;
    if (code != 2) report("dotnet self-contained exit status", code);
    try check(code == 2);
    try check(helpers.runPairExpect(path, 0)); // two runtimes at once
    try expectFootprint(memory); // code heaps, mapped assemblies, threads: all gone
}

/// The C, Rust and Go programs built the way a developer builds them, with
/// no flags: `gcc hello.c`, `cargo build --release`, `go build`. The first
/// two are linked against glibc. A toolchain built for newer CPUs (some
/// distributions') marks the C one as needing an x86-64-v4 CPU (AVX-512);
/// where the CPU has none, glibc's loader then refuses it, as on Linux.
fn plainBuilds() TestError!void {
    if (!helpers.haveFixtures(&.{ "c-hello-gcc", "go-hello-plain", "rust-hello-cargo" })) return;
    if (!helpers.fileExists("/lib64/ld-linux-x86-64.so.2")) {
        root.print("  skipped: the image has no C library (scripts/fetch-sysroot.sh)\n", .{});
        return;
    }
    _ = helpers.runProgram("/fixtures/rust-hello-cargo"); // warm up: the heap may grow
    const memory = helpers.footprint();
    helpers.traceUnknownSyscalls(true);
    defer helpers.traceUnknownSyscalls(false);
    const args = [_][]const u8{ "hello", "built", "plainly" };
    for ([_][]const u8{ "/fixtures/rust-hello-cargo", "/fixtures/go-hello-plain" }) |path| {
        const code = helpers.runProgramArgs(path, &args, &.{}) orelse return error.Failed;
        if (code != 3) report("plain build exit status", code);
        try check(code == 3);
    }
    const c = helpers.runProgramArgs("/fixtures/c-hello-gcc", &args, &.{}) orelse return error.Failed;
    // Whether it asks for x86-64-v4 depends on the machine it was built
    // on: where the CPU has that, it must run; where not, it runs or is
    // refused by glibc's loader (status 127), as on Linux.
    if (c == 127 and !helpers.cpuHasX86_64V4()) {
        root.print("  the gcc build asks for x86-64-v4 and this CPU is not: refused, as on Linux\n", .{});
    } else {
        if (c != 3) report("gcc build exit status", c);
        try check(c == 3);
    }
    try expectFootprint(memory);
}

/// Threads and futexes through the raw calls: a lock made of a futex,
/// each thread's own FS base, join through the exit announcement, wake
/// counts, timeouts, requeue; and the ways a threaded process ends.
fn threadsAndFutexes() TestError!void {
    _ = helpers.runProgram("/test/threads"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/threads") orelse return error.Failed;
    if (code != 0) report("/test/threads failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/threads"));
    // A thread ends the process while another sleeps for good; a thread's
    // fault kills them all; the last thread's status is the process's.
    inline for (.{ .{ "exitgroup", 7 }, .{ "fault", 255 }, .{ "mainexits", 5 } }) |mode| {
        const status = helpers.runProgramArgs("/test/threads", &.{ "threads", mode[0] }, &.{}) orelse return error.Failed;
        if (status != mode[1]) report("/test/threads " ++ mode[0] ++ " exit status", status);
        try check(status == mode[1]);
    }
    try expectFootprint(memory); // every thread, stack and futex waiter is gone
}

/// Descriptors that are more than files: the standard streams, `dup`,
/// pipes with their waiting and their ends; and a process that ends with
/// a thread asleep in a pipe takes the thread and the pipe with it.
fn descriptorsAndPipes() TestError!void {
    // (With 16 descriptors: it fills the table to see what happens then.)
    _ = helpers.runProgramLimited("/test/pipes", .{ .max_files = 16 }); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgramLimited("/test/pipes", .{ .max_files = 16 }) orelse return error.Failed;
    if (code != 0) report("/test/pipes failed check", code);
    try check(code == 0);
    try check(helpers.runPairLimited("/test/pipes", .{ .max_files = 16 }));
    const status = helpers.runProgramArgs("/test/pipes", &.{ "pipes", "blocked" }, &.{}) orelse return error.Failed;
    if (status != 9) report("/test/pipes blocked exit status", status);
    try check(status == 9);
    // Writing to a pipe nobody reads: SIGPIPE, which ends it by default.
    try check(helpers.runProgramArgs("/test/pipes", &.{ "pipes", "sigpipe" }, &.{}) == 128 + 13);
    try expectFootprint(memory); // open files and pipes are all gone
}

/// What a program finds besides plain files: directories, `/proc` about
/// itself, `/dev/null` and the random device, a descriptor table that
/// grows, a filesystem that says it is read-only; and the scheduling
/// calls a runtime makes.
fn filesAndProc() TestError!void {
    _ = helpers.runProgram("/test/files"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/files") orelse return error.Failed;
    if (code != 0) report("/test/files failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/files"));
    try expectFootprint(memory); // generated files and grown tables are freed
}

/// `eventfd` and `epoll`: a counter, a set of descriptors waited on
/// together with a timeout, woken by another thread.
fn eventLoop() TestError!void {
    _ = helpers.runProgram("/test/epoll"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/epoll") orelse return error.Failed;
    if (code != 0) report("/test/epoll failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/epoll"));
    try expectFootprint(memory);
}

/// A page fault from a stale translation of a kernel page that has just
/// been made writable is let through, not reported as a crash.
fn spuriousKernelFault() TestError!void {
    var faults: usize = 0;
    const failed = helpers.spuriousKernelFault(&faults);
    if (failed != 0) report("spurious fault check", failed);
    try check(failed == 0);
}

/// A woken thread runs soon even when every CPU is busy: within a few
/// ticks, not after a time slice (`thread.preemptForWoken`).
fn wakeLatency() TestError!void {
    const worst = helpers.wakeLatency() orelse return error.Failed;
    if (worst > 1) report("ticks from a wake-up to running", worst);
    try check(worst <= 1); // the tick it fired in, or the next (a slice is 5)
}

/// Signals: handlers with their arguments, a context they may change and
/// that comes back, masks, faults that become signals, the alternate
/// stack, EINTR and SA_RESTART, rt_sigsuspend; and the ways a signal ends
/// a program.
fn signals() TestError!void {
    _ = helpers.runProgram("/test/signals"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/signals") orelse return error.Failed;
    if (code != 0) report("/test/signals failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/signals"));
    inline for (.{ .{ "term", 128 + 15 }, .{ "kill", 128 + 9 }, .{ "resethand", 128 + 10 }, .{ "norestorer", 255 }, .{ "fault", 255 } }) |mode| {
        const status = helpers.runProgramArgs("/test/signals", &.{ "signals", mode[0] }, &.{}) orelse return error.Failed;
        if (status != mode[1]) report("/test/signals " ++ mode[0] ++ " exit status", status);
        try check(status == mode[1]);
    }
    try expectFootprint(memory);
}

/// The terminal: lines edited and handed over whole, Ctrl+D, keys without
/// line editing, its settings and size; Ctrl+C ends the foreground
/// program.
fn terminal() TestError!void {
    const memory = helpers.footprint();
    try expectChecks("terminal", helpers.terminalSession());
    try expectFootprint(memory);
}

/// A filesystem that can be written, at `/tmp`: files, directories,
/// renames, a program copied there and run, from two processes at once;
/// and nothing of it left when they are done.
fn writableFiles() TestError!void {
    _ = helpers.runProgram("/test/tmp"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/tmp") orelse return error.Failed;
    if (code != 0) report("/test/tmp failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/tmp"));
    try check(helpers.tmpBlocksUsed() == 0);
    try expectFootprint(memory);
}

/// The heap of MyOS's own programs: the standard library's containers on
/// the user library's allocator, which sits on `mmap`.
fn programHeap() TestError!void {
    _ = helpers.runProgram("/test/alloc"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/test/alloc") orelse return error.Failed;
    if (code != 0) report("/test/alloc failed check", code);
    try check(code == 0);
    try check(helpers.runPair("/test/alloc"));
    try expectFootprint(memory);
}

/// A multi-threaded C program built for Linux against musl runs: eight
/// pthreads with a mutex, a condition variable, a barrier, thread-local
/// storage, a timed wait and joins. It checks its own numbers and says
/// so; the host script checks what it printed.
fn muslThreads() TestError!void {
    if (!helpers.haveFixtures(&.{"musl-threads-static"})) return;
    _ = helpers.runProgram("/fixtures/musl-threads-static"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgram("/fixtures/musl-threads-static") orelse return error.Failed;
    if (code != 0) report("musl threads exit status", code);
    try check(code == 0);
    try check(helpers.runPair("/fixtures/musl-threads-static")); // two processes of eight threads
    try expectFootprint(memory);
}

/// A Rust program built for Linux against musl runs with its standard
/// library: arguments, the environment, heap allocation, formatted
/// output. The host script checks what it printed.
fn rustHello() TestError!void {
    if (!helpers.haveFixtures(&.{"rust-hello-static"})) return;
    _ = helpers.runProgram("/fixtures/rust-hello-static"); // warm up: the heap may grow
    const memory = helpers.footprint();
    const code = helpers.runProgramArgs(
        "/fixtures/rust-hello-static",
        &.{ "rust-hello", "from", "MyOS" },
        &.{"GREETING=hi rust"},
    ) orelse return error.Failed;
    if (code != 3) report("rust hello exit status", code);
    try check(code == 3);
    try check(helpers.runPairExpect("/fixtures/rust-hello-static", 1)); // two at once
    try expectFootprint(memory);
}

/// A Go program built for Linux runs: its runtime's threads, its heap
/// reservation and its signal setup, then goroutines, a channel and a
/// garbage collection. The host script checks what it printed.
fn goHello() TestError!void {
    if (!helpers.haveFixtures(&.{"go-hello-static"})) return;
    _ = helpers.runProgram("/fixtures/go-hello-static"); // warm up: the heap may grow
    const memory = helpers.footprint();
    helpers.traceUnknownSyscalls(true); // anything it asks for that is missing shows in the log
    defer helpers.traceUnknownSyscalls(false);
    const code = helpers.runProgramArgs("/fixtures/go-hello-static", &.{ "go-hello", "from", "MyOS" }, &.{"GREETING=hi go"}) orelse return error.Failed;
    if (code != 3) report("go hello exit status", code);
    try check(code == 3);
    try check(helpers.runPairExpect("/fixtures/go-hello-static", 1)); // two runtimes at once
    try expectFootprint(memory); // its threads, its reservations, all gone
}

/// A .NET program compiled ahead of time for Linux (Native AOT, linked
/// statically against musl) runs: the runtime starts, managed threads
/// allocate, the garbage collector stops them and collects. The host
/// script checks what it printed.
fn dotnetHello() TestError!void {
    if (!helpers.haveFixtures(&.{"dotnet-hello-static"})) return;
    _ = helpers.runProgramArgs("/fixtures/dotnet-hello-static", &.{"dotnet-hello"}, &.{}); // warm up: the heap may grow
    const memory = helpers.footprint();
    helpers.traceUnknownSyscalls(true);
    defer helpers.traceUnknownSyscalls(false);
    const code = helpers.runProgramArgs("/fixtures/dotnet-hello-static", &.{ "dotnet-hello", "from", "MyOS" }, &.{"GREETING=hi dotnet"}) orelse return error.Failed;
    if (code != 2) report("dotnet hello exit status", code);
    try check(code == 2); // .NET's `args` leaves the program's name out
    try check(helpers.runPairExpect("/fixtures/dotnet-hello-static", 0)); // two runtimes at once
    try expectFootprint(memory); // its threads, its heap, its pipe: all gone
}

/// Programs run, are preempted, crash and are torn down on every CPU at once.
fn parallelPrograms() TestError!void {
    const irq = helpers.enableInterrupts();
    defer helpers.restoreInterrupts(irq);
    var first: usize = 0;
    const failed = helpers.parallelPrograms(&first);
    if (first != 0) report("parallel programs: wrong exit status from program number", first);
    try expectChecks("parallel programs", failed);
}

/// Allocators, locks, wait queues and timers used from every CPU at once.
fn kernelStress() TestError!void {
    const irq = helpers.enableInterrupts();
    defer helpers.restoreInterrupts(irq);
    try expectChecks("kernel stress", helpers.kernelStress());
}

/// A kernel mapping that is removed is gone from every CPU's TLB.
fn tlbShootdown() TestError!void {
    const irq = helpers.enableInterrupts();
    defer helpers.restoreInterrupts(irq);
    try expectChecks("TLB shootdown", helpers.tlbShootdown());
}

/// The CPU cannot run on past the conditional `swapgs` on a wrong guess.
fn swapgsFences() TestError!void {
    try expectChecks("swapgs fence", helpers.swapgsFences());
}

/// SSE is on, with XSAVE (or FXSAVE where the scenario says so) sized from CPUID.
fn extendedStateSetup() TestError!void {
    const failed = helpers.extendedStateSetup(!expect_fxsave);
    if (failed != 0) report("extended state check", failed);
    try check(failed == 0);
}

/// x87, SSE and AVX registers survive switches between two processes that
/// both use all of them, by `sched_yield` and by timer preemption; the save
/// areas are freed with their threads.
fn extendedStateSwitching() TestError!void {
    _ = helpers.runPair("/test/fpu"); // warm up: the heap may grow
    const memory = helpers.footprint();
    helpers.installProbes(.noncanonical_rip);
    defer helpers.removeProbes();
    // 10 timer interrupts in ring 3 are two full time slices: at least one
    // of them ended with the timer switching to the other process.
    var runs: usize = 0;
    while (runs < 10) : (runs += 1) {
        try check(helpers.runPair("/test/fpu"));
        if (helpers.probes.user_ticks >= 10) break;
    }
    if (helpers.probes.user_ticks < 10) report("timer interrupts in ring 3:", helpers.probes.user_ticks);
    try check(helpers.probes.user_ticks >= 10 and helpers.probes.violation == 0);
    helpers.removeProbes();
    try expectFootprint(memory);
}

/// A new process gets clean x87, SSE and AVX registers, not the previous
/// program's (`/test/fpu` has just filled them all).
fn extendedStateClean() TestError!void {
    try check(helpers.runPair("/test/fpu"));
    try expectProgram("/test/fpu_clean");
}

/// 20 000 random syscalls from ring 3: the process is not killed, the
/// kernel keeps working and no memory is lost.
fn syscallFuzz() TestError!void {
    try expectProgram("/test/fuzz"); // also the warm-up: the heap may grow
    const memory = helpers.footprint();
    try expectProgram("/test/fuzz");
    try expectFootprint(memory);
    try expectProgram("/bin/hello");
}

/// A new process starts with all general-purpose registers zeroed.
fn userEntryRegisters() TestError!void {
    try check(helpers.runProgram("/test/entry_regs") == 0);
}

/// Two preemptible threads allocating and freeing pages never share a page.
fn pmmConcurrentStress() TestError!void {
    try check(helpers.pmmConcurrentStress());
}

/// Ring 3 cannot read kernel memory, run privileged instructions, write its
/// own code, or read the kernel's descriptor-table addresses: each attempt kills only that process (exit code 255).
fn userIsolation() TestError!void {
    try check(helpers.runProgram("/test/kernel_read") == 255);
    try check(helpers.runProgram("/test/privileged") == 255);
    try check(helpers.runProgram("/test/write_text") == 255);
    try check(helpers.runProgram("/test/umip") == 255); // sgdt
}

/// Ordinary CPU exceptions in ring 3 (divide error, invalid opcode) kill only
/// the faulting process: the next program runs normally and nothing leaks.
/// The host script checks the diagnostics these print.
fn userFaults() TestError!void {
    _ = helpers.runProgram("/test/div_zero"); // warm up: the heap may grow
    const memory = helpers.footprint();
    try check(helpers.runProgram("/test/div_zero") == 255);
    try check(helpers.runProgram("/test/invalid_opcode") == 255);
    // Single-stepping into a syscall: the trap arrives in ring 3, after the
    // syscall has returned through iretq, never in the kernel.
    const iret_before = helpers.iretReturns();
    try check(helpers.runProgram("/test/single_step") == 255);
    try check(helpers.iretReturns() == iret_before + 1);
    try check(helpers.runProgram("/bin/hello") == 0);
    try expectFootprint(memory);
}

/// Double faults, NMIs and debug exceptions have their own stacks, and the CPU switches to them.
fn emergencyStacks() TestError!void {
    const failed = helpers.emergencyStacks();
    if (failed != 0) {
        var buf: [64]u8 = undefined;
        serial.puts(std.fmt.bufPrint(&buf, "  emergency stack check {d} failed\n", .{failed}) catch "");
    }
    try check(failed == 0);
}

/// Kernel stacks come from the guarded allocator and are fully released.
fn kernelStacks() TestError!void {
    const failed = helpers.kernelStacks();
    if (failed != 0) {
        var buf: [64]u8 = undefined;
        serial.puts(std.fmt.bufPrint(&buf, "  kernel stack check {d} failed\n", .{failed}) catch "");
    }
    try check(failed == 0);
}

/// The stack high-water mark measures what threads really use.
fn stackUsage() TestError!void {
    const failed = helpers.stackUsage();
    if (failed != 0) {
        var buf: [64]u8 = undefined;
        serial.puts(std.fmt.bufPrint(&buf, "  stack usage check {d} failed\n", .{failed}) catch "");
    }
    try check(failed == 0);
}

/// Spawn, run, wait and exit: exit codes reach the parent, and a finished or
/// crashed process leaves no pages or heap memory behind.
fn processLifecycle() TestError!void {
    try check(helpers.runProgram("/bin/hello") == 0);
    try check(helpers.runProgram("/does/not/exist") == null);

    // The first runs above may have grown the heap; measure from here.
    const memory = helpers.footprint();
    try check(helpers.runProgram("/bin/hello") == 0);
    try check(helpers.runProgram("/test/kernel_read") == 255);
    try expectFootprint(memory);
}

/// Kernel threads take turns in FIFO order and are reaped after exiting.
fn schedulerRoundRobin() TestError!void {
    try check(helpers.schedulerRoundRobin());
}

/// A wake that arrives before block is not lost.
fn wakeBeforeBlock() TestError!void {
    try check(helpers.wakeBeforeBlock());
}

// ---------------------------------------------------------------------------
// tarfs with malformed archives

/// Scratch buffer for tar archives built by the tests.
var tar_buf: [8 * 512]u8 = undefined;

/// One archive member for `buildTar`.
const TarMember = struct {
    name: []const u8,
    data: []const u8 = "",
    typ: u8 = '0',
    /// Overrides the size field (written verbatim) instead of `data.len`.
    size_field: ?[]const u8 = null,
};

/// Build a ustar archive in `tar_buf` from `members`, followed by the
/// two-block end marker unless `end_marker` is false.
fn buildTar(members: []const TarMember, end_marker: bool) []const u8 {
    @memset(&tar_buf, 0);
    var off: usize = 0;
    for (members) |m| {
        const h = tar_buf[off..][0..512];
        @memcpy(h[0..m.name.len], m.name);
        @memcpy(h[100..107], "0000644");
        if (m.size_field) |sf| {
            @memcpy(h[124..][0..sf.len], sf);
        } else {
            _ = std.fmt.bufPrint(h[124..135], "{o:0>11}", .{m.data.len}) catch unreachable;
        }
        h[156] = m.typ;
        @memcpy(h[257..263], "ustar\x00");
        off += 512;
        @memcpy(tar_buf[off..][0..m.data.len], m.data);
        off += std.mem.alignForward(usize, m.data.len, 512);
    }
    if (end_marker) off += 1024;
    return tar_buf[0..off];
}

/// Read `path` from `image` into a buffer and compare it with `want` (null = not found).
fn expectTarFile(image: []const u8, path: []const u8, want: ?[]const u8) TestError!void {
    var buf: [64]u8 = undefined;
    const n = helpers.tarfsRead(image, path, 0, &buf);
    if (want) |w| {
        try check(n != null and std.mem.eql(u8, buf[0..n.?], w));
    } else try check(n == null);
}

/// Normal archives: several files, path normalization, directories ignored.
fn tarfsLookup() TestError!void {
    const img = buildTar(&.{
        .{ .name = "./etc/", .typ = '5' },
        .{ .name = "./etc/a", .data = "alpha" },
        .{ .name = "b", .data = "bravo!" },
        .{ .name = "empty" },
    }, true);
    try expectTarFile(img, "/etc/a", "alpha");
    try expectTarFile(img, "etc/a", "alpha");
    try expectTarFile(img, "/b", "bravo!");
    try expectTarFile(img, "/empty", "");
    try expectTarFile(img, "/etc", null); // directories are not files
    try expectTarFile(img, "/", null);
    try expectTarFile(img, "", null);
    try expectTarFile(img, "/etc/a/x", null);
}

/// Offsets at, past and inside the file; short buffers get partial reads.
fn tarfsBoundaries() TestError!void {
    const img = buildTar(&.{.{ .name = "f", .data = "0123456789" }}, true);
    var buf: [4]u8 = undefined;
    try check(helpers.tarfsRead(img, "/f", 0, &buf) == 4 and std.mem.eql(u8, &buf, "0123"));
    try check(helpers.tarfsRead(img, "/f", 8, &buf) == 2 and std.mem.eql(u8, buf[0..2], "89"));
    try check(helpers.tarfsRead(img, "/f", 10, &buf) == 0);
    try check(helpers.tarfsRead(img, "/f", 1 << 40, &buf) == 0);
    try check(helpers.tarfsRead(img, "/f", 0, buf[0..0]) == 0);
}

/// Malformed archives: missing end marker, truncated data, short or garbage
/// headers and names without a terminator never read out of bounds.
fn tarfsMalformed() TestError!void {
    // No end marker: the files are still found.
    try expectTarFile(buildTar(&.{.{ .name = "a", .data = "x" }}, false), "/a", "x");

    // Data runs past the end of the archive: that entry and everything after
    // it are ignored, earlier entries still work.
    const truncated = buildTar(&.{
        .{ .name = "ok", .data = "fine" },
        .{ .name = "big", .size_field = "00000077777" },
        .{ .name = "after", .data = "never" },
    }, false);
    try expectTarFile(truncated, "/ok", "fine");
    try expectTarFile(truncated, "/big", null);
    try expectTarFile(truncated, "/after", null);

    // Archive shorter than one header.
    try expectTarFile(buildTar(&.{.{ .name = "a", .data = "x" }}, false)[0..100], "/a", null);
    try expectTarFile("", "/a", null);

    // Non-octal size field: parsed as size 0.
    try expectTarFile(buildTar(&.{.{ .name = "z", .size_field = "zzzz" }}, true), "/z", "");

    // A 100-byte name without a NUL terminator.
    const long_name: [100]u8 = @splat('n');
    try expectTarFile(buildTar(&.{.{ .name = &long_name, .data = "long" }}, true), "/" ++ long_name, "long");

    // Unknown entry types (e.g. symlinks) are not files.
    try expectTarFile(buildTar(&.{.{ .name = "link", .typ = '2' }}, true), "/link", null);

    // The real initrd is mounted again afterwards.
    try check(helpers.hasFile("/etc/motd"));
}

/// The NVMe driver reads the marker `scripts/test-qemu.sh` writes at the
/// start of the test disk; the rest of the sector and the next one are zero.
fn nvmeRead() TestError!void {
    const marker = "Hello from the NVMe test disk!";
    const buf = &page_buf;
    @memset(buf, 0xAA);
    const first = helpers.nvmeRead(0, buf) orelse return error.Failed;
    try check(first.len >= 512 and std.mem.startsWith(u8, first, marker));
    try check(std.mem.allEqual(u8, first[marker.len..], 0));
    const second = helpers.nvmeRead(1, buf) orelse return error.Failed;
    try check(std.mem.allEqual(u8, second, 0));
    // Reading past the end of the 64 MiB disk fails instead of returning data.
    try check(helpers.nvmeRead(1 << 40, buf) == null);
}

/// Known initrd files are found and missing ones are not.
fn vfsLookup() TestError!void {
    try check(helpers.hasFile("/etc/motd"));
    try check(helpers.hasFile("/bin/sh"));
    try check(!helpers.hasFile("/does-not-exist"));
}

/// `/etc/motd` has the expected size and contents.
fn vfsContents() TestError!void {
    const size = helpers.fileSize("/etc/motd") orelse
        return error.Failed;

    try check(size == "Welcome to MyOS!\n".len);

    var buf: [64]u8 = undefined;
    const n = helpers.readFileAt(
        "/etc/motd",
        0,
        &buf,
    ) orelse return error.Failed;

    try check(n == size);
    try check(std.mem.eql(
        u8,
        buf[0..n],
        "Welcome to MyOS!\n",
    ));
}

/// Reads honour the offset and return 0 at or past end of file.
fn vfsOffsets() TestError!void {
    var buf: [8]u8 = undefined;

    const n = helpers.readFileAt(
        "/etc/motd",
        8,
        &buf,
    ) orelse return error.Failed;

    try check(n == 8);
    try check(std.mem.eql(
        u8,
        buf[0..n],
        "to MyOS!",
    ));

    const end = helpers.fileSize("/etc/motd") orelse
        return error.Failed;

    try check(
        (helpers.readFileAt("/etc/motd", end, &buf) orelse
            return error.Failed) == 0,
    );

    try check(
        (helpers.readFileAt("/etc/motd", end + 10, &buf) orelse
            return error.Failed) == 0,
    );
}

/// Size and read queries for a missing file return null.
fn missingFile() TestError!void {
    var buf: [32]u8 = undefined;

    try check(
        helpers.readFileAt("/missing", 0, &buf) == null,
    );
    try check(helpers.fileSize("/missing") == null);
}

/// Integration-test scenario "shell": the system as it boots for a user,
/// `init` and the shell, with every CPU taking threads; the host types a
/// session over the serial line (`scripts/test-qemu.sh`). `init` restarts
/// the shell once, then ends with the second shell's status, which ends
/// the run.
fn scenarioShell() noreturn {
    _ = helpers.setOthersParked(false);
    const init = process.spawnPath("/sbin/init", .{ .argv = &.{ "init", "--restarts", "1" } }) catch |e|
        panicFmt("shell scenario: cannot start /sbin/init: {s}", .{@errorName(e)});
    process.setInit(init);
    const code = process.wait(init);
    var line: [64]u8 = undefined;
    serial.puts(std.fmt.bufPrint(&line, "MYOS_SHELL_DONE status={d}\n", .{code}) catch unreachable);
    qemu_exit.exit(if (code == 0) 0 else 1);
}

/// Scenario "bench" (`tools/bench/run.sh`): run `/usr/bin/bench` with every
/// CPU taking threads, as a program a user starts, and end the run. Not a
/// test: the numbers are for the host to compare with Linux's. `only`
/// limits it to the benchmarks whose name has it in.
fn scenarioBench(only: []const u8) noreturn {
    _ = helpers.setOthersParked(false);
    const p = process.spawnPath("/usr/bin/bench", .{ .argv = &.{ "bench", only } }) catch |e|
        panicFmt("bench scenario: cannot start /usr/bin/bench: {s}", .{@errorName(e)});
    const code = process.wait(p);
    var line: [64]u8 = undefined;
    serial.puts(std.fmt.bufPrint(&line, "MYOS_BENCH_DONE status={d}\n", .{code}) catch unreachable);
    qemu_exit.exit(if (code == 0) 0 else 1);
}

/// Integration-test scenario "panic": fail a subsystem assertion two calls
/// deep, so the panic output must contain a symbolized backtrace through
/// these functions.
noinline fn scenarioPanic() void {
    scenarioPanicInner(true);
}

/// Inner frame of `scenarioPanic`.
noinline fn scenarioPanicInner(fail: bool) void {
    assert.check(.scenario, !fail, "deliberate test panic", .{});
}

/// Integration-test scenario "fault": write to an unmapped kernel address, so
/// the page-fault report must show CR2 and a symbolized backtrace.
noinline fn scenarioFault() void {
    const p: *volatile u64 = @ptrFromInt(0xFFFF_B000_0000_0000);
    p.* = 0xDEAD;
}

/// Integration-test scenario "smap": read a user page from kernel code
/// outside a user copy. With SMAP on this must page-fault; if the read goes
/// through, the panic makes the scenario fail.
noinline fn scenarioSmap() void {
    if (!helpers.enterUserPageSpace()) @panic("smap scenario: out of memory");
    const p: *const volatile u8 = @ptrFromInt(helpers.USER_PAGE);
    const byte = p.*;
    panicFmt("SMAP not enforced: the kernel read 0x{x} from user memory", .{byte});
}

/// Integration-test scenario "smep": call code in a user page from ring 0.
/// With SMEP on the instruction fetch must page-fault; if the `ret` there
/// runs, the panic makes the scenario fail.
noinline fn scenarioSmep() void {
    if (!helpers.enterUserPageSpace()) @panic("smep scenario: out of memory");
    const user_code: *const fn () callconv(.c) void = @ptrFromInt(helpers.USER_PAGE);
    user_code();
    @panic("SMEP not enforced: the kernel executed user memory");
}

/// Integration-test scenario "double_fault": a kernel thread loses its stack
/// (RSP points at unmapped memory) and then faults. Without the emergency
/// stack this is a triple fault, i.e. a silent reset; with it, the kernel
/// must print a double-fault report.
noinline fn scenarioDoubleFault() void {
    helpers.doubleFaultInThread();
    @panic("double_fault scenario: no double fault was raised");
}

/// Integration-test scenario "stack_overflow": a kernel thread recurses until
/// its stack is used up. It must hit the guard page and be reported as a
/// kernel stack overflow, instead of overwriting other memory.
noinline fn scenarioStackOverflow() void {
    helpers.overflowStackInThread();
    @panic("stack_overflow scenario: the overflow was not caught");
}

/// Integration-test scenario "panic_smp": panic while every CPU is busy
/// printing. The CPU that panics must halt the others first, so its report
/// comes out whole and nothing is printed after it.
noinline fn scenarioPanicSmp() void {
    const irq = helpers.enableInterrupts();
    _ = helpers.startChatter() orelse @panic("panic_smp scenario: out of memory");
    helpers.restoreInterrupts(irq);
    scenarioPanicInner(true);
}

/// Integration-test scenario "lock_order": take two spinlocks in the wrong
/// order. The kernel must panic on the spot, naming both, on one CPU as on
/// several: a wrong order that is only noticed when it deadlocks is noticed
/// too late.
noinline fn scenarioLockOrder() void {
    helpers.takeLocksOutOfOrder();
    @panic("lock_order scenario: the wrong order was not caught");
}

/// Integration-test scenario "sleep_with_lock": sleep while holding a
/// spinlock. Interrupts are off and no other CPU could take the lock for as
/// long as the thread sleeps, so the kernel must refuse.
noinline fn scenarioSleepWithLock() void {
    helpers.sleepHoldingSpinlock();
    @panic("sleep_with_lock scenario: the sleep was not caught");
}

/// Entry point of the test kernel, called by `kmain` after boot: run the
/// scenario the host passed through fw_cfg (`opt/myos/scenario`, default
/// "tests"). Never returns; every scenario ends by exiting QEMU.
pub fn run() noreturn {
    var buf: [32]u8 = undefined;
    const scenario = fw_cfg.readFile("opt/myos/scenario", &buf) orelse "tests";
    log.info("test scenario: {s}", .{scenario});
    // Where the kernel was loaded this time. The host script compares the
    // boots of one run: with KASLR they must not all be the same.
    var slide_line: [64]u8 = undefined;
    serial.puts(std.fmt.bufPrint(&slide_line, "MYOS_KERNEL_SLIDE 0x{x}\n", .{helpers.kernelSlide()}) catch unreachable);
    if (std.mem.eql(u8, scenario, "panic")) scenarioPanic();
    if (std.mem.eql(u8, scenario, "fault")) scenarioFault();
    if (std.mem.eql(u8, scenario, "smap")) scenarioSmap();
    if (std.mem.eql(u8, scenario, "smep")) scenarioSmep();
    if (std.mem.eql(u8, scenario, "double_fault")) scenarioDoubleFault();
    if (std.mem.eql(u8, scenario, "stack_overflow")) scenarioStackOverflow();
    if (std.mem.eql(u8, scenario, "use_after_free")) scenarioUseAfterFree();
    if (std.mem.eql(u8, scenario, "relro")) scenarioRelro();
    if (std.mem.eql(u8, scenario, "text_alias")) scenarioTextAlias();
    if (std.mem.eql(u8, scenario, "panic_smp")) scenarioPanicSmp();
    if (std.mem.eql(u8, scenario, "lock_order")) scenarioLockOrder();
    if (std.mem.eql(u8, scenario, "sleep_with_lock")) scenarioSleepWithLock();
    if (std.mem.eql(u8, scenario, "shell")) scenarioShell();
    // "bench", or "bench:<name>" for only the benchmarks named so.
    if (std.mem.eql(u8, scenario, "bench")) scenarioBench("");
    if (std.mem.startsWith(u8, scenario, "bench:")) scenarioBench(scenario["bench:".len..]);
    expect_fxsave = std.mem.eql(u8, scenario, "tests_fxsave");
    const smp_run = std.mem.eql(u8, scenario, "tests_smp");
    expect_cpus = if (smp_run) 4 else 1; // as `scripts/test-qemu.sh` starts QEMU
    if (!std.mem.eql(u8, scenario, "tests") and !expect_fxsave and !smp_run) panicFmt("unknown test scenario '{s}'", .{scenario});
    runCases();
}

/// Run one test case and return whether it passed. Unless the case must
/// be `alone`, it runs with every CPU taking threads; the other CPUs are
/// parked again before the next case. A function of its own, not part of
/// the loop in `runCases`: unrolled over every case, its locals would make
/// that function's stack frame larger than a page.
noinline fn runCase(func: *const fn () TestError!void, alone: bool) bool {
    if (!alone) _ = helpers.setOthersParked(false);
    helpers.beginCase();
    const ok = if (func()) |_| true else |_| false;
    const irq = helpers.enableInterrupts();
    defer helpers.restoreInterrupts(irq);
    helpers.quiesce(); // the next case starts with this one's threads gone
    if (!alone and !helpers.setOthersParked(true)) @panic("tests: the other CPUs did not park");
    return ok;
}

/// Print the deepest use of any kernel stack and of any emergency stack in
/// this run, and return how many of them were past their warning level
/// (each counts as a failed check). Not part of `runCases`, whose stack
/// frame is large enough.
noinline fn reportStackPeaks() usize {
    var too_deep: usize = 0;
    // The deepest any kernel stack got in this run (every thread that exited,
    // and this one). Past the warning level the run fails: the stack is too
    // tight, even though nothing overflowed.
    const peak = helpers.stackPeak();
    var peak_line: [96]u8 = undefined;
    serial.puts(std.fmt.bufPrint(&peak_line, "MYOS_STACK_PEAK bytes={d} of={d} limit={d}\n", .{ peak, helpers.STACK_SIZE, helpers.STACK_WARN_BYTES }) catch unreachable);
    if (peak > helpers.STACK_WARN_BYTES) {
        too_deep += 1;
        // Most often an interrupt on top of the deepest path: where one
        // found a stack deepest.
        const d = root.arch.x86_64.idt.deepestInterrupted();
        var line: [96]u8 = undefined;
        serial.puts(std.fmt.bufPrint(&line, "deepest an interrupt found a stack: {d} bytes, at:\n", .{d.depth}) catch unreachable);
        root.kernel.debug.backtrace.printFrame(0, d.rip, false);
        for (d.frames[0..d.n], 1..) |ret, i| root.kernel.debug.backtrace.printFrame(i, ret, true);
        serial.puts("[FAIL] kernel stack usage below the warning level\n");
    } else serial.puts("[PASS] kernel stack usage below the warning level\n");

    if (helpers.istPeak()) |ist_peak| {
        var ist_line: [96]u8 = undefined;
        serial.puts(std.fmt.bufPrint(&ist_line, "MYOS_IST_PEAK bytes={d} of={d}\n", .{ ist_peak, helpers.IST_STACK_SIZE }) catch unreachable);
        // Past three quarters the run fails: too tight, though nothing overflowed.
        if (ist_peak > helpers.IST_STACK_SIZE / 4 * 3) {
            too_deep += 1;
            serial.puts("[FAIL] emergency stack usage below the warning level\n");
        } else serial.puts("[PASS] emergency stack usage below the warning level\n");
    }

    return too_deep;
}

/// Run every test case, log the results and exit QEMU with 0 if all passed, 1 otherwise.
fn runCases() noreturn {
    serial.puts("MYOS_TEST_BEGIN\n");

    var passed: usize = 0;
    var failed: usize = 0;

    const cases = .{
        .{
            .name = "PMM page accounting and read/write",
            .func = pageAccounting,
        },
        .{
            .name = "PMM distinct pages",
            .func = multiplePages,
        },
        .{ .name = "PMM rejects misaligned, unmanaged and double frees", .func = pmmBadFrees },
        .{
            .name = "kernel heap roundtrip",
            .func = heapTest,
        },
        .{
            .name = "kernel heap usage statistics",
            .func = heapStats,
        },
        .{
            .name = "VMM address-space create/destroy",
            .func = addressSpaceTest,
        },
        .{
            .name = "VMM map and translate",
            .func = vmmMapTranslate,
        },
        .{ .name = "VMM refuses to replace a mapping", .func = vmmMapConflicts },
        .{ .name = "VMM unmap frees empty page tables", .func = vmmUnmap },
        .{ .name = "VMM unmap and remap flush the TLB", .func = vmmTlbFlush },
        .{ .name = "kernel mappings are global, user mappings are not", .func = globalMappings },
        .{ .name = "VMM unmap flushes a global kernel mapping from the TLB", .func = kernelTlbFlush },
        .{ .name = "kernel code, constants and relocated tables are read-only, also in the direct map", .func = kernelWriteProtection },
        .{
            .name = "NVMe sector reads",
            .func = nvmeRead,
        },
        .{
            .name = "VFS lookup",
            .func = vfsLookup,
        },
        .{
            .name = "VFS file contents",
            .func = vfsContents,
        },
        .{
            .name = "VFS offset and EOF",
            .func = vfsOffsets,
        },
        .{
            .name = "VFS missing file",
            .func = missingFile,
        },
        .{ .name = "ELF load valid image", .func = elfLoadValid },
        .{ .name = "ELF segment not on a page boundary", .func = elfLoadUnaligned },
        .{ .name = "ELF segment permissions", .func = elfLoadPermissions },
        .{ .name = "ELF /bin/hello permissions", .func = elfLoadHelloPermissions },
        .{ .name = "ELF reject malformed images", .func = elfRejectMalformed },
        .{ .name = "ELF spawn rollback", .func = elfSpawnRollback },
        .{ .name = "syscall buffer and fd validation (ring 3)", .func = userSyscalls },
        .{ .name = "user copy routines (bad, partial and read-only ranges)", .func = userCopy },
        .{ .name = "bad user pointers in syscalls (ring 3)", .func = userPointers },
        .{ .name = "UMIP, SMEP, SMAP and ring 0 write protection enabled", .func = userProtectionOn },
        .{ .name = "RFLAGS.AC cleared on interrupt and syscall entry", .func = acClearedOnKernelEntry },
        .{ .name = "registers cleared on entry to user mode", .func = userEntryRegisters },
        .{ .name = "syscalls preserve registers, flags and the stack pointer (ring 3)", .func = syscallRegisters },
        .{ .name = "kernel state at syscalls and timer interrupts, preemption mid-syscall", .func = kernelEntryInvariants },
        .{ .name = "syscall return states (iretq fallback, bad states killed)", .func = syscallReturnStates },
        .{ .name = "GS base switched on every entry and exit", .func = gsBaseSwitching },
        .{ .name = "debug exception with the user GS base in ring 0", .func = debugTrapEntry },
        .{ .name = "FS and GS base set by the program itself (FSGSBASE)", .func = fsgsbase },
        .{ .name = "fork, vfork, clone of a process, wait4 (ring 3)", .func = forkWait },
        .{ .name = "job control: stop, continue, the terminal's background (ring 3)", .func = jobControl },
        .{ .name = "every system call's documented errors (ring 3)", .func = documentedErrors },
        .{ .name = "real-time signals, rt_sigtimedwait, signalfd (ring 3)", .func = queuedSignals },
        .{ .name = "flock: shared, exclusive, waiting, given up on close (ring 3)", .func = fileLocks },
        .{ .name = "rseq and getcpu: the CPU in the area, a critical section aborted, kept by fork (ring 3)", .func = restartableSequences },
        .{ .name = "memfd_create and shared mappings: two views of one file, the JIT's W^X, fork, seals (ring 3)", .func = memoryFiles },
        .{ .name = "FIFOs: mknod in /tmp, each end waiting for the other, ENXIO, EINTR (ring 3)", .func = namedPipes },
        .{ .name = "inotify: a directory's and a file's watches, renames with a cookie, a read that waits (ring 3)", .func = fileWatches },
        .{ .name = "2 MiB pages: given, split, copied, moved (ring 3)", .func = hugePages },
        .{ .name = "execve: arguments, descriptors, signal actions, scripts, threads (ring 3)", .func = execProgram },
        .{ .name = "clocks: TSC or HPET, in step on every CPU; sleeps; the wall clock from the RTC", .func = clocks },
        .{ .name = "extended state setup (SSE, XSAVE or FXSAVE)", .func = extendedStateSetup },
        .{ .name = "x87/SSE/AVX registers survive process switches", .func = extendedStateSwitching },
        .{ .name = "new process starts with clean x87/SSE/AVX state", .func = extendedStateClean },
        .{ .name = "syscall fuzzing from ring 3", .func = syscallFuzz },
        .{ .name = "PMM concurrent alloc/free under preemption", .func = pmmConcurrentStress },
        // Alone: each CPU's page cache has a critical section of its own,
        // so two threads exclude each other only when they share a CPU.
        .{ .name = "PMM critical sections exclude other threads", .func = pmmLock, .alone = true },
        .{ .name = "memory exhaustion fails cleanly (page tables, stacks, heap, processes)", .func = memoryExhaustion },
        // Alone: makes page allocation fail for the whole machine, and counts on which allocation is which.
        .{ .name = "process, kernel stack and heap growth fail cleanly at every allocation", .func = spawnAllocationFailures, .alone = true },
        .{ .name = "per-process limits (memory, open files, descendants)", .func = processLimits },
        .{ .name = "recursive spawning until memory runs out (ring 3)", .func = recursionUntilOutOfMemory },
        .{ .name = "user/kernel isolation (ring 3 faults)", .func = userIsolation },
        .{ .name = "user faults kill only the process (ring 3 exceptions)", .func = userFaults },
        .{ .name = "double-fault, NMI, debug and machine-check emergency stacks", .func = emergencyStacks },
        .{ .name = "guarded kernel stacks (alloc, guard page, free, reuse)", .func = kernelStacks },
        .{ .name = "kernel stack high-water mark", .func = stackUsage },
        .{ .name = "process lifecycle and cleanup", .func = processLifecycle },
        .{ .name = "random-number generator (seeding, balance, bounds)", .func = randomNumbers },
        .{ .name = "freed memory is poisoned, user pages are zeroed", .func = poisonAndZero },
        .{ .name = "a new process sees only zeroes (ring 3)", .func = userMemoryIsZeroed },
        .{ .name = "speculation guards (index clamp, user address clamp in user copies)", .func = speculationGuards },
        .{ .name = "Meltdown: CPU checked at boot", .func = meltdownDecision },
        // Alone: it reads each process's page tables before the process runs,
        // which another CPU taking threads would not wait for.
        .{ .name = "user stack address randomization", .func = stackRandomization, .alone = true },
        .{ .name = "kernel runs at a randomized address", .func = kernelRelocation },
        .{ .name = "spinlocks (interrupt state, nesting, exclusion under preemption)", .func = spinlocks },
        // Alone: checks the order in which woken threads run.
        .{ .name = "wait queues (several waiters, order, timeouts)", .func = waitQueues, .alone = true },
        // Alone: looks at the other CPUs while they are parked.
        .{ .name = "CPUs (all online, own per-CPU state, tables and stacks, same setup, timer interrupts)", .func = cpus, .alone = true },
        .{ .name = "speculation barrier after the conditional swapgs at kernel entry", .func = swapgsFences },
        .{ .name = "Linux startup: initial stack, FS and GS base, writev, ioctl, set_tid_address, exit_group", .func = linuxStartup },
        .{ .name = "memory on demand: mmap, munmap, mprotect, madvise, brk, stack growth, faults, the limit", .func = userMemory },
        .{ .name = "a static musl program built for Linux runs (arguments, environment, printf)", .func = muslHello },
        .{ .name = "threads and futexes (clone, own FS base, join, wake counts, timeouts, requeue, how a threaded process ends)", .func = threadsAndFutexes },
        .{ .name = "a multi-threaded musl program built for Linux runs (pthreads: mutex, condvar, barrier, TLS, join)", .func = muslThreads },
        .{ .name = "a static Rust program built for Linux runs (std: arguments, environment, allocation, println)", .func = rustHello },
        .{ .name = "a Go program built for Linux runs (runtime threads, goroutines, channel, GC)", .func = goHello },
        .{ .name = "position-independent programs built for Linux run, at a random address", .func = positionIndependent },
        .{ .name = "a program's ELF interpreter is loaded and started in its place", .func = elfInterpreter },
        .{ .name = "a dynamically linked C program runs with its loader and C library from files", .func = dynamicHello },
        .{ .name = "C, Rust and Go built with plain gcc, cargo build, go build run", .func = plainBuilds },
        .{ .name = "a .NET program published ahead of time for linux-x64 (glibc, dynamic) runs", .func = dotnetAot },
        .{ .name = "a self-contained .NET program with the JIT runtime runs", .func = dotnetSelfContained },
        .{ .name = "descriptors: standard streams, dup, pipes that wait, closed ends (ring 3)", .func = descriptorsAndPipes },
        .{ .name = "directories, /proc/self, /dev/null, a growing descriptor table, scheduling calls (ring 3)", .func = filesAndProc },
        .{ .name = "a woken thread preempts a busy CPU", .func = wakeLatency },
        .{ .name = "a spurious kernel page fault (stale TLB entry) is retried", .func = spuriousKernelFault },
        .{ .name = "eventfd and epoll: counters, waiting on several descriptors (ring 3)", .func = eventLoop },
        .{ .name = "signals: handlers, masks, faults, alternate stack, EINTR and SA_RESTART (ring 3)", .func = signals },
        .{ .name = "the terminal: line editing, Ctrl+D, raw keys, settings, Ctrl+C ends the foreground (ring 3)", .func = terminal },
        .{ .name = "a writable filesystem at /tmp: files, directories, rename, a program run from it (ring 3)", .func = writableFiles },
        .{ .name = "the program heap: standard containers on the user library's allocator (ring 3)", .func = programHeap },
        .{ .name = "a .NET Native AOT program built for Linux runs (runtime, managed threads, GC)", .func = dotnetHello },
        .{ .name = "on every CPU at once: removed kernel mappings leave every TLB", .func = tlbShootdown },
        .{ .name = "on every CPU at once: allocators, locks, wait queues with timeouts, kernel stacks", .func = kernelStress },
        .{ .name = "on every CPU at once: programs run, are preempted, crash and are torn down", .func = parallelPrograms },
        .{ .name = "locking model (locks held per CPU, idle wake-up in place, wake timers, unstarted threads)", .func = lockingModel },
        .{ .name = "kernel timers (order, expiry, cancel, sleep)", .func = timers },
        .{ .name = "an idle CPU takes interrupts with a request to switch threads left standing", .func = idleWithPreemptRequest },
        .{ .name = "mutex exclusion and hand-off under preemption", .func = mutexes },
        .{ .name = "keyboard readers wait on a queue", .func = keyboardReaders },
        .{ .name = "process exit status outlives the process; early exit, shared and no waiters", .func = processWaiting },
        .{ .name = "orphaned child is handed to its grandparent", .func = orphanedChild },
        .{ .name = "lifecycle stress (spawn, exit, wait, orphan, failures)", .func = lifecycleStress },
        // Alone: checks the exact interleaving of two threads.
        .{ .name = "scheduler round robin and reaping", .func = schedulerRoundRobin, .alone = true },
        .{ .name = "wake before block", .func = wakeBeforeBlock },
        // Alone: counts one CPU's CR3 loads while two threads take turns on it.
        .{ .name = "kernel thread keeps the loaded address space (no CR3 load)", .func = kernelThreadAddressSpace, .alone = true },
        // Alone: counts one CPU's switches and halts.
        .{ .name = "no idling while a thread is ready; a retired thread never runs", .func = idleOnlyWhenNothingIsReady, .alone = true },
        .{ .name = "syscall handler is replaceable in the test kernel only", .func = syscallHandlerReplaceable },
        .{ .name = "tarfs lookup and normalization", .func = tarfsLookup },
        .{ .name = "tarfs offsets and partial reads", .func = tarfsBoundaries },
        .{ .name = "tarfs malformed archives", .func = tarfsMalformed },
        .{
            .name = "symbolize kernel functions",
            .func = symbolizeKnownFunctions,
        },
        .{
            .name = "backtrace through frame chain",
            .func = backtraceThroughFrames,
        },
        .{
            .name = "fw_cfg scenario selection",
            .func = fwCfgScenario,
        },
    };

    // A test runs with every CPU taking threads, so its threads and the
    // programs it starts are spread over the machine, unless it is marked
    // `.alone = true` (with the reason, above): then the other CPUs are
    // parked while it runs. They start out parked.
    const irq = helpers.enableInterrupts();
    if (!helpers.setOthersParked(true)) @panic("tests: the other CPUs did not park");
    helpers.restoreInterrupts(irq);

    // A loop over a table, not an unrolled one: each unrolled case would
    // add to this function's stack frame.
    const Case = struct { name: []const u8, func: *const fn () TestError!void, alone: bool };
    const table = comptime blk: {
        var t: [cases.len]Case = undefined;
        for (cases, 0..) |case, i| t[i] = .{ .name = case.name, .func = case.func, .alone = @hasField(@TypeOf(case), "alone") and case.alone };
        break :blk t;
    };
    for (&table) |*case| {
        // A case that hangs panics instead (`watchdog` in `main.zig`): the
        // report says where every CPU was. No case takes a minute.
        root.test_deadline.store(root.kernel.clock.nanos() + WATCHDOG_NS, .monotonic);
        const ok = runCase(case.func, case.alone);
        root.test_deadline.store(0, .monotonic);
        if (ok) passed += 1 else failed += 1;
        serial.puts(if (ok) "[PASS] " else "[FAIL] ");
        serial.puts(case.name);
        serial.puts("\n");
    }

    failed += reportStackPeaks();

    var summary: [128]u8 = undefined;

    const line = std.fmt.bufPrint(
        &summary,
        "MYOS_TEST_SUMMARY passed={d} failed={d}\n",
        .{ passed, failed },
    ) catch unreachable;

    serial.puts(line);

    if (failed == 0 and passed == cases.len) {
        serial.puts("MYOS_TEST_PASS\n");
        qemu_exit.exit(0);
    }

    serial.puts("MYOS_TEST_FAIL\n");
    qemu_exit.exit(1);
}
