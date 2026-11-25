//! System calls: the kernel side of the ABI in `abi/linux.zig`.
//!
//! The ABI is Linux's for x86-64: the number is in RAX, up to six arguments
//! in RDI, RSI, RDX, R10, R8 and R9, and the result comes back in RAX, as a
//! value or as a negated error number (`abi.err`). `docs/syscalls.md` lists
//! the calls. User memory is never dereferenced directly: data is copied to
//! and from kernel buffers with `uaccess`, which fails cleanly on bad pointers.

const std = @import("std");
const root = @import("root");

const abi = @import("abi");
const Sys = abi.Sys;
const err = abi.err;
const cpu = @import("../arch/x86_64/cpu.zig");
const nospec = @import("../arch/x86_64/nospec.zig");
const arch = @import("../arch/x86_64/syscall.zig");
const keyboard = @import("../drivers/ps2_keyboard.zig");
const heap = @import("heap.zig");
const proc = @import("process.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");
const uaccess = @import("uaccess.zig");
const user_memory = @import("user_memory.zig");
const user_range = @import("user_range.zig");
const vfs = @import("vfs.zig");

/// Size of the kernel bounce buffer used to move data to and from user space.
const CHUNK = 256;
/// Descriptors below this are the standard streams; `open` never returns them.
const FIRST_FILE_FD = 3;

/// `myos_getchar`: return the next key from the keyboard buffer, blocking
/// the calling thread until one is typed.
fn sysGetChar() u64 {
    return keyboard.read();
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

/// The strings of an argument or environment list copied from user
/// space: the strings themselves in one block, and a slice for each.
const StringList = struct {
    storage: []u8,
    /// Room for the most strings allowed; the first `len` are set.
    slots: [][]const u8,
    len: usize = 0,

    fn items(self: StringList) []const []const u8 {
        return self.slots[0..self.len];
    }

    fn deinit(self: StringList) void {
        heap.allocator.free(self.slots);
        heap.allocator.free(self.storage);
    }
};

/// Copy the NULL-terminated array of NUL-terminated strings at the user
/// address `ptr` (as `execve` takes them). A null `ptr` is an empty list.
/// `budget` is how many bytes and how many strings are still allowed; both
/// are reduced by what was used. Errors are syscall results: `EFAULT`,
/// `E2BIG` (too many strings, or too long together), `ENOMEM`.
fn copyStringList(ptr: u64, bytes_left: *usize, count_left: *usize) union(enum) { list: StringList, fail: u64 } {
    const storage = heap.allocator.alloc(u8, bytes_left.*) catch return .{ .fail = err(.NOMEM) };
    const items = heap.allocator.alloc([]const u8, count_left.*) catch {
        heap.allocator.free(storage);
        return .{ .fail = err(.NOMEM) };
    };
    const list: StringList = .{ .storage = storage, .slots = items };
    var used: usize = 0;
    var n: usize = 0;
    while (ptr != 0) : (n += 1) {
        var word: [8]u8 = undefined;
        const fail: ?u64 = blk: {
            const at = std.math.add(u64, ptr, n * 8) catch break :blk err(.FAULT);
            uaccess.copyFromUser(&word, at) catch break :blk err(.FAULT);
            const string = std.mem.readInt(u64, &word, .little);
            if (string == 0) break :blk null;
            if (n == items.len) break :blk err(.@"2BIG");
            const len = uaccess.copyStringFromUser(storage[used..], string) catch |e| break :blk switch (e) {
                error.Fault => err(.FAULT),
                error.TooLong => err(.@"2BIG"),
            };
            items[n] = storage[used..][0..len];
            used += len + 1;
            continue;
        };
        if (fail) |e| {
            list.deinit();
            return .{ .fail = e };
        }
        break;
    }
    bytes_left.* -= used;
    count_left.* -= n;
    return .{ .list = .{ .storage = storage, .slots = items, .len = n } };
}

/// `myos_run`: spawn the program at the user path `ptr` as a child process,
/// with the arguments `argv` and the environment `envp` (user arrays as for
/// `execve`; null for none), and block until it exits. Returns the child's
/// exit status (0-255), or an error: those of `userPath`, `ENOENT` (no such
/// file), `ENOEXEC` (not a loadable program), `E2BIG` (arguments and
/// environment too long), `EFAULT`, `ENOMEM` (no memory, or the program is
/// larger than the caller's memory limit) or `EAGAIN` (the caller, or a
/// process above it, has as many descendants as it may).
fn sysRun(ptr: u64, argv: u64, envp: u64) u64 {
    var path_buf: [abi.PATH_MAX]u8 = undefined;
    const path = switch (userPath(&path_buf, ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    var bytes_left: usize = abi.ARG_MAX;
    var count_left: usize = abi.ARG_COUNT_MAX;
    const args = switch (copyStringList(argv, &bytes_left, &count_left)) {
        .list => |l| l,
        .fail => |e| return e,
    };
    defer args.deinit();
    const env = switch (copyStringList(envp, &bytes_left, &count_left)) {
        .list => |l| l,
        .fail => |e| return e,
    };
    defer env.deinit();
    const child = proc.spawnPath(path, .{ .parent = thread.current().process, .argv = args.items(), .envp = env.items() }) catch |e| return switch (e) {
        error.FileNotFound => err(.NOENT),
        error.OutOfMemory, error.TooLarge => err(.NOMEM),
        error.TooManyProcesses => err(.AGAIN),
        error.ArgumentsTooLong => err(.@"2BIG"),
        else => err(.NOEXEC), // unreadable, or refused by the ELF loader
    };
    return proc.wait(child); // whether it is still running or already gone
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

/// `writev`: `write` from the `count` buffers described by the `iovec`
/// array at the user address `iov`, in order. Returns the total written,
/// short if a buffer cannot be read; `EINVAL` for more than `IOV_MAX`
/// buffers or lengths that add up past what one call may transfer;
/// `EFAULT` if the array, or the first buffer with anything in it, cannot
/// be read; `EBADF` as for `write`.
fn sysWritev(fd: u64, iov: u64, count: u64) u64 {
    if (fd != abi.STDOUT and fd != abi.STDERR) return err(.BADF);
    if (count > abi.IOV_MAX) return err(.INVAL);
    var total: u64 = 0;
    // First pass: the lengths, before anything is written.
    for (0..count) |i| {
        const v = readIoVec(iov, i) orelse return err(.FAULT);
        total = std.math.add(u64, total, v.len) catch return err(.INVAL);
        if (total > abi.MAX_RW_COUNT) return err(.INVAL);
    }
    var done: u64 = 0;
    for (0..count) |i| {
        const v = readIoVec(iov, i) orelse break;
        if (v.len == 0) continue;
        const n = sysWrite(fd, v.base, v.len);
        if (abi.isError(n)) return if (done == 0) n else done;
        done += n;
        if (n < v.len) break; // a short write ends the call
    }
    return done;
}

/// Entry `index` of the `iovec` array at the user address `iov`, or null
/// if it cannot be read.
fn readIoVec(iov: u64, index: usize) ?abi.IoVec {
    var v: abi.IoVec = undefined;
    const at = std.math.add(u64, iov, index * @sizeOf(abi.IoVec)) catch return null;
    uaccess.copyFromUser(std.mem.asBytes(&v), at) catch return null;
    return v;
}

/// `ioctl`: no descriptor has device requests yet. The standard streams
/// and open files answer `ENOTTY` ("not a terminal", which is how a C
/// library asks whether to buffer its output by line); anything else is
/// `EBADF`.
fn sysIoctl(fd: u64) u64 {
    if (fd <= abi.STDERR or fileOf(fd) != null) return err(.NOTTY);
    return err(.BADF);
}

/// `arch_prctl`: set or read the FS or GS base of the calling thread,
/// where a program keeps its thread-local data. A base must be an address
/// in user space (`EPERM` otherwise, as on Linux): the kernel tells its own
/// GS base from a program's by exactly that (`idt.zig`). `EINVAL` for an
/// unknown code, `EFAULT` if the result cannot be stored.
fn sysArchPrctl(code: u64, addr: u64) u64 {
    const me = thread.current();
    switch (code) {
        abi.ARCH.SET_FS, abi.ARCH.SET_GS => {
            if (!user_range.valid(addr, 1)) return err(.PERM); // below the end of user space
            thread.setUserBase(if (code == abi.ARCH.SET_FS) .fs else .gs, addr);
            return 0;
        },
        abi.ARCH.GET_FS, abi.ARCH.GET_GS => {
            const value = if (code == abi.ARCH.GET_FS) me.fs_base else me.gs_base;
            uaccess.copyToUser(addr, std.mem.asBytes(&value)) catch return err(.FAULT);
            return 0;
        },
        else => return err(.INVAL),
    }
}

/// `set_tid_address`: remember where the thread's exit is to be announced
/// and return its ID. Nothing waits for a thread yet (milestone 7), so the
/// address is only kept.
fn sysSetTidAddress(ptr: u64) u64 {
    const me = thread.current();
    me.clear_child_tid = ptr;
    return me.id;
}

/// Return the open file for descriptor `fd` of the current process, or null
/// if `fd` is out of range, not open, or the thread has no process.
fn fileOf(fd: u64) ?*vfs.OpenFile {
    const p = thread.current().process orelse return null;
    if (fd >= p.files.len) return null;
    return p.files[nospec.index(fd, p.files.len)];
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
    const files = &thread.current().process.?.files;
    files[nospec.index(fd, files.len)] = null;
    return 0;
}

/// Copy a value of type `T` from the user address `ptr`, or null if it
/// cannot be read.
fn fromUser(comptime T: type, ptr: u64) ?T {
    var value: T = undefined;
    uaccess.copyFromUser(std.mem.asBytes(&value), ptr) catch return null;
    return value;
}

/// Copy `value` to the user address `ptr`. False if it cannot be written.
fn toUser(ptr: u64, value: anytype) bool {
    uaccess.copyToUser(ptr, std.mem.asBytes(&value)) catch return false;
    return true;
}

/// Bits of the signals that cannot be blocked, caught or ignored.
const UNBLOCKABLE: u64 = (1 << (abi.SIGKILL - 1)) | (1 << (abi.SIGSTOP - 1));

/// `rt_sigaction`: set what signal `sig` does and return what it did
/// before; either pointer may be null. No signal is delivered yet
/// (milestone 8: a fault still ends the process), but a program that
/// installs its handlers at startup, as language runtimes do, finds them
/// recorded. `EINVAL` for a signal that does not exist, for changing
/// `SIGKILL` or `SIGSTOP`, and for a mask of the wrong size; `EFAULT`.
fn sysSigAction(sig: u64, act: u64, old: u64, set_size: u64) u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    if (set_size != abi.SIGSET_SIZE or sig < 1 or sig > abi.NSIG) return err(.INVAL);
    const slot = &p.signal_actions[nospec.index(sig - 1, abi.NSIG)];
    const before = slot.*;
    if (act != 0) {
        if (sig == abi.SIGKILL or sig == abi.SIGSTOP) return err(.INVAL);
        var new = fromUser(abi.SigAction, act) orelse return err(.FAULT);
        new.mask &= ~UNBLOCKABLE;
        if (old != 0 and !toUser(old, before)) return err(.FAULT);
        slot.* = new;
        return 0;
    }
    if (old != 0 and !toUser(old, before)) return err(.FAULT);
    return 0;
}

/// `rt_sigprocmask`: change the calling thread's set of blocked signals
/// (`how` says whether `set` is added, removed or replaces it) and return
/// the previous set; either pointer may be null.
fn sysSigProcMask(how: u64, set: u64, old: u64, set_size: u64) u64 {
    if (set_size != abi.SIGSET_SIZE) return err(.INVAL);
    const me = thread.current();
    const before = me.signal_mask;
    if (set != 0) {
        const bits = fromUser(u64, set) orelse return err(.FAULT);
        const new = switch (how) {
            abi.SIG.BLOCK => before | bits,
            abi.SIG.UNBLOCK => before & ~bits,
            abi.SIG.SETMASK => bits,
            else => return err(.INVAL),
        };
        if (old != 0 and !toUser(old, before)) return err(.FAULT);
        me.signal_mask = new & ~UNBLOCKABLE;
        return 0;
    }
    if (old != 0 and !toUser(old, before)) return err(.FAULT);
    return 0;
}

/// `sigaltstack`: set the stack the calling thread's signal handlers may
/// run on and return the previous one; either pointer may be null.
/// `ENOMEM` for a stack smaller than `MINSIGSTKSZ`, `EINVAL` for unknown flags.
fn sysSigAltStack(new_ptr: u64, old_ptr: u64) u64 {
    const me = thread.current();
    const before = me.signal_stack;
    if (new_ptr != 0) {
        var new = fromUser(abi.SigStack, new_ptr) orelse return err(.FAULT);
        if (new.flags & ~@as(i32, abi.SS.DISABLE) != 0) return err(.INVAL);
        if (new.flags & abi.SS.DISABLE != 0) {
            new = .{}; // disabled: the rest is not looked at
        } else if (new.size < abi.SS.MIN_SIZE) return err(.NOMEM);
        if (old_ptr != 0 and !toUser(old_ptr, before)) return err(.FAULT);
        me.signal_stack = new;
        return 0;
    }
    if (old_ptr != 0 and !toUser(old_ptr, before)) return err(.FAULT);
    return 0;
}

/// `poll`: say which of the `count` descriptors at the user address `fds`
/// have the events asked for. Console output is always writable, an open
/// file always readable, the keyboard not readable through a descriptor
/// yet; a descriptor that is not open gets `POLLNVAL`. If none has an
/// event the call waits out `timeout_ms` (forever if negative) and returns
/// 0: nothing here becomes ready later. `EINVAL` for more descriptors than
/// a process can have open, `EFAULT`.
fn sysPoll(fds: u64, count: u64, timeout_ms: u64) u64 {
    if (count > proc.MAX_FILES) return err(.INVAL);
    var ready: u64 = 0;
    for (0..count) |i| {
        const at = fds + i * @sizeOf(abi.PollFd);
        var entry = fromUser(abi.PollFd, at) orelse return err(.FAULT);
        entry.revents = 0;
        if (entry.fd >= 0) {
            const fd: u64 = @intCast(entry.fd);
            if (fd == abi.STDOUT or fd == abi.STDERR) {
                entry.revents = entry.events & abi.POLL.OUT;
            } else if (fd == abi.STDIN) {
                // Nothing to read from descriptor 0 yet.
            } else if (fileOf(fd) != null) {
                entry.revents = entry.events & abi.POLL.IN;
            } else entry.revents = abi.POLL.NVAL;
        }
        if (entry.revents != 0) ready += 1;
        if (!toUser(at, entry)) return err(.FAULT);
    }
    if (ready == 0) {
        const timeout: i32 = @truncate(@as(i64, @bitCast(timeout_ms)));
        if (timeout < 0) while (true) timer.sleepMs(1000);
        if (timeout > 0) timer.sleepMs(@intCast(timeout));
    }
    return ready;
}

/// The memory calls (`user_memory.zig`), for the calling thread's process.
fn memory(comptime call: enum { mmap, mprotect, munmap, brk, madvise }, f: *const arch.Frame) u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    return switch (call) {
        // The offset (`f.r9`) only means something for a file.
        .mmap => user_memory.mmap(p, f.rdi, f.rsi, f.rdx, f.r10, f.r8),
        .mprotect => user_memory.mprotect(p, f.rdi, f.rsi, f.rdx),
        .munmap => user_memory.munmap(p, f.rdi, f.rsi),
        .brk => user_memory.brk(p, f.rdi),
        .madvise => user_memory.madvise(p, f.rdi, f.rsi, f.rdx),
    };
}

/// Syscall handler, called by the arch layer's entry code: call the implementation
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
        Sys.poll => sysPoll(f.rdi, f.rsi, f.rdx),
        Sys.rt_sigaction => sysSigAction(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.rt_sigprocmask => sysSigProcMask(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.sigaltstack => sysSigAltStack(f.rdi, f.rsi),
        Sys.mmap => memory(.mmap, f),
        Sys.mprotect => memory(.mprotect, f),
        Sys.munmap => memory(.munmap, f),
        Sys.brk => memory(.brk, f),
        Sys.madvise => memory(.madvise, f),
        Sys.ioctl => sysIoctl(f.rdi),
        Sys.writev => sysWritev(f.rdi, f.rsi, f.rdx),
        Sys.arch_prctl => sysArchPrctl(f.rdi, f.rsi),
        Sys.set_tid_address => sysSetTidAddress(f.rdi),
        // One thread per process: leaving the group is leaving.
        Sys.exit, Sys.exit_group => proc.exit(abi.exitStatus(f.rdi)),
        Sys.gettid => thread.id(),
        Sys.myos_getchar => sysGetChar(),
        Sys.myos_run => sysRun(f.rdi, f.rsi, f.rdx),
        else => err(.NOSYS),
    };
}

/// A syscall is about to return to a state the CPU cannot return to (a
/// return address outside user space, say): report it and kill the process,
/// as a fault at that address would.
pub fn badReturn(f: *const arch.Frame) noreturn {
    const p = thread.current().process.?;
    root.print("\n*** thread {d} ({s}): invalid return state after syscall, killed\n", .{ thread.id(), p.name });
    root.print("RIP=0x{x} RSP=0x{x} RFLAGS=0x{x} CS=0x{x} SS=0x{x}\n", .{ f.rip, f.rsp, f.rflags, f.cs, f.ss });
    proc.exit(proc.EXIT_KILLED);
}

/// Enable the `syscall` instruction, which the arch layer routes to
/// `dispatch`. Called once during boot.
pub fn init() void {
    arch.init();
}
