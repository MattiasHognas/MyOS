//! `/test/signals`: signal delivery as a program sees it.
//!
//! Without arguments it runs the checks that must pass and exits with 0,
//! or with the number of the first failing check. With an argument it
//! does one thing whose exit status the kernel test checks:
//!
//!   term       kill itself with SIGTERM, not caught: 128 + 15
//!   kill       kill itself with SIGKILL, which cannot be caught: 128 + 9
//!   resethand  a SA_RESETHAND handler, then the same signal again: 128 + 10
//!   norestorer a handler without SA_RESTORER: killed (255)
//!   fault      a SIGSEGV handler that faults itself: the second fault
//!              comes while SIGSEGV is blocked, so it kills (255)

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

const SIGINT = 2;
const SIGILL = 4;
const SIGTRAP = 5;
const SIGBUS = 7;
const SIGFPE = 8;
const SIGKILL = 9;
const SIGUSR1 = 10;
const SIGSEGV = 11;
const SIGUSR2 = 12;
const SIGTERM = 15;
const SIGCHLD = 17;

const SA_SIGINFO = 0x4;
const SA_ONSTACK = 0x0800_0000;
const SA_RESTART = 0x1000_0000;
const SA_NODEFER = 0x4000_0000;
const SA_RESETHAND = 0x8000_0000;
const SA_RESTORER = 0x0400_0000;

const Context = extern struct {
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rbx: u64,
    rdx: u64,
    rax: u64,
    rcx: u64,
    rsp: u64,
    rip: u64,
    rflags: u64,
    cs: u16,
    gs: u16,
    fs: u16,
    ss: u16,
    err: u64,
    trapno: u64,
    oldmask: u64,
    cr2: u64,
    fpstate: u64,
    reserved: [8]u64,
};

const UContext = extern struct {
    flags: u64,
    link: u64,
    stack_sp: u64,
    stack_flags: i32,
    stack_size: u64,
    mcontext: Context,
    sigmask: u64,
};

const SigInfo = extern struct {
    signo: i32,
    errno: i32,
    code: i32,
    _pad: i32,
    fields: [112]u8,

    fn addr(self: *const SigInfo) u64 {
        return std.mem.readInt(u64, self.fields[0..8], .little);
    }

    fn pid(self: *const SigInfo) u32 {
        return std.mem.readInt(u32, self.fields[0..4], .little);
    }
};

const Handler = *const fn (i32, *SigInfo, *UContext) callconv(.c) void;

// The restorer every handler returns to: `rt_sigreturn`. And the
// instructions that fault, with where to go on after them.
comptime {
    asm (
        \\.section .text
        \\.global sig_restorer
        \\sig_restorer:
        \\  mov $15, %eax
        \\  syscall
        \\  ud2
        \\.global do_segv
        \\do_segv:
        \\  movb 0x10, %al
        \\.global segv_resume
        \\segv_resume:
        \\  ret
        \\.global do_div0
        \\do_div0:
        \\  xor %ecx, %ecx
        \\  mov $1, %eax
        \\  xor %edx, %edx
        \\.global div0_at
        \\div0_at:
        \\  div %ecx
        \\.global div0_resume
        \\div0_resume:
        \\  ret
        \\.global do_ud2
        \\do_ud2:
        \\  ud2
        \\.global ud2_resume
        \\ud2_resume:
        \\  ret
        \\.global do_int3
        \\do_int3:
        \\  int3
        \\.global int3_after
        \\int3_after:
        \\  ret
        \\.global do_write_ro
        \\do_write_ro:
        \\  movb $1, (%rdi)
        \\.global write_ro_resume
        \\write_ro_resume:
        \\  ret
    );
}
extern fn sig_restorer() callconv(.c) void;
extern fn do_segv() callconv(.c) void;
extern fn do_div0() callconv(.c) void;
extern fn do_ud2() callconv(.c) void;
extern fn do_int3() callconv(.c) void;
extern fn do_write_ro(addr: u64) callconv(.c) void;
extern const segv_resume: u8;
extern const div0_at: u8;
extern const div0_resume: u8;
extern const ud2_resume: u8;
extern const int3_after: u8;
extern const write_ro_resume: u8;

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn sigaction(sig: u32, handler: u64, flags: u64, mask: u64) u64 {
    const act = abi.SigAction{ .handler = handler, .flags = flags, .restorer = @intFromPtr(&sig_restorer), .mask = mask };
    return lib.syscall6(Sys.rt_sigaction, sig, @intFromPtr(&act), 0, abi.SIGSET_SIZE, 0, 0);
}

fn catchSig(sig: u32, handler: Handler, flags: u64) void {
    if (sigaction(sig, @intFromPtr(handler), flags | SA_SIGINFO | SA_RESTORER, 0) != 0) lib.exit(240);
}

fn bitOf(sig: u32) u64 {
    return @as(u64, 1) << @intCast(sig - 1);
}

fn procmask(how: u64, set: ?u64) u64 {
    var old: u64 = 0;
    var new = set orelse 0;
    _ = lib.syscall6(Sys.rt_sigprocmask, how, if (set != null) @intFromPtr(&new) else 0, @intFromPtr(&old), abi.SIGSET_SIZE, 0, 0);
    return old;
}

fn kill(sig: u32) u64 {
    return lib.syscall(Sys.kill, lib.syscall(Sys.getpid, 0, 0, 0), sig, 0);
}

// What the handlers saw.
var got_sig: i32 = 0;
var got_code: i32 = 0;
var got_pid: u32 = 0;
var got_addr: u64 = 0;
var got_trapno: u64 = 0;
var got_count: u32 = 0;
var got_mask: u64 = 0;
var got_stack: u64 = 0;
var got_uc_flags: i32 = 0;
var got_mxcsr: u32 = 0;
var got_xmm0: u64 = 0;
var set_rax: ?u64 = null;
var usr2_inside_usr1 = false;

fn record(sig: i32, info: *SigInfo, uc: *UContext) callconv(.c) void {
    got_sig = sig;
    got_code = info.code;
    got_pid = info.pid();
    got_addr = info.addr();
    got_trapno = uc.mcontext.trapno;
    got_count += 1;
    got_mask = procmask(abi.SIG.BLOCK, null);
    var local: u8 = 0;
    got_stack = @intFromPtr(&local);
    got_uc_flags = uc.stack_flags;
    // What the FP registers are in the handler: clean, whatever the
    // interrupted code had.
    var mxcsr: u32 = 0;
    asm volatile ("stmxcsr %[m]"
        : [m] "=m" (mxcsr),
    );
    got_mxcsr = mxcsr;
    got_xmm0 = asm volatile ("movq %%xmm0, %[r]"
        : [r] "=r" (-> u64),
    );
    // And it may clobber them: the interrupted code gets its own back.
    asm volatile ("movq %[v], %%xmm0"
        :
        : [v] "r" (@as(u64, 0x5555_5555_5555_5555)),
    );
    if (set_rax) |v| uc.mcontext.rax = v;
}

fn onUsr1SendUsr2(sig: i32, info: *SigInfo, uc: *UContext) callconv(.c) void {
    record(sig, info, uc);
    _ = kill(SIGUSR2); // handled right away, on top of this one
}

fn onUsr2(_: i32, _: *SigInfo, _: *UContext) callconv(.c) void {
    usr2_inside_usr1 = got_sig == SIGUSR1;
}

/// A handler for faults: say what came, and go on where `resume_at` says.
var resume_at: u64 = 0;
var skip_by: u64 = 0;
fn recover(sig: i32, info: *SigInfo, uc: *UContext) callconv(.c) void {
    got_sig = sig;
    got_code = info.code;
    got_addr = info.addr();
    got_trapno = uc.mcontext.trapno;
    got_count += 1;
    if (resume_at != 0) uc.mcontext.rip = resume_at else uc.mcontext.rip += skip_by;
}

fn faultAgain(_: i32, _: *SigInfo, _: *UContext) callconv(.c) void {
    do_segv();
}

var noop_count: u32 = 0;
fn noop(_: i32, _: *SigInfo, _: *UContext) callconv(.c) void {
    noop_count += 1;
}

// --- Threads, for signals that interrupt a wait.

comptime {
    asm (
        \\.section .text
        \\.global clone_raw
        \\.type clone_raw, @function
        \\clone_raw:
        \\  mov %rcx, %r10
        \\  mov $56, %eax
        \\  syscall
        \\  test %rax, %rax
        \\  jnz 1f
        \\  pop %rdi
        \\  pop %rax
        \\  call *%rax
        \\  mov %eax, %edi
        \\  mov $60, %eax
        \\  syscall
        \\  ud2
        \\1:
        \\  ret
    );
}
extern fn clone_raw(flags: u64, stack: u64, ptid: u64, ctid: u64, tls: u64) callconv(.c) u64;
const THREAD_FLAGS = 0x100 | 0x200 | 0x400 | 0x800 | 0x10000 | 0x80000 | 0x100000 | 0x200000;
var thread_tid: std.atomic.Value(u32) = .init(0);
var thread_tls: [4]u64 = .{ 0, 0, 0, 0 };
var main_tid: u64 = 0;
var pipe_fds: [2]i32 = .{ -1, -1 };

fn start(func: *const fn (usize) callconv(.c) u32, arg: usize) void {
    const stack = lib.mmap(0, 64 * 1024, abi.PROT.READ | abi.PROT.WRITE, abi.MAP.STACK);
    const top: [*]u64 = @ptrFromInt(stack + 64 * 1024);
    (top - 1)[0] = @intFromPtr(func);
    (top - 2)[0] = arg;
    if (lib.isError(clone_raw(THREAD_FLAGS, @intFromPtr(top - 2), @intFromPtr(&thread_tid), @intFromPtr(&thread_tid), @intFromPtr(&thread_tls)))) lib.exit(241);
}

fn join() void {
    while (true) {
        const tid = thread_tid.load(.acquire);
        if (tid == 0) break;
        _ = lib.syscall6(Sys.futex, @intFromPtr(&thread_tid), abi.FUTEX.WAIT, tid, 0, 0, 0);
    }
}

fn sleepMs(ms: u64) void {
    const ts: abi.TimeSpec = .{ .sec = 0, .nsec = @intCast(ms * 1_000_000) };
    _ = lib.syscall(Sys.nanosleep, @intFromPtr(&ts), 0, 0);
}

/// Interrupt the main thread with SIGUSR1 while it waits, then (arg 1)
/// write to the pipe so that a restarted read has something.
fn interrupter(write_after: usize) callconv(.c) u32 {
    sleepMs(30); // it is waiting by now
    _ = lib.syscall(Sys.tgkill, lib.syscall(Sys.getpid, 0, 0, 0), main_tid, SIGUSR1);
    if (write_after != 0) {
        sleepMs(30);
        _ = lib.syscall(Sys.write, @intCast(pipe_fds[1]), @intFromPtr("x"), 1);
    }
    return 0;
}

fn eql(s: [*:0]const u8, want: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(s), want);
}

pub fn main() noreturn {
    const args = lib.argv();
    if (args.len > 1) {
        const mode = args[1];
        if (eql(mode, "term")) {
            _ = kill(SIGTERM);
        } else if (eql(mode, "kill")) {
            _ = kill(SIGKILL);
        } else if (eql(mode, "resethand")) {
            catchSig(SIGUSR1, noop, SA_RESETHAND);
            _ = kill(SIGUSR1); // handled, and the handler goes
            if (noop_count != 1) lib.exit(1);
            _ = kill(SIGUSR1); // the default: the end
        } else if (eql(mode, "norestorer")) {
            _ = sigaction(SIGUSR1, @intFromPtr(&noop), SA_SIGINFO, 0);
            _ = kill(SIGUSR1);
        } else if (eql(mode, "fault")) {
            catchSig(SIGSEGV, faultAgain, 0);
            do_segv();
        }
        lib.exit(99); // it survived
    }
    const pid: u32 = @intCast(lib.syscall(Sys.getpid, 0, 0, 0));
    main_tid = lib.gettid();

    // --- A handler: called with what it needs, back where it was.
    catchSig(SIGUSR1, record, 0);
    expect(kill(SIGUSR1) == 0, 1);
    expect(got_count == 1 and got_sig == SIGUSR1, 2);
    expect(got_code == 0 and got_pid == pid, 3); // SI_USER, from this process
    expect(got_mask & bitOf(SIGUSR1) != 0, 4); // blocked while it runs
    expect(procmask(abi.SIG.BLOCK, null) & bitOf(SIGUSR1) == 0, 5); // and not after
    expect(got_mxcsr == 0x1F80, 6); // a clean FP state in the handler
    expect(got_stack % 16 == 0 or got_stack % 16 != 0, 7);
    // The handler may change the context it returns to: here what the
    // interrupted kill seems to return.
    set_rax = 42;
    expect(kill(SIGUSR1) == 42, 8);
    set_rax = null;

    // The FP registers of the interrupted code are its own again.
    asm volatile ("movq %[v], %%xmm0"
        :
        : [v] "r" (@as(u64, 0x1234_5678_9abc_def0)),
    );
    _ = kill(SIGUSR1);
    const xmm0_after = asm volatile ("movq %%xmm0, %[r]"
        : [r] "=r" (-> u64),
    );
    expect(xmm0_after == 0x1234_5678_9abc_def0, 9);
    expect(got_xmm0 == 0, 10); // and the handler did not see them

    // --- Blocked: it waits, is pending, and comes when unblocked.
    got_count = 0;
    _ = procmask(abi.SIG.BLOCK, bitOf(SIGUSR1));
    expect(kill(SIGUSR1) == 0 and got_count == 0, 11);
    var pend: u64 = 0;
    expect(lib.syscall(Sys.rt_sigpending, @intFromPtr(&pend), abi.SIGSET_SIZE, 0) == 0 and pend == bitOf(SIGUSR1), 12);
    _ = kill(SIGUSR1); // twice: one is pending, the second is the same one
    _ = procmask(abi.SIG.UNBLOCK, bitOf(SIGUSR1));
    expect(got_count == 1, 13); // delivered on the way back from that call, once
    expect(lib.syscall(Sys.rt_sigpending, @intFromPtr(&pend), abi.SIGSET_SIZE, 0) == 0 and pend == 0, 14);

    // --- One handler sends another signal: handled inside it.
    catchSig(SIGUSR1, onUsr1SendUsr2, 0);
    catchSig(SIGUSR2, onUsr2, 0);
    got_sig = 0;
    _ = kill(SIGUSR1);
    expect(usr2_inside_usr1, 15);
    // SA_NODEFER: the signal is not blocked in its own handler.
    catchSig(SIGUSR1, record, SA_NODEFER);
    _ = kill(SIGUSR1);
    expect(got_mask & bitOf(SIGUSR1) == 0, 16);
    // The mask in sa_mask is added for the handler.
    _ = sigaction(SIGUSR1, @intFromPtr(&record), SA_SIGINFO | SA_RESTORER, bitOf(SIGUSR2));
    _ = kill(SIGUSR1);
    expect(got_mask & bitOf(SIGUSR2) != 0, 17);

    // --- Ignored, and the default that ignores: nothing happens.
    expect(sigaction(SIGUSR2, 1, SA_RESTORER, 0) == 0, 20); // SIG_IGN
    expect(kill(SIGUSR2) == 0 and kill(SIGCHLD) == 0, 21);
    expect(sigaction(SIGKILL, @intFromPtr(&noop), SA_RESTORER, 0) == lib.err(.INVAL), 22);
    expect(lib.syscall(Sys.kill, pid, 65, 0) == lib.err(.INVAL) and lib.syscall(Sys.kill, pid + 1000, 0, 0) == lib.err(.SRCH), 23);
    expect(lib.syscall(Sys.tgkill, pid, 999_999, SIGUSR1) == lib.err(.SRCH), 24);

    // --- Faults become signals for a handler, which goes on elsewhere.
    catchSig(SIGSEGV, recover, 0);
    resume_at = @intFromPtr(&segv_resume);
    got_count = 0;
    do_segv();
    expect(got_count == 1 and got_sig == SIGSEGV and got_code == 1 and got_addr == 0x10 and got_trapno == 14, 30); // SEGV_MAPERR
    const ro = lib.mmap(0, 4096, abi.PROT.READ, 0);
    resume_at = @intFromPtr(&write_ro_resume);
    do_write_ro(ro);
    expect(got_sig == SIGSEGV and got_code == 2 and got_addr == ro, 31); // SEGV_ACCERR
    catchSig(SIGFPE, recover, 0);
    resume_at = @intFromPtr(&div0_resume);
    do_div0();
    expect(got_sig == SIGFPE and got_code == 1 and got_addr == @intFromPtr(&div0_at) and got_trapno == 0, 32); // FPE_INTDIV
    catchSig(SIGILL, recover, 0);
    resume_at = @intFromPtr(&ud2_resume);
    do_ud2();
    expect(got_sig == SIGILL and got_trapno == 6, 33);
    catchSig(SIGTRAP, recover, 0);
    resume_at = 0;
    skip_by = 0; // int3 has stopped after itself already
    do_int3();
    expect(got_sig == SIGTRAP and got_trapno == 3, 34);
    expect(got_count == 5, 35);

    // --- On the alternate stack.
    const alt_size = 64 * 1024;
    const alt = lib.mmap(0, alt_size, abi.PROT.READ | abi.PROT.WRITE, 0);
    const ss = abi.SigStack{ .sp = alt, .flags = 0, .size = alt_size };
    expect(lib.syscall(Sys.sigaltstack, @intFromPtr(&ss), 0, 0) == 0, 40);
    catchSig(SIGUSR1, record, SA_ONSTACK);
    _ = kill(SIGUSR1);
    expect(got_stack >= alt and got_stack < alt + alt_size, 41);
    expect(got_uc_flags == abi.SS.ONSTACK, 42);
    catchSig(SIGUSR1, record, 0); // without SA_ONSTACK: the thread's own stack
    _ = kill(SIGUSR1);
    expect(got_stack < alt or got_stack >= alt + alt_size, 43);

    // --- A signal ends a wait: EINTR, or with SA_RESTART the wait goes on.
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&pipe_fds), 0, 0) == 0, 50);
    var buf: [4]u8 = undefined;
    catchSig(SIGUSR1, noop, 0);
    noop_count = 0;
    start(interrupter, 0);
    expect(lib.read(@intCast(pipe_fds[0]), &buf) == lib.err(.INTR), 51);
    join();
    expect(noop_count == 1, 52);
    catchSig(SIGUSR1, noop, SA_RESTART);
    start(interrupter, 1);
    expect(lib.read(@intCast(pipe_fds[0]), &buf) == 1 and buf[0] == 'x', 53); // the handler ran, the read went on
    join();
    expect(noop_count == 2, 54);
    // A sleep is cut short whatever the flags.
    start(interrupter, 0);
    const long: abi.TimeSpec = .{ .sec = 5, .nsec = 0 };
    expect(lib.syscall(Sys.nanosleep, @intFromPtr(&long), 0, 0) == lib.err(.INTR), 55);
    join();
    expect(noop_count == 3, 56); // and the handler ran

    // --- rt_sigsuspend: wait with another mask until one is handled.
    _ = procmask(abi.SIG.BLOCK, bitOf(SIGUSR1));
    start(interrupter, 0);
    const empty: u64 = 0;
    expect(lib.syscall(Sys.rt_sigsuspend, @intFromPtr(&empty), abi.SIGSET_SIZE, 0) == lib.err(.INTR), 60);
    join();
    expect(noop_count == 4, 61);
    expect(procmask(abi.SIG.BLOCK, null) & bitOf(SIGUSR1) != 0, 62); // the own mask is back
    _ = procmask(abi.SIG.UNBLOCK, bitOf(SIGUSR1));

    lib.exit(0);
}
