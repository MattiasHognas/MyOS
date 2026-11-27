//! Signals: sending them, and delivering them on the way back to user
//! mode, as Linux does.
//!
//! A signal is sent to a thread (`tgkill`, a fault) or to a process
//! (`kill`, Ctrl+C), and is pending there until a thread that does not
//! block it comes back from the kernel: after a system call, or after an
//! interrupt or exception taken in user mode (`atSyscallReturn`,
//! `atInterruptReturn`). Then it is ignored, ends the process, or is
//! handed to the handler the program installed with `rt_sigaction`: the
//! thread's registers and signal mask are saved in a frame on its stack
//! (`signal_frame.zig`) and it goes on in the handler, which ends with
//! `rt_sigreturn` to put them back.
//!
//! A thread waiting in the kernel when a signal comes for it stops
//! waiting (`thread.dying` says so), and its system call returns `EINTR`;
//! with `SA_RESTART`, or if no handler ran, the call is made again instead.
//!
//! A fault in user mode (a bad pointer, a division by zero, an invalid
//! instruction) becomes `SIGSEGV`, `SIGBUS`, `SIGFPE`, `SIGILL` or
//! `SIGTRAP` for a program that handles it, and kills the program, as
//! before, for one that does not.
//!
//! What is not there yet: stopping and continuing (`SIGSTOP`, `SIGTSTP`
//! and `SIGCONT` are ignored: there is no job control), queued real-time
//! signals (a second one sent before the first is delivered is lost, as
//! with the standard signals), signals between processes (`kill` reaches
//! the caller's own process only), and `siginfo` values beyond the sender
//! and the faulting address.

const std = @import("std");
const root = @import("root");

const abi = @import("abi");
const arch_syscall = @import("../arch/x86_64/syscall.zig");
const fpu = @import("../arch/x86_64/fpu.zig");
const idt = @import("../arch/x86_64/idt.zig");
const sysret = @import("../arch/x86_64/sysret.zig");
const nospec = @import("../arch/x86_64/nospec.zig");
const proc = @import("process.zig");
const sf = @import("signal_frame.zig");
const thread = @import("thread.zig");
const heap = @import("heap.zig");
const user_memory = @import("user_memory.zig");
const uaccess = @import("uaccess.zig");

const Process = proc.Process;
const Thread = thread.Thread;

/// Signals that cannot be blocked, caught or ignored.
pub const UNBLOCKABLE: u64 = bit(abi.SIGKILL) | bit(abi.SIGSTOP);

pub fn bit(sig: u32) u64 {
    return @as(u64, 1) << @intCast(sig - 1);
}

pub const SIG = struct {
    pub const HUP = 1;
    pub const INT = 2;
    pub const QUIT = 3;
    pub const ILL = 4;
    pub const TRAP = 5;
    pub const ABRT = 6;
    pub const BUS = 7;
    pub const FPE = 8;
    pub const KILL = 9;
    pub const USR1 = 10;
    pub const SEGV = 11;
    pub const USR2 = 12;
    pub const PIPE = 13;
    pub const ALRM = 14;
    pub const TERM = 15;
    pub const CHLD = 17;
    pub const CONT = 18;
    pub const STOP = 19;
    pub const TSTP = 20;
    pub const TTIN = 21;
    pub const TTOU = 22;
    pub const URG = 23;
    pub const WINCH = 28;
};

/// `sa_flags`.
pub const SA = struct {
    pub const NOCLDSTOP = 0x1;
    pub const SIGINFO = 0x4;
    pub const ONSTACK = 0x0800_0000;
    pub const RESTART = 0x1000_0000;
    pub const NODEFER = 0x4000_0000;
    pub const RESETHAND = 0x8000_0000;
    pub const RESTORER = 0x0400_0000;
};

/// `si_code` values.
pub const SI = struct {
    pub const USER: i32 = 0;
    pub const KERNEL: i32 = 0x80;
    pub const TKILL: i32 = -6;
};
pub const SEGV_MAPERR: i32 = 1;
pub const SEGV_ACCERR: i32 = 2;
pub const BUS_ADRERR: i32 = 2;
pub const ILL_ILLOPN: i32 = 2;
pub const FPE_INTDIV: i32 = 1;
pub const FPE_FLTINV: i32 = 7;
pub const TRAP_BRKPT: i32 = 1;
pub const TRAP_TRACE: i32 = 2;

const SIG_DFL = 0;
const SIG_IGN = 1;

/// What a signal does when nobody catches it.
const Default = enum { terminate, ignore };

fn defaultAction(sig: u32) Default {
    return switch (sig) {
        SIG.CHLD, SIG.URG, SIG.WINCH => .ignore,
        // No job control: stopping and continuing do nothing.
        SIG.CONT, SIG.STOP, SIG.TSTP, SIG.TTIN, SIG.TTOU => .ignore,
        else => .terminate,
    };
}

/// The exit status of a process a signal ended: 128 + the signal, as a
/// shell reports it.
pub fn killedStatus(sig: u32) u64 {
    return 128 + sig;
}

/// The signal a CPU exception from ring 3 stands for (as `fault` sends).
pub fn forVector(vector: u64) u32 {
    return switch (vector) {
        0, 16, 19 => SIG.FPE,
        1, 3 => SIG.TRAP,
        6 => SIG.ILL,
        12, 17 => SIG.BUS,
        else => SIG.SEGV,
    };
}

fn actionOf(p: *Process, sig: u32) abi.SigAction {
    const held = p.signal_lock.acquire();
    defer p.signal_lock.release(held);
    return p.signal_actions[nospec.index(sig - 1, abi.NSIG)];
}

/// Whether `sig` would be thrown away on arrival: ignored, and nothing to
/// wake anyone for.
fn ignored(p: *Process, sig: u32) bool {
    if (sig == SIG.KILL or sig == SIG.STOP) return false;
    const action = actionOf(p, sig);
    return action.handler == SIG_IGN or (action.handler == SIG_DFL and defaultAction(sig) == .ignore);
}

// ---------------------------------------------------------------------------
// Sending

/// Send `sig` (1-64) to the process `p` as a whole: the first of its
/// threads that does not block it will take it. `SIGKILL` ends it at once.
/// With the process tree's lock held (`proc.signalProcess` takes it),
/// which keeps the threads from going meanwhile; callable from interrupt
/// handlers (Ctrl+C).
pub fn sendProcessLocked(p: *Process, sig: u32) void {
    if (sig == SIG.KILL) return proc.requestKillLocked(p, sig);
    if (ignored(p, sig)) return;
    _ = p.signal_pending.fetchOr(bit(sig), .acq_rel);
    // Wake a thread that may take it: one that does not block it, if
    // there is one (it may be waiting in the kernel, or running a program
    // on another CPU, which is interrupted to come through the kernel).
    var t = p.thread_list;
    while (t) |one| : (t = one.proc_next) {
        if (one.signal_mask & bit(sig) != 0) continue;
        thread.interrupt(one);
        return;
    }
}

/// Send `sig` to the thread `t` of the process `p` (`tgkill`), with the
/// process tree's lock held (`proc.withThread`).
pub fn sendThreadLocked(p: *Process, t: *Thread, sig: u32) void {
    if (sig == SIG.KILL) return proc.requestKillLocked(p, sig);
    if (ignored(p, sig)) return;
    _ = t.signal_pending.fetchOr(bit(sig), .acq_rel);
    thread.interrupt(t);
}

/// Whether the calling thread has a signal it does not block waiting for
/// it: what makes it stop waiting in the kernel (`thread.dying`).
pub fn pending(t: *const Thread) bool {
    const p = t.process orelse return false;
    const bits = t.signal_pending.load(.acquire) | p.signal_pending.load(.acquire);
    return bits & ~t.signal_mask != 0;
}

/// The signals pending for the calling thread, blocked ones included
/// (`rt_sigpending`).
pub fn pendingSet(t: *const Thread) u64 {
    const p = t.process orelse return 0;
    return t.signal_pending.load(.acquire) | p.signal_pending.load(.acquire);
}

/// Take the next signal for `t`: the lowest-numbered one it does not
/// block, its own before its process's. Null if there is none.
fn take(t: *Thread, p: *Process) ?u32 {
    while (true) {
        const mine = t.signal_pending.load(.acquire) & ~t.signal_mask;
        if (mine != 0) {
            const sig: u32 = @ctz(mine) + 1;
            if (t.signal_pending.fetchAnd(~bit(sig), .acq_rel) & bit(sig) != 0) return sig;
            continue;
        }
        const shared = p.signal_pending.load(.acquire) & ~t.signal_mask;
        if (shared == 0) return null;
        const sig: u32 = @ctz(shared) + 1;
        // Another thread may take it first.
        if (p.signal_pending.fetchAnd(~bit(sig), .acq_rel) & bit(sig) != 0) return sig;
    }
}

// ---------------------------------------------------------------------------
// Faults

/// A fault in user mode, which a program may handle: queue its signal for
/// the faulting thread with what `siginfo` and `sigcontext` say about it,
/// and return true; the signal is delivered on the way back
/// (`atInterruptReturn`). False if the program does not handle it (no
/// handler, ignored, or blocked: a fault cannot be put off), and the
/// caller kills it as before.
pub fn fault(vector: u64, error_code: u64, cr2: u64, rip: u64, past_end: bool) bool {
    const t = thread.current();
    const p = t.process orelse return false;
    const info: struct { sig: u32, code: i32, addr: u64 } = switch (vector) {
        0 => .{ .sig = SIG.FPE, .code = FPE_INTDIV, .addr = rip },
        1 => .{ .sig = SIG.TRAP, .code = TRAP_TRACE, .addr = rip },
        3 => .{ .sig = SIG.TRAP, .code = TRAP_BRKPT, .addr = rip },
        6 => .{ .sig = SIG.ILL, .code = ILL_ILLOPN, .addr = rip },
        13 => .{ .sig = SIG.SEGV, .code = SI.KERNEL, .addr = 0 },
        14 => if (past_end)
            .{ .sig = SIG.BUS, .code = BUS_ADRERR, .addr = cr2 }
        else
            .{ .sig = SIG.SEGV, .code = if (error_code & 1 != 0 or user_memory.isMapped(p, cr2)) SEGV_ACCERR else SEGV_MAPERR, .addr = cr2 },
        12, 17 => .{ .sig = SIG.BUS, .code = BUS_ADRERR, .addr = rip },
        16, 19 => .{ .sig = SIG.FPE, .code = FPE_FLTINV, .addr = rip },
        else => .{ .sig = SIG.SEGV, .code = SI.KERNEL, .addr = 0 },
    };
    if (t.signal_mask & bit(info.sig) != 0) return false;
    const action = actionOf(p, info.sig);
    if (action.handler == SIG_DFL or action.handler == SIG_IGN) return false;
    // A second fault while the frame for the first is being written
    // would come here again: the first's frame is what failed.
    if (t.signal_fault != null) return false;
    t.signal_fault = sf.SigInfo.fromFault(info.sig, info.code, info.addr);
    t.signal_fault_regs = .{ .err = error_code, .trapno = vector, .cr2 = if (vector == 14) cr2 else 0 };
    _ = t.signal_pending.fetchOr(bit(info.sig), .acq_rel);
    return true;
}

// ---------------------------------------------------------------------------
// Delivery

/// The registers a thread returns to user mode with, whichever way it
/// entered the kernel.
const Regs = union(enum) {
    syscall: *arch_syscall.Frame,
    interrupt: *idt.Frame,

    fn context(self: Regs) sf.Context {
        return switch (self) {
            inline else => |f| .{
                .r8 = f.r8,
                .r9 = f.r9,
                .r10 = f.r10,
                .r11 = f.r11,
                .r12 = f.r12,
                .r13 = f.r13,
                .r14 = f.r14,
                .r15 = f.r15,
                .rdi = f.rdi,
                .rsi = f.rsi,
                .rbp = f.rbp,
                .rbx = f.rbx,
                .rdx = f.rdx,
                .rax = f.rax,
                .rcx = f.rcx,
                .rsp = f.rsp,
                .rip = f.rip,
                .rflags = f.rflags,
                .cs = @truncate(f.cs),
                .ss = @truncate(f.ss),
            },
        };
    }

    /// Load the registers of `c`. Selectors are always user mode's,
    /// whatever `c` says; the flags and RIP are checked on the way out
    /// (`sysret.zig`), as for any return.
    fn load(self: Regs, c: sf.Context) void {
        switch (self) {
            inline else => |f| {
                f.r8 = c.r8;
                f.r9 = c.r9;
                f.r10 = c.r10;
                f.r11 = c.r11;
                f.r12 = c.r12;
                f.r13 = c.r13;
                f.r14 = c.r14;
                f.r15 = c.r15;
                f.rdi = c.rdi;
                f.rsi = c.rsi;
                f.rbp = c.rbp;
                f.rbx = c.rbx;
                f.rdx = c.rdx;
                f.rax = c.rax;
                f.rcx = c.rcx;
                f.rsp = c.rsp;
                f.rip = c.rip;
                f.rflags = sysret.sanitizeFlags(c.rflags);
                f.cs = sysret.USER_CS;
                f.ss = sysret.USER_SS;
            },
        }
    }
};

/// What the system call that is returning was, for restarting it.
const Syscall = struct {
    number: u64,
};

/// Calls that `SA_RESTART` makes again when a handler interrupted them;
/// the rest return `EINTR`, as on Linux (`poll`, `nanosleep` and the
/// like never restart after a handler).
fn restartable(number: u64) bool {
    return switch (number) {
        abi.Sys.read, abi.Sys.readv, abi.Sys.write, abi.Sys.writev, abi.Sys.pread64, abi.Sys.pwrite64, abi.Sys.ioctl, abi.Sys.futex, abi.Sys.myos_run, abi.Sys.open, abi.Sys.openat => true,
        else => false,
    };
}

/// Calls that wait for a signal and so end with one in every case.
fn neverRestarted(number: u64) bool {
    return number == abi.Sys.rt_sigsuspend;
}

/// On the way back from a system call: deliver what is pending, and make
/// an interrupted call again where that is what should happen. Returns
/// true if the registers changed in a way only `iretq` restores.
pub fn atSyscallReturn(f: *arch_syscall.Frame, number: u64) bool {
    // `rt_sigreturn` has put back a whole context already.
    if (number == abi.Sys.rt_sigreturn) return true;
    const t = thread.current();
    const p = t.process orelse return false;
    const interrupted = f.rax == abi.err(.INTR) and !neverRestarted(number);
    const outcome = deliverNext(t, p, .{ .syscall = f }, if (interrupted) number else null);
    // `rt_sigsuspend` with nothing handled: its mask is undone here; with
    // a handler, the frame took the saved one.
    if (outcome != .handled) {
        if (t.signal_saved_mask) |m| {
            t.signal_mask = m;
            t.signal_saved_mask = null;
        }
    }
    switch (outcome) {
        .none, .ignored => {
            // Interrupted, and no handler ran: the call is made again,
            // as if nothing had happened.
            if (interrupted) restart(f, number);
            return outcome == .ignored and interrupted;
        },
        .handled => return true,
    }
}

/// Back to the `syscall` instruction, with its number in RAX again.
fn restart(f: *arch_syscall.Frame, number: u64) void {
    f.rax = number;
    f.rip -= 2; // `syscall` is two bytes
    f.rcx = f.rip;
}

/// On the way back to user mode from an interrupt or exception.
pub fn atInterruptReturn(f: *idt.Frame) void {
    const t = thread.current();
    const p = t.process orelse return;
    if (!pending(t)) return;
    _ = deliverNext(t, p, .{ .interrupt = f }, null);
}

const Outcome = enum { none, ignored, handled };

/// Deliver the next signal for `t`, if there is one: ignore it, end the
/// process for it, or set the thread up to run its handler. `interrupted`
/// is the number of a system call that was cut short for it, to be made
/// again first if the handler has `SA_RESTART`.
fn deliverNext(t: *Thread, p: *Process, regs: Regs, interrupted: ?u64) Outcome {
    var outcome: Outcome = .none;
    while (take(t, p)) |sig| {
        const action = actionOf(p, sig);
        const from_fault = t.signal_fault != null and t.signal_fault.?.signo == @as(i32, @intCast(sig));
        if (action.handler == SIG_IGN or (action.handler == SIG_DFL and defaultAction(sig) == .ignore)) {
            outcome = .ignored;
            continue;
        }
        if (action.handler == SIG_DFL) {
            if (from_fault) t.signal_fault = null;
            proc.exitBySignal(sig);
        }
        // A handler. An interrupted call is made again when it returns, if
        // the handler asks for that.
        if (interrupted) |number| {
            switch (regs) {
                .syscall => |f| if (action.flags & SA.RESTART != 0 and restartable(number)) restart(f, number),
                .interrupt => {},
            }
        }
        const info = if (from_fault) t.signal_fault.? else sf.SigInfo.fromProcess(sig, SI.USER, @intCast(p.pid), 0);
        const fault_regs = if (from_fault) t.signal_fault_regs else @TypeOf(t.signal_fault_regs){};
        t.signal_fault = null;
        setUpHandler(t, p, regs, sig, action, info, fault_regs) catch |e| {
            // No room for the frame, a stack that cannot be written, a
            // handler with nowhere to return to: the program cannot be
            // told, and dies of it, as on Linux.
            const why = switch (e) {
                error.NoRestorer => "a handler without SA_RESTORER",
                error.NoRoom => "no room on its stack for a signal frame",
                else => "a signal frame that cannot be written",
            };
            root.print("\n*** thread {d} ({s}): {s} for signal {d}, killed\n", .{ thread.id(), p.name, why, sig });
            proc.exitForFault(SIG.SEGV);
        };
        return .handled;
    }
    return outcome;
}

/// Most bytes of FP state a frame carries: the largest save area and the
/// second magic word behind it.
const FP_MAX = fpu.MAX_AREA_SIZE + 4;

fn setUpHandler(t: *Thread, p: *Process, regs: Regs, sig: u32, action: abi.SigAction, info: sf.SigInfo, fault_regs: anytype) !void {
    if (action.flags & SA.RESTORER == 0 or action.restorer == 0) return error.NoRestorer;
    const old_mask = t.signal_saved_mask orelse t.signal_mask;
    t.signal_saved_mask = null;
    var ctx = regs.context();
    ctx.err = fault_regs.err;
    ctx.trapno = fault_regs.trapno;
    ctx.cr2 = fault_regs.cr2;
    ctx.oldmask = old_mask;

    // The FP state as it is now, which the handler is not to see.
    const xsave = fpu.currentMode() == .xsave;
    const area_size = fpu.areaSize();
    const fp_size: u64 = if (xsave) area_size + 4 else area_size;
    const area_ptr = t.fpuArea() orelse return error.NoFpArea;
    fpu.saveCurrent(area_ptr);
    // The FP image and the frame are made on the heap: together 3 KiB,
    // too much for a kernel stack frame.
    // (A copy only: the save instructions work on the thread's own area,
    // which is aligned as they need; the heap gives 16 bytes, which is
    // what the frame's fields need.)
    const fp_slot = std.mem.alignForward(usize, FP_MAX, 16);
    const block = try heap.allocator.alloc(u8, fp_slot + @sizeOf(sf.Frame));
    defer heap.allocator.free(block);
    const fp_copy = block[0..FP_MAX];
    const frame: *sf.Frame = @ptrCast(@alignCast(block[fp_slot..].ptr));
    @memcpy(fp_copy[0..area_size], area_ptr[0..area_size]);
    if (xsave) sf.markXsave(fp_copy[0..fp_size], @intCast(area_size), fpu.enabledFeatures());

    const alt: sf.Stack = .{ .sp = t.signal_stack.sp, .flags = t.signal_stack.flags, .size = t.signal_stack.size };
    const at = try sf.place(ctx.rsp, action.flags & SA.ONSTACK != 0, alt, fp_size);
    ctx.fpstate = at.fpstate;

    frame.* = .{
        .pretcode = action.restorer,
        .uc = .{
            .flags = (if (xsave) @as(u64, sf.UC_FP_XSTATE) else 0) | sf.UC_SIGCONTEXT_SS | sf.UC_STRICT_RESTORE_SS,
            .stack = .{
                .sp = alt.sp,
                .size = alt.size,
                .flags = if (at.on_alt_stack) abi.SS.ONSTACK else alt.flags,
            },
            .mcontext = ctx,
            .sigmask = old_mask,
        },
        .info = info,
    };
    try uaccess.copyToUser(at.fpstate, fp_copy[0..fp_size]);
    try uaccess.copyToUser(at.frame, std.mem.asBytes(frame));

    // The handler: its arguments, a clean FP state, and the signal mask
    // with what it asked to block, and the signal itself unless it said
    // otherwise.
    var mask = old_mask | (action.mask & ~UNBLOCKABLE);
    if (action.flags & SA.NODEFER == 0) mask |= bit(sig);
    t.signal_mask = mask & ~UNBLOCKABLE;
    if (action.flags & SA.RESETHAND != 0) {
        const held = p.signal_lock.acquire();
        defer p.signal_lock.release(held);
        p.signal_actions[nospec.index(sig - 1, abi.NSIG)] = .{};
    }
    // The saved context is in the frame now; `ctx` becomes the handler's.
    ctx.rip = action.handler;
    ctx.rsp = at.frame;
    ctx.rdi = sig;
    ctx.rsi = at.frame + @offsetOf(sf.Frame, "info");
    ctx.rdx = at.frame + @offsetOf(sf.Frame, "uc");
    ctx.rax = 0;
    // Direction and trap flags cleared, as the C ABI and Linux have it.
    ctx.rflags &= ~@as(u64, sysret.FLAG_TF | sysret.FLAG_RF | 0x400);
    ctx.rcx = ctx.rip;
    ctx.r11 = ctx.rflags;
    regs.load(ctx);
    fpu.initArea(area_ptr[0..area_size]);
    fpu.switchState(null, area_ptr);
}

// ---------------------------------------------------------------------------
// Calls

/// `rt_sigreturn`: put back what the frame at the calling thread's stack
/// says (its registers, signal mask, alternate stack and FP state): the
/// handler has returned to its restorer, which made this call. What the
/// program changed in the frame counts, within what is safe: user mode's
/// selectors whatever it wrote, user-settable flags only, a return address
/// checked on the way out like any, an FP image that cannot fault. A frame
/// that cannot be read ends the process, as on Linux.
pub fn sigreturn(f: *arch_syscall.Frame) void {
    const t = thread.current();
    const p = t.process.?;
    const frame_addr = f.rsp -% 8; // the handler's `ret` took the return address
    var frame: sf.Frame = undefined;
    uaccess.copyFromUser(std.mem.asBytes(&frame), frame_addr) catch return badFrame(p);
    const ctx = frame.uc.mcontext;
    t.signal_mask = frame.uc.sigmask & ~UNBLOCKABLE;

    // The alternate stack, as `sigaltstack` would take it; not while on it.
    const s = frame.uc.stack;
    if (s.flags & abi.SS.DISABLE != 0) {
        t.signal_stack = .{};
    } else if (s.size >= abi.SS.MIN_SIZE) {
        t.signal_stack = .{ .sp = s.sp, .size = s.size, .flags = 0 };
    }

    // The FP state: the whole XSAVE image if the frame carries Linux's
    // description of one, the FXSAVE part otherwise, the reset state if
    // there is none.
    const area_ptr = t.fpuArea().?;
    const area_size = fpu.areaSize();
    const xsave = fpu.currentMode() == .xsave;
    if (ctx.fpstate == 0) {
        fpu.initArea(area_ptr[0..area_size]);
    } else {
        const image = heap.allocator.alloc(u8, FP_MAX) catch return badFrame(p);
        defer heap.allocator.free(image);
        const want: usize = if (xsave) area_size + 4 else area_size;
        uaccess.copyFromUser(image[0..want], ctx.fpstate) catch return badFrame(p);
        fpu.initArea(area_ptr[0..area_size]);
        const whole = xsave and sf.hasXsaveMarks(image[0..want], @intCast(area_size));
        const take_len: usize = if (whole) area_size else sf.LEGACY_SIZE;
        @memcpy(area_ptr[0..take_len], image[0..take_len]);
        if (xsave and !whole) {
            // Only the x87 and SSE state: the header says so.
            std.mem.writeInt(u64, area_ptr[sf.LEGACY_SIZE..][0..8], 0x3, .little);
        }
        sf.sanitizeFp(area_ptr[0..area_size], xsave, fpu.enabledFeatures(), fpu.mxcsrMask());
    }
    fpu.switchState(null, area_ptr);
    const regs: Regs = .{ .syscall = f };
    regs.load(ctx);
}

fn badFrame(p: *Process) void {
    root.print("\n*** thread {d} ({s}): rt_sigreturn without a readable signal frame, killed\n", .{ thread.id(), p.name });
    proc.exitForFault(SIG.SEGV);
}
