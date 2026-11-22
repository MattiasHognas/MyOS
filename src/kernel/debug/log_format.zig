//! Formatting of kernel log lines.
//!
//! Pure code with no kernel dependencies, so it is also unit tested on the
//! host. The kernel's `std.log` handler (`logFn` in `main.zig`) formats each
//! message with `format` and writes it to the serial port and console.

const std = @import("std");

/// Marker appended when a message does not fit in the buffer.
pub const truncated_marker = "...\n";

/// Format one log line into `buf` and return the used part.
///
/// The line looks like `info(pmm): message\n`; messages in the default scope
/// omit the scope: `info: message\n`. If the line does not fit, it is cut
/// short and ends with `truncated_marker`. `buf` must be at least
/// `truncated_marker.len` bytes long.
pub fn format(
    buf: []u8,
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) []const u8 {
    const prefix = comptime level.asText() ++
        (if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")") ++ ": ";
    var w: std.Io.Writer = .fixed(buf);
    w.print(prefix ++ fmt ++ "\n", args) catch {
        @memcpy(buf[buf.len - truncated_marker.len ..], truncated_marker);
        return buf;
    };
    return w.buffered();
}
