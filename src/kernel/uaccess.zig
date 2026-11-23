//! Safe access to user memory: the only way the kernel reads or writes
//! memory named by a user-space pointer.
//!
//! A copy first checks that the whole range lies in user space
//! (`user_range.valid`), then runs the fault-tolerant copy routine of the arch
//! layer. Pages that are unmapped, or read-only for `copyToUser`, make the
//! copy fail with `error.Fault` instead of crashing the kernel. Syscalls copy
//! user data into kernel buffers with these functions and never keep a user
//! pointer around.

const std = @import("std");

const usercopy = @import("../arch/x86_64/usercopy.zig");
const user_range = @import("user_range.zig");

/// The user range is outside user space, not mapped, or not writable.
pub const Error = error{Fault};

/// Copy `dst.len` bytes from the user address `src` into `dst`.
///
/// On `error.Fault`, `dst` may have been partly overwritten. The copy uses
/// the current address space, so it must be called on a thread of the process
/// that owns the pointer.
pub fn copyFromUser(dst: []u8, src: u64) Error!void {
    if (!user_range.valid(src, dst.len)) return error.Fault;
    if (!usercopy.copy(@intFromPtr(dst.ptr), src, dst.len)) return error.Fault;
}

/// Copy `src` to the user address `dst`.
///
/// On `error.Fault`, the bytes before the faulting page may already have
/// been written. Same address-space rule as `copyFromUser`.
pub fn copyToUser(dst: u64, src: []const u8) Error!void {
    if (!user_range.valid(dst, src.len)) return error.Fault;
    if (!usercopy.copy(dst, @intFromPtr(src.ptr), src.len)) return error.Fault;
}

/// Why `copyStringFromUser` failed.
pub const StringError = error{
    /// Part of the string is outside user space or not mapped.
    Fault,
    /// No NUL within the buffer.
    TooLong,
};

const PAGE_SIZE = 4096;

/// Copy the NUL-terminated string at the user address `src` into `dst`,
/// including the NUL, and return its length without it.
///
/// The string is read up to the end of one page at a time, so a string that
/// ends just before an unmapped page is not a fault. `error.TooLong` means
/// `dst` filled up before a NUL was found.
pub fn copyStringFromUser(dst: []u8, src: u64) StringError!usize {
    var done: usize = 0;
    while (done < dst.len) {
        const addr = std.math.add(u64, src, done) catch return error.Fault;
        const in_page: usize = @intCast(PAGE_SIZE - addr % PAGE_SIZE);
        const part = dst[done..][0..@min(in_page, dst.len - done)];
        copyFromUser(part, addr) catch return error.Fault;
        if (std.mem.indexOfScalar(u8, part, 0)) |i| return done + i;
        done += part.len;
    }
    return error.TooLong;
}
