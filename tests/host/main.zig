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
}
