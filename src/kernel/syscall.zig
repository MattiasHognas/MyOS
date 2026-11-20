const root = @import("root");
const thread = @import("thread.zig");
const arch = @import("../arch/x86_64/syscall.zig");

pub const WRITE = 0;
pub const EXIT = 1;
pub const YIELD = 2;
pub const GETTID = 3;

const USER_END: u64 = 0x0000_8000_0000_0000; // user space is the lower half
const ERR: u64 = @bitCast(@as(i64, -1));

fn sysWrite(ptr: u64, len: u64) u64 {
    // Never trust a pointer from user space: it must lie entirely in the lower half.
    if (len > 4096 or ptr >= USER_END or ptr + len > USER_END) return ERR;
    const s: [*]const u8 = @ptrFromInt(ptr);
    var off: usize = 0;
    while (off < len) : (off += 256) { // print's buffer is 512 bytes
        root.print("{s}", .{s[off..@min(off + 256, len)]});
    }
    return len;
}

fn dispatch(f: *arch.Frame) void {
    f.rax = switch (f.rax) {
        WRITE => sysWrite(f.rdi, f.rsi),
        EXIT => {
            root.print("[thread {d}] exit({d})\n", .{ thread.id(), f.rdi });
            thread.exit();
        },
        YIELD => blk: {
            thread.yield();
            break :blk 0;
        },
        GETTID => thread.id(),
        else => ERR,
    };
}

pub fn init() void {
    arch.init(dispatch);
}
