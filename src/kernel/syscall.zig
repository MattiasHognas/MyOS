//! System calls: the kernel side of the ABI in `abi/linux.zig`.
//!
//! The ABI is Linux's for x86-64: the number is in RAX, up to six arguments
//! in RDI, RSI, RDX, R10, R8 and R9, and the result comes back in RAX, as a
//! value or as a negated error number (`abi.err`). `docs/syscalls.md` lists
//! the calls. User memory is never dereferenced directly: data is copied to
//! and from kernel buffers with `uaccess`, which fails cleanly on bad pointers.

const root = @import("root");
const abi = @import("../abi/linux.zig");
const thread = @import("thread.zig");
const arch = @import("../arch/x86_64/syscall.zig");
const heap = @import("heap.zig");
const vfs = @import("vfs.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const keyboard = @import("../drivers/ps2_keyboard.zig");
const proc = @import("process.zig");
const uaccess = @import("uaccess.zig");
const user_range = @import("user_range.zig");

const Sys = abi.Sys;
const err = abi.err;

/// Size of the kernel bounce buffer used to move data to and from user space.
const CHUNK = 256;
/// Descriptors below this are the standard streams; `open` never returns them.
const FIRST_FILE_FD = 3;

/// `myos_getchar`: return the next key from the keyboard buffer, blocking
/// the calling thread until one is typed.
fn sysGetChar() u64 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    while (true) {
        if (keyboard.getChar()) |c| return c;
        keyboard.waiter = thread.current(); // register first, then sleep
        thread.block();
    }
}

/// Copy the NUL-terminated path at the user address `ptr` into `buf` and
/// return it without the NUL. Errors are syscall results: `EFAULT` if it
/// cannot be read, `ENAMETOOLONG` if it does not end within `PATH_MAX`
/// bytes, `ENOENT` if it is empty.
fn userPath(buf: *[abi.PATH_MAX]u8, ptr: u64) union(enum) { path: []const u8, fail: u64 } {
    const len = uaccess.copyStringFromUser(buf, ptr) catch |e| return .{ .fail = switch (e) {
        error.Fault => err(.FAULT),
        error.TooLong => err(.NAMETOOLONG),
    } };
    if (len == 0) return .{ .fail = err(.NOENT) };
    return .{ .path = buf[0..len] };
}

/// `myos_run`: spawn the program at the user path `ptr` as a child process
/// and block until it exits. Returns the child's exit status (0-255), or an
/// error: those of `userPath`, `ENOENT` (no such file), `ENOEXEC` (not a
/// loadable program), `ENOMEM` (no memory, or the program is larger than
/// the caller's memory limit) or `EAGAIN` (the caller, or a process above
/// it, has as many descendants as it may).
fn sysRun(ptr: u64) u64 {
    var path_buf: [abi.PATH_MAX]u8 = undefined;
    const path = switch (userPath(&path_buf, ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    const me = thread.current();
    _ = proc.spawnPath(path, .{ .waiter = me, .parent = me.process }) catch |e| return switch (e) {
        error.FileNotFound => err(.NOENT),
        error.OutOfMemory, error.TooLarge => err(.NOMEM),
        error.TooManyProcesses => err(.AGAIN),
        else => err(.NOEXEC), // unreadable, or refused by the ELF loader
    };
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    thread.block(); // until the child calls process.exit
    return me.wake_value;
}

/// `write`: print `count` bytes at the user address `ptr` to the console.
/// Only descriptors 1 and 2 can be written; anything else is `EBADF` (files
/// are read-only). Returns the number of bytes written, which is short if a
/// later part of the buffer cannot be read, or `EFAULT` if none of it can.
fn sysWrite(fd: u64, ptr: u64, count: u64) u64 {
    if (fd != abi.STDOUT and fd != abi.STDERR) return err(.BADF);
    const len = @min(count, abi.MAX_RW_COUNT);
    if (!user_range.valid(ptr, len)) return err(.FAULT);
    var chunk: [CHUNK]u8 = undefined;
    var done: u64 = 0;
    while (done < len) {
        const part = chunk[0..@intCast(@min(CHUNK, len - done))];
        uaccess.copyFromUser(part, ptr + done) catch break;
        root.print("{s}", .{part});
        done += part.len;
    }
    if (done == 0 and len != 0) return err(.FAULT);
    return done;
}

/// Return the open file for descriptor `fd` of the current process, or null
/// if `fd` is out of range, not open, or the thread has no process.
fn fileOf(fd: u64) ?*vfs.OpenFile {
    const p = thread.current().process orelse return null;
    if (fd >= p.files.len) return null;
    return p.files[fd];
}

/// `open`: look up the user path `ptr` and store an `OpenFile` for it in the
/// lowest free descriptor from 3 up. `flags` must ask for read-only access
/// (`EROFS` otherwise: every filesystem is read-only); other flag bits and
/// the mode are ignored. Returns the descriptor, or an error: those of
/// `userPath`, `ENOENT`, `EMFILE` (the process has as many descriptors as
/// its limit allows) or `ENOMEM`.
fn sysOpen(ptr: u64, flags: u64) u64 {
    var path_buf: [abi.PATH_MAX]u8 = undefined;
    const path = switch (userPath(&path_buf, ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    const node = vfs.lookup(path) orelse
        return if (flags & abi.O.CREAT != 0) err(.ROFS) else err(.NOENT);
    if (flags & abi.O.ACCMODE != abi.O.RDONLY) return err(.ROFS);
    const p = thread.current().process orelse return err(.BADF);
    const max_files = @min(p.files.len, p.limits.max_files);
    if (max_files <= FIRST_FILE_FD) return err(.MFILE);
    for (p.files[FIRST_FILE_FD..max_files], FIRST_FILE_FD..) |*slot, fd| {
        if (slot.* != null) continue;
        const of = heap.allocator.create(vfs.OpenFile) catch return err(.NOMEM);
        of.* = .{ .node = node };
        slot.* = of;
        return fd;
    }
    return err(.MFILE);
}

/// `read`: read up to `count` bytes from descriptor `fd` into the user
/// buffer at `ptr`, advancing the file offset by what was read. Returns the
/// number of bytes read (0 at end of file), which is short if a later part
/// of the buffer cannot be written; `EBADF` if `fd` is not an open file
/// (descriptor 0 has no input yet: milestone 6); `EFAULT` if nothing could
/// be stored. On `EFAULT` the offset is unchanged.
fn sysRead(fd: u64, ptr: u64, count: u64) u64 {
    const of = fileOf(fd) orelse return err(.BADF);
    const len = @min(count, abi.MAX_RW_COUNT);
    if (!user_range.valid(ptr, len)) return err(.FAULT);
    var chunk: [CHUNK]u8 = undefined;
    var done: u64 = 0;
    var faulted = false;
    while (done < len) {
        const want: usize = @intCast(@min(CHUNK, len - done));
        const n = vfs.read(&of.node, of.offset + done, chunk[0..want]);
        if (n == 0) break; // end of file
        uaccess.copyToUser(ptr + done, chunk[0..n]) catch {
            faulted = true;
            break;
        };
        done += n;
    }
    if (faulted and done == 0) return err(.FAULT);
    of.offset += done;
    return done;
}

/// `close`: free the open file behind descriptor `fd` and clear its slot.
/// Returns 0, or `EBADF` if `fd` is not an open file. Closing a standard
/// stream succeeds and changes nothing, since they cannot be reopened yet.
fn sysClose(fd: u64) u64 {
    if (fd < FIRST_FILE_FD) return 0;
    const of = fileOf(fd) orelse return err(.BADF);
    heap.allocator.destroy(of);
    thread.current().process.?.files[fd] = null;
    return 0;
}

/// Syscall handler registered with the arch layer: call the implementation
/// selected by `f.rax` with the arguments from the frame and store its
/// result in `f.rax`. Unknown numbers return `ENOSYS`.
pub fn dispatch(f: *arch.Frame) void {
    f.rax = switch (f.rax) {
        Sys.read => sysRead(f.rdi, f.rsi, f.rdx),
        Sys.write => sysWrite(f.rdi, f.rsi, f.rdx),
        Sys.open => sysOpen(f.rdi, f.rsi),
        Sys.close => sysClose(f.rdi),
        Sys.sched_yield => blk: {
            thread.yield();
            break :blk 0;
        },
        Sys.exit => proc.exit(abi.exitStatus(f.rdi)),
        Sys.gettid => thread.id(),
        Sys.myos_getchar => sysGetChar(),
        Sys.myos_run => sysRun(f.rdi),
        else => err(.NOSYS),
    };
}

/// A syscall is about to return to a state the CPU cannot return to (a
/// return address outside user space, say): report it and kill the process,
/// as a fault at that address would.
fn badReturn(f: *const arch.Frame) noreturn {
    const p = thread.current().process.?;
    root.print("\n*** thread {d} ({s}): invalid return state after syscall, killed\n", .{ thread.id(), p.name });
    root.print("RIP=0x{x} RSP=0x{x} RFLAGS=0x{x} CS=0x{x} SS=0x{x}\n", .{ f.rip, f.rsp, f.rflags, f.cs, f.ss });
    proc.exit(proc.EXIT_KILLED);
}

/// Enable the `syscall` instruction and route it to `dispatch`. Called once during boot.
pub fn init() void {
    arch.init(dispatch, badReturn);
}
