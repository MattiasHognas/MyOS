//! Host unit tests for `src/kernel/debug/log_format.zig`.

const std = @import("std");

const log_format = @import("log_format");

test "log format: level and scope prefix" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "info(pmm): 12 MiB free\n",
        log_format.format(&buf, .info, .pmm, "{d} MiB free", .{12}),
    );
    try std.testing.expectEqualStrings(
        "error(nvme): timeout\n",
        log_format.format(&buf, .err, .nvme, "timeout", .{}),
    );
    try std.testing.expectEqualStrings(
        "warning(acpi): x\n",
        log_format.format(&buf, .warn, .acpi, "{s}", .{"x"}),
    );
}

test "log format: default scope has no scope tag" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "debug: hello\n",
        log_format.format(&buf, .debug, .default, "hello", .{}),
    );
}

test "log format: long messages are truncated with a marker" {
    var buf: [16]u8 = undefined;
    const out = log_format.format(&buf, .info, .heap, "{s}", .{"a message that is far too long"});
    try std.testing.expectEqual(buf.len, out.len);
    try std.testing.expect(std.mem.startsWith(u8, out, "info(heap): "));
    try std.testing.expect(std.mem.endsWith(u8, out, log_format.truncated_marker));
}

test "log format: exact fit is not truncated" {
    var buf: ["info: 123\n".len]u8 = undefined;
    try std.testing.expectEqualStrings("info: 123\n", log_format.format(&buf, .info, .default, "123", .{}));
}
