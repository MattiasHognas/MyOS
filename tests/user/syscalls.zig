//! `/test/syscalls`: check from ring 3 that the kernel validates syscall
//! buffers and file descriptors.
//!
//! Exits with 0 if every check passes, otherwise with the number of the first
//! failing check, so the kernel test can report which one broke. Only invalid
//! values the kernel rejects without touching memory are used here; unmapped
//! user pointers are not tested yet (they need fault-safe user copies, todo 2.1).

const lib = @import("lib");

pub const panic = lib.panic;

const ERR = lib.ERR;
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

/// Program entry point: run the checks in order.
export fn _start() callconv(.c) noreturn {
    var buf: [64]u8 = undefined;
    const path = "/etc/motd";

    // write: kernel pointer, too long, crossing the end of user space, empty.
    expect(lib.syscall(0, KERNEL_PTR, 4, 0) == ERR); // 1
    expect(lib.syscall(0, @intFromPtr(&buf), 4097, 0) == ERR); // 2
    expect(lib.syscall(0, NEAR_USER_END, 32, 0) == ERR); // 3
    expect(lib.syscall(0, @intFromPtr(&buf), 0, 0) == 0); // 4

    // open: kernel pointer, path longer than 256 bytes, missing file.
    expect(lib.syscall(4, KERNEL_PTR, path.len, 0) == ERR); // 5
    expect(lib.syscall(4, @intFromPtr(path.ptr), 300, 0) == ERR); // 6
    expect(lib.open("/does/not/exist") == ERR); // 7

    // read/close on descriptors that are out of range or not open.
    expect(lib.read(99, &buf) == ERR); // 8
    expect(lib.read(5, &buf) == ERR); // 9
    expect(lib.syscall(6, 99, 0, 0) == ERR); // 10

    // A normal open/read/close cycle, then use after close.
    const fd = lib.open(path);
    expect(fd != ERR); // 11
    expect(lib.syscall(5, fd, KERNEL_PTR, 16) == ERR); // 12: kernel buffer
    expect(lib.read(fd, &buf) == "Welcome to MyOS!\n".len); // 13
    expect(lib.read(fd, &buf) == 0); // 14: end of file
    expect(lib.syscall(6, fd, 0, 0) == 0); // 15
    expect(lib.syscall(6, fd, 0, 0) == ERR); // 16: double close
    expect(lib.read(fd, &buf) == ERR); // 17: read after close

    // Descriptor table exhaustion: 16 slots, the 17th open fails.
    var fds: [16]u64 = undefined;
    for (&fds) |*f| {
        f.* = lib.open(path);
        expect(f.* != ERR); // 18-33
    }
    expect(lib.open(path) == ERR); // 34
    for (fds) |f| lib.close(f);
    const again = lib.open(path);
    expect(again != ERR); // 35: slots are reusable after close
    lib.close(again);

    // Unknown syscall numbers fail; gettid works.
    expect(lib.syscall(999, 0, 0, 0) == ERR); // 36
    expect(lib.syscall(3, 0, 0, 0) != 0); // 37: user threads never have ID 0

    lib.exit(0);
}
