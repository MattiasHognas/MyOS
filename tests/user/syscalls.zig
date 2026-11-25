//! `/test/syscalls`: check from ring 3 that the kernel validates syscall
//! buffers and file descriptors, and that every failure returns its own
//! Linux error number.
//!
//! Exits with 0 if every check passes, otherwise with the number of the first
//! failing check, so the kernel test can report which one broke. Only invalid
//! values the kernel rejects without touching memory are used here; unmapped,
//! partly mapped and read-only buffers are tested by `/test/user_pointers`.

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const Sys = lib.Sys;
const err = lib.err;

/// An address in the kernel half; user buffers must never point here.
const KERNEL_PTR: u64 = 0xFFFF_FFFF_8000_0000;
/// The last 16 bytes below the end of the user half.
const NEAR_USER_END: u64 = 0x0000_7FFF_FFFF_FFF0;

var check_no: u64 = 0;

/// Record check number `check_no + 1`; exit with that number if `ok` is false.
fn expect(ok: bool) void {
    check_no += 1;
    if (!ok) lib.exit(check_no);
}

/// A path of `len` 'a' characters after the leading slash, NUL-terminated.
var long_path: [600]u8 = undefined;
fn longPath(len: usize) u64 {
    @memset(&long_path, 'a');
    long_path[0] = '/';
    long_path[len] = 0;
    return @intFromPtr(&long_path);
}

/// Program entry point: run the checks in order.
pub fn main() noreturn {
    var buf: [64]u8 = undefined;
    const path = "/etc/motd";
    const bufp = @intFromPtr(&buf);

    // write: kernel pointer, crossing the end of user space, empty, bad descriptors.
    expect(lib.syscall(Sys.write, 1, KERNEL_PTR, 4) == err(.FAULT)); // 1
    expect(lib.syscall(Sys.write, 1, NEAR_USER_END, 32) == err(.FAULT)); // 2
    expect(lib.syscall(Sys.write, 1, bufp, 0) == 0); // 3
    expect(lib.syscall(Sys.write, 2, bufp, 0) == 0); // 4: stderr is the console too
    expect(lib.syscall(Sys.write, 0, bufp, 4) == err(.BADF)); // 5: stdin
    expect(lib.syscall(Sys.write, 99, bufp, 4) == err(.BADF)); // 6
    expect(lib.syscall(Sys.write, ~@as(u64, 0), bufp, 4) == err(.BADF)); // 7
    // A count over the 2 GiB limit is shortened to it; here the shortened
    // range still runs off the end of user space, from an unmapped address.
    expect(lib.syscall(Sys.write, 1, NEAR_USER_END - 0x8000, ~@as(u64, 0)) == err(.FAULT)); // 8

    // open: kernel pointer, path too long, empty path, missing file, write access.
    expect(lib.syscall(Sys.open, KERNEL_PTR, 0, 0) == err(.FAULT)); // 9
    expect(lib.syscall(Sys.open, longPath(300), 0, 0) == err(.NAMETOOLONG)); // 10
    expect(lib.syscall(Sys.open, longPath(256), 0, 0) == err(.NAMETOOLONG)); // 11: 256 bytes + NUL
    expect(lib.syscall(Sys.open, longPath(255), 0, 0) == err(.NOENT)); // 12: the longest path that fits
    expect(lib.open("") == err(.NOENT)); // 13
    expect(lib.open("/does/not/exist") == err(.NOENT)); // 14
    expect(lib.syscall(Sys.open, @intFromPtr(path), lib.abi.O.WRONLY, 0) == err(.ROFS)); // 15
    expect(lib.syscall(Sys.open, @intFromPtr(path), lib.abi.O.RDWR, 0) == err(.ROFS)); // 16
    expect(lib.syscall(Sys.open, @intFromPtr("/new"), lib.abi.O.CREAT | lib.abi.O.WRONLY, 0o644) == err(.ROFS)); // 17

    // read/close on descriptors that are out of range or not open.
    expect(lib.read(99, &buf) == err(.BADF)); // 18
    expect(lib.read(5, &buf) == err(.BADF)); // 19
    expect(lib.read(0, &buf) == err(.BADF)); // 20: no console input through read yet
    expect(lib.close(99) == err(.BADF)); // 21
    expect(lib.close(~@as(u64, 0)) == err(.BADF)); // 22

    // A normal open/read/close cycle, then use after close. The first file
    // gets descriptor 3: 0, 1 and 2 are the standard streams.
    const fd = lib.open(path);
    expect(fd == 3); // 23
    expect(lib.syscall(Sys.read, fd, KERNEL_PTR, 16) == err(.FAULT)); // 24: kernel buffer
    expect(lib.syscall(Sys.write, fd, bufp, 4) == err(.BADF)); // 25: files are read-only
    expect(lib.read(fd, &buf) == "Welcome to MyOS!\n".len); // 26
    expect(lib.read(fd, &buf) == 0); // 27: end of file
    expect(lib.close(fd) == 0); // 28
    expect(lib.close(fd) == err(.BADF)); // 29: double close
    expect(lib.read(fd, &buf) == err(.BADF)); // 30: read after close

    // Descriptor table exhaustion: 16 slots less the 3 standard streams.
    var fds: [13]u64 = undefined;
    for (&fds, 3..) |*f, want| {
        f.* = lib.open(path);
        expect(f.* == want); // 31-43
    }
    expect(lib.open(path) == err(.MFILE)); // 44
    for (fds) |f| _ = lib.close(f);
    const again = lib.open(path);
    expect(again == 3); // 45: slots are reusable after close, lowest first
    _ = lib.close(again);

    // sched_yield returns 0 and the process keeps running, with the same thread ID.
    const tid = lib.gettid();
    expect(lib.syscall(Sys.sched_yield, 0, 0, 0) == 0); // 46
    lib.yield();
    expect(lib.gettid() == tid); // 47
    expect(tid != 0 and !lib.isError(tid)); // 48: user threads never have ID 0

    // Unknown numbers fail with ENOSYS: unassigned Linux numbers, MyOS's old
    // numbers that Linux uses for calls MyOS lacks, the x32 range, garbage.
    for ([_]u64{ 4, 5, 6, 7, 8, 59, 231, 999, lib.Sys.PRIVATE_BASE + 2, 0x4000_0001, ~@as(u64, 0) }) |n| {
        expect(lib.syscall(n, 0, 0, 0) == err(.NOSYS)); // 49-59
    }

    // run: bad paths and files that are not programs.
    expect(lib.run("/does/not/exist") == err(.NOENT)); // 60
    expect(lib.run("/etc/motd") == err(.NOEXEC)); // 61
    expect(lib.run("") == err(.NOENT)); // 62
    expect(lib.syscall(Sys.myos_run, KERNEL_PTR, 0, 0) == err(.FAULT)); // 63
    expect(lib.syscall(Sys.myos_run, longPath(300), 0, 0) == err(.NAMETOOLONG)); // 64
    // A child's exit status is its low 8 bits, so it can never look like an error.
    expect(lib.run("/test/entry_regs") == 0); // 65

    lib.exit(0);
}
