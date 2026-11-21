const root = @import("root");
const thread = @import("thread.zig");
const arch = @import("../arch/x86_64/syscall.zig");
const heap = @import("heap.zig");
const vfs = @import("vfs.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const keyboard = @import("../drivers/ps2_keyboard.zig");
const proc = @import("process.zig");

pub const GETCHAR = 7;
pub const RUN = 8;
pub const OPEN = 4;
pub const READ = 5;
pub const CLOSE = 6;
pub const WRITE = 0;
pub const EXIT = 1;
pub const YIELD = 2;
pub const GETTID = 3;

const USER_END: u64 = 0x0000_8000_0000_0000; // user space is the lower half
const ERR: u64 = @bitCast(@as(i64, -1));

// Get a character from the keyboard. If no character is available, block until one is typed. Returns the character as a u64, or ERR if the current thread has no process (which should never happen).
fn sysGetChar() u64 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    while (true) {
        if (keyboard.getChar()) |c| return c;
        keyboard.waiter = thread.current(); // register first, then sleep
        thread.block();
    }
}

// Run a program in user space. The program is loaded from the filesystem, and a new thread is created to run it. The current thread is blocked until the new thread exits, at which point the new thread's exit value is returned.
fn sysRun(ptr: u64, len: u64) u64 {
    const path = userSlice(ptr, len, 256) orelse return ERR;
    const me = thread.current();
    _ = proc.spawnPath(path, me) catch return ERR;
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    thread.block(); // until the child calls process.exit
    return me.wake_value;
}

// Return a slice of user memory, or null if the slice is invalid. The slice must be entirely in user space, and must not exceed `max` bytes.
fn userSlice(ptr: u64, len: u64, max: u64) ?[]u8 {
    if (len > max or ptr >= USER_END or ptr + len > USER_END) return null;
    return @as([*]u8, @ptrFromInt(ptr))[0..len];
}

// Write a string to the console. The string is in user space, so it must be copied to kernel space first. Returns the number of bytes written, or ERR if the string is invalid.
fn sysWrite(ptr: u64, len: u64) u64 {
    const s = userSlice(ptr, len, 4096) orelse return ERR;
    var off: usize = 0;
    while (off < s.len) : (off += 256) root.print("{s}", .{s[off..@min(off + 256, s.len)]});
    return len;
}

// Return the OpenFile for a file descriptor, or null if the fd is invalid. The fd table is stored in the current thread's process, so this function returns null if the current thread has no process.
fn fileOf(fd: u64) ?*vfs.OpenFile {
    const p = thread.current().process orelse return null;
    if (fd >= p.files.len) return null;
    return p.files[fd];
}

// Open a file. Returns a file descriptor, or ERR if the file doesn't exist or the process has too many open files. The file descriptor is added to the process's fd table, and an OpenFile is created for it.
fn sysOpen(ptr: u64, len: u64) u64 {
    const path = userSlice(ptr, len, 256) orelse return ERR;
    const node = vfs.lookup(path) orelse return ERR;
    const p = thread.current().process orelse return ERR;
    for (&p.files, 0..) |*slot, fd| {
        if (slot.* != null) continue;
        const of = heap.allocator.create(vfs.OpenFile) catch return ERR;
        of.* = .{ .node = node };
        slot.* = of;
        return fd;
    }
    return ERR; // fd table full
}

// Read from a file descriptor. Returns the number of bytes read, or 0 on end-of-file, or ERR if the fd is invalid. The file's offset is updated by the number of bytes read.
fn sysRead(fd: u64, ptr: u64, len: u64) u64 {
    const of = fileOf(fd) orelse return ERR;
    const buf = userSlice(ptr, len, 1 << 20) orelse return ERR;
    const n = vfs.read(&of.node, of.offset, buf);
    of.offset += n;
    return n; // 0 = end of file
}

// Close a file descriptor. Returns 0 on success, or -1 if the fd is invalid. The file descriptor is removed from the process's fd table, and the OpenFile is freed.
fn sysClose(fd: u64) u64 {
    const of = fileOf(fd) orelse return ERR;
    heap.allocator.destroy(of);
    thread.current().process.?.files[fd] = null;
    return 0;
}

// Dispatch a syscall. The syscall number is in rax, and the arguments are in rdi, rsi, and rdx. The return value is written to rax. If the syscall fails, rax is set to -1.
fn dispatch(f: *arch.Frame) void {
    f.rax = switch (f.rax) {
        EXIT => proc.exit(f.rdi),
        GETCHAR => sysGetChar(),
        RUN => sysRun(f.rdi, f.rsi),
        OPEN => sysOpen(f.rdi, f.rsi),
        READ => sysRead(f.rdi, f.rsi, f.rdx),
        CLOSE => sysClose(f.rdi),
        WRITE => sysWrite(f.rdi, f.rsi),
        YIELD => blk: {
            thread.yield();
            break :blk 0;
        },
        GETTID => thread.id(),
        else => ERR,
    };
}

// Initialize the syscall handler. This is called by the kernel during boot.
pub fn init() void {
    arch.init(dispatch);
}
