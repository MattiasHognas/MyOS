//! `/test/fsgsbase`: a program sets its own FS and GS base with `wrfsbase`
//! and `wrgsbase`, as it may on Linux when `AT_HWCAP2` says so. The kernel
//! must keep what the program set across thread switches, report it through
//! `arch_prctl`, and never be fooled by it: with the argument `kernel_gs`,
//! the program loads a GS base that looks like a kernel address and makes
//! a debug exception arrive at the first instruction of the kernel's
//! syscall entry, where the GS base is still the program's. The kernel must
//! use its own there (`isr_paranoid`), and the program dies of the trap.
//!
//! Exits with 0, with 1 if the CPU or the kernel does not offer FSGSBASE
//! (nothing to test), or with the number of the first failing check.

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn rdfsbase() u64 {
    return asm volatile ("rdfsbase %[r]"
        : [r] "=r" (-> u64),
    );
}

fn wrfsbase(v: u64) void {
    asm volatile ("wrfsbase %[v]"
        :
        : [v] "r" (v),
    );
}

fn rdgsbase() u64 {
    return asm volatile ("rdgsbase %[r]"
        : [r] "=r" (-> u64),
    );
}

fn wrgsbase(v: u64) void {
    asm volatile ("wrgsbase %[v]"
        :
        : [v] "r" (v),
    );
}

fn archGet(code: u64) u64 {
    var v: u64 = 0;
    expect(lib.syscall(Sys.arch_prctl, code, @intFromPtr(&v), 0) == 0, 90);
    return v;
}

fn eql(s: [*:0]const u8, want: []const u8) bool {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        if (i >= want.len or s[i] != want[i]) return false;
    }
    return i == want.len;
}

pub fn main() noreturn {
    if ((lib.auxValue(abi.AT.HWCAP2) orelse 0) & abi.HWCAP2.FSGSBASE == 0) lib.exit(1);
    const old_fs = rdfsbase();
    const args = lib.argv();

    if (args.len > 1 and eql(args[1], "kernel_gs")) {
        // A GS base in the kernel half, then single-step into `syscall`:
        // the debug exception comes at the first instruction of the entry,
        // in ring 0, before `swapgs`.
        wrgsbase(0xFFFF_8000_0010_0000);
        asm volatile (
            \\ pushfq
            \\ orq $0x100, (%%rsp)
            \\ mov $186, %%eax
            \\ popfq
            \\ syscall
            \\ nop
            \\ nop
            ::: .{ .rax = true, .rcx = true, .r11 = true, .memory = true });
        wrgsbase(0);
        lib.exit(0); // no trap at all: nothing seen, nothing wrong
    }

    // The FS base: what the program writes, through switches and calls.
    const fs: u64 = 0x7000_1234_5000;
    wrfsbase(fs);
    expect(rdfsbase() == fs, 2);
    for (0..20) |_| lib.yield();
    expect(rdfsbase() == fs, 3);
    expect(archGet(abi.ARCH.GET_FS) == fs, 4);

    // The GS base too, and each leaves the other alone.
    const gs: u64 = 0x6000_0000_8000;
    wrgsbase(gs);
    for (0..20) |_| lib.yield();
    expect(rdgsbase() == gs and rdfsbase() == fs, 5);
    expect(archGet(abi.ARCH.GET_GS) == gs, 6);

    // `arch_prctl` sets one; the other stays what the program wrote.
    expect(lib.syscall(Sys.arch_prctl, abi.ARCH.SET_GS, 0x5000_0000_0000, 0) == 0, 7);
    expect(rdgsbase() == 0x5000_0000_0000 and rdfsbase() == fs, 8);
    for (0..20) |_| lib.yield();
    expect(rdgsbase() == 0x5000_0000_0000 and rdfsbase() == fs, 9);

    // Back to the TLS the C-less startup had.
    wrgsbase(0);
    wrfsbase(old_fs);
    lib.exit(0);
}
