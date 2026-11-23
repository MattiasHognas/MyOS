//! Loading and storing the whole extended register state from ring 3, for
//! the `/test/fpu` and `/test/fpu_clean` programs.
//!
//! Everything between loading the registers and storing them again is one
//! assembly routine, so no compiler-generated code (which uses SSE freely)
//! runs in between. AVX instructions are written as bytes: the programs are
//! built for baseline x86-64 and decide at run time whether to use them.

const std = @import("std");

/// The state the tests set and compare.
pub const State = extern struct {
    /// XMM0-15 in the low 16 bytes of each entry, the upper halves of
    /// YMM0-15 in the high 16 (only used with AVX).
    vec: [16][32]u8 align(64),
    /// x87 ST(0) as an 80-bit value.
    st0: [10]u8,
    /// x87 control word.
    fcw: u16,
    mxcsr: u32,
};

comptime {
    std.debug.assert(@offsetOf(State, "st0") == 512);
    std.debug.assert(@offsetOf(State, "fcw") == 522);
    std.debug.assert(@offsetOf(State, "mxcsr") == 524);
}

/// `vmovdqu` between YMM`reg` and `disp`(%rdi) (load) or `disp`(%rsi) (store).
fn vmovdqu(comptime store: bool, comptime reg: u8, comptime disp: u32) []const u8 {
    return std.fmt.comptimePrint("  .byte 0xc5, 0x{x}, 0x{x}, 0x{x}\n  .long {d}\n", .{
        @as(u8, if (reg >= 8) 0x7e else 0xfe),
        @as(u8, if (store) 0x7f else 0x6f),
        0x80 | ((reg & 7) << 3) | @as(u8, if (store) 6 else 7),
        disp,
    });
}

/// The 16 moves of one kind, for registers 0-15.
fn moves(comptime avx: bool, comptime store: bool) []const u8 {
    comptime var text: []const u8 = "";
    inline for (0..16) |i| {
        text = text ++ if (avx)
            vmovdqu(store, i, i * 32)
        else if (store)
            std.fmt.comptimePrint("  movups %xmm{d}, {d}(%rsi)\n", .{ i, i * 32 })
        else
            std.fmt.comptimePrint("  movups {d}(%rdi), %xmm{d}\n", .{ i * 32, i });
    }
    return text;
}

// fpu_roundtrip(in: rdi, out: rsi, spins: rdx, yields: rcx, avx: r8)
//   Load every register from `in`, count `spins` down, call sched_yield
//   (24) `yields` times, store every register to `out`. The registers are
//   left as they are, so the next program to run would see them if the
//   kernel leaked state. The syscall preserves RSI, R8 and R9.
//
// fpu_store_vec(out: rsi, avx: r8): store the vector registers only.
comptime {
    asm (
        \\.section .text
        \\.global fpu_roundtrip
        \\.type fpu_roundtrip, @function
        \\fpu_roundtrip:
        \\  mov %rcx, %r9
        \\  fninit
        \\  fldcw 522(%rdi)
        \\  fldt 512(%rdi)
        \\  ldmxcsr 524(%rdi)
        \\  test %r8, %r8
        \\  jnz 1f
        \\
    ++ moves(false, false) ++
        \\  jmp 2f
        \\1:
        \\
    ++ moves(true, false) ++
        \\2:
        \\  test %rdx, %rdx
        \\  jz 4f
        \\3:
        \\  dec %rdx
        \\  jnz 3b
        \\4:
        \\  test %r9, %r9
        \\  jz 6f
        \\5:
        \\  mov $24, %eax
        \\  syscall
        \\  dec %r9
        \\  jnz 5b
        \\6:
        \\  stmxcsr 524(%rsi)
        \\  fnstcw 522(%rsi)
        \\  fstpt 512(%rsi)
        \\.global fpu_store_vec
        \\.type fpu_store_vec, @function
        \\fpu_store_vec:
        \\  test %r8, %r8
        \\  jnz 7f
        \\
    ++ moves(false, true) ++
        \\  ret
        \\7:
        \\
    ++ moves(true, true) ++
        \\  ret
    );
}

pub extern fn fpu_roundtrip(in: *const State, out: *State, spins: u64, yields: u64, avx: u64) callconv(.c) void;

/// Store XMM0-15 (YMM0-15 with `avx`) to `out.vec`.
pub fn storeVec(out: *State, avx: bool) void {
    asm volatile ("call fpu_store_vec"
        :
        : [out] "{rsi}" (out),
          [avx] "{r8}" (@as(u64, @intFromBool(avx))),
        : .{ .memory = true });
}

/// True if the CPU has AVX and the kernel has enabled it (CPUID says the OS
/// uses XSAVE, and XCR0 has the SSE and AVX state bits).
pub fn avxUsable() bool {
    var ecx: u32 = undefined;
    asm volatile ("cpuid"
        : [c] "={ecx}" (ecx),
        : [leaf] "{eax}" (@as(u32, 1)),
          [sub] "{ecx}" (@as(u32, 0)),
        : .{ .rax = true, .rbx = true, .rdx = true });
    if (ecx & (1 << 27) == 0 or ecx & (1 << 28) == 0) return false;
    const xcr0 = asm volatile (".byte 0x0f, 0x01, 0xd0" // xgetbv
        : [lo] "={eax}" (-> u32),
        : [idx] "{ecx}" (@as(u32, 0)),
        : .{ .rdx = true });
    return xcr0 & 6 == 6;
}
