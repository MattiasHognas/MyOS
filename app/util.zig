//! What MyOS's own programs share: system calls by number, output, and
//! Linux's error messages. The programs are ordinary Linux programs built
//! with Zig's standard library (`x86_64-linux`); this module only keeps
//! them short. It calls the kernel directly rather than through the
//! standard library's wrappers, whose shapes change between Zig versions.

const std = @import("std");
const linux = std.os.linux;

pub const SYS = linux.SYS;

pub fn sys0(n: SYS) usize {
    return linux.syscall0(n);
}
pub fn sys1(n: SYS, a: usize) usize {
    return linux.syscall1(n, a);
}
pub fn sys2(n: SYS, a: usize, b: usize) usize {
    return linux.syscall2(n, a, b);
}
pub fn sys3(n: SYS, a: usize, b: usize, c: usize) usize {
    return linux.syscall3(n, a, b, c);
}
pub fn sys4(n: SYS, a: usize, b: usize, c: usize, d: usize) usize {
    return linux.syscall4(n, a, b, c, d);
}

/// Whether a system call's result is an error, and which.
pub fn isErr(rc: usize) bool {
    return rc > std.math.maxInt(usize) - 4095;
}
pub fn errnoOf(rc: usize) u16 {
    return @intCast(0 -% rc);
}

/// Linux's message for error number `e`, as `strerror` gives it.
pub fn message(e: u16) []const u8 {
    return switch (e) {
        1 => "Operation not permitted",
        2 => "No such file or directory",
        3 => "No such process",
        4 => "Interrupted system call",
        7 => "Argument list too long",
        8 => "Exec format error",
        9 => "Bad file descriptor",
        10 => "No child processes",
        11 => "Resource temporarily unavailable",
        12 => "Cannot allocate memory",
        13 => "Permission denied",
        14 => "Bad address",
        17 => "File exists",
        18 => "Invalid cross-device link",
        20 => "Not a directory",
        21 => "Is a directory",
        22 => "Invalid argument",
        24 => "Too many open files",
        25 => "Inappropriate ioctl for device",
        27 => "File too large",
        28 => "No space left on device",
        29 => "Illegal seek",
        30 => "Read-only file system",
        32 => "Broken pipe",
        36 => "File name too long",
        38 => "Function not implemented",
        39 => "Directory not empty",
        40 => "Too many levels of symbolic links",
        else => "Unknown error",
    };
}

pub const AT_FDCWD: usize = @bitCast(@as(isize, -100));

pub const O = struct {
    pub const RDONLY = 0;
    pub const WRONLY = 1;
    pub const RDWR = 2;
    pub const CREAT = 0o100;
    pub const EXCL = 0o200;
    pub const TRUNC = 0o1000;
    pub const APPEND = 0o2000;
    pub const DIRECTORY = 0o200000;
    pub const CLOEXEC = 0o2000000;
};

/// `openat(AT_FDCWD, path, flags, mode)`.
pub fn open(path: [*:0]const u8, flags: usize, mode: usize) usize {
    return sys4(.openat, AT_FDCWD, @intFromPtr(path), flags, mode);
}

pub fn close(fd: usize) void {
    _ = sys1(.close, fd);
}

pub fn read(fd: usize, buf: []u8) usize {
    return sys3(.read, fd, @intFromPtr(buf.ptr), buf.len);
}

/// Write all of `bytes` to `fd`; false if it could not.
pub fn writeAll(fd: usize, bytes: []const u8) bool {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = sys3(.write, fd, @intFromPtr(bytes.ptr + done), bytes.len - done);
        if (isErr(n)) {
            if (errnoOf(n) == 4) continue; // EINTR
            return false;
        }
        if (n == 0) return false;
        done += n;
    }
    return true;
}

/// Formatted output to `fd`, in pieces of at most 1 KiB each.
pub fn print(fd: usize, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    _ = writeAll(fd, text);
}

/// `<program>: <what>: <message>` on standard error, as the usual tools
/// say it.
pub fn complain(program: []const u8, what: []const u8, rc: usize) void {
    print(2, "{s}: {s}: {s}\n", .{ program, what, message(errnoOf(rc)) });
}

/// A buffered writer onto a descriptor, for programs that print a lot.
pub const Out = struct {
    fd: usize,
    buf: [4096]u8 = undefined,
    len: usize = 0,

    pub fn write(self: *Out, bytes: []const u8) void {
        if (bytes.len > self.buf.len - self.len) self.flush();
        if (bytes.len > self.buf.len) {
            _ = writeAll(self.fd, bytes);
            return;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
        var tmp: [512]u8 = undefined;
        self.write(std.fmt.bufPrint(&tmp, fmt, args) catch tmp[0..]);
    }

    pub fn flush(self: *Out) void {
        _ = writeAll(self.fd, self.buf[0..self.len]);
        self.len = 0;
    }
};

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn span(s: [*:0]const u8) []const u8 {
    return std.mem.span(s);
}

/// `struct stat` of x86-64 Linux.
pub const Stat = extern struct {
    dev: u64 = 0,
    ino: u64 = 0,
    nlink: u64 = 0,
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    _pad0: u32 = 0,
    rdev: u64 = 0,
    size: i64 = 0,
    blksize: i64 = 0,
    blocks: i64 = 0,
    atime: [2]i64 = .{ 0, 0 },
    mtime: [2]i64 = .{ 0, 0 },
    ctime: [2]i64 = .{ 0, 0 },
    _unused: [3]i64 = .{ 0, 0, 0 },
};

/// `std.fmt.bufPrint` ending in a NUL, for paths given to the kernel.
pub fn bufZ(buf: []u8, comptime fmt: []const u8, args: anytype) error{NoSpaceLeft}![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, fmt, args, 0);
}

/// What `newfstatat` says of a path.
pub fn stat(path: [*:0]const u8, st: *Stat) usize {
    return sys4(.newfstatat, AT_FDCWD, @intFromPtr(path), @intFromPtr(st), 0);
}

pub fn isDir(mode: u32) bool {
    return mode & 0o170000 == 0o040000;
}
