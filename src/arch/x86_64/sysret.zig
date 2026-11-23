//! Is it safe to return to user mode with this register state, and how?
//!
//! `sysretq` is the fast way back from a syscall, but it is not safe for every
//! state: on Intel CPUs it raises #GP *in ring 0, on the user's stack pointer*
//! when the return address is not canonical, and it cannot restore RF or
//! deliver a pending single-step trap the way `iretq` does. `iretq` itself
//! faults in ring 0 for a non-canonical address or bad selectors. So the
//! syscall exit path asks `classify` for every return. Today the saved state
//! always comes straight from the `syscall` instruction; once `mmap`,
//! signals or `sigreturn` let a program choose it, this check is what keeps
//! a crafted state from crashing the kernel.
//!
//! No kernel dependencies: tested on the host.

/// First address above user space (the non-canonical hole starts here).
pub const USER_END: u64 = 0x0000_8000_0000_0000;

/// Ring 3 code and stack selectors (`gdt.USER_CODE`, `gdt.USER_DATA`).
pub const USER_CS: u64 = 0x20 | 3;
pub const USER_SS: u64 = 0x18 | 3;

pub const FLAG_TF: u64 = 1 << 8;
pub const FLAG_IF: u64 = 1 << 9;
pub const FLAG_RF: u64 = 1 << 16;

/// RFLAGS bits a user program may have set: the arithmetic flags, TF, DF,
/// RF, AC and ID. Everything else (IOPL, NT, VM, VIF, VIP, reserved bits) is
/// cleared on the way out.
pub const USER_FLAGS: u64 = 0x1 | 0x4 | 0x10 | 0x40 | 0x80 | FLAG_TF | 0x400 | 0x800 | FLAG_RF | (1 << 18) | (1 << 21);

/// The flags a return to user mode may load, given the saved value: only
/// user-settable bits, interrupts always on, the always-one bit 1 set.
pub fn sanitizeFlags(rflags: u64) u64 {
    return (rflags & USER_FLAGS) | FLAG_IF | 0x2;
}

/// How to return to user mode.
pub const Return = enum(u8) {
    /// `sysretq`: the fast path.
    sysret = 0,
    /// `iretq`: restores everything, including RF and a pending trap.
    iret = 1,
    /// No instruction can return to this state without faulting in ring 0:
    /// the process must be killed instead.
    invalid = 2,
};

/// Decide how to return to user mode at `rip` with `rflags` (already passed
/// through `sanitizeFlags`), code selector `cs` and stack selector `ss`.
///
/// The stack pointer needs no check: both instructions load any value, and a
/// bad one faults in ring 3 on first use.
pub fn classify(rip: u64, rflags: u64, cs: u64, ss: u64) Return {
    if (rip >= USER_END) return .invalid; // non-canonical, or kernel memory
    if (cs != USER_CS or ss != USER_SS) return .invalid;
    if (rflags & (FLAG_TF | FLAG_RF) != 0) return .iret;
    return .sysret;
}
