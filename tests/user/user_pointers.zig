//! `/test/user_pointers`: pass syscalls pointers to memory that is unmapped,
//! partly mapped or read-only. The kernel must fail each call with `ERR`
//! instead of crashing or killing this process, and valid buffers that cross
//! page boundaries must keep working.
//!
//! Exits with 0 if every check passes, otherwise with the number of the first
//! failing check.

const std = @import("std");
const lib = @import("lib");

pub const panic = lib.panic;

const ERR = lib.ERR;
/// Nothing is mapped here: programs are linked far below, the stack is far above.
const UNMAPPED: u64 = 0x1000_0000;
/// First byte above the user stack (`STACK_TOP` in src/kernel/process.zig).
/// The page below it is mapped, the page starting here is not.
const STACK_TOP: u64 = 0x0000_7FFF_FFFF_0000;
const PAGE = 4096;
const motd = "Welcome to MyOS!\n";

/// Three pages of writable memory, so buffers inside it can cross page boundaries.
var big: [3 * PAGE]u8 align(PAGE) = undefined;

var check_no: u64 = 0;

/// Record check number `check_no + 1`; exit with that number if `ok` is false.
fn expect(ok: bool) void {
    check_no += 1;
    if (!ok) lib.exit(check_no);
}

/// Program entry point: run the checks in order.
export fn _start() callconv(.c) noreturn {
    const path = "/etc/motd";

    // write: null, unmapped, starting mapped but running into an unmapped page.
    expect(lib.syscall(0, 0, 4, 0) == ERR); // 1
    expect(lib.syscall(0, UNMAPPED, 4, 0) == ERR); // 2
    expect(lib.syscall(0, STACK_TOP - 8, 16, 0) == ERR); // 3
    // ...while the last mapped bytes alone, and a page-crossing buffer, work.
    const edge: *[8]u8 = @ptrFromInt(STACK_TOP - 8);
    edge.* = "at edge\n".*;
    expect(lib.syscall(0, STACK_TOP - 8, 8, 0) == 8); // 4
    const msg = "across pages\n";
    @memcpy(big[PAGE - 6 ..][0..msg.len], msg);
    expect(lib.syscall(0, @intFromPtr(&big) + PAGE - 6, msg.len, 0) == msg.len); // 5
    // A zero-length write never touches memory.
    expect(lib.syscall(0, UNMAPPED, 0, 0) == 0); // 6
    // Address + length overflows, or runs off the end of user space.
    expect(lib.syscall(0, std.math.maxInt(u64) - 3, 8, 0) == ERR); // 7
    expect(lib.syscall(0, 0x0000_7FFF_FFFF_FFF8, 16, 0) == ERR); // 8

    // open and run: the same kinds of bad path pointers.
    expect(lib.syscall(4, 0, path.len, 0) == ERR); // 9
    expect(lib.syscall(4, UNMAPPED, path.len, 0) == ERR); // 10
    expect(lib.syscall(4, STACK_TOP - 4, path.len, 0) == ERR); // 11
    expect(lib.syscall(8, 0, path.len, 0) == ERR); // 12
    expect(lib.syscall(8, UNMAPPED, path.len, 0) == ERR); // 13
    expect(lib.syscall(8, STACK_TOP - 4, path.len, 0) == ERR); // 14

    // read: bad destination buffers.
    const fd = lib.open(path);
    expect(fd != ERR); // 15
    expect(lib.syscall(5, fd, 0, 16) == ERR); // 16
    expect(lib.syscall(5, fd, UNMAPPED, 16) == ERR); // 17
    expect(lib.syscall(5, fd, STACK_TOP - 8, 16) == ERR); // 18: partly mapped
    expect(lib.syscall(5, fd, std.math.maxInt(u64) - 3, 8) == ERR); // 19
    // Reading into this program's own read-only code fails and changes nothing.
    const code: *const volatile [16]u8 = @ptrFromInt(@intFromPtr(&_start));
    const code_before = code.*;
    expect(lib.syscall(5, fd, @intFromPtr(code), 16) == ERR); // 20
    const code_after = code.*;
    expect(std.mem.eql(u8, &code_before, &code_after)); // 21

    // None of the failed reads moved the file offset, and a buffer that
    // crosses a page boundary receives the whole file.
    const dst = big[2 * PAGE - 5 ..][0..64];
    expect(lib.read(fd, dst) == motd.len); // 22
    expect(std.mem.eql(u8, dst[0..motd.len], motd)); // 23
    lib.close(fd);

    // A large read starting one byte before a page boundary crosses at least
    // two boundaries (the file is larger than a page; its size depends on the
    // build mode) and leaves the byte before the buffer alone.
    const elf = lib.open("/bin/hello");
    expect(elf != ERR); // 24
    @memset(&big, 0);
    const n = lib.read(elf, big[PAGE - 1 ..]);
    expect(n != ERR and n > PAGE + 1 and n <= big.len - (PAGE - 1)); // 25
    expect(std.mem.eql(u8, big[PAGE - 1 ..][0..4], "\x7fELF") and big[PAGE - 2] == 0); // 26
    lib.close(elf);

    // Still alive and able to make ordinary syscalls.
    expect(lib.syscall(3, 0, 0, 0) != 0); // 27
    lib.exit(0);
}
