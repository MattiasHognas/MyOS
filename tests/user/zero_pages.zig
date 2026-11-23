//! `/test/zero_pages`: check that every byte of memory this process was
//! given and has not written itself is zero: its `.bss` (which starts in
//! the middle of the last page of its data) and the rest of its stack. The
//! kernel test first fills all
//! free memory with a pattern, so anything the kernel failed to clear
//! shows up here as another program's (or the kernel's) leftovers.
//!
//! Exit status: 0 clean; 1 `.bss`; 2 the stack.

const std = @import("std");
const lib = @import("lib");

pub const panic = lib.panic;

const PAGE = 4096;

/// 256 KiB that nothing has written to.
var untouched: [64 * PAGE]u8 = undefined;

/// The stack pointer the program started with.
var entry_rsp: u64 = 0;

/// Program entry point. Naked: the stack is inspected before any
/// compiler-generated code has pushed anything.
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ mov %%rsp, entry_rsp(%%rip)
        \\ sub $8, %%rsp
        \\ call zeroPagesMain
        \\ ud2
    );
}

comptime {
    @export(&entry_rsp, .{ .name = "entry_rsp" });
}

export fn zeroPagesMain() callconv(.c) noreturn {
    const bss: *const volatile [untouched.len]u8 = &untouched;
    for (bss) |b| {
        if (b != 0) lib.exit(1);
    }

    // The stack is 16 KiB ending at the page boundary above the entry
    // stack pointer. Everything from its start up to well below the
    // frames in use now has never been written.
    const top = std.mem.alignForward(u64, entry_rsp, PAGE);
    const low = top - 4 * PAGE;
    const here = @frameAddress();
    const stack: [*]const volatile u8 = @ptrFromInt(low);
    for (0..here - 1024 - low) |i| {
        if (stack[i] != 0) lib.exit(2);
    }
    // And above the entry stack pointer, up to the top, except the eight
    // bytes the kernel leaves for a return address.
    const above: [*]const volatile u8 = @ptrFromInt(entry_rsp + 8);
    for (0..top - (entry_rsp + 8)) |i| {
        if (above[i] != 0) lib.exit(2);
    }

    lib.exit(0);
}
