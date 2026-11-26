//! What a signal handler finds on its stack, as Linux lays it out on
//! x86-64, and the checks on what `rt_sigreturn` brings back.
//!
//! When a handler is called, the stack holds, from its stack pointer up:
//!
//!   - the return address: the handler's `sa_restorer`, which calls
//!     `rt_sigreturn` (C libraries set it; the kernel has no code of its
//!     own in user space);
//!   - a `struct ucontext`: the alternate stack, the registers the thread
//!     had (`struct sigcontext`), the signal mask to go back to;
//!   - a `siginfo_t`;
//!   - and, 64-byte aligned above them, the x87/SSE/AVX state as XSAVE
//!     (or FXSAVE) writes it, which `sigcontext.fpstate` points to.
//!
//! The handler is called with the signal number in RDI, the `siginfo_t` in
//! RSI and the `ucontext` in RDX, RSP 8 below a multiple of 16 as after a
//! `call`. Runtimes read and change all of this: the .NET runtime takes a
//! thread's context from it to raise a `NullReferenceException`, Go
//! rewrites the saved RIP to preempt a goroutine. So the layout is
//! Linux's, field for field.
//!
//! No kernel dependencies: tested on the host against Linux's offsets.

const std = @import("std");

/// `struct sigcontext` (x86-64): the registers, in Linux's order.
pub const Context = extern struct {
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rdi: u64 = 0,
    rsi: u64 = 0,
    rbp: u64 = 0,
    rbx: u64 = 0,
    rdx: u64 = 0,
    rax: u64 = 0,
    rcx: u64 = 0,
    rsp: u64 = 0,
    rip: u64 = 0,
    rflags: u64 = 0,
    cs: u16 = 0,
    gs: u16 = 0,
    fs: u16 = 0,
    ss: u16 = 0,
    /// The fault's error code and vector, for a signal from a fault.
    err: u64 = 0,
    trapno: u64 = 0,
    oldmask: u64 = 0,
    /// The faulting address, for a page fault.
    cr2: u64 = 0,
    /// Where the x87/SSE/AVX state is: in the frame, or 0.
    fpstate: u64 = 0,
    reserved: [8]u64 = @splat(0),
};

/// `stack_t`.
pub const Stack = extern struct {
    sp: u64 = 0,
    flags: i32 = 0,
    size: u64 = 0,
};

/// `struct ucontext` as the kernel writes it.
pub const UContext = extern struct {
    flags: u64 = 0,
    link: u64 = 0,
    stack: Stack = .{},
    mcontext: Context = .{},
    /// The signal mask to go back to.
    sigmask: u64 = 0,
};

/// `uc_flags`: the FP state is in XSAVE form with its extended part.
pub const UC_FP_XSTATE = 0x1;
/// `uc_flags`: SS was saved, and is restored as it was.
pub const UC_SIGCONTEXT_SS = 0x2;
pub const UC_STRICT_RESTORE_SS = 0x4;

/// `siginfo_t`: 128 bytes, of which these are what MyOS fills in.
pub const SigInfo = extern struct {
    signo: i32 = 0,
    errno: i32 = 0,
    code: i32 = 0,
    _pad: i32 = 0,
    /// The sender's process ID (signals sent by a program), or the address
    /// that faulted (signals from faults) in its first 8 bytes.
    fields: [112]u8 = @splat(0),

    pub fn fromFault(signo: u32, code: i32, addr: u64) SigInfo {
        var info: SigInfo = .{ .signo = @intCast(signo), .code = code };
        std.mem.writeInt(u64, info.fields[0..8], addr, .little);
        return info;
    }

    pub fn fromProcess(signo: u32, code: i32, pid: u32, uid: u32) SigInfo {
        var info: SigInfo = .{ .signo = @intCast(signo), .code = code };
        std.mem.writeInt(u32, info.fields[0..4], pid, .little);
        std.mem.writeInt(u32, info.fields[4..8], uid, .little);
        return info;
    }
};

/// What the frame is, without the FP state.
pub const Frame = extern struct {
    /// Where the handler returns to: `sa_restorer`.
    pretcode: u64,
    uc: UContext,
    info: SigInfo,
};

comptime {
    // Linux's sizes and offsets (arch/x86/include/uapi/asm/sigcontext.h,
    // ucontext.h, signal.h, siginfo.h).
    std.debug.assert(@sizeOf(Context) == 256);
    std.debug.assert(@offsetOf(Context, "rip") == 128);
    std.debug.assert(@offsetOf(Context, "cs") == 144);
    std.debug.assert(@offsetOf(Context, "fpstate") == 184);
    std.debug.assert(@sizeOf(Stack) == 24);
    std.debug.assert(@offsetOf(UContext, "mcontext") == 40);
    std.debug.assert(@offsetOf(UContext, "sigmask") == 296);
    std.debug.assert(@sizeOf(SigInfo) == 128);
    std.debug.assert(@offsetOf(Frame, "uc") == 8);
    std.debug.assert(@offsetOf(Frame, "info") == 312);
}

/// Bytes below the interrupted stack pointer a frame never touches: the
/// red zone, which leaf functions may use without moving RSP.
pub const RED_ZONE = 128;

/// The magic words that say an FP area is in XSAVE form with Linux's
/// software-reserved description (`struct _fpx_sw_bytes`, at byte 464 of
/// the FXSAVE part) and that it ends where that says.
pub const FP_XSTATE_MAGIC1: u32 = 0x46505853;
pub const FP_XSTATE_MAGIC2: u32 = 0x46505845;
const SW_BYTES_OFFSET = 464;
/// Size of the FXSAVE part, at whose end the XSAVE header begins.
pub const LEGACY_SIZE = 512;
const HEADER_SIZE = 64;
const MXCSR_OFFSET = 24;

/// Where a frame goes, for a thread whose stack pointer is `sp`.
pub const Placement = struct {
    /// The frame (and the handler's RSP).
    frame: u64,
    /// The FP state.
    fpstate: u64,
    /// Whether it went on the alternate stack.
    on_alt_stack: bool,
};

/// Why a frame cannot be placed.
pub const PlaceError = error{
    /// The alternate stack (or the stack pointer) leaves no room.
    NoRoom,
};

/// Place a frame with `fp_size` bytes of FP state (the save area and
/// `FP_XSTATE_MAGIC2` behind it, or just the FXSAVE area), as Linux's
/// `get_sigframe` does: on the alternate stack `alt` if the handler asks
/// for it (`use_alt`) and the thread is not on it already, otherwise below
/// the red zone of the stack it is on.
pub fn place(sp: u64, use_alt: bool, alt: Stack, fp_size: u64) PlaceError!Placement {
    const alt_enabled = alt.flags & 2 == 0 and alt.size != 0; // SS_DISABLE
    const on_alt = alt_enabled and sp > alt.sp and sp - alt.sp <= alt.size;
    var top: u64 = undefined;
    var switched = false;
    if (use_alt and alt_enabled and !on_alt) {
        top = std.math.add(u64, alt.sp, alt.size) catch return error.NoRoom;
        switched = true;
    } else {
        top = std.math.sub(u64, sp, RED_ZONE) catch return error.NoRoom;
    }
    const fp = std.mem.alignBackward(u64, std.math.sub(u64, top, fp_size) catch return error.NoRoom, 64);
    const below = std.math.sub(u64, fp, @sizeOf(Frame)) catch return error.NoRoom;
    // After the handler's `ret` pops the return address, RSP is a multiple
    // of 16 again, as after a call.
    const frame = std.math.sub(u64, std.mem.alignBackward(u64, below, 16), 8) catch return error.NoRoom;
    // A frame that does not fit the alternate stack it was put on is
    // refused: below it is somebody else's memory.
    if (switched and frame < alt.sp) return error.NoRoom;
    return .{ .frame = frame, .fpstate = fp, .on_alt_stack = switched or on_alt };
}

/// Mark the XSAVE image `area` (its `xstate_size` bytes and 4 behind them)
/// as Linux does, for the handler and for `rt_sigreturn`: the description
/// in the FXSAVE part's software-reserved bytes, the second magic word at
/// the end.
pub fn markXsave(area: []u8, xstate_size: u32, xfeatures: u64) void {
    const sw = area[SW_BYTES_OFFSET..][0..48];
    @memset(sw, 0);
    std.mem.writeInt(u32, sw[0..4], FP_XSTATE_MAGIC1, .little);
    std.mem.writeInt(u32, sw[4..8], xstate_size + 4, .little); // extended_size
    std.mem.writeInt(u64, sw[8..16], xfeatures, .little);
    std.mem.writeInt(u32, sw[16..20], xstate_size, .little);
    std.mem.writeInt(u32, area[xstate_size..][0..4], FP_XSTATE_MAGIC2, .little);
}

/// Make an FP image from user memory safe to load: `XRSTOR` and `FXRSTOR`
/// fault in the kernel on reserved MXCSR bits and, for XSAVE, on a header
/// with reserved bits or features that are not enabled. Bits that would do
/// that are cleared; the rest is the program's to choose. `xsave` says
/// which form the image is in; `xcr0` is what is enabled, `mxcsr_mask` the
/// MXCSR bits the CPU has.
pub fn sanitizeFp(area: []u8, xsave: bool, xcr0: u64, mxcsr_mask: u32) void {
    const mxcsr = std.mem.readInt(u32, area[MXCSR_OFFSET..][0..4], .little);
    std.mem.writeInt(u32, area[MXCSR_OFFSET..][0..4], mxcsr & mxcsr_mask, .little);
    if (!xsave) return;
    const header = area[LEGACY_SIZE..][0..HEADER_SIZE];
    const bv = std.mem.readInt(u64, header[0..8], .little);
    std.mem.writeInt(u64, header[0..8], bv & xcr0, .little);
    @memset(header[8..], 0); // XCOMP_BV (the standard form) and the reserved bytes
}

/// Whether the FP image `area` carries Linux's XSAVE description, with an
/// extended part of `xstate_size` bytes: what tells `rt_sigreturn` it may
/// load the AVX state from it. Without it only the FXSAVE part is taken.
pub fn hasXsaveMarks(area: []const u8, xstate_size: u32) bool {
    if (area.len < xstate_size + 4) return false;
    const sw = area[SW_BYTES_OFFSET..][0..48];
    return std.mem.readInt(u32, sw[0..4], .little) == FP_XSTATE_MAGIC1 and
        std.mem.readInt(u32, sw[16..20], .little) == xstate_size and
        std.mem.readInt(u32, area[xstate_size..][0..4], .little) == FP_XSTATE_MAGIC2;
}
