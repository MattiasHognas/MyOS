//! Restartable sequences (`rseq`), as Linux has them.
//!
//! A thread registers a 32-byte area of its own memory (`struct rseq`):
//! the kernel keeps the number of the CPU the thread runs on in it
//! (`cpu_id_start`, `cpu_id`), which glibc 2.35 and later read for
//! `sched_getcpu` instead of making a call. And the thread may name a
//! critical section in it (`rseq_cs`: start, length, where to go
//! instead): if the thread is preempted, moved to another CPU or gets a
//! signal while inside, it does not go on where it was but at the
//! section's abort address. Per-CPU data structures (tcmalloc's caches,
//! for one) are built on that.
//!
//! The work happens on the way back to the program (`atReturn`), when the
//! thread has been switched onto a CPU since it last ran there
//! (`Thread.rseq_resume`, set by the scheduler), and before a signal
//! handler's frame is built (`beforeSignal`), as on Linux. The program's
//! memory is read and written with the user copies, so a bad area or
//! section ends the process with `SIGSEGV`, as on Linux.

const std = @import("std");

const uaccess = @import("uaccess.zig");
const thread = @import("thread.zig");
const percpu = @import("../arch/x86_64/percpu.zig");

/// The size of the area a thread registers (the original `struct rseq`).
pub const AREA_SIZE = 32;
/// `rseq`'s flag to take the registration back.
pub const FLAG_UNREGISTER = 1;
/// What `cpu_id` says while the area is not registered.
pub const CPU_ID_UNINITIALIZED: u32 = 0xFFFF_FFFF;

const OFF_CPU_ID_START = 0;
const OFF_CPU_ID = 4;
const OFF_RSEQ_CS = 8;

/// A critical section as the program describes it (`struct rseq_cs`).
const Section = extern struct {
    version: u32,
    flags: u32,
    start_ip: u64,
    post_commit_offset: u64,
    abort_ip: u64,
};

/// A thread's registration.
pub const Registration = struct {
    /// The area's user address, 0 if none.
    area: u64 = 0,
    /// The signature that must precede every abort address.
    sig: u32 = 0,
};

pub const Error = error{ Invalid, Busy, Fault };

/// `rseq(area, len, flags, sig)` for the calling thread.
pub fn register(t: *thread.Thread, area: u64, len: u32, flags: u32, sig: u32) Error!void {
    if (flags & FLAG_UNREGISTER != 0) {
        if (flags != FLAG_UNREGISTER) return error.Invalid;
        if (t.rseq.area != area or len != AREA_SIZE) return error.Invalid;
        if (t.rseq.sig != sig) return error.Invalid; // Linux: EPERM, mapped by the caller
        writeU32(area + OFF_CPU_ID, CPU_ID_UNINITIALIZED) catch return error.Fault;
        t.rseq = .{};
        t.rseq_resume = false;
        return;
    }
    if (flags != 0) return error.Invalid;
    if (t.rseq.area != 0) {
        // The same registration again is refused as busy; another one as wrong.
        if (t.rseq.area == area and len == AREA_SIZE and t.rseq.sig == sig) return error.Busy;
        return error.Invalid;
    }
    if (area == 0 or area % AREA_SIZE != 0 or len != AREA_SIZE) return error.Invalid;
    // The area must be writable now: the CPU number goes in at once.
    writeCpu(area, percpu.current().id) catch return error.Fault;
    t.rseq = .{ .area = area, .sig = sig };
    t.rseq_resume = false;
}

/// The user frame's instruction pointer, whichever frame it is.
pub const Ip = struct { ptr: *u64 };

/// On the way back to the program: if the thread was switched onto a CPU
/// since it last came this way, abort a critical section it was in and
/// tell it the CPU. False if the area or section cannot be used: the
/// caller ends the process (`SIGSEGV`).
pub fn atReturn(t: *thread.Thread, ip: Ip) bool {
    if (!t.rseq_resume) return true;
    t.rseq_resume = false;
    if (t.rseq.area == 0) return true;
    fixup(t, ip) catch return false;
    writeCpu(t.rseq.area, percpu.current().id) catch return false;
    return true;
}

/// Before a signal handler's frame is built from the interrupted context:
/// a critical section the thread was in is aborted, so that the handler
/// returns to the abort address. False as for `atReturn`.
pub fn beforeSignal(t: *thread.Thread, ip: Ip) bool {
    if (t.rseq.area == 0) return true;
    fixup(t, ip) catch return false;
    return true;
}

/// If `rseq_cs` names a section `ip` is in, move `ip` to its abort
/// address; either way `rseq_cs` is cleared, as Linux does.
fn fixup(t: *thread.Thread, ip: Ip) error{Fault}!void {
    var cs_addr: u64 = undefined;
    uaccess.copyFromUser(std.mem.asBytes(&cs_addr), t.rseq.area + OFF_RSEQ_CS) catch return error.Fault;
    if (cs_addr == 0) return;
    var cs: Section = undefined;
    uaccess.copyFromUser(std.mem.asBytes(&cs), cs_addr) catch return error.Fault;
    if (cs.version != 0) return error.Fault;
    const end = std.math.add(u64, cs.start_ip, cs.post_commit_offset) catch return error.Fault;
    // The abort address must lie outside the section.
    if (cs.abort_ip >= cs.start_ip and cs.abort_ip < end) return error.Fault;
    const in_section = ip.ptr.* >= cs.start_ip and ip.ptr.* < end;
    if (in_section) {
        if (cs.abort_ip < 4) return error.Fault;
        var sig: u32 = undefined;
        uaccess.copyFromUser(std.mem.asBytes(&sig), cs.abort_ip - 4) catch return error.Fault;
        if (sig != t.rseq.sig) return error.Fault;
        ip.ptr.* = cs.abort_ip;
    }
    const zero: u64 = 0;
    uaccess.copyToUser(t.rseq.area + OFF_RSEQ_CS, std.mem.asBytes(&zero)) catch return error.Fault;
}

fn writeCpu(area: u64, cpu_id: usize) error{Fault}!void {
    const id: u32 = @intCast(cpu_id);
    const both = [2]u32{ id, id }; // cpu_id_start, cpu_id
    uaccess.copyToUser(area + OFF_CPU_ID_START, std.mem.sliceAsBytes(&both)) catch return error.Fault;
}

fn writeU32(addr: u64, value: u32) error{Fault}!void {
    uaccess.copyToUser(addr, std.mem.asBytes(&value)) catch return error.Fault;
}
