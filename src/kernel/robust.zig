//! Robust futexes: a mutex whose owner dies is given up for it.
//!
//! A C library registers, for each thread, the head of a list of the
//! robust mutexes it holds (`set_robust_list`); the list is the thread's
//! own memory and changes as it locks and unlocks. When the thread ends,
//! the kernel walks it (`release`): each futex word that still names the
//! thread as its owner gets `FUTEX_OWNER_DIED`, keeping `FUTEX_WAITERS`,
//! and one waiter is woken, who then takes the mutex with `EOWNERDEAD`.
//! That is what .NET's named `Mutex` and `pthread_mutexattr_setrobust`
//! rely on. The entry a thread was in the middle of adding or removing
//! (`list_op_pending`) counts too. As on Linux, at most 2048 entries are
//! looked at, so a list that loops cannot hold the thread up.
//!
//! The word is changed with an atomic compare-and-swap in the program's
//! memory, as another thread may be setting `FUTEX_WAITERS` at the same
//! moment.

const std = @import("std");

const futex = @import("futex.zig");
const proc = @import("process.zig");
const thread = @import("thread.zig");
const uaccess = @import("uaccess.zig");
const user_memory = @import("user_memory.zig");
const usercopy = @import("../arch/x86_64/usercopy.zig");
const user_range = @import("user_range.zig");

pub const FUTEX_WAITERS: u32 = 0x8000_0000;
pub const FUTEX_OWNER_DIED: u32 = 0x4000_0000;
pub const FUTEX_TID_MASK: u32 = 0x3FFF_FFFF;

/// Most entries looked at (Linux's `ROBUST_LIST_LIMIT`).
const LIMIT = 2048;

fn readU64(addr: u64) ?u64 {
    var v: u64 = undefined;
    uaccess.copyFromUser(std.mem.asBytes(&v), addr) catch return null;
    return v;
}

/// Give up the robust mutexes the calling thread, which is ending, still
/// holds. Its process's memory is still there.
pub fn release(p: *proc.Process) void {
    const me = thread.current();
    const head = me.robust_head;
    if (head == 0) return;
    me.robust_head = 0;
    const futex_offset: i64 = @bitCast(readU64(head + 8) orelse return);
    const pending = (readU64(head + 16) orelse 0) & ~@as(u64, 1);
    var entry = (readU64(head) orelse return) & ~@as(u64, 1); // bit 0: a PI mutex
    var seen: usize = 0;
    while (entry != head and entry != 0 and seen < LIMIT) : (seen += 1) {
        // The next one first: handling this one may let it be freed.
        const next = (readU64(entry) orelse break) & ~@as(u64, 1);
        if (entry != pending) releaseOne(p, entry, futex_offset, me.id);
        entry = next;
    }
    if (pending != 0) releaseOne(p, pending, futex_offset, me.id);
}

/// The futex word of the list entry at `entry`: if `tid` owns it, mark
/// its owner dead and wake one waiter.
fn releaseOne(p: *proc.Process, entry: u64, offset: i64, tid: u64) void {
    const addr_signed = @as(i64, @bitCast(entry)) +% offset;
    const addr: u64 = @bitCast(addr_signed);
    if (addr % 4 != 0 or !user_range.valid(addr, 4)) return;
    var tries: usize = 0;
    while (tries < 16) : (tries += 1) {
        var word: u32 = undefined;
        uaccess.copyFromUser(std.mem.asBytes(&word), addr) catch return;
        if (word & FUTEX_TID_MASK != @as(u32, @truncate(tid))) return; // not ours (any more)
        const new = (word & FUTEX_WAITERS) | FUTEX_OWNER_DIED;
        const old = usercopy.cmpxchgUser32(addr, word, new) orelse return;
        if (old != word) continue; // changed meanwhile: look again
        // Whether anyone waits or not, one is woken if there is one (a
        // waiter may be about to set the bit): both kinds of key.
        const own = futex.privateKey(p, addr);
        _ = futex.wake(own, 1, futex.ANY);
        const shared = user_memory.futexKey(p, addr, false);
        if (!std.meta.eql(shared, own)) _ = futex.wake(shared, 1, futex.ANY);
        return;
    }
}
