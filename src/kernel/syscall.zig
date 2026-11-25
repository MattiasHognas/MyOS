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
const ipi = @import("../arch/x86_64/ipi.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const kfutex = @import("futex.zig");
const kpipe = @import("pipe.zig");
const open_file = @import("open_file.zig");
const procfs = @import("procfs.zig");
const OpenFile = open_file.OpenFile;
const pmm = @import("pmm.zig");
const futex = kfutex; // its clock helpers read better by this name
const random = @import("random.zig");
const timer = @import("timer.zig");
const uaccess = @import("uaccess.zig");
const user_memory = @import("user_memory.zig");
const user_range = @import("user_range.zig");
const vfs = @import("vfs.zig");

/// Size of the kernel bounce buffer used to move data to and from user space.
const CHUNK = 256;

/// `myos_getchar`: return the next key from the keyboard buffer, blocking
/// the calling thread until one is typed.
fn sysGetChar() u64 {
    return keyboard.read() orelse err(.INTR); // the process is ending: the result goes nowhere
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
    // Whether it is still running or already gone. If this process is
    // ended meanwhile, the child runs on with nobody waiting for it.
    return proc.waitKillable(child) orelse {
        proc.release(child);
        return err(.INTR);
    };
}

/// `write`: print `count` bytes at the user address `ptr` to the console.
/// Only descriptors 1 and 2 can be written; anything else is `EBADF` (files
/// are read-only). Returns the number of bytes written, which is short if a
/// later part of the buffer cannot be read, or `EFAULT` if none of it can.
/// Whether the descriptor behind `of` is non-blocking.
fn nonblocking(of: *OpenFile) bool {
    const p = thread.current().process.?;
    const held = p.files_lock.acquire();
    defer p.files_lock.release(held);
    return of.nonblock;
}

/// `read` from a pipe: what is there, up to `len` bytes, waiting only
/// while there is nothing. The bytes come out of the pipe before they are
/// copied to the program; if that copy faults they are lost with `EFAULT`.
fn pipeRead(of: *OpenFile, ptr: u64, len: u64) u64 {
    if (!user_range.valid(ptr, len)) return err(.FAULT);
    var chunk: [CHUNK]u8 = undefined;
    const want: usize = @intCast(@min(CHUNK, len));
    switch (kpipe.read(of.pipe, chunk[0..want], nonblocking(of))) {
        .bytes => |n| {
            uaccess.copyToUser(ptr, chunk[0..n]) catch return err(.FAULT);
            return n;
        },
        .again => return err(.AGAIN),
        .killed => return err(.INTR),
    }
}

/// `write` to a pipe: all of it, a piece at a time, waiting for room;
/// short only if a later piece cannot be read from the program, would
/// have to wait on a non-blocking descriptor, or finds the reader gone.
fn pipeWrite(of: *OpenFile, ptr: u64, len: u64) u64 {
    if (!user_range.valid(ptr, len)) return err(.FAULT);
    const nonblock = nonblocking(of);
    var chunk: [CHUNK]u8 = undefined;
    var done: u64 = 0;
    while (done < len) {
        const part = chunk[0..@intCast(@min(CHUNK, len - done))];
        uaccess.copyFromUser(part, ptr + done) catch return if (done == 0) err(.FAULT) else done;
        switch (kpipe.write(of.pipe, part, nonblock)) {
            .bytes => |n| done += n,
            .again => return if (done == 0) err(.AGAIN) else done,
            // Linux also sends SIGPIPE; signals are not delivered yet (8).
            .broken => return if (done == 0) err(.PIPE) else done,
            .killed => return if (done == 0) err(.INTR) else done,
        }
    }
    return done;
}

/// `pipe` and `pipe2`: make a pipe and store its reading and its writing
/// descriptor at `fds`. `EINVAL` for flags other than `O_NONBLOCK` and
/// `O_CLOEXEC`, `EMFILE`, `ENOMEM`, `EFAULT` (then nothing stays open).
fn sysPipe(fds_ptr: u64, flags: u64) u64 {
    if (flags & ~@as(u64, abi.O.NONBLOCK | abi.O.CLOEXEC) != 0) return err(.INVAL);
    const p = thread.current().process orelse return err(.BADF);
    const nonblock = flags & abi.O.NONBLOCK != 0;
    const r = heap.allocator.create(OpenFile) catch return err(.NOMEM);
    const w = heap.allocator.create(OpenFile) catch {
        heap.allocator.destroy(r);
        return err(.NOMEM);
    };
    const pp = kpipe.create() catch {
        heap.allocator.destroy(r);
        heap.allocator.destroy(w);
        return err(.NOMEM);
    };
    // From here the open files own the pipe: destroying both frees it.
    r.* = .{ .kind = .pipe_read, .pipe = pp, .nonblock = nonblock };
    w.* = .{ .kind = .pipe_write, .pipe = pp, .nonblock = nonblock };
    const rfd = installFile(p, r, 0) orelse {
        open_file.destroy(r);
        open_file.destroy(w);
        return err(.MFILE);
    };
    const wfd = installFile(p, w, 0) orelse {
        _ = sysClose(rfd);
        open_file.destroy(w);
        return err(.MFILE);
    };
    const out = [2]i32{ @intCast(rfd), @intCast(wfd) };
    if (!toUser(fds_ptr, out)) {
        _ = sysClose(rfd);
        _ = sysClose(wfd);
        return err(.FAULT);
    }
    return 0;
}

fn sysWrite(fd: u64, ptr: u64, count: u64) u64 {
    {
        const of = getFile(fd) orelse return err(.BADF);
        defer putFile(of);
        switch (of.kind) {
            .console => {},
            .pipe_write => return pipeWrite(of, ptr, @min(count, abi.MAX_RW_COUNT)),
            .null_device, .random_device => {
                // Thrown away unread; only an address outside user space is refused.
                const len = @min(count, abi.MAX_RW_COUNT);
                return if (user_range.valid(ptr, len)) len else err(.FAULT);
            },
            .file, .pipe_read => return err(.BADF), // files are read-only
        }
    }
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
    {
        const of = getFile(fd) orelse return err(.BADF);
        defer putFile(of);
        if (of.kind == .file or of.kind == .pipe_read) return err(.BADF);
    }
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
    return if (isOpen(fd)) err(.NOTTY) else err(.BADF);
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

/// The open file behind descriptor `fd` of the current process, with a
/// reference taken for the caller, who gives it back with `putFile`; null
/// if `fd` is out of range, not open, or the thread has no process. The
/// reference keeps the file there while another thread closes the descriptor.
fn getFile(fd: u64) ?*OpenFile {
    const p = thread.current().process orelse return null;
    const held = p.files_lock.acquire();
    defer p.files_lock.release(held);
    if (fd >= p.files.len) return null;
    const of = p.files[nospec.index(fd, p.files.len)] orelse return null;
    of.refs += 1;
    return of;
}

/// Give back a reference from `getFile`; the file is freed with its last one.
fn putFile(of: *OpenFile) void {
    const p = thread.current().process.?;
    const last = blk: {
        const held = p.files_lock.acquire();
        defer p.files_lock.release(held);
        of.refs -= 1;
        break :blk of.refs == 0;
    };
    if (last) open_file.destroy(of);
}

/// True if `fd` is an open file.
fn isOpen(fd: u64) bool {
    const of = getFile(fd) orelse return false;
    putFile(of);
    return true;
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
    const p = thread.current().process orelse return err(.BADF);
    const what = named(path);
    var opened: OpenFile = .{};
    switch (what) {
        .none => return if (flags & abi.O.CREAT != 0) err(.ROFS) else err(.NOENT),
        // Directories cannot be opened yet: there is nothing to do with
        // one (no `getdents64`, no paths relative to it).
        .directory => return if (flags & abi.O.ACCMODE != abi.O.RDONLY) err(.ISDIR) else err(.ACCES),
        .device => |kind| {
            if (flags & abi.O.DIRECTORY != 0) return err(.NOTDIR);
            opened.kind = kind; // may be opened for writing: what is written is thrown away
        },
        .file, .exe_link, .generated => {
            if (flags & abi.O.DIRECTORY != 0) return err(.NOTDIR);
            if (flags & abi.O.ACCMODE != abi.O.RDONLY) return err(.ROFS);
            if (what == .generated) {
                const text = procfs.generate(what.generated, p) catch return err(.NOMEM);
                opened.generated = text;
                opened.node = open_file.memoryNode(text);
            } else opened.node = fileAt(path) orelse return err(.NOENT);
        },
    }
    opened.nonblock = flags & abi.O.NONBLOCK != 0;

    // Allocated before the table is locked, and freed again if it is full.
    const of = heap.allocator.create(OpenFile) catch {
        if (opened.generated) |text| heap.allocator.free(text);
        return err(.NOMEM);
    };
    of.* = opened;
    return installFile(p, of, 0) orelse {
        open_file.destroy(of);
        return err(.MFILE);
    };
}

/// Put `of` in the lowest free descriptor of `p` that is at least `from`
/// and within the process's limit, and return it; null if there is none.
/// The reference the caller holds becomes the descriptor's.
fn installFile(p: *proc.Process, of: *OpenFile, from: usize) ?usize {
    const limit = @min(proc.MAX_FILES, p.limits.max_files);
    while (true) {
        const len = blk: {
            const held = p.files_lock.acquire();
            defer p.files_lock.release(held);
            var fd = from;
            while (fd < @min(p.files.len, limit)) : (fd += 1) {
                if (p.files[fd] != null) continue;
                p.files[fd] = of;
                return fd;
            }
            break :blk p.files.len;
        };
        // None free in the table as it is: a longer one, if the limit
        // allows, and again (another thread may take what was added).
        const need = @max(len, from) + 1;
        if (need > limit or !proc.growFiles(p, need)) return null;
    }
}

/// `dup` and `fcntl(F_DUPFD)`: a second descriptor for what `fd` refers
/// to, the lowest free one that is at least `from`. Both share the file
/// and its offset. `EBADF`, `EINVAL` (no such descriptor number), `EMFILE`.
fn sysDup(fd: u64, from: u64) u64 {
    const p = thread.current().process orelse return err(.BADF);
    if (from >= @min(proc.MAX_FILES, p.limits.max_files)) return err(.INVAL);
    const of = getFile(fd) orelse return err(.BADF);
    // The reference from `getFile` becomes the new descriptor's.
    return installFile(p, of, @intCast(from)) orelse {
        putFile(of);
        return err(.MFILE);
    };
}

/// `dup2` and `dup3`: make `new` refer to what `old` does, closing what
/// `new` referred to. With `same_is_error`, `old == new` is `EINVAL`
/// (`dup3`); otherwise it does nothing and returns `new` (`dup2`).
fn sysDup2(old: u64, new: u64, same_is_error: bool) u64 {
    const p = thread.current().process orelse return err(.BADF);
    const of = getFile(old) orelse return err(.BADF);
    if (new >= @min(proc.MAX_FILES, p.limits.max_files)) {
        putFile(of);
        return err(.BADF);
    }
    if (old == new) {
        putFile(of);
        return if (same_is_error) err(.INVAL) else new;
    }
    // The table only ever grows, so once it is long enough it stays so.
    if (!proc.growFiles(p, @intCast(new + 1))) {
        putFile(of);
        return err(.NOMEM);
    }
    const replaced = blk: {
        const held = p.files_lock.acquire();
        defer p.files_lock.release(held);
        const slot = &p.files[nospec.index(new, p.files.len)];
        const before = slot.*;
        slot.* = of; // with the reference from `getFile`
        break :blk before;
    };
    if (replaced) |r| putFile(r);
    return new;
}

/// `openat`: `open` for a path that is absolute, or relative to the
/// current directory (`AT_FDCWD`), which is the root: there are no other
/// directories to be relative to yet (`EBADF` for one).
fn sysOpenAt(dirfd: u64, ptr: u64, flags: u64) u64 {
    const dir: i32 = @truncate(@as(i64, @bitCast(dirfd)));
    if (dir != abi.AT_FDCWD) {
        // An absolute path ignores the directory, as on Linux.
        const first = fromUser(u8, ptr) orelse return err(.FAULT);
        if (first != '/') return err(.BADF);
    }
    return sysOpen(ptr, flags);
}

/// Read up to `len` bytes of the open file `of` from `offset` into the
/// user buffer at `ptr`. Returns the number of bytes read, short if a
/// later part of the buffer cannot be written, or `EFAULT` if none could.
fn readAt(of: *OpenFile, offset: u64, ptr: u64, len: u64) u64 {
    if (!user_range.valid(ptr, len)) return err(.FAULT);
    var chunk: [CHUNK]u8 = undefined;
    var done: u64 = 0;
    var faulted = false;
    while (done < len) {
        const want: usize = @intCast(@min(CHUNK, len - done));
        const n = vfs.read(&of.node, offset + done, chunk[0..want]);
        if (n == 0) break; // end of file
        uaccess.copyToUser(ptr + done, chunk[0..n]) catch {
            faulted = true;
            break;
        };
        done += n;
    }
    if (faulted and done == 0) return err(.FAULT);
    return done;
}

/// `read`: read up to `count` bytes from descriptor `fd` into the user
/// buffer at `ptr`, advancing the file offset by what was read. Returns the
/// number of bytes read (0 at end of file), which is short if a later part
/// of the buffer cannot be written; `EBADF` if `fd` is not an open file
/// (descriptor 0 has no input yet: milestone 6); `EFAULT` if nothing could
/// be stored. On `EFAULT` the offset is unchanged.
fn sysRead(fd: u64, ptr: u64, count: u64) u64 {
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    switch (of.kind) {
        .file => {},
        .pipe_read => return pipeRead(of, ptr, @min(count, abi.MAX_RW_COUNT)),
        .null_device => return 0,
        .random_device => return sysGetRandom(ptr, count),
        // Nothing to read from the console yet.
        .console, .pipe_write => return err(.BADF),
    }
    const p = thread.current().process.?;
    const start = blk: {
        const held = p.files_lock.acquire();
        defer p.files_lock.release(held);
        break :blk of.offset;
    };
    const done = readAt(of, start, ptr, @min(count, abi.MAX_RW_COUNT));
    if (abi.isError(done)) return done;
    // Two threads reading one descriptor at once each get data, and the
    // offset moves by both amounts; which of them gets which part is not
    // defined, as on Linux.
    const held = p.files_lock.acquire();
    defer p.files_lock.release(held);
    of.offset += done;
    return done;
}

/// `pread64`: `read` from `offset`, leaving the file's own offset alone.
fn sysPread(fd: u64, ptr: u64, count: u64, offset: u64) u64 {
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    if (of.kind != .file) return err(.SPIPE);
    if (offset > std.math.maxInt(i64)) return err(.INVAL);
    return readAt(of, offset, ptr, @min(count, abi.MAX_RW_COUNT));
}

/// `lseek`: move the offset of the open file `fd` and return it. `ESPIPE`
/// for the standard streams, `EINVAL` for a position before the start or
/// an unknown `whence`.
fn sysLseek(fd: u64, offset: u64, whence: u64) u64 {
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    if (of.kind != .file) return err(.SPIPE);
    const p = thread.current().process.?;
    const held = p.files_lock.acquire();
    defer p.files_lock.release(held);
    const base: i64 = switch (whence) {
        abi.SEEK.SET => 0,
        abi.SEEK.CUR => @intCast(of.offset),
        abi.SEEK.END => @intCast(of.node.size),
        else => return err(.INVAL),
    };
    const new = std.math.add(i64, base, @bitCast(offset)) catch return err(.INVAL);
    if (new < 0) return err(.INVAL);
    of.offset = @intCast(new);
    return of.offset;
}

/// `fstat`: what kind of thing `fd` is and, for a file, how large. The
/// standard streams are character devices.
/// What a path names.
const Named = union(enum) {
    /// Nothing.
    none,
    file: vfs.Node,
    directory,
    /// A symbolic link to the program the calling process runs
    /// (`/proc/self/exe`): the only links there are.
    exe_link,
    /// A text file made when it is opened (`procfs.zig`).
    generated: procfs.File,
    /// `/dev/null`, `/dev/urandom`, `/dev/random`.
    device: open_file.Kind,
};

/// What `path` (absolute) names, without following a link at its end. The
/// filesystem's files and directories, and the few entries of `/proc` a
/// program finds itself by: `/proc`, `/proc/self` and `/proc/<its pid>`
/// are directories, and `exe` in the last two is a link to its program.
fn named(path: []const u8) Named {
    if (procEntry(path)) |entry| return entry;
    if (std.mem.eql(u8, path, "/dev/null")) return .{ .device = .null_device };
    if (std.mem.eql(u8, path, "/dev/urandom") or std.mem.eql(u8, path, "/dev/random")) return .{ .device = .random_device };
    if (std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), "/dev")) return .directory;
    if (vfs.lookup(path)) |node| return .{ .file = node };
    return if (vfs.isDirectory(path)) .directory else .none;
}

fn procEntry(path: []const u8) ?Named {
    const p = thread.current().process orelse return null;
    var rest = std.mem.trimEnd(u8, path, "/");
    if (!std.mem.startsWith(u8, rest, "/proc")) return null;
    rest = rest["/proc".len..];
    if (rest.len == 0) return .directory;
    if (rest[0] != '/') return null; // "/process", say
    rest = rest[1..];
    // "/proc/<name>", or "/proc/<self or the caller's ID>[/<name>]".
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const first = rest[0 .. slash orelse rest.len];
    var id_buf: [20]u8 = undefined;
    const own_id = std.fmt.bufPrint(&id_buf, "{d}", .{p.pid}) catch unreachable;
    if (!std.mem.eql(u8, first, "self") and !std.mem.eql(u8, first, own_id)) {
        if (slash == null) if (procfs.find(first, false)) |file| return .{ .generated = file };
        return .none;
    }
    const name = rest[(slash orelse return .directory) + 1 ..];
    if (std.mem.eql(u8, name, "exe")) return .exe_link;
    return if (procfs.find(name, true)) |file| .{ .generated = file } else .none;
}

/// The file `path` names, following the link if it is one. Null if it
/// names nothing or a directory.
fn fileAt(path: []const u8) ?vfs.Node {
    return switch (named(path)) {
        .file => |node| node,
        .exe_link => vfs.lookup(thread.current().process.?.name),
        .none, .directory, .generated, .device => null,
    };
}

/// What `stat` says about a directory.
fn directoryStat() abi.Stat {
    var st: abi.Stat = .{};
    st.mode = abi.S.IFDIR | 0o555;
    st.nlink = 2;
    st.dev = 1;
    st.ino = 2;
    return st;
}

/// What `stat` says about a text file of `/proc`: a file of no length,
/// as on Linux, since its text does not exist until it is opened.
fn generatedStat() abi.Stat {
    var st: abi.Stat = .{};
    st.mode = abi.S.IFREG | 0o444;
    st.dev = 2;
    st.ino = 4;
    return st;
}

/// What `stat` says about `/dev/null` and the random devices.
fn deviceStat() abi.Stat {
    var st: abi.Stat = .{};
    st.mode = abi.S.IFCHR | 0o666;
    st.rdev = 0x0103; // 1, 3: /dev/null's number; programs only look at the type
    st.dev = 3;
    st.ino = 5;
    return st;
}

/// What `stat` says about a file of the filesystem.
fn fileStat(node: vfs.Node) abi.Stat {
    var st: abi.Stat = .{};
    st.mode = abi.S.IFREG | 0o555;
    st.size = @intCast(node.size);
    st.blocks = @intCast((node.size + 511) / 512);
    st.blksize = 4096;
    st.nlink = 1;
    // Two files are the same file if these two are equal: a dynamic
    // loader tells by them whether it has a library already.
    st.dev = 1;
    st.ino = node.ctx;
    return st;
}

/// The path at `ptr`, which must be absolute unless `dirfd` is
/// `AT_FDCWD`: there are no directories to be relative to (`ENOTDIR`),
/// and the working directory is always "/".
fn pathAt(buf: *[abi.PATH_MAX]u8, dirfd: u64, ptr: u64) union(enum) { path: []const u8, fail: u64 } {
    const path = switch (userPath(buf, ptr)) {
        .path => |p| p,
        .fail => |e| return .{ .fail = e },
    };
    const dir: i32 = @truncate(@as(i64, @bitCast(dirfd)));
    if (path[0] != '/' and dir != abi.AT_FDCWD) return .{ .fail = if (isOpen(dirfd)) err(.NOTDIR) else err(.BADF) };
    return .{ .path = path };
}

/// `newfstatat`: `stat` of the file at a path, or of the descriptor
/// itself with an empty path and `AT_EMPTY_PATH`. `ENOENT`, `EINVAL`
/// for unknown flags, `EFAULT`.
fn sysNewfstatat(dirfd: u64, path_ptr: u64, stat_ptr: u64, flags: u64) u64 {
    if (flags & ~@as(u64, abi.AT_EMPTY_PATH | abi.AT_SYMLINK_NOFOLLOW | 0x800) != 0) return err(.INVAL); // 0x800: AT_NO_AUTOMOUNT
    if (flags & abi.AT_EMPTY_PATH != 0) {
        const first = fromUser(u8, path_ptr) orelse return err(.FAULT);
        if (first == 0) return sysFstat(dirfd, stat_ptr);
    }
    var path_buf: [abi.PATH_MAX]u8 = undefined;
    const path = switch (pathAt(&path_buf, dirfd, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    const st = switch (named(path)) {
        .none => return err(.NOENT),
        .directory => directoryStat(),
        .file => |node| fileStat(node),
        .generated => generatedStat(),
        .device => deviceStat(),
        .exe_link => blk: {
            if (flags & abi.AT_SYMLINK_NOFOLLOW != 0) {
                var link: abi.Stat = .{};
                link.mode = abi.S.IFLNK | 0o777;
                link.dev = 1;
                link.ino = 3;
                break :blk link;
            }
            break :blk fileStat(fileAt(path) orelse return err(.NOENT));
        },
    };
    return if (toUser(stat_ptr, st)) 0 else err(.FAULT);
}

/// A call that would change the filesystem, at a path: `ENOENT` and the
/// other errors of a path that cannot be found come first, as on Linux
/// with a read-only filesystem; then `EROFS`. With `must_exist` false
/// (the call would make the file) a missing file is `EROFS` too.
fn sysReadOnlyPath(dirfd: u64, path_ptr: u64, must_exist: bool) u64 {
    var path_buf: [abi.PATH_MAX]u8 = undefined;
    const path = switch (pathAt(&path_buf, dirfd, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    if (must_exist and named(path) == .none) return err(.NOENT);
    return err(.ROFS);
}

/// `access`, `faccessat` and `faccessat2`: files can be read and run,
/// never written (`EROFS`). `ENOENT`, `EINVAL` for an unknown mode.
fn sysAccess(dirfd: u64, path_ptr: u64, mode: u64) u64 {
    if (mode & ~@as(u64, abi.ACCESS.R_OK | abi.ACCESS.W_OK | abi.ACCESS.X_OK) != 0) return err(.INVAL);
    var path_buf: [abi.PATH_MAX]u8 = undefined;
    const path = switch (pathAt(&path_buf, dirfd, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    if (named(path) == .none) return err(.NOENT);
    return if (mode & abi.ACCESS.W_OK != 0) err(.ROFS) else 0;
}

/// `readlink` and `readlinkat`: what a symbolic link points to, without
/// a NUL, cut to `size` bytes; returns the bytes stored. The one link is
/// `/proc/self/exe`, by which a program finds its own file. `EINVAL` for
/// what exists and is no link, or a size of zero; `ENOENT`; `EFAULT`.
fn sysReadlink(dirfd: u64, path_ptr: u64, buf: u64, size: u64) u64 {
    var path_buf: [abi.PATH_MAX]u8 = undefined;
    const path = switch (pathAt(&path_buf, dirfd, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    switch (named(path)) {
        .none => return err(.NOENT),
        .file, .directory, .generated, .device => return err(.INVAL),
        .exe_link => {},
    }
    if (size == 0) return err(.INVAL);
    // The name can change under another thread's feet only by the process
    // ending, and then this thread ends too.
    const target = thread.current().process.?.name;
    const n = @min(target.len, size);
    uaccess.copyToUser(buf, target[0..n]) catch return err(.FAULT);
    return n;
}

/// `getcwd`: the working directory is always "/". Returns the length
/// with the NUL, as the system call does; `ERANGE` if the buffer is
/// shorter, `EFAULT`.
fn sysGetcwd(buf: u64, size: u64) u64 {
    const cwd = [2]u8{ '/', 0 };
    if (size < cwd.len) return err(.RANGE);
    return if (toUser(buf, cwd)) cwd.len else err(.FAULT);
}

/// `set_robust_list`: a thread's list of locks to mark as abandoned if it
/// dies holding them. The address is checked and otherwise ignored: a
/// thread that dies takes its process with it (there is no shared memory
/// between processes for another one to wait on such a lock in).
fn sysSetRobustList(head: u64, size: u64) u64 {
    if (size != abi.ROBUST_LIST_HEAD_SIZE) return err(.INVAL);
    _ = head;
    return 0;
}

fn sysFstat(fd: u64, ptr: u64) u64 {
    var st: abi.Stat = .{};
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    switch (of.kind) {
        .console => {
            st.mode = abi.S.IFCHR | 0o620;
            st.rdev = 0x8800; // a pseudo-terminal's device number
            st.blksize = 1024;
        },
        .pipe_read, .pipe_write => {
            st.mode = abi.S.IFIFO | 0o600;
            st.blksize = kpipe.SIZE;
        },
        .null_device, .random_device => st = deviceStat(),
        .file => st = fileStat(of.node),
    }
    return if (toUser(ptr, st)) 0 else err(.FAULT);
}

/// `fcntl`: the descriptor and status flags can be read; setting them is
/// accepted and changes nothing (there is nothing they would change yet).
fn sysFcntl(fd: u64, command: u64, arg: u64) u64 {
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    const p = thread.current().process.?;
    switch (command) {
        // F_DUPFD and F_DUPFD_CLOEXEC. Nothing is closed on exec yet:
        // there is no exec.
        0, 1030 => return sysDup(fd, arg),
        1, 2 => return 0, // F_GETFD, F_SETFD
        3 => { // F_GETFL
            const access: u64 = switch (of.kind) {
                .console, .null_device, .random_device => abi.O.RDWR,
                .file, .pipe_read => abi.O.RDONLY,
                .pipe_write => abi.O.WRONLY,
            };
            return access | if (nonblocking(of)) @as(u64, abi.O.NONBLOCK) else 0;
        },
        4 => { // F_SETFL: only O_NONBLOCK can change
            const held = p.files_lock.acquire();
            defer p.files_lock.release(held);
            of.nonblock = arg & abi.O.NONBLOCK != 0;
            return 0;
        },
        else => return err(.INVAL),
    }
}

/// `close`: make descriptor `fd` free again. What it referred to goes
/// when its last descriptor does. Returns 0, or `EBADF` if `fd` is not open.
fn sysClose(fd: u64) u64 {
    const p = thread.current().process orelse return err(.BADF);
    const of = blk: {
        const held = p.files_lock.acquire();
        defer p.files_lock.release(held);
        if (fd >= p.files.len) return err(.BADF);
        const slot = &p.files[nospec.index(fd, p.files.len)];
        const of = slot.* orelse return err(.BADF);
        slot.* = null;
        break :blk of;
    };
    putFile(of); // the descriptor's reference; a call in flight keeps its own
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
    const timeout: i32 = @truncate(@as(i64, @bitCast(timeout_ms)));
    // Ticks left to wait; null is for ever.
    var left: ?u64 = if (timeout < 0) null else timer.msToTicks(@intCast(timeout));
    while (true) {
        var ready: u64 = 0;
        for (0..count) |i| {
            const at = fds + i * @sizeOf(abi.PollFd);
            var entry = fromUser(abi.PollFd, at) orelse return err(.FAULT);
            entry.revents = 0;
            if (entry.fd >= 0) {
                if (getFile(@intCast(entry.fd))) |of| {
                    entry.revents = pollState(of, entry.events);
                    putFile(of);
                } else entry.revents = abi.POLL.NVAL;
            }
            if (entry.revents != 0) ready += 1;
            if (!toUser(at, entry)) return err(.FAULT);
        }
        if (ready != 0) return ready;
        // Nothing yet: look again a tick later. Descriptors have no way
        // to wake a poller yet; that comes with `epoll`.
        if (left) |l| {
            if (l == 0) return 0;
            left = l - 1;
        }
        if (!timer.sleepTicksKillable(1)) return err(.INTR);
    }
}

/// What `poll` reports for an open file, of the events asked for; hang-up
/// and error are reported whether asked for or not.
fn pollState(of: *OpenFile, events: i16) i16 {
    switch (of.kind) {
        // The console can be written to and has nothing to read yet.
        .console => return events & abi.POLL.OUT,
        .null_device, .random_device => return events & (abi.POLL.IN | abi.POLL.OUT),
        // A file can always be read.
        .file => return events & abi.POLL.IN,
        .pipe_read => {
            const st = kpipe.state(of.pipe);
            var r: i16 = 0;
            if (st.readable) r |= events & abi.POLL.IN;
            if (st.hung_up) r |= abi.POLL.HUP;
            return r;
        },
        .pipe_write => {
            const st = kpipe.state(of.pipe);
            if (st.broken) return abi.POLL.ERR;
            return if (st.writable) events & abi.POLL.OUT else 0;
        },
    }
}

/// Seconds between 1970 and the moment the wall clock is taken to have
/// started at boot: 2026-01-01. There is no clock chip driver yet, so
/// "real" time is time since boot from there.
const BOOT_EPOCH_SECONDS: u64 = 1_767_225_600;
const NS_PER_SEC: u64 = 1_000_000_000;

/// Nanoseconds on `clock`, or null if there is no such clock.
fn clockNanos(clock: u64) ?u64 {
    return switch (clock) {
        abi.CLOCK.MONOTONIC, abi.CLOCK.MONOTONIC_RAW, abi.CLOCK.MONOTONIC_COARSE, abi.CLOCK.BOOTTIME => futex.monotonicNanos(),
        abi.CLOCK.REALTIME, abi.CLOCK.REALTIME_COARSE => futex.monotonicNanos() + BOOT_EPOCH_SECONDS * NS_PER_SEC,
        // CPU time used is not counted yet; time since boot is an upper bound.
        abi.CLOCK.PROCESS_CPUTIME_ID, abi.CLOCK.THREAD_CPUTIME_ID => futex.monotonicNanos(),
        else => null,
    };
}

fn timeSpec(ns: u64) abi.TimeSpec {
    return .{ .sec = @intCast(ns / NS_PER_SEC), .nsec = @intCast(ns % NS_PER_SEC) };
}

/// The nanoseconds in the `timespec` at the user address `ptr`, or an
/// error value: `EFAULT`, or `EINVAL` if it is not a valid time.
fn userNanos(ptr: u64) union(enum) { ns: u64, fail: u64 } {
    const ts = fromUser(abi.TimeSpec, ptr) orelse return .{ .fail = err(.FAULT) };
    if (ts.sec < 0 or ts.nsec < 0 or ts.nsec >= NS_PER_SEC) return .{ .fail = err(.INVAL) };
    const sec: u64 = @intCast(ts.sec);
    if (sec > std.math.maxInt(u64) / NS_PER_SEC / 2) return .{ .ns = std.math.maxInt(u64) / 2 }; // as good as forever
    return .{ .ns = sec * NS_PER_SEC + @as(u64, @intCast(ts.nsec)) };
}

/// `clock_gettime`.
fn sysClockGetTime(clock: u64, ptr: u64) u64 {
    const ns = clockNanos(clock) orelse return err(.INVAL);
    return if (toUser(ptr, timeSpec(ns))) 0 else err(.FAULT);
}

/// `time`: seconds of the real-time clock, also stored at `tloc` if that
/// is not null.
fn sysTime(tloc: u64) u64 {
    const seconds: i64 = @intCast(clockNanos(abi.CLOCK.REALTIME).? / NS_PER_SEC);
    if (tloc != 0 and !toUser(tloc, seconds)) return err(.FAULT);
    return @intCast(seconds);
}

/// `gettimeofday`: seconds and microseconds; the time zone is not filled in.
fn sysGetTimeOfDay(tv: u64) u64 {
    if (tv == 0) return 0;
    const ns = clockNanos(abi.CLOCK.REALTIME).?;
    const value = [2]i64{ @intCast(ns / NS_PER_SEC), @intCast(ns % NS_PER_SEC / 1000) };
    return if (toUser(tv, value)) 0 else err(.FAULT);
}

/// Sleep until `deadline` (nanoseconds since boot). Returns 0, or `EINTR`
/// if the process is ending.
fn sleepUntil(deadline: u64) u64 {
    while (true) {
        const now = futex.monotonicNanos();
        if (now >= deadline) return 0;
        // In ticks, rounded up; a tick more than needed is slept by `sleepTicks`.
        const ticks = futex.nanosToTicks(deadline - now);
        if (!timer.sleepTicksKillable(ticks -| 1)) return err(.INTR);
    }
}

/// `nanosleep` and `clock_nanosleep`: sleep for the time at `request`, or
/// with `absolute` until that time on `clock`. Nothing interrupts a sleep
/// yet, so `remaining` is never written.
fn sysSleep(clock: u64, absolute: bool, request: u64) u64 {
    const now = clockNanos(clock) orelse return err(.INVAL);
    const ns = switch (userNanos(request)) {
        .ns => |n| n,
        .fail => |e| return e,
    };
    const wait_ns = if (absolute) ns -| now else ns;
    return sleepUntil(futex.monotonicNanos() +| wait_ns);
}

/// `futex`: wait on, wake, or move the waiters of the 32-bit word at
/// `addr` (`futex.zig`). `EINVAL` for an operation that does not exist
/// here, and for an empty bit set.
fn sysFutex(f: *const arch.Frame) u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    const addr = f.rdi;
    const op = f.rsi;
    const value: u32 = @truncate(f.rdx);
    if (addr % 4 != 0) return err(.INVAL);
    if (!user_range.valid(addr, 4)) return err(.FAULT);
    const command = op & abi.FUTEX.CMD_MASK;
    switch (command) {
        abi.FUTEX.WAIT, abi.FUTEX.WAIT_BITSET => {
            const bitset: u32 = if (command == abi.FUTEX.WAIT) kfutex.ANY else @truncate(f.r9);
            if (bitset == 0) return err(.INVAL);
            var ticks: ?u64 = null;
            if (f.r10 != 0) {
                const ns = switch (userNanos(f.r10)) {
                    .ns => |n| n,
                    .fail => |e| return e,
                };
                // WAIT takes how long; WAIT_BITSET takes until when.
                const left = if (command == abi.FUTEX.WAIT) ns else blk: {
                    const clock: u64 = if (op & abi.FUTEX.CLOCK_REALTIME != 0) abi.CLOCK.REALTIME else abi.CLOCK.MONOTONIC;
                    break :blk ns -| clockNanos(clock).?;
                };
                if (left == 0) {
                    // No time to wait: only the comparison is left to do.
                    const now = fromUser(u32, addr) orelse return err(.FAULT);
                    return if (now != value) err(.AGAIN) else err(.TIMEDOUT);
                }
                ticks = kfutex.nanosToTicks(left);
            }
            kfutex.wait(p, addr, value, bitset, ticks) catch |e| return futexError(e);
            return 0;
        },
        abi.FUTEX.WAKE, abi.FUTEX.WAKE_BITSET => {
            const bitset: u32 = if (command == abi.FUTEX.WAKE) kfutex.ANY else @truncate(f.r9);
            if (bitset == 0) return err(.INVAL);
            return kfutex.wake(p, addr, value, bitset);
        },
        abi.FUTEX.REQUEUE, abi.FUTEX.CMP_REQUEUE => {
            if (f.r8 % 4 != 0) return err(.INVAL);
            if (!user_range.valid(f.r8, 4)) return err(.FAULT);
            const expected: ?u32 = if (command == abi.FUTEX.CMP_REQUEUE) @as(u32, @truncate(f.r9)) else null;
            return kfutex.requeue(p, addr, value, @truncate(f.r10), f.r8, expected) catch |e| futexError(e);
        },
        else => return err(.NOSYS),
    }
}

fn futexError(e: kfutex.WaitError) u64 {
    return switch (e) {
        error.Again => err(.AGAIN),
        error.TimedOut => err(.TIMEDOUT),
        error.Fault => err(.FAULT),
        error.Interrupted => err(.INTR),
    };
}

/// `clone`: a new thread of the calling process. Only that: the flags must
/// say that it shares the address space and the signal handlers and is
/// part of the same thread group (`EINVAL` otherwise; there is no `fork`
/// yet). Returns the new thread's ID in the caller, 0 in the new thread.
fn sysClone(f: *const arch.Frame) u64 {
    const flags = f.rdi;
    if (flags & proc.CLONE.THREAD_FLAGS != proc.CLONE.THREAD_FLAGS) return err(.INVAL);
    if (thread.current().process == null) return err(.NOSYS);
    // The order of the last arguments is x86-64's: child_tid, then tls.
    const tid = proc.cloneThread(f, .{ .flags = flags, .stack = f.rsi, .parent_tid = f.rdx, .child_tid = f.r10, .tls = f.r8 }) catch |e| return switch (e) {
        error.OutOfMemory => err(.NOMEM),
        error.Fault => err(.FAULT),
        error.BadAddress => err(.PERM),
        error.ProcessEnding => err(.INTR),
    };
    return tid;
}

/// `clone3`: `clone` with its arguments in a structure of `size` bytes,
/// which newer C libraries try first. The same rules: a new thread of the
/// calling process and nothing else. The stack is given by its lowest
/// address and its size. `EINVAL` for a size below the first version of
/// the structure or above a page, for nonzero fields this kernel does
/// not know (as Linux does for fields it does not know), for a signal on
/// exit, and for a stack with a size and no address or the reverse.
fn sysClone3(f: *const arch.Frame) u64 {
    const size = f.rsi;
    if (size < @sizeOf(abi.CloneArgs) or size > pmm.PAGE_SIZE) return err(.INVAL);
    const args = fromUser(abi.CloneArgs, f.rdi) orelse return err(.FAULT);
    var extra: u64 = @sizeOf(abi.CloneArgs);
    while (extra < size) : (extra += 1) {
        const byte = fromUser(u8, f.rdi + extra) orelse return err(.FAULT);
        if (byte != 0) return err(.INVAL); // set_tid, cgroup: not offered
    }
    if (args.flags & proc.CLONE.THREAD_FLAGS != proc.CLONE.THREAD_FLAGS) return err(.INVAL);
    if (args.exit_signal != 0 or (args.stack == 0) != (args.stack_size == 0)) return err(.INVAL);
    const top = std.math.add(u64, args.stack, args.stack_size) catch return err(.INVAL);
    if (thread.current().process == null) return err(.NOSYS);
    const tid = proc.cloneThread(f, .{ .flags = args.flags, .stack = top, .parent_tid = args.parent_tid, .child_tid = args.child_tid, .tls = args.tls }) catch |e| return switch (e) {
        error.OutOfMemory => err(.NOMEM),
        error.Fault => err(.FAULT),
        error.BadAddress => err(.PERM),
        error.ProcessEnding => err(.INTR),
    };
    return tid;
}

/// The thread a scheduling call is about: `tid` 0 is the caller, anything
/// else must be a thread of the calling process (`ESRCH`; other
/// processes' threads are nobody's business yet).
fn schedTarget(tid: u64) ?u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    if (tid != 0 and !proc.hasThread(p, tid)) return err(.SRCH);
    return null;
}

/// `sched_setaffinity`: which CPUs a thread may run on. The scheduler has
/// one queue for all CPUs and does not keep threads off any, so a mask is
/// accepted if it leaves the thread a CPU that is up, and changes
/// nothing. `EINVAL` for a mask with none, `EFAULT`, `ESRCH`.
fn sysSchedSetAffinity(tid: u64, size: u64, ptr: u64) u64 {
    if (schedTarget(tid)) |e| return e;
    var mask: u64 = 0;
    const take = @min(size, @sizeOf(u64));
    uaccess.copyFromUser(std.mem.asBytes(&mask)[0..take], ptr) catch return err(.FAULT);
    const n = percpu.count();
    const up: u64 = if (n >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;
    return if (mask & up == 0) err(.INVAL) else 0;
}

/// `sched_getscheduler`, `sched_getparam`, `sched_setscheduler`,
/// `sched_setparam`: every thread has the policy `SCHED_OTHER` and the
/// priority 0, and may be given just that. `EINVAL` for another policy or
/// priority, `ESRCH`, `EFAULT`.
fn sysSchedPolicy(comptime call: enum { get_policy, get_param, set_policy, set_param }, f: *const arch.Frame) u64 {
    if (schedTarget(f.rdi)) |e| return e;
    switch (call) {
        .get_policy => return abi.SCHED.OTHER,
        .get_param => return if (toUser(f.rsi, @as(i32, 0))) 0 else err(.FAULT),
        .set_policy, .set_param => {
            const param_ptr = if (call == .set_policy) f.rdx else f.rsi;
            const priority = fromUser(i32, param_ptr) orelse return err(.FAULT);
            if (call == .set_policy and f.rsi != abi.SCHED.OTHER) return err(.INVAL);
            return if (priority == 0) 0 else err(.INVAL);
        },
    }
}

/// `sched_get_priority_max` and `_min`: 0 for the one policy there is;
/// the real-time policies, which Linux knows and this kernel does not,
/// are `EINVAL` like any unknown one.
fn sysSchedPriorityRange(policy: u64) u64 {
    return if (policy == abi.SCHED.OTHER) 0 else err(.INVAL);
}

/// `getsid`: every process is a session of its own, since there is no
/// terminal to share. `ESRCH` for another process.
fn sysGetsid(pid: u64) u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    return if (pid == 0 or pid == p.pid) p.pid else err(.SRCH);
}

/// `sched_getaffinity`: the CPUs the thread may run on, which is all that
/// are up. Runtimes count the bits to learn how many CPUs there are.
/// Returns the bytes written (8); `EINVAL` if the buffer is smaller.
fn sysSchedGetAffinity(size: u64, ptr: u64) u64 {
    if (size < 8) return err(.INVAL);
    const n = percpu.count();
    const mask: u64 = if (n >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;
    return if (toUser(ptr, mask)) 8 else err(.FAULT);
}

/// `getrandom`: fill the user buffer with random bytes. Never blocks: the
/// generator is seeded at boot.
fn sysGetRandom(ptr: u64, count: u64) u64 {
    const len = @min(count, abi.MAX_RW_COUNT);
    if (!user_range.valid(ptr, len)) return err(.FAULT);
    var chunk: [CHUNK]u8 = undefined;
    var done: u64 = 0;
    while (done < len) {
        const part = chunk[0..@intCast(@min(CHUNK, len - done))];
        random.bytes(part);
        uaccess.copyToUser(ptr + done, part) catch return if (done == 0) err(.FAULT) else done;
        done += part.len;
    }
    return done;
}

/// `uname`: programs written for Linux ask, and some refuse a kernel that
/// does not say Linux or that claims a version older than they need.
fn sysUname(ptr: u64) u64 {
    var u: abi.UtsName = .{};
    const fields = .{ .{ &u.sysname, "Linux" }, .{ &u.nodename, "myos" }, .{ &u.release, "6.1.0-myos" }, .{ &u.version, "MyOS" }, .{ &u.machine, "x86_64" } };
    inline for (fields) |field| @memcpy(field[0][0..field[1].len], field[1]);
    return if (toUser(ptr, u)) 0 else err(.FAULT);
}

/// `prlimit64`: read a resource limit of the calling process. The stack
/// may grow to its reservation, a process has a fixed number of
/// descriptors, and nothing else is limited through this call. Limits
/// cannot be changed with it yet (`EPERM`).
fn sysPrlimit(pid: u64, resource: u64, new: u64, old: u64) u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    if (pid != 0 and pid != p.pid) return err(.SRCH);
    if (new != 0) return err(.PERM);
    if (old == 0) return 0;
    const limit: abi.RLimit = switch (resource) {
        abi.RLIMIT.STACK => .{ .cur = proc.STACK_RESERVE, .max = abi.RLIM_INFINITY },
        abi.RLIMIT.NOFILE => .{ .cur = p.limits.max_files, .max = proc.MAX_FILES },
        0...2, 4...6, 8...15 => .{ .cur = abi.RLIM_INFINITY, .max = abi.RLIM_INFINITY },
        else => return err(.INVAL),
    };
    return if (toUser(old, limit)) 0 else err(.FAULT);
}

/// `kill`, `tkill` and `tgkill`. Signals are not delivered yet (milestone
/// 8), so this does what can be done without that: signal 0 only checks
/// that the target exists; a signal whose default is to end the process,
/// sent to the calling process when no handler is set for it, ends it
/// (that is how `abort` works); anything else is accepted and dropped.
/// Only the calling process can be signalled (`ESRCH` for another).
fn sysKill(pid: u64, sig: u64) u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    if (sig > abi.NSIG) return err(.INVAL);
    if (pid != p.pid) return err(.SRCH);
    if (sig == 0) return 0;
    const action = p.signal_actions[nospec.index(sig - 1, abi.NSIG)];
    const ignored_by_default = switch (sig) {
        17, 18, 23, 28 => true, // SIGCHLD, SIGCONT, SIGURG, SIGWINCH
        else => false,
    };
    const unhandled = action.handler == 0 or sig == abi.SIGKILL; // SIG_DFL
    if (unhandled and !ignored_by_default) proc.exit(128 + sig);
    return 0;
}

/// `membarrier`: have every CPU pass a memory barrier before the call
/// returns, so that a thread of this process on another CPU has seen what
/// the caller wrote before it. Runtimes with a garbage collector use it
/// instead of making every thread pay for a barrier of its own. Every
/// other CPU is interrupted, which is more than asked for and correct.
/// `EINVAL` for a command that is not offered.
fn sysMembarrier(command: u64, flags: u64) u64 {
    if (flags != 0) return err(.INVAL);
    return switch (command) {
        abi.MEMBARRIER.QUERY => abi.MEMBARRIER.PRIVATE_EXPEDITED | abi.MEMBARRIER.REGISTER_PRIVATE_EXPEDITED,
        abi.MEMBARRIER.REGISTER_PRIVATE_EXPEDITED => 0,
        abi.MEMBARRIER.PRIVATE_EXPEDITED => blk: {
            ipi.broadcast(.barrier);
            break :blk 0;
        },
        else => err(.INVAL),
    };
}

/// `sysinfo`: how much memory the machine has and how much is free, and
/// how long it has been up. Runtimes size their heaps by it.
fn sysSysinfo(ptr: u64) u64 {
    const info: abi.SysInfo = .{
        .uptime = @intCast(kfutex.monotonicNanos() / NS_PER_SEC),
        .totalram = pmm.totalPages() * pmm.PAGE_SIZE,
        .freeram = pmm.free_pages * pmm.PAGE_SIZE,
        .procs = @truncate(proc.liveCount()),
        .mem_unit = 1,
    };
    return if (toUser(ptr, info)) 0 else err(.FAULT);
}

/// `statfs`: the only filesystem is the read-only one in memory.
/// `ENOENT` for a path that does not exist, which is how a program finds
/// that there are no control groups here.
fn sysStatfs(path_ptr: u64, ptr: u64) u64 {
    var path_buf: [abi.PATH_MAX]u8 = undefined;
    const path = switch (userPath(&path_buf, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    if (named(path) == .none) return err(.NOENT);
    const st: abi.StatFs = .{ .type = abi.TMPFS_MAGIC };
    return if (toUser(ptr, st)) 0 else err(.FAULT);
}

/// `get_mempolicy`: which memory nodes a thread allocates from. There is
/// one node and no policy: mode 0 (`MPOL_DEFAULT`) and an empty node
/// mask of `maxnode` bits. `EINVAL` for flags (none is supported) and for
/// a mask of more than a page of bits; `EFAULT`.
fn sysGetMempolicy(mode_ptr: u64, mask_ptr: u64, maxnode: u64, flags: u64) u64 {
    if (flags != 0) return err(.INVAL);
    if (mode_ptr != 0 and !toUser(mode_ptr, @as(i32, 0))) return err(.FAULT);
    if (mask_ptr != 0) {
        if (maxnode > 8 * pmm.PAGE_SIZE) return err(.INVAL);
        const zero: u64 = 0;
        var at: u64 = 0;
        while (at < (maxnode + 63) / 64) : (at += 1) {
            if (!toUser(mask_ptr + at * 8, zero)) return err(.FAULT);
        }
    }
    return 0;
}

/// `mlock` and `munlock`: memory is never paged out, so there is nothing
/// to lock; the range only has to be the program's.
fn sysMlock(addr: u64, len: u64) u64 {
    if (!user_range.valid(addr, len)) return err(.NOMEM);
    return 0;
}

/// The memory calls (`user_memory.zig`), for the calling thread's process.
fn memory(comptime call: enum { mmap, mprotect, munmap, mremap, brk, madvise }, f: *const arch.Frame) u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    return switch (call) {
        .mmap => blk: {
            // The descriptor and the offset only mean something for a file.
            if (f.r10 & abi.MAP.ANONYMOUS != 0) break :blk user_memory.mmap(p, f.rdi, f.rsi, f.rdx, f.r10, null);
            const of = getFile(f.r8) orelse break :blk err(.BADF);
            defer putFile(of); // the mapping keeps the file, not the descriptor
            if (of.kind != .file or of.generated != null) break :blk err(.NODEV);
            break :blk user_memory.mmap(p, f.rdi, f.rsi, f.rdx, f.r10, .{ .node = of.node, .offset = f.r9 });
        },
        .mprotect => user_memory.mprotect(p, f.rdi, f.rsi, f.rdx),
        .munmap => user_memory.munmap(p, f.rdi, f.rsi),
        .mremap => user_memory.mremap(p, f.rdi, f.rsi, f.rdx, f.r10),
        .brk => user_memory.brk(p, f.rdi),
        .madvise => user_memory.madvise(p, f.rdi, f.rsi, f.rdx),
    };
}

/// Syscall handler, called by the arch layer's entry code: call the implementation
/// selected by `f.rax` with the arguments from the frame and store its
/// result in `f.rax`. Unknown numbers return `ENOSYS`.
pub fn dispatch(f: *arch.Frame) void {
    if (trace_all) {
        const number = f.rax;
        const args = [3]u64{ f.rdi, f.rsi, f.rdx };
        root.print("syscall: thread {d} call {d}(0x{x}, 0x{x}, 0x{x}) ...\n", .{ thread.id(), number, args[0], args[1], args[2] });
        dispatchCall(f);
        root.print("syscall: thread {d} call {d} = 0x{x}\n", .{ thread.id(), number, f.rax });
        return;
    }
    dispatchCall(f);
}

/// Log every system call of every program, with its first three arguments
/// when it starts and its result when it returns (calls that wait show
/// where a program is stuck). For finding out what a program does; off
/// by default.
pub var trace_all: bool = false;

fn dispatchCall(f: *arch.Frame) void {
    f.rax = switch (f.rax) {
        Sys.read => sysRead(f.rdi, f.rsi, f.rdx),
        Sys.write => sysWrite(f.rdi, f.rsi, f.rdx),
        Sys.open => sysOpen(f.rdi, f.rsi),
        Sys.close => sysClose(f.rdi),
        Sys.sched_yield => blk: {
            thread.yield();
            break :blk 0;
        },
        Sys.fstat => sysFstat(f.rdi, f.rsi),
        Sys.lseek => sysLseek(f.rdi, f.rsi, f.rdx),
        Sys.pread64 => sysPread(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.openat => sysOpenAt(f.rdi, f.rsi, f.rdx),
        Sys.fcntl => sysFcntl(f.rdi, f.rsi, f.rdx),
        Sys.newfstatat => sysNewfstatat(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.stat => sysNewfstatat(@bitCast(@as(i64, abi.AT_FDCWD)), f.rdi, f.rsi, 0),
        Sys.lstat => sysNewfstatat(@bitCast(@as(i64, abi.AT_FDCWD)), f.rdi, f.rsi, abi.AT_SYMLINK_NOFOLLOW),
        Sys.unlink => sysReadOnlyPath(@bitCast(@as(i64, abi.AT_FDCWD)), f.rdi, true),
        Sys.unlinkat => sysReadOnlyPath(f.rdi, f.rsi, true),
        Sys.mknodat => sysReadOnlyPath(f.rdi, f.rsi, false),
        Sys.fchmod => if (isOpen(f.rdi)) err(.ROFS) else err(.BADF),
        // No descriptor can be open for writing a file, which is what
        // Linux says `EINVAL` for.
        Sys.ftruncate => if (isOpen(f.rdi)) err(.INVAL) else err(.BADF),
        // No networking yet (12): every address family is unsupported.
        Sys.socket => err(.AFNOSUPPORT),
        // Not offered yet; a runtime that wants one for mapping its
        // compiled code twice (writable here, executable there) maps it
        // once instead.
        Sys.memfd_create => err(.NOSYS),
        Sys.access => sysAccess(@bitCast(@as(i64, abi.AT_FDCWD)), f.rdi, f.rsi),
        Sys.faccessat, Sys.faccessat2 => sysAccess(f.rdi, f.rsi, f.rdx),
        Sys.readlink => sysReadlink(@bitCast(@as(i64, abi.AT_FDCWD)), f.rdi, f.rsi, f.rdx),
        Sys.readlinkat => sysReadlink(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.getcwd => sysGetcwd(f.rdi, f.rsi),
        Sys.set_robust_list => sysSetRobustList(f.rdi, f.rsi),
        // Restartable sequences are not offered; a C library asks once
        // and does without.
        Sys.rseq => err(.NOSYS),
        Sys.pipe => sysPipe(f.rdi, 0),
        Sys.pipe2 => sysPipe(f.rdi, f.rsi),
        Sys.dup => sysDup(f.rdi, 0),
        Sys.dup2 => sysDup2(f.rdi, f.rsi, false),
        Sys.dup3 => sysDup2(f.rdi, f.rsi, true),
        Sys.nanosleep => sysSleep(abi.CLOCK.MONOTONIC, false, f.rdi),
        Sys.clock_nanosleep => sysSleep(f.rdi, f.rsi & 1 != 0, f.rdx),
        Sys.clock_gettime => sysClockGetTime(f.rdi, f.rsi),
        Sys.gettimeofday => sysGetTimeOfDay(f.rdi),
        Sys.getpid => if (thread.current().process) |p| p.pid else err(.NOSYS),
        Sys.clone => sysClone(f),
        Sys.clone3 => sysClone3(f),
        Sys.sched_setaffinity => sysSchedSetAffinity(f.rdi, f.rsi, f.rdx),
        Sys.sched_getscheduler => sysSchedPolicy(.get_policy, f),
        Sys.sched_getparam => sysSchedPolicy(.get_param, f),
        Sys.sched_setscheduler => sysSchedPolicy(.set_policy, f),
        Sys.sched_setparam => sysSchedPolicy(.set_param, f),
        Sys.sched_get_priority_max, Sys.sched_get_priority_min => sysSchedPriorityRange(f.rdi),
        Sys.getsid => sysGetsid(f.rdi),
        Sys.time => sysTime(f.rdi),
        Sys.futex => sysFutex(f),
        Sys.sched_getaffinity => sysSchedGetAffinity(f.rsi, f.rdx),
        Sys.getrandom => sysGetRandom(f.rdi, f.rsi),
        Sys.uname => sysUname(f.rdi),
        Sys.prlimit64 => sysPrlimit(f.rdi, f.rsi, f.rdx, f.r10),
        // No option exists here yet. Runtimes try a few (naming their
        // mappings, for one) and go on without them.
        Sys.prctl => err(.INVAL),
        Sys.membarrier => sysMembarrier(f.rdi, f.rsi),
        Sys.sysinfo => sysSysinfo(f.rdi),
        Sys.get_mempolicy => sysGetMempolicy(f.rdi, f.rsi, f.rdx, f.r8),
        Sys.mremap => memory(.mremap, f),
        Sys.statfs => sysStatfs(f.rdi, f.rsi),
        Sys.mlock, Sys.munlock => sysMlock(f.rdi, f.rsi),
        Sys.kill => sysKill(f.rdi, f.rsi),
        Sys.tgkill => sysKill(f.rdi, f.rdx),
        Sys.tkill => if (thread.current().process) |p| sysKill(p.pid, f.rsi) else err(.NOSYS),
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
        Sys.exit => proc.exitThread(abi.exitStatus(f.rdi)),
        Sys.exit_group => proc.exit(abi.exitStatus(f.rdi)),
        Sys.gettid => thread.id(),
        Sys.myos_getchar => sysGetChar(),
        Sys.myos_run => sysRun(f.rdi, f.rsi, f.rdx),
        else => unknown(f.rax),
    };
}

/// Set to have every call the kernel does not know logged, with the
/// program that made it: how to find out what a new program still needs.
/// Off by default: a program probing for what exists makes many.
pub var trace_unknown: bool = false;

fn unknown(number: u64) u64 {
    if (trace_unknown) {
        const name = if (thread.current().process) |p| p.name else "kernel";
        root.print("syscall trace: {s} (thread {d}) made unknown call {d}\n", .{ name, thread.id(), number });
    }
    return err(.NOSYS);
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
