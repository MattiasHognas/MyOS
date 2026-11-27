//! `/test/user_pointers`: pass syscalls pointers to memory that is unmapped,
//! partly mapped or read-only. The kernel must fail each call with `EFAULT`
//! (or return a short count when the first part of the buffer was usable)
//! instead of crashing or killing this process, and valid buffers that cross
//! page boundaries must keep working.
//!
//! Exits with 0 if every check passes, otherwise with the number of the first
//! failing check.

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
const Sys = lib.Sys;

const EFAULT = lib.err(.FAULT);
/// Nothing is mapped here: programs are linked far below, the stack is far above.
const UNMAPPED: u64 = 0x1000_0000;
/// First byte above the user stack: its position is random, so it is worked
/// out from the stack pointer the program starts with, which is in the
/// stack's last page.
/// The page below it is mapped, the page starting here is not.
var STACK_TOP: u64 = 0;
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

/// Program entry point. The checks use the top of the stack as memory
/// that ends at an unmapped page, so the program's own frames start a page
/// below it (and 16-byte aligned for the call).
pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ mov %%rsp, %%rdi
        \\ sub $4096, %%rsp
        \\ call userPointersMain
        \\ ud2
    );
}

/// Run the checks in order.
export fn userPointersMain(entry_rsp: u64) callconv(.c) noreturn {
    STACK_TOP = std.mem.alignForward(u64, entry_rsp, PAGE);
    const path = "/etc/motd";

    // write: null, unmapped, starting mapped but running into an unmapped page.
    expect(lib.syscall(Sys.write, 1, 0, 4) == EFAULT); // 1
    expect(lib.syscall(Sys.write, 1, UNMAPPED, 4) == EFAULT); // 2
    expect(lib.syscall(Sys.write, 1, STACK_TOP - 8, 16) == EFAULT); // 3
    // ...while the last mapped bytes alone, and a page-crossing buffer, work.
    const edge: *[8]u8 = @ptrFromInt(STACK_TOP - 8);
    edge.* = "at edge\n".*;
    expect(lib.syscall(Sys.write, 1, STACK_TOP - 8, 8) == 8); // 4
    const msg = "across pages\n";
    @memcpy(big[PAGE - 6 ..][0..msg.len], msg);
    expect(lib.syscall(Sys.write, 1, @intFromPtr(&big) + PAGE - 6, msg.len) == msg.len); // 5
    // A zero-length write never touches memory.
    expect(lib.syscall(Sys.write, 1, UNMAPPED, 0) == 0); // 6
    // Address + length overflows, or runs off the end of user space.
    expect(lib.syscall(Sys.write, 1, std.math.maxInt(u64) - 3, 8) == EFAULT); // 7
    expect(lib.syscall(Sys.write, 1, 0x0000_7FFF_FFFF_FFF8, 16) == EFAULT); // 8
    // A long write whose buffer runs into unmapped memory writes what it can
    // and returns the short count: the 512 bytes up to the top of the stack.
    const tail: *[512]u8 = @ptrFromInt(STACK_TOP - 512);
    @memset(tail, '.');
    tail[511] = '\n';
    expect(lib.syscall(Sys.write, 1, STACK_TOP - 512, 4096) == 512); // 9

    // open and run: the same kinds of bad path pointers. A path must be
    // NUL-terminated inside mapped memory.
    @memset(edge, 'x'); // runs off the mapped stack without a NUL
    expect(lib.syscall(Sys.open, 0, 0, 0) == EFAULT); // 10
    expect(lib.syscall(Sys.open, UNMAPPED, 0, 0) == EFAULT); // 11
    expect(lib.syscall(Sys.open, STACK_TOP - 4, 0, 0) == EFAULT); // 12
    expect(lib.syscall(Sys.execve, 0, 0, 0) == EFAULT); // 13
    expect(lib.syscall(Sys.execve, UNMAPPED, 0, 0) == EFAULT); // 14
    expect(lib.syscall(Sys.execve, STACK_TOP - 4, 0, 0) == EFAULT); // 15
    // A path that ends exactly at the last mapped byte is fine: the kernel
    // does not read past the NUL into the unmapped page.
    const at_end: *[path.len + 1]u8 = @ptrFromInt(STACK_TOP - (path.len + 1));
    at_end.* = (path ++ "\x00").*;
    const edge_fd = lib.syscall(Sys.open, @intFromPtr(at_end), 0, 0);
    expect(edge_fd == 3); // 16
    expect(lib.close(edge_fd) == 0); // 17

    // read: bad destination buffers.
    const fd = lib.open(path);
    expect(fd == 3); // 18
    expect(lib.syscall(Sys.read, fd, 0, 16) == EFAULT); // 19
    expect(lib.syscall(Sys.read, fd, UNMAPPED, 16) == EFAULT); // 20
    expect(lib.syscall(Sys.read, fd, STACK_TOP - 8, 16) == EFAULT); // 21: partly mapped
    expect(lib.syscall(Sys.read, fd, std.math.maxInt(u64) - 3, 8) == EFAULT); // 22
    // Reading into this program's own read-only code fails and changes nothing.
    const code: *const volatile [16]u8 = @ptrFromInt(@intFromPtr(&_start));
    const code_before = code.*;
    expect(lib.syscall(Sys.read, fd, @intFromPtr(code), 16) == EFAULT); // 23
    const code_after = code.*;
    expect(std.mem.eql(u8, &code_before, &code_after)); // 24

    // None of the failed reads moved the file offset, and a buffer that
    // crosses a page boundary receives the whole file.
    const dst = big[2 * PAGE - 5 ..][0..64];
    expect(lib.read(fd, dst) == motd.len); // 25
    expect(std.mem.eql(u8, dst[0..motd.len], motd)); // 26
    _ = lib.close(fd);

    // A large read starting one byte before a page boundary crosses at least
    // two boundaries (the file is larger than a page; its size depends on the
    // build mode) and leaves the byte before the buffer alone.
    const elf = lib.open("/bin/hello");
    expect(elf == 3); // 27
    @memset(&big, 0);
    const n = lib.read(elf, big[PAGE - 1 ..]);
    expect(!lib.isError(n) and n > PAGE + 1 and n <= big.len - (PAGE - 1)); // 28
    expect(std.mem.eql(u8, big[PAGE - 1 ..][0..4], "\x7fELF") and big[PAGE - 2] == 0); // 29
    _ = lib.close(elf);

    // A read whose buffer runs into unmapped memory stores what fits (in the
    // kernel's 256-byte steps), returns the short count and moves the offset
    // by exactly that: the next read continues where it stopped.
    const again = lib.open("/bin/hello");
    expect(again == 3); // 30
    expect(lib.syscall(Sys.read, again, STACK_TOP - 512, 4096) == 512); // 31
    expect(std.mem.eql(u8, tail[0..512], big[PAGE - 1 ..][0..512])); // 32
    expect(lib.read(again, tail[0..16]) == 16); // 33
    expect(std.mem.eql(u8, tail[0..16], big[PAGE - 1 + 512 ..][0..16])); // 34
    _ = lib.close(again);

    // Still alive and able to make ordinary syscalls.
    expect(lib.gettid() != 0); // 35
    lib.exit(0);
}
