//! In-kernel integration tests, run inside QEMU by the test kernel.
//!
//! `kmain` calls `run` in the test kernel. The tests reach the kernel through
//! `@import("root")` (see `helpers.zig`), so they use the kernel's own module
//! instances. `run` picks the scenario the host asked for: the test cases
//! below, or a deliberate panic or fault. Results are logged to serial as
//! `[PASS]`/`[FAIL]` lines followed by `MYOS_TEST_PASS` or `MYOS_TEST_FAIL`,
//! then QEMU is exited.

const std = @import("std");
const root = @import("root");
const pmm = root.kernel.pmm;
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
    const charged = helpers.chargedPages("/bin/hello") orelse return error.Failed;
    try check(charged > 4 + 4 + 7); // more than the two stacks and the smallest set of page tables
    try check(helpers.runProgramLimited("/bin/hello", .{ .max_pages = charged }) == 0);
    try check(tooLarge(helpers.spawnError("/bin/hello", .{ .max_pages = charged - 1 })));
    // Too little even for the stacks: refused before anything is allocated.
    try check(tooLarge(helpers.spawnError("/bin/hello", .{ .max_pages = 8 })));

    // Open files: 13 by default, fewer with a lower limit, none at 3.
    try check(helpers.runProgram("/test/open_count") == 13);
    try check(helpers.runProgramLimited("/test/open_count", .{ .max_files = 5 }) == 2);
    try check(helpers.runProgramLimited("/test/open_count", .{ .max_files = 3 }) == 0);
    try check(helpers.runProgramLimited("/test/open_count", .{ .max_files = 0 }) == 0);
    try check(helpers.runProgramLimited("/test/open_count", .{ .max_files = 1000 }) == 13); // the table is the cap

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
    try check(std.mem.eql(u8, scenario, if (expect_fxsave) "tests_fxsave" else "tests"));
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
        .{ .typ = 3 }, // ET_DYN, not ET_EXEC
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
        .{ .phnum = 2, .second_vaddr = 0x50_0000, .second_type = 3 }, // PT_INTERP: dynamically linked
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
    const code = helpers.runProgram("/test/syscalls") orelse return error.Failed;
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
    const pages = pmm.free_pages;
    const heap_bytes = helpers.heapInUse();
    const code = helpers.runProgram("/test/user_pointers") orelse return error.Failed;
    if (code != 0) {
        var buf: [64]u8 = undefined;
        serial.puts(std.fmt.bufPrint(&buf, "  /test/user_pointers failed check {d}\n", .{code}) catch "");
    }
    try check(code == 0);
    try check(pmm.free_pages == pages and helpers.heapInUse() == heap_bytes);
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
    var runs: usize = 0;
    while (runs < 30) : (runs += 1) {
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
    const pages = pmm.free_pages;
    const heap_bytes = helpers.heapInUse();
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
    try check(pmm.free_pages == pages and helpers.heapInUse() == heap_bytes);
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
fn debugTrapEntry() TestError!void {
    const failed = helpers.debugTrapEntry();
    if (failed != 0) report("debug trap check", failed);
    try check(failed == 0);
}

/// True in the `tests_fxsave` scenario, where QEMU hides XSAVE from the kernel.
var expect_fxsave = false;

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
    const pages = pmm.free_pages;
    const heap_bytes = helpers.heapInUse();
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
    try check(pmm.free_pages == pages and helpers.heapInUse() == heap_bytes);
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
    const pages = pmm.free_pages;
    const heap_bytes = helpers.heapInUse();
    try expectProgram("/test/fuzz");
    try check(pmm.free_pages == pages and helpers.heapInUse() == heap_bytes);
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
    const pages = pmm.free_pages;
    const heap_bytes = helpers.heapInUse();
    try check(helpers.runProgram("/test/div_zero") == 255);
    try check(helpers.runProgram("/test/invalid_opcode") == 255);
    // Single-stepping into a syscall: the trap arrives in ring 3, after the
    // syscall has returned through iretq, never in the kernel.
    const iret_before = helpers.iretReturns();
    try check(helpers.runProgram("/test/single_step") == 255);
    try check(helpers.iretReturns() == iret_before + 1);
    try check(helpers.runProgram("/bin/hello") == 0);
    try check(pmm.free_pages == pages and helpers.heapInUse() == heap_bytes);
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
    const pages = pmm.free_pages;
    const heap_bytes = helpers.heapInUse();
    try check(helpers.runProgram("/bin/hello") == 0);
    try check(helpers.runProgram("/test/kernel_read") == 255);
    try check(pmm.free_pages == pages);
    try check(helpers.heapInUse() == heap_bytes);
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

/// Entry point of the test kernel, called by `kmain` after boot: run the
/// scenario the host passed through fw_cfg (`opt/myos/scenario`, default
/// "tests"). Never returns; every scenario ends by exiting QEMU.
pub fn run() noreturn {
    var buf: [32]u8 = undefined;
    const scenario = fw_cfg.readFile("opt/myos/scenario", &buf) orelse "tests";
    log.info("test scenario: {s}", .{scenario});
    if (std.mem.eql(u8, scenario, "panic")) scenarioPanic();
    if (std.mem.eql(u8, scenario, "fault")) scenarioFault();
    if (std.mem.eql(u8, scenario, "smap")) scenarioSmap();
    if (std.mem.eql(u8, scenario, "smep")) scenarioSmep();
    if (std.mem.eql(u8, scenario, "double_fault")) scenarioDoubleFault();
    if (std.mem.eql(u8, scenario, "stack_overflow")) scenarioStackOverflow();
    expect_fxsave = std.mem.eql(u8, scenario, "tests_fxsave");
    if (!std.mem.eql(u8, scenario, "tests") and !expect_fxsave) panicFmt("unknown test scenario '{s}'", .{scenario});
    runCases();
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
        .{ .name = "extended state setup (SSE, XSAVE or FXSAVE)", .func = extendedStateSetup },
        .{ .name = "x87/SSE/AVX registers survive process switches", .func = extendedStateSwitching },
        .{ .name = "new process starts with clean x87/SSE/AVX state", .func = extendedStateClean },
        .{ .name = "syscall fuzzing from ring 3", .func = syscallFuzz },
        .{ .name = "PMM concurrent alloc/free under preemption", .func = pmmConcurrentStress },
        .{ .name = "PMM critical sections exclude other threads", .func = pmmLock },
        .{ .name = "memory exhaustion fails cleanly (page tables, stacks, heap, processes)", .func = memoryExhaustion },
        .{ .name = "process, kernel stack and heap growth fail cleanly at every allocation", .func = spawnAllocationFailures },
        .{ .name = "per-process limits (memory, open files, descendants)", .func = processLimits },
        .{ .name = "recursive spawning until memory runs out (ring 3)", .func = recursionUntilOutOfMemory },
        .{ .name = "user/kernel isolation (ring 3 faults)", .func = userIsolation },
        .{ .name = "user faults kill only the process (ring 3 exceptions)", .func = userFaults },
        .{ .name = "double-fault, NMI and debug emergency stacks", .func = emergencyStacks },
        .{ .name = "guarded kernel stacks (alloc, guard page, free, reuse)", .func = kernelStacks },
        .{ .name = "kernel stack high-water mark", .func = stackUsage },
        .{ .name = "process lifecycle and cleanup", .func = processLifecycle },
        .{ .name = "scheduler round robin and reaping", .func = schedulerRoundRobin },
        .{ .name = "wake before block", .func = wakeBeforeBlock },
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

    inline for (cases) |case| {
        if (case.func()) |_| {
            passed += 1;
            serial.puts("[PASS] " ++ case.name ++ "\n");
        } else |_| {
            failed += 1;
            serial.puts("[FAIL] " ++ case.name ++ "\n");
        }
    }

    // The deepest any kernel stack got in this run (every thread that exited,
    // and this one). Past the warning level the run fails: the stack is too
    // tight, even though nothing overflowed.
    const peak = helpers.stackPeak();
    var peak_line: [96]u8 = undefined;
    serial.puts(std.fmt.bufPrint(&peak_line, "MYOS_STACK_PEAK bytes={d} of={d} limit={d}\n", .{ peak, helpers.STACK_SIZE, helpers.STACK_WARN_BYTES }) catch unreachable);
    if (peak > helpers.STACK_WARN_BYTES) {
        failed += 1;
        serial.puts("[FAIL] kernel stack usage below the warning level\n");
    } else serial.puts("[PASS] kernel stack usage below the warning level\n");

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
