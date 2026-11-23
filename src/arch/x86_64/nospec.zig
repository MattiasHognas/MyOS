//! Keeping the CPU from speculating past bounds checks (Spectre variant 1).
//!
//! A bounds check is a conditional branch, and the CPU guesses which way it
//! goes. While it runs ahead on a wrong guess it can read memory through an
//! index that the check was about to reject; the read is thrown away, but it
//! leaves traces in the cache that a program can measure. So wherever a
//! value from user space is used as an index or an address after a check,
//! the check alone is not enough.
//!
//! Two tools:
//!
//! - `index` clamps an index without a branch: the result is the index if
//!   it is in range and 0 otherwise, computed from the comparison's carry
//!   flag (`cmp`, `sbb`, `and`), which the CPU does not speculate on.
//! - An `lfence` instruction, which lets nothing after it start until
//!   everything before it is done. `user_copy` (`usercopy.zig`) begins with
//!   one, after the range check on the user address.
//!
//! Where they are used: file descriptors index the descriptor table
//! (`syscall.zig`); user addresses and lengths reach memory through
//! `user_copy`. The syscall number is not an index: the dispatcher is a
//! `switch` over scattered numbers, compiled to comparisons.

/// `i` if `i < len`, otherwise 0, computed without a conditional branch.
/// Use it on an index from user space after the ordinary bounds check, so
/// that even a mispredicted check cannot reach outside the array.
pub inline fn index(i: usize, len: usize) usize {
    // cmp sets the carry flag exactly when i < len; sbb turns it into a
    // mask of all ones or all zeroes.
    return asm volatile (
        \\ cmp %[len], %[i]
        \\ sbb %[mask], %[mask]
        \\ and %[mask], %[i]
        : [ret] "={rax}" (-> usize),
        : [i] "{rax}" (i),
          [len] "r" (len),
          [mask] "{rcx}" (@as(usize, 0)),
        : .{ .rcx = true, .cc = true });
}
