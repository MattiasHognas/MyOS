//! `/test/memfd`: memory files and shared mappings as Linux has them.
//! `memfd_create` makes a file in memory that is read, written, sized
//! and mapped; two shared mappings of it see each other's writes, one
//! writable and one executable (what the .NET JIT does: code written in
//! one place runs from another, no page both); a private mapping's writes
//! stay its own; a child made by `fork` shares shared mappings, anonymous
//! ones too; seals refuse what they say; the mapping outlives the
//! descriptor; `/proc/self/maps` shows it. Exits with 0, or with the
//! number of the first failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

const PAGE = 4096;
const PROT_READ = 1;
const PROT_WRITE = 2;
const PROT_EXEC = 4;
const SHARED = 0x01;
const PRIVATE = 0x02;
const ANON = 0x20;

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn mmap(addr: u64, len: u64, prot: u64, flags: u64, fd: i64, off: u64) u64 {
    return lib.syscall6(Sys.mmap, addr, len, prot, flags, @bitCast(fd), off);
}

fn create(name: [*:0]const u8, flags: u64) u64 {
    return lib.syscall(Sys.memfd_create, @intFromPtr(name), flags, 0);
}

fn fcntl(fd: u64, cmd: u64, arg: u64) u64 {
    return lib.syscall(Sys.fcntl, fd, cmd, arg);
}

fn wait(pid: u64) i32 {
    var status: i32 = -1;
    _ = lib.syscall6(Sys.wait4, pid, @intFromPtr(&status), 0, 0, 0, 0);
    return status;
}

pub fn main() noreturn {
    // --- Making one.
    expect(create("x", 0x100) == lib.err(.INVAL), 1); // unknown flag
    expect(create("x", abi.MFD.HUGETLB) == lib.err(.INVAL), 2);
    var long: [300:0]u8 = @splat('a');
    expect(create(&long, 0) == lib.err(.INVAL), 3);
    expect(lib.syscall(Sys.memfd_create, 8, 0, 0) == lib.err(.FAULT), 4);
    const fd = create("jit", abi.MFD.CLOEXEC | abi.MFD.ALLOW_SEALING);
    expect(!lib.isError(fd), 5);
    expect(fcntl(fd, 1, 0) == 1, 6); // FD_CLOEXEC

    // --- A file: written, read back, sized.
    expect(lib.syscall(Sys.write, fd, @intFromPtr("hello"), 5) == 5, 7);
    var buf: [16]u8 = undefined;
    expect(lib.syscall6(Sys.pread64, fd, @intFromPtr(&buf), 5, 0, 0, 0) == 5 and std.mem.eql(u8, buf[0..5], "hello"), 8);
    var st: abi.Stat = .{};
    expect(lib.syscall(Sys.fstat, fd, @intFromPtr(&st), 0) == 0 and st.size == 5, 9);
    expect(lib.syscall(Sys.ftruncate, fd, 2 * PAGE, 0) == 0, 10);
    expect(lib.syscall6(Sys.pread64, fd, @intFromPtr(&buf), 16, 2 * PAGE - 8, 0, 0) == 8 and buf[0] == 0, 11);

    // --- Two shared mappings: written in one, seen in the other; code
    // written through the writable one runs through the executable one.
    const rw = mmap(0, 2 * PAGE, PROT_READ | PROT_WRITE, SHARED, @bitCast(fd), 0);
    expect(!lib.isError(rw), 12);
    const rx = mmap(0, 2 * PAGE, PROT_READ | PROT_EXEC, SHARED, @bitCast(fd), 0);
    expect(!lib.isError(rx) and rx != rw, 13);
    const w: [*]volatile u8 = @ptrFromInt(rw);
    const x: [*]volatile u8 = @ptrFromInt(rx);
    expect(w[0] == 'h' and x[4] == 'o', 14); // the file's contents
    const code = [_]u8{ 0xB8, 42, 0, 0, 0, 0xC3 }; // mov eax, 42; ret
    for (code, 0..) |b, i| w[PAGE + i] = b;
    const f: *const fn () callconv(.c) u32 = @ptrFromInt(rx + PAGE);
    expect(f() == 42, 15);
    w[0] = 'J';
    expect(x[0] == 'J', 16);
    expect(lib.syscall6(Sys.pread64, fd, @intFromPtr(&buf), 1, 0, 0, 0) == 1 and buf[0] == 'J', 17); // and the file
    _ = lib.syscall6(Sys.pwrite64, fd, @intFromPtr("K"), 1, 1, 0, 0);
    expect(w[1] == 'K' and x[1] == 'K', 18);
    // The executable mapping cannot be written, nor made writable here
    // through mprotect (it may, the descriptor is open for writing; a
    // write through it from a child is what is checked).
    const writer = lib.syscall(Sys.fork, 0, 0, 0);
    if (writer == 0) {
        x[0] = 1; // faults: the mapping is not writable
        lib.exit(0);
    }
    expect(wait(writer) & 0x7F == 11, 19); // SIGSEGV

    // --- A private mapping: its writes are its own.
    const priv = mmap(0, PAGE, PROT_READ | PROT_WRITE, PRIVATE, @bitCast(fd), 0);
    expect(!lib.isError(priv), 20);
    const pp: [*]volatile u8 = @ptrFromInt(priv);
    expect(pp[0] == 'J', 21);
    pp[0] = 'P';
    expect(w[0] == 'J', 22);

    // --- fork: the child shares the shared mappings, anonymous ones too.
    const anon = mmap(0, PAGE, PROT_READ | PROT_WRITE, SHARED | ANON, -1, 0);
    expect(!lib.isError(anon), 23);
    const a: *volatile u64 = @ptrFromInt(anon);
    a.* = 1;
    const child = lib.syscall(Sys.fork, 0, 0, 0);
    if (child == 0) {
        if (a.* != 1 or w[0] != 'J') lib.exit(40);
        a.* = 2;
        w[2] = 'C';
        pp[0] = 'Q'; // private: its own copy
        lib.exit(0);
    }
    expect(wait(child) == 0, 24);
    expect(a.* == 2, 25);
    expect(w[2] == 'C' and x[2] == 'C', 26);
    expect(pp[0] == 'P', 27);

    // --- /proc/self/maps shows the shared mappings with the name.
    {
        const maps = lib.syscall(Sys.open, @intFromPtr("/proc/self/maps"), 0, 0);
        expect(!lib.isError(maps), 28);
        var text: [8192]u8 = undefined;
        var n: usize = 0;
        while (n < text.len) {
            const got = lib.syscall(Sys.read, maps, @intFromPtr(&text[n]), text.len - n);
            if (lib.isError(got) or got == 0) break;
            n += got;
        }
        _ = lib.syscall(Sys.close, maps, 0, 0);
        expect(std.mem.indexOf(u8, text[0..n], "rw-s") != null, 29);
        expect(std.mem.indexOf(u8, text[0..n], "r-xs") != null, 30);
        expect(std.mem.indexOf(u8, text[0..n], "/memfd:jit (deleted)") != null, 31);
    }

    // --- Seals.
    expect(fcntl(fd, abi.F_GET_SEALS, 0) == 0, 32);
    expect(fcntl(fd, abi.F_ADD_SEALS, abi.F_SEAL.SHRINK) == 0, 33);
    expect(lib.syscall(Sys.ftruncate, fd, PAGE, 0) == lib.err(.PERM), 34);
    expect(lib.syscall(Sys.ftruncate, fd, 3 * PAGE, 0) == 0, 35); // growing still may
    expect(fcntl(fd, abi.F_ADD_SEALS, abi.F_SEAL.WRITE) == lib.err(.BUSY), 36); // a writable mapping exists
    expect(lib.syscall(Sys.munmap, rw, 2 * PAGE, 0) == 0, 37);
    // The executable mapping may write too, as on Linux: its descriptor
    // is open for writing, whatever its protection is now.
    expect(fcntl(fd, abi.F_ADD_SEALS, abi.F_SEAL.WRITE) == lib.err(.BUSY), 38);
    expect(lib.syscall(Sys.munmap, rx, 2 * PAGE, 0) == 0, 53);
    _ = lib.syscall(Sys.munmap, priv, PAGE, 0); // a private mapping does not count
    expect(fcntl(fd, abi.F_ADD_SEALS, abi.F_SEAL.WRITE | abi.F_SEAL.GROW) == 0, 39);
    expect(lib.syscall(Sys.write, fd, @intFromPtr("z"), 1) == lib.err(.PERM), 40);
    expect(lib.isError(mmap(0, PAGE, PROT_READ | PROT_WRITE, SHARED, @bitCast(fd), 0)), 41);
    const ro = mmap(0, PAGE, PROT_READ, SHARED, @bitCast(fd), 0);
    expect(!lib.isError(ro) and @as(*volatile u8, @ptrFromInt(ro)).* == 'J', 42);
    expect(lib.syscall(Sys.mprotect, ro, PAGE, PROT_READ | PROT_WRITE) == lib.err(.ACCES), 43);
    expect(lib.syscall(Sys.ftruncate, fd, 4 * PAGE, 0) == lib.err(.PERM), 44); // F_SEAL_GROW
    expect(fcntl(fd, abi.F_ADD_SEALS, abi.F_SEAL.SEAL) == 0, 45);
    expect(fcntl(fd, abi.F_ADD_SEALS, abi.F_SEAL.SHRINK) == lib.err(.PERM), 46);
    expect(fcntl(fd, abi.F_GET_SEALS, 0) == abi.F_SEAL.SEAL | abi.F_SEAL.SHRINK | abi.F_SEAL.WRITE | abi.F_SEAL.GROW, 47);
    // Without MFD_ALLOW_SEALING it comes sealed against seals.
    const plain = create("plain", 0);
    expect(fcntl(plain, abi.F_GET_SEALS, 0) == abi.F_SEAL.SEAL, 48);
    expect(fcntl(plain, abi.F_ADD_SEALS, abi.F_SEAL.WRITE) == lib.err(.PERM), 49);
    expect(fcntl(0, abi.F_GET_SEALS, 0) == lib.err(.INVAL), 50); // not a memory file

    // --- The mapping outlives the descriptor.
    _ = lib.syscall(Sys.close, fd, 0, 0);
    expect(@as(*volatile u8, @ptrFromInt(ro)).* == 'J' and @as([*]volatile u8, @ptrFromInt(ro))[2] == 'C', 51);
    expect(lib.syscall(Sys.munmap, ro, PAGE, 0) == 0, 52);
    _ = lib.syscall(Sys.munmap, anon, PAGE, 0);
    _ = lib.syscall(Sys.close, plain, 0, 0);
    lib.exit(0);
}
