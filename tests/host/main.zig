//! Root of the native host test binary (`zig build test-host`).

const std = @import("std");

// Import every test file from this root. Zig discovers their test declarations.
test {
    std.testing.refAllDecls(@import("vfs_test.zig"));
}
