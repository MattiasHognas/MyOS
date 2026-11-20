const std = @import("std");

fn syscall(n: u64, a1: u64, a2: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [n] "{rax}" (n),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn write(s: []const u8) void {
    _ = syscall(0, @intFromPtr(s.ptr), s.len);
}

fn exit(code: u64) noreturn {
    _ = syscall(1, code, 0);
    unreachable;
}

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, _: ?usize) noreturn {
    write("panic: ");
    write(msg);
    write("\n");
    exit(1);
}

export fn _start() callconv(.c) noreturn {
    write("Hello from an ELF process!\n");
    var buf: [64]u8 = undefined;
    write(std.fmt.bufPrint(&buf, "my thread id is {d}\n", .{syscall(3, 0, 0)}) catch "?\n");
    exit(0);
}
