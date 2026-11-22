//! Panic messages formatted in a small buffer.
//!
//! `std.debug.FullPanic` and `std.debug.panic` format their message into a
//! 4 KiB buffer on the stack. That is a quarter of a kernel stack and more
//! than its guard page, so a panic on a nearly full stack could step over the
//! guard (see `kstack.zig` and `scripts/check-frames.sh`). The versions here
//! do the same job with a 256-byte buffer; longer messages are cut off.

const std = @import("std");

/// Longest panic message; the rest is dropped.
pub const max_message = 256;

/// Format a message and panic with it. `ret_addr` is where the backtrace
/// starts. Passes the message to the program's panic handler (`root.panic`).
pub fn format(ret_addr: ?usize, comptime fmt: []const u8, args: anytype) noreturn {
    @branchHint(.cold);
    var buf: [max_message]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(fmt, args) catch {}; // out of space: keep what fits
    std.builtin.panic.call(w.buffered(), ret_addr);
}

/// Like `std.debug.panic`: panic with a formatted message. The backtrace
/// starts at the caller.
pub noinline fn panicFmt(comptime fmt: []const u8, args: anytype) noreturn {
    @branchHint(.cold);
    format(@returnAddress(), fmt, args);
}

/// The panic namespace for a program whose panic handler is `panicFn`, for
/// `pub const panic = Handler(panicFn)` in the root file. Same messages as
/// `std.debug.FullPanic`, formatted with `format`.
pub fn Handler(comptime panicFn: fn ([]const u8, ?usize) noreturn) type {
    return struct {
        pub const call = panicFn;
        pub fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
            @branchHint(.cold);
            format(@returnAddress(), "sentinel mismatch: expected {any}, found {any}", .{ expected, found });
        }
        pub fn unwrapError(err: anyerror) noreturn {
            @branchHint(.cold);
            format(@returnAddress(), "attempt to unwrap error: {s}", .{@errorName(err)});
        }
        pub fn outOfBounds(index: usize, len: usize) noreturn {
            @branchHint(.cold);
            format(@returnAddress(), "index out of bounds: index {d}, len {d}", .{ index, len });
        }
        pub fn startGreaterThanEnd(start: usize, end: usize) noreturn {
            @branchHint(.cold);
            format(@returnAddress(), "start index {d} is larger than end index {d}", .{ start, end });
        }
        pub fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
            @branchHint(.cold);
            format(@returnAddress(), "access of union field '{s}' while field '{s}' is active", .{ @tagName(accessed), @tagName(active) });
        }
        pub fn sliceCastLenRemainder(src_len: usize) noreturn {
            @branchHint(.cold);
            format(@returnAddress(), "slice length '{d}' does not divide exactly into destination elements", .{src_len});
        }
        pub fn reachedUnreachable() noreturn {
            @branchHint(.cold);
            call("reached unreachable code", @returnAddress());
        }
        pub fn unwrapNull() noreturn {
            @branchHint(.cold);
            call("attempt to use null value", @returnAddress());
        }
        pub fn castToNull() noreturn {
            @branchHint(.cold);
            call("cast causes pointer to be null", @returnAddress());
        }
        pub fn incorrectAlignment() noreturn {
            @branchHint(.cold);
            call("incorrect alignment", @returnAddress());
        }
        pub fn invalidErrorCode() noreturn {
            @branchHint(.cold);
            call("invalid error code", @returnAddress());
        }
        pub fn unexpectedErrorCode(err: anyerror) noreturn {
            @branchHint(.cold);
            format(@returnAddress(), "unexpected error code, found error.{s}", .{@errorName(err)});
        }
        pub fn integerOutOfBounds() noreturn {
            @branchHint(.cold);
            call("integer does not fit in destination type", @returnAddress());
        }
        pub fn integerOverflow() noreturn {
            @branchHint(.cold);
            call("integer overflow", @returnAddress());
        }
        pub fn shlOverflow() noreturn {
            @branchHint(.cold);
            call("left shift overflowed bits", @returnAddress());
        }
        pub fn shrOverflow() noreturn {
            @branchHint(.cold);
            call("right shift overflowed bits", @returnAddress());
        }
        pub fn divideByZero() noreturn {
            @branchHint(.cold);
            call("division by zero", @returnAddress());
        }
        pub fn exactDivisionRemainder() noreturn {
            @branchHint(.cold);
            call("exact division produced remainder", @returnAddress());
        }
        pub fn integerPartOutOfBounds() noreturn {
            @branchHint(.cold);
            call("integer part of floating point value out of bounds", @returnAddress());
        }
        pub fn corruptSwitch() noreturn {
            @branchHint(.cold);
            call("switch on corrupt value", @returnAddress());
        }
        pub fn shiftRhsTooBig() noreturn {
            @branchHint(.cold);
            call("shift amount is greater than the type size", @returnAddress());
        }
        pub fn invalidEnumValue() noreturn {
            @branchHint(.cold);
            call("invalid enum value", @returnAddress());
        }
        pub fn forLenMismatch() noreturn {
            @branchHint(.cold);
            call("for loop over objects with non-equal lengths", @returnAddress());
        }
        pub fn copyLenMismatch() noreturn {
            @branchHint(.cold);
            call("source and destination arguments have non-equal lengths", @returnAddress());
        }
        pub fn memcpyAlias() noreturn {
            @branchHint(.cold);
            call("@memcpy arguments alias", @returnAddress());
        }
        pub fn noreturnReturned() noreturn {
            @branchHint(.cold);
            call("'noreturn' function returned", @returnAddress());
        }
        pub fn loadUninstantiableType() noreturn {
            @branchHint(.cold);
            call("attempt to load uninstantiable type", @returnAddress());
        }
    };
}
