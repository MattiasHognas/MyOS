//! Root of the native host test binary (`zig build test-host`).

const std = @import("std");

// Import every test file from this root. Zig discovers their test declarations.
test {
    std.testing.refAllDecls(@import("vfs_test.zig"));
    std.testing.refAllDecls(@import("symbols_test.zig"));
    std.testing.refAllDecls(@import("log_format_test.zig"));
    std.testing.refAllDecls(@import("user_range_test.zig"));
    std.testing.refAllDecls(@import("elf_image_test.zig"));
    std.testing.refAllDecls(@import("abi_test.zig"));
    std.testing.refAllDecls(@import("sysret_test.zig"));
    std.testing.refAllDecls(@import("fpu_test.zig"));
    std.testing.refAllDecls(@import("page_bitmap_test.zig"));
    std.testing.refAllDecls(@import("raw_spinlock_test.zig"));
    std.testing.refAllDecls(@import("lock_order_test.zig"));
    std.testing.refAllDecls(@import("startup_stack_test.zig"));
    std.testing.refAllDecls(@import("cmdline_test.zig"));
    std.testing.refAllDecls(@import("timer_queue_test.zig"));
    std.testing.refAllDecls(@import("random_core_test.zig"));
    std.testing.refAllDecls(@import("meltdown_rule_test.zig"));
}
