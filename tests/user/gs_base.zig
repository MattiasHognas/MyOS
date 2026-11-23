//! `/test/gs_base`: read through the GS segment in ring 3. The kernel keeps
//! a pointer to its per-CPU data in the GS base while it runs and must swap
//! the user's value (0) back in on every return, so after a few syscalls and
//! thread switches `%gs:0x5a5000` is still the unmapped user address
//! 0x5a5000: a page fault with exactly that CR2 kills this process (exit
//! status 255). A kernel GS base that leaked would show up as a fault on a
//! kernel address, or as a successful read (exit status 0).

const lib = @import("lib");
pub const panic = lib.panic;

/// Program entry point.
export fn _start() callconv(.c) noreturn {
    for (0..4) |_| {
        lib.yield();
        _ = lib.gettid();
    }
    _ = asm volatile ("mov %%gs:0x5a5000, %[ret]"
        : [ret] "=r" (-> u64),
    );
    lib.exit(0);
}
