//! `/test/hugepages`: anonymous memory given 2 MiB pages, and what must
//! hold of it when part of one is unmapped, protected, given back or
//! moved, and when the process forks. Each of those splits the 2 MiB page
//! into small ones first; the memory a program sees must not change.
//! Exits with 0, or with the number of the first failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

const MIB2 = 2 * 1024 * 1024;
const PAGE = 4096;

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

/// `AnonHugePages` of `/proc/meminfo`, in kB.
fn hugeKb() u64 {
    const fd = lib.open("/proc/meminfo");
    if (lib.isError(fd)) return 0;
    defer _ = lib.close(fd);
    var buf: [512]u8 = undefined;
    const n = lib.read(fd, &buf);
    if (lib.isError(n)) return 0;
    const text = buf[0..n];
    const at = std.mem.indexOf(u8, text, "AnonHugePages:") orelse return 0;
    var rest = std.mem.trimStart(u8, text[at + "AnonHugePages:".len ..], " ");
    rest = rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
    return std.fmt.parseInt(u64, rest, 10) catch 0;
}

/// A byte that says where it is, to check memory after it is moved about.
fn pattern(off: u64) u8 {
    return @truncate((off / PAGE) *% 31 +% (off % PAGE));
}

fn fill(base: u64, len: u64) void {
    var off: u64 = 0;
    while (off < len) : (off += 64) @as(*volatile u8, @ptrFromInt(base + off)).* = pattern(off);
}

/// Whether `[base + from, base + to)` holds what `fill` wrote there.
fn same(base: u64, from: u64, to: u64) bool {
    var off = from;
    while (off < to) : (off += 64) {
        if (@as(*volatile u8, @ptrFromInt(base + off)).* != pattern(off)) return false;
    }
    return true;
}

/// `len` bytes of anonymous memory that start on a 2 MiB boundary: more
/// is mapped, and the edges given back.
fn alignedMap(len: u64) u64 {
    const raw = lib.mmap(0, len + MIB2, abi.PROT.READ | abi.PROT.WRITE, abi.MAP.PRIVATE | abi.MAP.ANONYMOUS);
    expect(!lib.isError(raw), 1);
    const base = std.mem.alignForward(u64, raw, MIB2);
    if (base > raw) _ = lib.syscall(Sys.munmap, raw, base - raw, 0);
    const end = raw + len + MIB2;
    if (end > base + len) _ = lib.syscall(Sys.munmap, base + len, end - (base + len), 0);
    return base;
}

pub fn main() noreturn {
    // --- Touching 2 MiB-aligned anonymous memory gives 2 MiB pages.
    const before = hugeKb();
    const base = alignedMap(4 * MIB2);
    fill(base, 4 * MIB2);
    expect(hugeKb() >= before + 4 * 2048, 2);
    expect(same(base, 0, 4 * MIB2), 3);

    // --- Unmapping one small page of the first: the rest stays.
    expect(lib.syscall(Sys.munmap, base + 5 * PAGE, PAGE, 0) == 0, 10);
    expect(same(base, 0, 5 * PAGE) and same(base, 6 * PAGE, 4 * MIB2), 11);
    // The unmapped page is gone: a child that touches it is killed.
    const toucher = lib.syscall(Sys.fork, 0, 0, 0);
    if (toucher == 0) {
        _ = @as(*volatile u8, @ptrFromInt(base + 5 * PAGE)).*;
        lib.exit(0);
    }
    var status: i32 = 0;
    expect(lib.syscall6(Sys.wait4, toucher, @intFromPtr(&status), 0, 0, 0, 0) == toucher and status & 0x7f == 11, 12); // SIGSEGV

    // --- Protecting part of the second: read-only there, writable around it.
    const second = base + MIB2;
    expect(lib.syscall(Sys.mprotect, second + 16 * PAGE, 4 * PAGE, abi.PROT.READ) == 0, 20);
    expect(same(base, MIB2, 2 * MIB2), 21);
    @as(*volatile u8, @ptrFromInt(second)).* = pattern(MIB2); // still writable
    const writer = lib.syscall(Sys.fork, 0, 0, 0);
    if (writer == 0) {
        @as(*volatile u8, @ptrFromInt(second + 16 * PAGE)).* = 1;
        lib.exit(0);
    }
    expect(lib.syscall6(Sys.wait4, writer, @intFromPtr(&status), 0, 0, 0, 0) == writer and status & 0x7f == 11, 22);

    // --- Giving part of the third back: zeroes there, the rest as it was.
    const third = base + 2 * MIB2;
    expect(lib.syscall(Sys.madvise, third + 100 * PAGE, 3 * PAGE, abi.MADV.DONTNEED) == 0, 30);
    expect(@as(*volatile u8, @ptrFromInt(third + 100 * PAGE + 7)).* == 0, 31);
    expect(same(base, 2 * MIB2, 2 * MIB2 + 100 * PAGE) and same(base, 2 * MIB2 + 103 * PAGE, 3 * MIB2), 32);

    // --- A child made by fork sees the same memory (the fourth, whole).
    const reader = lib.syscall(Sys.fork, 0, 0, 0);
    if (reader == 0) lib.exit(if (same(base, 3 * MIB2, 4 * MIB2)) 0 else 1);
    expect(lib.syscall6(Sys.wait4, reader, @intFromPtr(&status), 0, 0, 0, 0) == reader and status == 0, 40);

    // --- Moving the fourth elsewhere (mremap): its contents go with it.
    const MREMAP_MAYMOVE = 1;
    const moved = lib.syscall6(Sys.mremap, base + 3 * MIB2, MIB2, 2 * MIB2, MREMAP_MAYMOVE, 0, 0);
    expect(!lib.isError(moved), 50);
    var off: u64 = 0;
    var ok = true;
    while (off < MIB2) : (off += 64) {
        if (@as(*volatile u8, @ptrFromInt(moved + off)).* != pattern(3 * MIB2 + off)) ok = false;
    }
    expect(ok, 51);

    // --- Unmapped whole, the 2 MiB pages go back.
    expect(lib.syscall(Sys.munmap, base, 3 * MIB2, 0) == 0 and lib.syscall(Sys.munmap, moved, 2 * MIB2, 0) == 0, 60);
    lib.exit(0);
}
