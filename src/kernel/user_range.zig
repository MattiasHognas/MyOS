//! Validation of address ranges that come from user space.
//!
//! User space is the lower canonical half of the address space, so a range
//! that passes `valid` is canonical and can never reach kernel memory. Whether
//! its pages are mapped is found out by the copy itself (`uaccess.zig`). This
//! module has no kernel dependencies, so it is also tested on the host.

/// First address above the user half of the address space.
pub const USER_END: u64 = 0x0000_8000_0000_0000;

/// Return true if the `len` bytes at `addr` lie entirely inside user space.
///
/// The check cannot overflow: `addr + len` is never computed. An empty range
/// is valid anywhere in user space, including directly at its end.
pub fn valid(addr: u64, len: u64) bool {
    return addr <= USER_END and len <= USER_END - addr;
}
