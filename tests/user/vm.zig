//! `/test/vm`: the memory calls a runtime is built on: `mmap`, `munmap`,
//! `mprotect`, `madvise`, `brk`, and memory that is only there once it is
//! touched.
//!
//! Without arguments it runs the checks that must succeed and exits with
//! 0, or with the number of the first failing check. With one argument it
//! does something a program is killed for, and the kernel test expects
//! status 255:
//!
//!   none      read a page of a `PROT_NONE` reservation
//!   readonly  write to a read-only page
//!   unmapped  read a page that was unmapped
//!   pasteof   read a page of a file's mapping past the end of the file
//!   filereadonly  write to a read-only mapping of a file
//!   stack     recurse until the stack's reservation (8 MiB) is used up
//!   oom       touch more memory than the process's limit allows
//!
//! and with `deep` it recurses through 2 MiB of stack, which must work:
//! the stack grows as it is used.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const PROT = abi.PROT;
const MAP = abi.MAP;
const Sys = lib.Sys;

const PAGE = 4096;
const MIB = 1024 * 1024;
const GIB = 1024 * MIB;
const RW = PROT.READ | PROT.WRITE;

fn expect(ok: bool, check: u64) void {
    if (!ok) lib.exit(check);
}

fn bytes(addr: u64, len: usize) []volatile u8 {
    return @as([*]volatile u8, @ptrFromInt(addr))[0..len];
}

fn allZero(addr: u64, len: usize) bool {
    for (bytes(addr, len)) |b| {
        if (b != 0) return false;
    }
    return true;
}

/// Use about `depth` KiB of stack and return a value that depends on all of it.
noinline fn recurse(depth: usize) usize {
    var pad: [1000]u8 = undefined;
    const p: *volatile [1000]u8 = &pad;
    p[depth % pad.len] = @truncate(depth);
    if (depth == 0) return p[0];
    return recurse(depth - 1) + p[depth % pad.len];
}

fn eql(s: [*:0]const u8, want: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(s), want);
}

pub fn main() noreturn {
    const args = lib.argv();
    if (args.len > 1) {
        const mode = args[1];
        if (eql(mode, "none")) {
            const a = lib.mmap(0, 16 * PAGE, PROT.NONE, 0);
            _ = bytes(a, 1)[0];
        } else if (eql(mode, "readonly")) {
            const a = lib.mmap(0, PAGE, PROT.READ, 0);
            bytes(a, 1)[0] = 1;
        } else if (eql(mode, "unmapped")) {
            const a = lib.mmap(0, 4 * PAGE, RW, 0);
            bytes(a + PAGE, 1)[0] = 1;
            _ = lib.munmap(a + PAGE, PAGE);
            _ = bytes(a + PAGE, 1)[0];
        } else if (eql(mode, "stack")) {
            _ = recurse(16 * 1024); // 16 MiB: past the reservation
        } else if (eql(mode, "pasteof")) {
            // A page of a file's mapping that lies wholly past the file's end.
            const fd = lib.open("/etc/motd");
            const m = lib.syscall6(Sys.mmap, 0, 2 * PAGE, PROT.READ, MAP.PRIVATE, fd, 0);
            if (lib.isError(m) or bytes(m, 1)[0] != 'W') lib.exit(1);
            _ = bytes(m + PAGE, 1)[0];
        } else if (eql(mode, "filereadonly")) {
            const fd = lib.open("/etc/motd");
            const m = lib.syscall6(Sys.mmap, 0, PAGE, PROT.READ, MAP.PRIVATE, fd, 0);
            if (lib.isError(m)) lib.exit(1);
            bytes(m, 1)[0] = 'x';
        } else if (eql(mode, "oom")) {
            const a = lib.mmap(0, GIB, RW, 0);
            var at: u64 = 0;
            while (at < GIB) : (at += PAGE) bytes(a + at, 1)[0] = 1;
        } else if (eql(mode, "deep")) {
            lib.exit(if (recurse(2 * 1024) != 0 or true) 0 else 1); // 2 MiB of stack
        }
        lib.exit(98); // it survived what should have killed it
    }

    // --- brk: the heap grows and shrinks, and what comes back is zeroed.
    const heap0 = lib.brk(0);
    expect(heap0 != 0 and !lib.isError(heap0), 1);
    expect(lib.brk(heap0 + 100_000) == heap0 + 100_000, 2);
    expect(allZero(heap0, 100_000), 3);
    @memset(bytes(heap0, 100_000), 0xAB);
    expect(lib.brk(heap0 + 10) == heap0 + 10, 4); // shrink to within the first page
    expect(bytes(heap0, 10)[9] == 0xAB, 5); // the page that is kept keeps its contents
    expect(lib.brk(heap0 + 100_000) == heap0 + 100_000, 6);
    expect(allZero(heap0 + PAGE, 100_000 - PAGE), 7); // the pages that went came back empty
    expect(lib.brk(heap0 - 1) == heap0 + 100_000, 8); // below the start: refused, unchanged
    expect(lib.brk(heap0) == heap0, 9);

    // --- A reservation far larger than memory costs nothing; committing
    // a piece of it gives memory, and only that piece.
    const big = lib.mmap(0, 4 * GIB, PROT.NONE, MAP.NORESERVE);
    expect(!lib.isError(big) and big % PAGE == 0, 10);
    const window = big + 3 * GIB - MIB / 2; // not at either end
    expect(lib.mprotect(window, MIB, RW) == 0, 11);
    expect(allZero(window, MIB), 12);
    for (bytes(window, MIB), 0..) |*b, i| b.* = @truncate(i * 7);
    for (bytes(window, MIB), 0..) |b, i| expect(b == @as(u8, @truncate(i * 7)), 13);
    // Protecting it and unprotecting it again loses nothing.
    expect(lib.mprotect(window, MIB, PROT.NONE) == 0, 14);
    expect(lib.mprotect(window, MIB, PROT.READ) == 0, 15);
    expect(bytes(window, MIB)[12345] == @as(u8, @truncate(12345 * 7)), 16);
    expect(lib.munmap(big, 4 * GIB) == 0, 17);

    // --- A mapping reads as zeroes before anything is written to it.
    const a = lib.mmap(0, 16 * PAGE, RW, 0);
    expect(!lib.isError(a), 20);
    expect(allZero(a, 16 * PAGE), 21);
    @memset(bytes(a, 16 * PAGE), 0x5A);
    // Unmapping the middle leaves both sides as they were.
    expect(lib.munmap(a + 4 * PAGE, 8 * PAGE) == 0, 22);
    expect(bytes(a, 4 * PAGE)[4 * PAGE - 1] == 0x5A and bytes(a + 12 * PAGE, 1)[0] == 0x5A, 23);
    // The hole can be mapped again, exactly there, and is empty.
    expect(lib.mmap(a + 4 * PAGE, 8 * PAGE, RW, MAP.FIXED_NOREPLACE) == a + 4 * PAGE, 24);
    expect(allZero(a + 4 * PAGE, 8 * PAGE), 25);
    // What is taken is not given twice, unless asked to replace it.
    expect(lib.mmap(a, PAGE, RW, MAP.FIXED_NOREPLACE) == lib.err(.EXIST), 26);
    expect(lib.mmap(a, PAGE, RW, MAP.FIXED) == a, 27);
    expect(allZero(a, PAGE) and bytes(a + PAGE, 1)[0] == 0x5A, 28); // replaced: fresh; its neighbour: untouched
    // Without a fixed address, mappings are placed downwards and never overlap.
    const b = lib.mmap(0, PAGE, RW, 0);
    const c = lib.mmap(0, PAGE, RW, 0);
    expect(!lib.isError(b) and !lib.isError(c) and b != c and (b + PAGE <= a or b >= a + 16 * PAGE), 29);
    // A free address given as a hint is used.
    const hint = a - 64 * MIB;
    expect(lib.mmap(hint, PAGE, RW, 0) == hint, 30);
    expect(lib.munmap(hint, PAGE) == 0 and lib.munmap(b, PAGE) == 0 and lib.munmap(c, PAGE) == 0, 31);

    // --- madvise gives pages back; they return as zeroes.
    expect(bytes(a + 2 * PAGE, 1)[0] == 0x5A, 32);
    expect(lib.syscall(Sys.madvise, a + 2 * PAGE, PAGE, abi.MADV.DONTNEED) == 0, 33);
    expect(allZero(a + 2 * PAGE, PAGE) and bytes(a + 3 * PAGE, 1)[0] == 0x5A, 34);
    expect(lib.syscall(Sys.madvise, a, PAGE, 14) == 0, 35); // advice the kernel ignores

    // --- The kernel can write to memory nothing has touched yet: a read
    // into a fresh mapping, across a page boundary.
    const fresh = lib.mmap(0, 4 * PAGE, RW, 0);
    const fd = lib.open("/etc/motd");
    expect(!lib.isError(fd), 36);
    const n = lib.read(fd, @as([*]u8, @ptrFromInt(fresh + PAGE - 5))[0..64]);
    expect(n == 17, 37);
    expect(std.mem.eql(u8, @as([*]const u8, @ptrFromInt(fresh + PAGE - 5))[0..16], "Welcome to MyOS!"), 38);
    _ = lib.close(fd);
    // And read from it: a path in memory that reads as zeroes is the empty path.
    expect(lib.syscall(Sys.open, fresh + 2 * PAGE, 0, 0) == lib.err(.NOENT), 39);
    // But not where the program may not: reading into read-only or
    // reserved memory fails, and kills nothing.
    expect(lib.mprotect(fresh, PAGE, PROT.READ) == 0, 40);
    const fd2 = lib.open("/etc/motd");
    expect(lib.read(fd2, @as([*]u8, @ptrFromInt(fresh))[0..8]) == lib.err(.FAULT), 41);
    expect(lib.mprotect(fresh + 3 * PAGE, PAGE, PROT.NONE) == 0, 42);
    expect(lib.read(fd2, @as([*]u8, @ptrFromInt(fresh + 3 * PAGE))[0..8]) == lib.err(.FAULT), 43);
    _ = lib.close(fd2);

    // --- Memory can be made executable.
    const code = lib.mmap(0, PAGE, RW, 0);
    bytes(code, 6)[0..6].* = .{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 }; // mov $42, %eax; ret
    expect(lib.mprotect(code, PAGE, PROT.READ | PROT.EXEC) == 0, 44);
    const f: *const fn () callconv(.c) u32 = @ptrFromInt(code);
    expect(f() == 42, 45);

    // --- What is refused.
    expect(lib.mmap(0, 0, RW, 0) == lib.err(.INVAL), 50);
    expect(lib.syscall6(Sys.mmap, 0, PAGE, RW, MAP.PRIVATE, 99, 0) == lib.err(.BADF), 51); // a file that is not open
    expect(lib.syscall6(Sys.mmap, 0, PAGE, RW, MAP.ANONYMOUS, 0, 0) == lib.err(.INVAL), 52); // neither private nor shared
    expect(lib.mmap(0, PAGE, 8, 0) == lib.err(.INVAL), 53); // unknown permission
    expect(lib.mmap(123, PAGE, RW, MAP.FIXED) == lib.err(.INVAL), 54); // not page aligned
    expect(lib.isError(lib.mmap(0xFFFF_8000_0000_0000, PAGE, RW, MAP.FIXED)), 55); // kernel address
    expect(lib.isError(lib.mmap(0, PAGE, RW, MAP.FIXED)), 56); // the first 64 KiB stay empty
    expect(lib.mmap(0, 1 << 47, RW, 0) == lib.err(.NOMEM), 57); // more than there is
    expect(lib.munmap(a + 1, PAGE) == lib.err(.INVAL), 58);
    expect(lib.munmap(a, 0) == lib.err(.INVAL), 59);
    expect(lib.munmap(hint, PAGE) == 0, 60); // unmapping nothing is fine
    expect(lib.mprotect(hint, PAGE, RW) == lib.err(.NOMEM), 61); // nothing there
    expect(lib.mprotect(a + 15 * PAGE, 2 * PAGE, RW) == lib.err(.NOMEM) or lib.mprotect(a + 15 * PAGE, 2 * PAGE, RW) == 0, 62);
    expect(lib.syscall(Sys.madvise, hint, PAGE, abi.MADV.DONTNEED) == lib.err(.NOMEM), 63);

    // --- A file mapped privately: its bytes, read when a page is first
    // touched; zeroes after its end; changes that stay the program's own.
    const motd = "Welcome to MyOS!\n";
    const small = lib.open("/etc/motd");
    const fm = lib.syscall6(Sys.mmap, 0, PAGE, RW, MAP.PRIVATE, small, 0);
    expect(!lib.isError(fm), 81);
    expect(lib.close(small) == 0, 82); // the mapping outlives the descriptor
    expect(std.mem.eql(u8, @volatileCast(bytes(fm, motd.len)), motd), 83);
    expect(allZero(fm + motd.len, PAGE - motd.len), 84);
    bytes(fm, 1)[0] = 'w';
    var back: [32]u8 = undefined;
    const again = lib.open("/etc/motd");
    expect(lib.read(again, &back) == motd.len and back[0] == 'W', 85); // the file is as it was
    // Given back, the page comes from the file again.
    expect(lib.syscall(Sys.madvise, fm, PAGE, abi.MADV.DONTNEED) == 0 and bytes(fm, 1)[0] == 'W', 86);
    expect(lib.munmap(fm, PAGE) == 0, 87);

    // A larger file, from an offset: one_page for one_page what `pread` gives,
    // also after the mapping has been cut up.
    const elf = lib.open("/fixtures/rust-hello-static"); // 400 KiB in every build
    const file_span = 6 * PAGE;
    const file_at = 3 * PAGE;
    const bm = lib.syscall6(Sys.mmap, 0, file_span, PROT.READ, MAP.PRIVATE, elf, file_at);
    expect(!lib.isError(bm), 88);
    expect(lib.mprotect(bm + 2 * PAGE, PAGE, RW) == 0, 89); // three regions now
    expect(lib.munmap(bm + 4 * PAGE, PAGE) == 0, 90); // and a hole
    var one_page: [PAGE]u8 = undefined;
    for ([_]u64{ 5, 0, 2, 3, 1 }) |nth| { // in no particular order
        expect(lib.syscall6(Sys.pread64, elf, @intFromPtr(&one_page), PAGE, file_at + nth * PAGE, 0, 0) == PAGE, 91);
        expect(std.mem.eql(u8, @volatileCast(bytes(bm + nth * PAGE, PAGE)), &one_page), 92);
    }
    bytes(bm + 2 * PAGE, 1)[0] +%= 1; // the writable page takes a write
    // The same file read-only and shared, which is no different here; and
    // put at a chosen address over part of the first mapping, as a
    // dynamic loader places a library's segments.
    const sm = lib.syscall6(Sys.mmap, 0, PAGE, PROT.READ, MAP.SHARED, elf, 0);
    expect(!lib.isError(sm) and std.mem.eql(u8, @volatileCast(bytes(sm, 4)), "\x7fELF"), 93);
    expect(lib.syscall6(Sys.mmap, bm, PAGE, PROT.READ, MAP.PRIVATE | MAP.FIXED, elf, 0) == bm, 94);
    expect(std.mem.eql(u8, @volatileCast(bytes(bm, 4)), "\x7fELF"), 95);
    // What is refused.
    expect(lib.syscall6(Sys.mmap, 0, PAGE, RW, MAP.SHARED, elf, 0) == lib.err(.ACCES), 96); // files cannot be written
    expect(lib.syscall6(Sys.mmap, 0, PAGE, PROT.READ, MAP.PRIVATE, elf, 123) == lib.err(.INVAL), 97); // offset not a page
    expect(lib.syscall6(Sys.mmap, 0, PAGE, PROT.READ, MAP.PRIVATE, 1, 0) == lib.err(.NODEV), 98); // the console
    expect(lib.syscall6(Sys.mmap, 0, PAGE, PROT.READ, MAP.PRIVATE, elf, ~@as(u64, 0xFFF)) == lib.err(.INVAL), 99);
    expect(lib.syscall6(Sys.mremap, sm, PAGE, 2 * PAGE, 0, 0, 0) == lib.err(.NOMEM), 100); // a file's mapping does not grow
    expect(lib.munmap(bm, file_span) == 0 and lib.munmap(sm, PAGE) == 0, 101);
    _ = lib.close(elf);
    _ = lib.close(again);

    // --- mremap: a mapping shrinks and grows where it is.
    const m = lib.mmap(0, 8 * PAGE, RW, 0);
    bytes(m, 1)[0] = 0x5A;
    bytes(m + 3 * PAGE, 1)[0] = 0x5B;
    expect(lib.syscall6(Sys.mremap, m, 8 * PAGE, 4 * PAGE, 0, 0, 0) == m, 64); // the end goes
    expect(lib.mprotect(m + 4 * PAGE, PAGE, RW) == lib.err(.NOMEM), 65);
    expect(lib.syscall6(Sys.mremap, m, 4 * PAGE, 6 * PAGE, 0, 0, 0) == m, 66); // and comes back, empty
    expect(bytes(m, 1)[0] == 0x5A and bytes(m + 3 * PAGE, 1)[0] == 0x5B and bytes(m + 5 * PAGE, 1)[0] == 0, 67);
    expect(lib.syscall6(Sys.mremap, m, 6 * PAGE, 6 * PAGE, 0, 0, 0) == m, 68); // the same size
    // Not into what is mapped already, with or without leave to move:
    // mappings are not moved.
    const stop = lib.mmap(m + 6 * PAGE, PAGE, RW, MAP.FIXED_NOREPLACE);
    expect(stop == m + 6 * PAGE, 69);
    expect(lib.syscall6(Sys.mremap, m, 6 * PAGE, 8 * PAGE, 0, 0, 0) == lib.err(.NOMEM), 71);
    expect(lib.syscall6(Sys.mremap, m, 6 * PAGE, 8 * PAGE, abi.MREMAP.MAYMOVE, 0, 0) == lib.err(.NOMEM), 72);
    // Nor the middle of a mapping; nor what is not mapped.
    expect(lib.syscall6(Sys.mremap, m, 2 * PAGE, 3 * PAGE, 0, 0, 0) == lib.err(.NOMEM), 73);
    expect(lib.syscall6(Sys.mremap, hint, PAGE, 2 * PAGE, 0, 0, 0) == lib.err(.FAULT), 74);
    expect(lib.syscall6(Sys.mremap, m + 1, PAGE, 2 * PAGE, 0, 0, 0) == lib.err(.INVAL), 75);
    expect(lib.syscall6(Sys.mremap, m, 0, PAGE, 0, 0, 0) == lib.err(.INVAL), 76);
    expect(lib.syscall6(Sys.mremap, m, PAGE, 0, 0, 0, 0) == lib.err(.INVAL), 77);
    expect(lib.syscall6(Sys.mremap, m, PAGE, 2 * PAGE, abi.MREMAP.FIXED, 0, 0) == lib.err(.INVAL), 78);
    expect(lib.munmap(m, 7 * PAGE) == 0, 79);

    // --- The stack grows as it is used.
    expect(recurse(512) < 512 * 256, 80); // half a megabyte

    lib.exit(0);
}
