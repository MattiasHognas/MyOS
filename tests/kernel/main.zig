//! In-kernel integration tests, run inside QEMU by the test kernel.
//!
//! The kernel passes an `Api` of callbacks so the tests use the kernel's own
//! module instances. Results are logged to serial as `[PASS]`/`[FAIL]` lines
//! followed by `MYOS_TEST_PASS` or `MYOS_TEST_FAIL`, then QEMU is exited.

const std = @import("std");
const qemu_exit = @import("qemu_exit");

/// Kernel services the tests may use, provided by `src/main.zig`.
pub const Api = struct {
    log: *const fn ([]const u8) void,

    alloc_page: *const fn () ?u64,
    free_page: *const fn (u64) void,
    free_pages: *const fn () usize,
    page_rw: *const fn (u64) bool,

    heap_roundtrip: *const fn () bool,
    address_space_roundtrip: *const fn () bool,
    invalid_elf_rejected: *const fn () bool,

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

/// Spawning a process from a non-ELF image fails.
fn invalidElf(api: Api) TestError!void {
    try check(api.invalid_elf_rejected());
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
            .name = "VMM address-space create/destroy",
            .func = addressSpaceTest,
        },
        .{
            .name = "reject invalid ELF magic",
            .func = invalidElf,
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
