//! Subsystem assertions.
//!
//! Unlike `std.debug.assert`, which becomes undefined behaviour in
//! ReleaseFast builds, a failed `check` always panics with the subsystem name
//! and a message (and therefore a backtrace). They can be compiled out with
//! `zig build -Dassertions=false`.

const std = @import("std");
const build_options = @import("build_options");
/// True if assertions are compiled in (`-Dassertions`, default true).
pub const enabled = build_options.assertions;

const panic = @import("panic.zig");

/// Panic with `<subsystem>: assertion failed: <message>` if `ok` is false.
/// `fmt` and `args` format the message; they are only evaluated on failure.
/// The message is cut off after `panic.max_message` bytes.
pub inline fn check(
    comptime subsystem: @EnumLiteral(),
    ok: bool,
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (!enabled) return;
    if (!ok) panic.panicFmt(@tagName(subsystem) ++ ": assertion failed: " ++ fmt, args);
}
