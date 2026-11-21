// Freestanding integration tests. No imports of src/ modules here:
// the production kernel injects callbacks bound to its initialized PMM/VFS.
const qemu_exit = @import("qemu_exit");

pub const Api = struct {
    log: *const fn ([]const u8) void,
    alloc_page: *const fn () ?u64,
    free_page: *const fn (u64) void,
    free_pages: *const fn () usize,
    has_file: *const fn ([]const u8) bool,
    read_file: *const fn ([]const u8, []u8) ?usize,
};

const TestError = error{ AssertionFailed, OutOfMemory, MissingFile };

fn ensure(ok: bool) TestError!void {
    if (!ok) return error.AssertionFailed;
}

fn testPage(api: Api) TestError!void {
    const before = api.free_pages();
    const page = api.alloc_page() orelse return error.OutOfMemory;
    defer api.free_page(page);
    try ensure(page % 4096 == 0);
    try ensure(api.free_pages() + 1 == before);
}

fn testInitrd(api: Api) TestError!void {
    try ensure(api.has_file("/etc/motd"));
    try ensure(!api.has_file("/not-present"));
    var buffer: [128]u8 = undefined;
    const n = api.read_file("/etc/motd", &buffer) orelse return error.MissingFile;
    try ensure(n > 0);
}

pub fn run(api: Api) noreturn {
    api.log("MYOS_TEST_BEGIN\n");
    var passed: usize = 0;
    var failed: usize = 0;

    const tests = .{
        .{ .name = "pmm allocation", .func = testPage },
        .{ .name = "initrd VFS read", .func = testInitrd },
    };
    inline for (tests) |case| {
        if (case.func(api)) |_| {
            passed += 1;
            api.log("[PASS] " ++ case.name ++ "\n");
        } else |_| {
            failed += 1;
            api.log("[FAIL] " ++ case.name ++ "\n");
        }
    }

    // Explicit stable protocol; host checks both summary and exit status.
    if (failed == 0 and passed == 2) {
        api.log("MYOS_TEST_SUMMARY passed=2 failed=0\n");
        api.log("MYOS_TEST_PASS\n");
        qemu_exit.exit(0);
    }
    api.log("MYOS_TEST_FAIL\n");
    qemu_exit.exit(1);
}
