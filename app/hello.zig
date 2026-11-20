const std = @import("std");

const ERR = std.math.maxInt(u64);

fn syscall(n: u64, a1: u64, a2: u64, a3: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [n] "{rax}" (n),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn write(s: []const u8) void {
    _ = syscall(0, @intFromPtr(s.ptr), s.len, 0);
}

fn exit(code: u64) noreturn {
    _ = syscall(1, code, 0, 0);
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
    write("Hello from /bin/hello!\n");

    const path = "/etc/motd";
    const fd = syscall(4, @intFromPtr(path.ptr), path.len, 0);
    if (fd == ERR) {
        write("cannot open /etc/motd\n");
        exit(1);
    }
    var buf: [256]u8 = undefined;
    const n = syscall(5, fd, @intFromPtr(&buf), buf.len);
    if (n != ERR) write(buf[0..n]);
    _ = syscall(6, fd, 0, 0);
    exit(0);
}
