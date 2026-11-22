//! System call numbers and their kernel implementations.
//!
//! User programs pass the syscall number in RAX and up to three arguments in
//! RDI, RSI and RDX; the result is returned in RAX. Failures return `ERR`
//! (all bits set, i.e. -1). User memory is never dereferenced directly: data
//! is copied to and from kernel buffers with `uaccess.copyFromUser` and
//! `uaccess.copyToUser`, which fail cleanly on bad pointers.

const root = @import("root");
const thread = @import("thread.zig");
const arch = @import("../arch/x86_64/syscall.zig");
const heap = @import("heap.zig");
const vfs = @import("vfs.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const keyboard = @import("../drivers/ps2_keyboard.zig");
const proc = @import("process.zig");
const uaccess = @import("uaccess.zig");
const user_range = @import("user_range.zig");

/// `getchar() -> char`: block until a key is pressed and return it.
pub const GETCHAR = 7;
/// `run(path_ptr, path_len) -> exit code`: start a program and wait for it to exit.
pub const RUN = 8;
/// `open(path_ptr, path_len) -> fd`: open a file for reading.
pub const OPEN = 4;
/// `read(fd, buf_ptr, buf_len) -> bytes read`: read from an open file; 0 at end of file.
pub const READ = 5;
/// `close(fd) -> 0`: close a file descriptor.
pub const CLOSE = 6;
/// `write(ptr, len) -> len`: write a string (at most 4 KiB) to the console.
pub const WRITE = 0;
/// `exit(code)`: terminate the calling process. Does not return.
pub const EXIT = 1;
/// `yield() -> 0`: give the CPU to another ready thread.
pub const YIELD = 2;
/// `gettid() -> id`: return the calling thread's ID.
pub const GETTID = 3;

/// Longest path accepted from user space, in bytes.
const MAX_PATH = 256;
/// Size of the kernel bounce buffer used to move data to and from user space.
const CHUNK = 256;
const ERR: u64 = @bitCast(@as(i64, -1));

/// `GETCHAR`: return the next key from the keyboard buffer, blocking the
/// calling thread until one is typed.
fn sysGetChar() u64 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    while (true) {
        if (keyboard.getChar()) |c| return c;
        keyboard.waiter = thread.current(); // register first, then sleep
        thread.block();
    }
}

/// Copy a path of `len` bytes from the user address `ptr` into `buf`.
/// Returns null if it is longer than `MAX_PATH` or cannot be read.
fn userPath(buf: *[MAX_PATH]u8, ptr: u64, len: u64) ?[]const u8 {
    if (len > MAX_PATH) return null;
    const path = buf[0..@intCast(len)];
    uaccess.copyFromUser(path, ptr) catch return null;
    return path;
}

/// `RUN`: spawn the program at the user-space path (`ptr`, `len`) as a child
/// process and block until it exits. Returns the child's exit code, or `ERR`
/// if the path is invalid or the program cannot be started.
fn sysRun(ptr: u64, len: u64) u64 {
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = userPath(&path_buf, ptr, len) orelse return ERR;
    const me = thread.current();
    _ = proc.spawnPath(path, me) catch return ERR;
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    thread.block(); // until the child calls process.exit
    return me.wake_value;
}

/// `WRITE`: print the user string (`ptr`, `len`) to the serial port and
/// console. Returns `len`, or `ERR` if the range is over 4 KiB, outside user
/// space or not readable. If only a later part is unreadable, the part before
/// it has already been printed.
fn sysWrite(ptr: u64, len: u64) u64 {
    if (len > 4096 or !user_range.valid(ptr, len)) return ERR;
    var chunk: [CHUNK]u8 = undefined;
    var off: u64 = 0;
    while (off < len) {
        const part = chunk[0..@intCast(@min(CHUNK, len - off))];
        uaccess.copyFromUser(part, ptr + off) catch return ERR;
        root.print("{s}", .{part});
        off += part.len;
    }
    return len;
}

/// Return the open file for descriptor `fd` of the current process, or null
/// if `fd` is out of range, not open, or the thread has no process.
fn fileOf(fd: u64) ?*vfs.OpenFile {
    const p = thread.current().process orelse return null;
    if (fd >= p.files.len) return null;
    return p.files[fd];
}

/// `OPEN`: look up the user path (`ptr`, `len`) and store an `OpenFile` for it
/// in the lowest free descriptor slot. Returns the descriptor, or `ERR` if the
/// path is invalid, the file doesn't exist or the descriptor table is full.
fn sysOpen(ptr: u64, len: u64) u64 {
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = userPath(&path_buf, ptr, len) orelse return ERR;
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

/// `READ`: read up to `len` bytes (max 1 MiB) from descriptor `fd` into the
/// user buffer at `ptr`, advancing the file offset. Returns the number of
/// bytes read, 0 at end of file, or `ERR` if `fd` or the buffer is invalid.
/// On `ERR` the file offset is unchanged, though part of the buffer may have
/// been written.
fn sysRead(fd: u64, ptr: u64, len: u64) u64 {
    const of = fileOf(fd) orelse return ERR;
    if (len > 1 << 20 or !user_range.valid(ptr, len)) return ERR;
    var chunk: [CHUNK]u8 = undefined;
    var done: u64 = 0;
    while (done < len) {
        const want: usize = @intCast(@min(CHUNK, len - done));
        const n = vfs.read(&of.node, of.offset + done, chunk[0..want]);
        if (n == 0) break; // end of file
        uaccess.copyToUser(ptr + done, chunk[0..n]) catch return ERR;
        done += n;
    }
    of.offset += done;
    return done;
}

/// `CLOSE`: free the open file behind descriptor `fd` and clear its slot.
/// Returns 0, or `ERR` if `fd` is not open.
fn sysClose(fd: u64) u64 {
    const of = fileOf(fd) orelse return ERR;
    heap.allocator.destroy(of);
    thread.current().process.?.files[fd] = null;
    return 0;
}

/// Syscall handler registered with the arch layer: call the implementation
/// selected by `f.rax` with the arguments from `f.rdi`, `f.rsi` and `f.rdx`,
/// and store its result in `f.rax`. Unknown numbers return `ERR`.
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

/// Enable the `syscall` instruction and route it to `dispatch`. Called once during boot.
pub fn init() void {
    arch.init(dispatch);
}
