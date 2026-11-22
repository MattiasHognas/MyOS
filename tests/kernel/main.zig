//! In-kernel integration tests, run inside QEMU by the test kernel.
//!
//! The kernel passes an `Api` of callbacks so the tests use the kernel's own
//! module instances. Results are logged to serial as `[PASS]`/`[FAIL]` lines
//! followed by `MYOS_TEST_PASS` or `MYOS_TEST_FAIL`, then QEMU is exited.

const std = @import("std");
const qemu_exit = @import("qemu_exit");

/// Result of loading an ELF image for inspection (see `Api.elf_probe`).
pub const ElfProbe = struct {
    /// Entry point returned by the loader.
    entry: u64,
    /// Leaf page-table entry mapping the probed address, or 0 if unmapped.
    pte: u64,
};

/// x86-64 page-table entry bits, for checking `ElfProbe.pte`.
const PTE_PRESENT: u64 = 1 << 0;
const PTE_WRITABLE: u64 = 1 << 1;
const PTE_USER: u64 = 1 << 2;
const PTE_NX: u64 = 1 << 63;

/// Kernel services the tests may use, provided by `src/main.zig`.
pub const Api = struct {
    log: *const fn ([]const u8) void,

    alloc_page: *const fn () ?u64,
    free_page: *const fn (u64) void,
    free_pages: *const fn () usize,
    page_rw: *const fn (u64) bool,

    heap_roundtrip: *const fn () bool,
    heap_stats: *const fn () bool,
    address_space_roundtrip: *const fn () bool,
    vmm_map_translate: *const fn () bool,

    /// Name of the function containing a code address, or null.
    symbolize: *const fn (u64) ?[]const u8,
    /// Return addresses of the caller's frame chain, innermost first.
    capture_backtrace: *const fn ([]u64) usize,
    /// Read a QEMU fw_cfg file into the buffer.
    fw_cfg_read: *const fn ([]const u8, []u8) ?[]u8,

    /// Load an ELF image into a scratch address space and inspect address `addr`
    /// (bytes copied into the buffer); null if loading fails.
    elf_probe: *const fn ([]const u8, u64, []u8) ?ElfProbe,
    /// Same as `elf_probe` for an ELF file in the VFS.
    elf_probe_path: *const fn ([]const u8, u64, []u8) ?ElfProbe,
    /// True if spawning the image fails and leaks no pages or heap memory.
    spawn_fails_cleanly: *const fn ([]const u8) bool,
    /// Run a program and wait for it: its exit code, or null if it can't start.
    run_program: *const fn ([]const u8) ?u64,
    /// Bytes currently allocated from the kernel heap.
    heap_in_use: *const fn () usize,
    /// Two yielding kernel threads alternate and are cleaned up.
    scheduler_round_robin: *const fn () bool,
    /// A wake before block makes block return immediately.
    wake_before_block: *const fn () bool,
    /// Mount a tar image, read a file from an offset, remount the initrd.
    tarfs_read: *const fn ([]const u8, []const u8, u64, []u8) ?usize,
    /// Read one sector of the NVMe disk; null if there is no disk or the read fails.
    nvme_read: *const fn (u64, []u8) ?[]u8,

    has_file: *const fn ([]const u8) bool,
    file_size: *const fn ([]const u8) ?u64,
    read_file_at: *const fn ([]const u8, u64, []u8) ?usize,
};

const TestError = error{ Failed, OutOfMemory };

/// Turn a boolean condition into `error.Failed`.
fn check(ok: bool) TestError!void {
    if (!ok) return error.Failed;
}

/// Allocating a page returns an aligned, non-zero, usable page and decrements the free count.
fn pageAccounting(api: Api) TestError!void {
    const before = api.free_pages();
    const page = api.alloc_page() orelse
        return error.OutOfMemory;
    defer api.free_page(page);

    try check(page != 0 and page % 4096 == 0);
    try check(api.free_pages() + 1 == before);
    try check(api.page_rw(page));
}

/// Consecutive allocations return distinct pages and are all accounted for.
fn multiplePages(api: Api) TestError!void {
    const before = api.free_pages();

    var pages: [8]u64 = undefined;
    var used: usize = 0;

    defer {
        for (pages[0..used]) |page| {
            api.free_page(page);
        }
    }

    while (used < pages.len) {
        const p = api.alloc_page() orelse
            return error.OutOfMemory;

        for (pages[0..used]) |other| {
            try check(p != other);
        }

        try check(p != 0 and p % 4096 == 0);
        pages[used] = p;
        used += 1;
    }

    try check(api.free_pages() + pages.len == before);
}

/// The kernel heap can allocate, fill and free a block.
fn heapTest(api: Api) TestError!void {
    try check(api.heap_roundtrip());
}

/// Creating and destroying an address space does not leak pages.
fn addressSpaceTest(api: Api) TestError!void {
    try check(api.address_space_roundtrip());
}

/// Heap usage counters follow allocations, shrinks and frees.
fn heapStats(api: Api) TestError!void {
    try check(api.heap_stats());
}

/// A mapped page translates back to its physical address; unmapped pages don't.
fn vmmMapTranslate(api: Api) TestError!void {
    try check(api.vmm_map_translate());
}

/// The kernel's own functions are symbolized from its ELF symbol table.
fn symbolizeKnownFunctions(api: Api) TestError!void {
    const name = api.symbolize(@intFromPtr(&symbolTarget)) orelse return error.Failed;
    try check(std.mem.endsWith(u8, name, "symbolTarget"));
    const run_name = api.symbolize(@intFromPtr(&run) + 1) orelse return error.Failed;
    try check(std.mem.endsWith(u8, run_name, "run"));
    try check(api.symbolize(0) == null);
}

/// Target for the symbolization test; never called.
noinline fn symbolTarget() callconv(.c) void {
    asm volatile ("");
}

/// Backtraces follow the frame chain through named functions.
fn backtraceThroughFrames(api: Api) TestError!void {
    try backtraceOuter(api);
}

/// Outer frame of the backtrace test.
noinline fn backtraceOuter(api: Api) TestError!void {
    try backtraceInner(api);
    asm volatile (""); // keep this from being a tail call
}

/// Inner frame of the backtrace test: capture and check the chain.
noinline fn backtraceInner(api: Api) TestError!void {
    var frames: [16]u64 = undefined;
    const n = api.capture_backtrace(&frames);
    try check(n >= 3);
    const inner = api.symbolize(frames[0] - 1) orelse return error.Failed;
    const outer = api.symbolize(frames[1] - 1) orelse return error.Failed;
    try check(std.mem.endsWith(u8, inner, "backtraceInner"));
    try check(std.mem.endsWith(u8, outer, "backtraceOuter"));
    asm volatile ("");
}

/// The host passed the scenario name through QEMU's fw_cfg device.
fn fwCfgScenario(api: Api) TestError!void {
    var buf: [32]u8 = undefined;
    const scenario = api.fw_cfg_read("opt/myos/scenario", &buf) orelse return error.Failed;
    try check(std.mem.eql(u8, scenario, "tests"));
    try check(api.fw_cfg_read("opt/myos/does-not-exist", &buf) == null);
}

// ---------------------------------------------------------------------------
// ELF loading

/// Scratch buffer for ELF images built by the tests (kept off the stack).
var elf_buf: [0x3000]u8 align(8) = undefined;

/// Options for `buildElf`. Defaults give a valid executable with one
/// read+execute segment of 16 bytes (0xAA) at 0x400000 and 0x2000 bytes of memory.
const ElfSpec = struct {
    class: u8 = 2,
    data: u8 = 1,
    typ: u16 = 2,
    machine: u16 = 0x3E,
    entry: u64 = 0x40_0000,
    phoff: u64 = 64,
    phnum: u16 = 1,
    /// Fields of the first program header.
    flags: u32 = 5, // R + X
    offset: u64 = 0x1000,
    vaddr: u64 = 0x40_0000,
    filesz: u64 = 16,
    memsz: u64 = 0x2000,
    /// Optional second PT_LOAD segment (used for rollback tests).
    second_vaddr: ?u64 = null,
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
    std.mem.writeInt(u32, b[20..24], 1, .little);
    std.mem.writeInt(u64, b[24..32], spec.entry, .little);
    std.mem.writeInt(u64, b[32..40], spec.phoff, .little);
    std.mem.writeInt(u16, b[52..54], 64, .little);
    std.mem.writeInt(u16, b[54..56], 56, .little);
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
        std.mem.writeInt(u32, ph2[0..4], 1, .little);
        std.mem.writeInt(u32, ph2[4..8], 6, .little); // R + W
        std.mem.writeInt(u64, ph2[8..16], 0x1000, .little);
        std.mem.writeInt(u64, ph2[16..24], v, .little);
        std.mem.writeInt(u64, ph2[32..40], 16, .little);
        std.mem.writeInt(u64, ph2[40..48], 0x1000, .little);
    }
    @memset(b[0x1000..0x1010], 0xAA);
    return b[0..spec.len];
}

/// A valid image loads: entry point, contents, zeroed .bss, and no leaked pages.
fn elfLoadValid(api: Api) TestError!void {
    const before = api.free_pages();
    var out: [32]u8 = undefined;

    const p = api.elf_probe(buildElf(.{}), 0x40_0000, &out) orelse return error.Failed;
    try check(p.entry == 0x40_0000);
    try check(std.mem.allEqual(u8, out[0..16], 0xAA)); // file contents
    try check(std.mem.allEqual(u8, out[16..32], 0)); // .bss tail of the first page

    _ = api.elf_probe(buildElf(.{}), 0x40_1000, &out) orelse return error.Failed;
    try check(std.mem.allEqual(u8, &out, 0)); // second page: all .bss

    try check(api.free_pages() == before);
}

/// Segment flags become page permissions: user, writable only if W, NX unless X.
fn elfLoadPermissions(api: Api) TestError!void {
    var out: [8]u8 = undefined;
    const rx = api.elf_probe(buildElf(.{ .flags = 5 }), 0x40_0000, &out) orelse return error.Failed;
    try check(rx.pte & PTE_PRESENT != 0 and rx.pte & PTE_USER != 0);
    try check(rx.pte & PTE_WRITABLE == 0 and rx.pte & PTE_NX == 0);

    const rw = api.elf_probe(buildElf(.{ .flags = 6 }), 0x40_0000, &out) orelse return error.Failed;
    try check(rw.pte & PTE_USER != 0 and rw.pte & PTE_WRITABLE != 0 and rw.pte & PTE_NX != 0);

    const r = api.elf_probe(buildElf(.{ .flags = 4 }), 0x40_0000, &out) orelse return error.Failed;
    try check(r.pte & PTE_USER != 0 and r.pte & PTE_WRITABLE == 0 and r.pte & PTE_NX != 0);
}

/// The real /bin/hello: every PT_LOAD segment from its program headers is
/// mapped for user mode with exactly the permissions its flags ask for
/// (writable only if W, non-executable unless X), and page 0 stays unmapped.
fn elfLoadHelloPermissions(api: Api) TestError!void {
    var hdr: [4096]u8 = undefined;
    const n = api.read_file_at("/bin/hello", 0, &hdr) orelse return error.Failed;
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
        const p = api.elf_probe_path("/bin/hello", vaddr, &out) orelse return error.Failed;
        try check(p.pte & PTE_PRESENT != 0 and p.pte & PTE_USER != 0);
        try check((p.pte & PTE_WRITABLE != 0) == (flags & 2 != 0));
        try check((p.pte & PTE_NX == 0) == (flags & 1 != 0));
        loads += 1;
        if (flags & 1 != 0) executable += 1;
    }
    try check(loads >= 2 and executable >= 1);

    const zero = api.elf_probe_path("/bin/hello", 0, &out) orelse return error.Failed;
    try check(zero.pte == 0);
}

/// Malformed or unsupported images are rejected without leaking pages.
fn elfRejectMalformed(api: Api) TestError!void {
    const before = api.free_pages();
    var out: [8]u8 = undefined;
    const bad = [_]ElfSpec{
        .{ .len = 63 }, // shorter than the ELF header
        .{ .class = 1 }, // 32-bit
        .{ .data = 2 }, // big endian
        .{ .machine = 3 }, // i386
        .{ .typ = 3 }, // ET_DYN, not ET_EXEC
        .{ .phoff = 0x2FFF }, // program header table past the end of the file
        .{ .phnum = 200 }, // program header table runs past the end
        .{ .vaddr = 0xFFFF_8000_0000_0000 }, // kernel half
        .{ .vaddr = 0x7FFF_FFFF_F000 }, // ends past the user half
        .{ .vaddr = 0xFFFF_FFFF_FFFF_F000 }, // vaddr + memsz wraps around
        .{ .vaddr = 0x40_0100 }, // not page aligned
        .{ .filesz = 0x3000 }, // filesz > memsz
        .{ .offset = 0x1000, .filesz = 0x100 }, // file data past the end of the image
        .{ .entry = 0xFFFF_FFFF_8000_0000 }, // entry point in the kernel
    };
    for (bad) |spec| try check(api.elf_probe(buildElf(spec), 0x40_0000, &out) == null);
    try check(api.free_pages() == before);
}

/// A failure after some segments were already loaded rolls everything back.
fn elfSpawnRollback(api: Api) TestError!void {
    // First segment loads (pages allocated), the second is in the kernel half.
    try check(api.spawn_fails_cleanly(buildElf(.{ .phnum = 2, .second_vaddr = 0xFFFF_8000_0000_0000 })));
    try check(api.spawn_fails_cleanly(buildElf(.{ .phnum = 2, .second_vaddr = 0x40_0123 })));
    try check(api.spawn_fails_cleanly(buildElf(.{ .machine = 3 })));
    try check(api.spawn_fails_cleanly("not an ELF"));
}

// ---------------------------------------------------------------------------
// User mode: syscalls, isolation, process lifecycle

/// Syscall buffer and descriptor validation, checked from ring 3.
fn userSyscalls(api: Api) TestError!void {
    const code = api.run_program("/test/syscalls") orelse return error.Failed;
    if (code != 0) {
        var buf: [64]u8 = undefined;
        api.log(std.fmt.bufPrint(&buf, "  /test/syscalls failed check {d}\n", .{code}) catch "");
    }
    try check(code == 0);
}

/// Ring 3 cannot read kernel memory, run privileged instructions, or write
/// its own code: each attempt kills only that process (exit code 255).
fn userIsolation(api: Api) TestError!void {
    try check(api.run_program("/test/kernel_read") == 255);
    try check(api.run_program("/test/privileged") == 255);
    try check(api.run_program("/test/write_text") == 255);
}

/// Spawn, run, wait and exit: exit codes reach the parent, and a finished or
/// crashed process leaves no pages or heap memory behind.
fn processLifecycle(api: Api) TestError!void {
    try check(api.run_program("/bin/hello") == 0);
    try check(api.run_program("/does/not/exist") == null);

    // The first runs above may have grown the heap; measure from here.
    const pages = api.free_pages();
    const heap_bytes = api.heap_in_use();
    try check(api.run_program("/bin/hello") == 0);
    try check(api.run_program("/test/kernel_read") == 255);
    try check(api.free_pages() == pages);
    try check(api.heap_in_use() == heap_bytes);
}

/// Kernel threads take turns in FIFO order and are reaped after exiting.
fn schedulerRoundRobin(api: Api) TestError!void {
    try check(api.scheduler_round_robin());
}

/// A wake that arrives before block is not lost.
fn wakeBeforeBlock(api: Api) TestError!void {
    try check(api.wake_before_block());
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
fn expectTarFile(api: Api, image: []const u8, path: []const u8, want: ?[]const u8) TestError!void {
    var buf: [64]u8 = undefined;
    const n = api.tarfs_read(image, path, 0, &buf);
    if (want) |w| {
        try check(n != null and std.mem.eql(u8, buf[0..n.?], w));
    } else try check(n == null);
}

/// Normal archives: several files, path normalization, directories ignored.
fn tarfsLookup(api: Api) TestError!void {
    const img = buildTar(&.{
        .{ .name = "./etc/", .typ = '5' },
        .{ .name = "./etc/a", .data = "alpha" },
        .{ .name = "b", .data = "bravo!" },
        .{ .name = "empty" },
    }, true);
    try expectTarFile(api, img, "/etc/a", "alpha");
    try expectTarFile(api, img, "etc/a", "alpha");
    try expectTarFile(api, img, "/b", "bravo!");
    try expectTarFile(api, img, "/empty", "");
    try expectTarFile(api, img, "/etc", null); // directories are not files
    try expectTarFile(api, img, "/", null);
    try expectTarFile(api, img, "", null);
    try expectTarFile(api, img, "/etc/a/x", null);
}

/// Offsets at, past and inside the file; short buffers get partial reads.
fn tarfsBoundaries(api: Api) TestError!void {
    const img = buildTar(&.{.{ .name = "f", .data = "0123456789" }}, true);
    var buf: [4]u8 = undefined;
    try check(api.tarfs_read(img, "/f", 0, &buf) == 4 and std.mem.eql(u8, &buf, "0123"));
    try check(api.tarfs_read(img, "/f", 8, &buf) == 2 and std.mem.eql(u8, buf[0..2], "89"));
    try check(api.tarfs_read(img, "/f", 10, &buf) == 0);
    try check(api.tarfs_read(img, "/f", 1 << 40, &buf) == 0);
    try check(api.tarfs_read(img, "/f", 0, buf[0..0]) == 0);
}

/// Malformed archives: missing end marker, truncated data, short or garbage
/// headers and names without a terminator never read out of bounds.
fn tarfsMalformed(api: Api) TestError!void {
    // No end marker: the files are still found.
    try expectTarFile(api, buildTar(&.{.{ .name = "a", .data = "x" }}, false), "/a", "x");

    // Data runs past the end of the archive: that entry and everything after
    // it are ignored, earlier entries still work.
    const truncated = buildTar(&.{
        .{ .name = "ok", .data = "fine" },
        .{ .name = "big", .size_field = "00000077777" },
        .{ .name = "after", .data = "never" },
    }, false);
    try expectTarFile(api, truncated, "/ok", "fine");
    try expectTarFile(api, truncated, "/big", null);
    try expectTarFile(api, truncated, "/after", null);

    // Archive shorter than one header.
    try expectTarFile(api, buildTar(&.{.{ .name = "a", .data = "x" }}, false)[0..100], "/a", null);
    try expectTarFile(api, "", "/a", null);

    // Non-octal size field: parsed as size 0.
    try expectTarFile(api, buildTar(&.{.{ .name = "z", .size_field = "zzzz" }}, true), "/z", "");

    // A 100-byte name without a NUL terminator.
    const long_name: [100]u8 = @splat('n');
    try expectTarFile(api, buildTar(&.{.{ .name = &long_name, .data = "long" }}, true), "/" ++ long_name, "long");

    // Unknown entry types (e.g. symlinks) are not files.
    try expectTarFile(api, buildTar(&.{.{ .name = "link", .typ = '2' }}, true), "/link", null);

    // The real initrd is mounted again afterwards.
    try check(api.has_file("/etc/motd"));
}

/// The NVMe driver reads the marker `scripts/test-qemu.sh` writes at the
/// start of the test disk; the rest of the sector and the next one are zero.
fn nvmeRead(api: Api) TestError!void {
    const marker = "Hello from the NVMe test disk!";
    var buf: [4096]u8 = @splat(0xAA);
    const first = api.nvme_read(0, &buf) orelse return error.Failed;
    try check(first.len >= 512 and std.mem.startsWith(u8, first, marker));
    try check(std.mem.allEqual(u8, first[marker.len..], 0));
    const second = api.nvme_read(1, &buf) orelse return error.Failed;
    try check(std.mem.allEqual(u8, second, 0));
    // Reading past the end of the 64 MiB disk fails instead of returning data.
    try check(api.nvme_read(1 << 40, &buf) == null);
}

/// Known initrd files are found and missing ones are not.
fn vfsLookup(api: Api) TestError!void {
    try check(api.has_file("/etc/motd"));
    try check(api.has_file("/bin/sh"));
    try check(!api.has_file("/does-not-exist"));
}

/// `/etc/motd` has the expected size and contents.
fn vfsContents(api: Api) TestError!void {
    const size = api.file_size("/etc/motd") orelse
        return error.Failed;

    try check(size == "Welcome to MyOS!\n".len);

    var buf: [64]u8 = undefined;
    const n = api.read_file_at(
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
fn vfsOffsets(api: Api) TestError!void {
    var buf: [8]u8 = undefined;

    const n = api.read_file_at(
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

    const end = api.file_size("/etc/motd") orelse
        return error.Failed;

    try check(
        (api.read_file_at("/etc/motd", end, &buf) orelse
            return error.Failed) == 0,
    );

    try check(
        (api.read_file_at("/etc/motd", end + 10, &buf) orelse
            return error.Failed) == 0,
    );
}

/// Size and read queries for a missing file return null.
fn missingFile(api: Api) TestError!void {
    var buf: [32]u8 = undefined;

    try check(
        api.read_file_at("/missing", 0, &buf) == null,
    );
    try check(api.file_size("/missing") == null);
}

/// Run every test case, log the results and exit QEMU with 0 if all passed, 1 otherwise.
pub fn run(api: Api) noreturn {
    api.log("MYOS_TEST_BEGIN\n");

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
        .{ .name = "ELF segment permissions", .func = elfLoadPermissions },
        .{ .name = "ELF /bin/hello permissions", .func = elfLoadHelloPermissions },
        .{ .name = "ELF reject malformed images", .func = elfRejectMalformed },
        .{ .name = "ELF spawn rollback", .func = elfSpawnRollback },
        .{ .name = "syscall buffer and fd validation (ring 3)", .func = userSyscalls },
        .{ .name = "user/kernel isolation (ring 3 faults)", .func = userIsolation },
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
        if (case.func(api)) |_| {
            passed += 1;
            api.log("[PASS] " ++ case.name ++ "\n");
        } else |_| {
            failed += 1;
            api.log("[FAIL] " ++ case.name ++ "\n");
        }
    }

    var summary: [128]u8 = undefined;

    const line = std.fmt.bufPrint(
        &summary,
        "MYOS_TEST_SUMMARY passed={d} failed={d}\n",
        .{ passed, failed },
    ) catch unreachable;

    api.log(line);

    if (failed == 0 and passed == cases.len) {
        api.log("MYOS_TEST_PASS\n");
        qemu_exit.exit(0);
    }

    api.log("MYOS_TEST_FAIL\n");
    qemu_exit.exit(1);
}
