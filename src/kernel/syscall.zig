//! System calls: the kernel side of the ABI in `abi/linux.zig`.
//!
//! The ABI is Linux's for x86-64: the number is in RAX, up to six arguments
//! in RDI, RSI, RDX, R10, R8 and R9, and the result comes back in RAX, as a
//! value or as a negated error number (`abi.err`). `docs/syscalls.md` lists
//! the calls. User memory is never dereferenced directly: data is copied to
//! and from kernel buffers with `uaccess`, which fails cleanly on bad pointers.

const std = @import("std");
const kfifo = @import("fifo.zig");
const memfd = @import("memfd.zig");
const rseq = @import("rseq.zig");
const root = @import("root");

const abi = @import("abi");
const Sys = abi.Sys;
const err = abi.err;
const cpu = @import("../arch/x86_64/cpu.zig");
const nospec = @import("../arch/x86_64/nospec.zig");
const arch = @import("../arch/x86_64/syscall.zig");
const tty = @import("tty.zig");
const signal = @import("signal.zig");
const heap = @import("heap.zig");
const proc = @import("process.zig");
const thread = @import("thread.zig");
const ipi = @import("../arch/x86_64/ipi.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const kfutex = @import("futex.zig");
const kpipe = @import("pipe.zig");
const kclock = @import("clock.zig");
const readiness = @import("readiness.zig");
const kepoll = @import("epoll.zig");
const open_file = @import("open_file.zig");
const procfs = @import("procfs.zig");
const kstats = @import("stats.zig");
const kflock = @import("flock.zig");
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

/// `AT_FDCWD` as a system call argument.
const CWD: u64 = @bitCast(@as(i64, abi.AT_FDCWD));

/// A path a program gave, made absolute and plain (`vfs.normalize`):
/// relative to the process's working directory, or to the directory a
/// descriptor is open on, unless it starts with a slash. It lives in heap
/// memory, two buffers of `PATH_MAX` bytes being too much for a kernel
/// stack: `deinit` when done.
const Path = struct {
    storage: []u8,
    text: []const u8,
    /// The program ended it with a slash: it has to name a directory.
    directory_wanted: bool,

    fn deinit(self: *Path) void {
        heap.allocator.free(self.storage);
    }

    const Result = union(enum) { path: Path, fail: u64 };

    /// The path at the user address `ptr`, relative to `dirfd` (`CWD` for
    /// the working directory). Errors are system call results: `EFAULT`
    /// if it cannot be read, `ENAMETOOLONG` if it or what it comes to does
    /// not fit `PATH_MAX` bytes or has a part of more than 255, `ENOENT`
    /// if it is empty, `EBADF` and `ENOTDIR` for a `dirfd` that is not an
    /// open directory (only looked at for a relative path), `ENOMEM`,
    /// `ELOOP` for more than 40 symbolic links.
    ///
    /// Symbolic links are followed in every part of the path, the last
    /// too: `fromNoFollow` leaves the last one alone (unless the path ends
    /// in a slash, which asks for what it points to).
    fn from(dirfd: u64, ptr: u64) Result {
        return fromFollowing(dirfd, ptr, true);
    }

    fn fromNoFollow(dirfd: u64, ptr: u64) Result {
        return fromFollowing(dirfd, ptr, false);
    }

    fn fromFollowing(dirfd: u64, ptr: u64, follow_last: bool) Result {
        const p = thread.current().process orelse return .{ .fail = err(.NOSYS) };
        const storage = heap.allocator.alloc(u8, 3 * abi.PATH_MAX) catch return .{ .fail = err(.NOMEM) };
        const raw_buf = storage[0..abi.PATH_MAX];
        // One byte less than the buffer: a path is at most `PATH_MAX - 1`
        // bytes, so that it fits a buffer of `PATH_MAX` with its NUL.
        const out = storage[abi.PATH_MAX..][0 .. abi.PATH_MAX - 1];
        const fail: u64 = blk: {
            const len = uaccess.copyStringFromUser(raw_buf, ptr) catch |e| break :blk switch (e) {
                error.Fault => err(.FAULT),
                error.TooLong => err(.NAMETOOLONG),
            };
            const raw = raw_buf[0..len];
            if (len == 0) break :blk err(.NOENT);
            const directory_wanted = raw[len - 1] == '/';
            // The base is looked at only while it cannot change: the
            // working directory under its lock, a directory's path while
            // this call holds the open file.
            const result = if (raw[0] == '/')
                vfs.normalize(out, "/", raw)
            else if (dirfd == CWD) with_cwd: {
                const held = p.files_lock.acquire();
                defer p.files_lock.release(held);
                break :with_cwd vfs.normalize(out, p.cwd, raw);
            } else with_dir: {
                const of = getFile(dirfd) orelse break :blk err(.BADF);
                defer putFile(of);
                if (of.kind != .directory) break :blk err(.NOTDIR);
                break :with_dir vfs.normalize(out, of.path, raw);
            };
            const plain = result catch |e| break :blk vfsError(e);
            // What the program gave is no longer needed: its buffer is
            // space to work in.
            const followed_buf = storage[2 * abi.PATH_MAX ..][0 .. abi.PATH_MAX - 1];
            const text = vfs.followLinks(followed_buf, raw_buf, plain, follow_last or directory_wanted) catch |e| break :blk switch (e) {
                error.Loop => err(.LOOP),
                else => |other| vfsError(other),
            };
            return .{ .path = .{ .storage = storage, .text = text, .directory_wanted = directory_wanted } };
        };
        heap.allocator.free(storage);
        return .{ .fail = fail };
    }
};

/// The Linux error number for what the filesystem layer said.
fn vfsError(e: vfs.Error) u64 {
    return switch (e) {
        error.NotFound => err(.NOENT),
        error.NotDirectory => err(.NOTDIR),
        error.IsDirectory => err(.ISDIR),
        error.NameTooLong => err(.NAMETOOLONG),
        error.Exists => err(.EXIST),
        error.NotEmpty => err(.NOTEMPTY),
        error.NoSpace => err(.NOSPC),
        error.ReadOnly => err(.ROFS),
        error.Invalid => err(.INVAL),
        error.TooLarge => err(.FBIG),
        error.Busy => err(.BUSY),
        error.CrossDevice => err(.XDEV),
        error.NotPermitted => err(.PERM),
    };
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

/// `execve` and `execveat` (with `dirfd` and `flags` 0 or `AT_FDCWD`):
/// replace the program of the calling process with the one at the user
/// path `ptr` (`proc.execve`). Returns only on an error, leaving the
/// program as it was: those of `Path.from`, `ENOENT`, `ENOEXEC`, `E2BIG`,
/// `EFAULT`, `ENOMEM`, `EINTR` (another thread replaced or ended the
/// process first).
fn sysExecve(f: *arch.Frame, dirfd: u64, ptr: u64, argv: u64, envp: u64) u64 {
    var given = switch (Path.from(dirfd, ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer given.deinit();
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
    proc.execve(f, given.text, args.items(), env.items()) catch |e| return switch (e) {
        error.FileNotFound => err(.NOENT),
        error.OutOfMemory, error.TooLarge => err(.NOMEM),
        error.ArgumentsTooLong => err(.@"2BIG"),
        error.Interrupted => err(.INTR),
        error.ReadFailed, error.NotExecutable => err(.NOEXEC),
    };
    return 0; // the new program's RAX, which `proc.execve` cleared too
}

/// `write`: print `count` bytes at the user address `ptr` to the console.
/// Only descriptors 1 and 2 can be written; anything else is `EBADF` (files
/// are read-only). Returns the number of bytes written, which is short if a
/// later part of the buffer cannot be read, or `EFAULT` if none of it can.
/// Whether the descriptor behind `of` is non-blocking.
fn nonblocking(of: *OpenFile) bool {
    return open_file.isNonblocking(of);
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
            // And SIGPIPE, which ends the program unless it handles or
            // ignores it (as most that use pipes do).
            .broken => {
                const me = thread.current();
                _ = proc.withThread(me.process.?, me.id, signal.sendThreadLocked, 13);
                return if (done == 0) err(.PIPE) else done;
            },
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
    const cloexec = flags & abi.O.CLOEXEC != 0;
    const rfd = installFileFlags(p, r, 0, cloexec) orelse {
        open_file.destroy(r);
        open_file.destroy(w);
        return err(.MFILE);
    };
    const wfd = installFileFlags(p, w, 0, cloexec) orelse {
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

/// `write` and `pwrite64` to a file: at `at`, or (null) at the
/// descriptor's offset, which moves on, or at the file's end for a
/// descriptor opened with `O_APPEND`. Short only if the space runs out
/// or part of the buffer cannot be read; `ENOSPC`, `EFBIG`, `EFAULT` if
/// nothing could be written.
///
/// Two threads appending through one descriptor at once may write over
/// each other: the end is looked at and written to in two steps.
fn fileWrite(of: *OpenFile, ptr: u64, len: u64, at: ?u64) u64 {
    if (!user_range.valid(ptr, len)) return err(.FAULT);
    var offset = at orelse blk: {
        if (of.append) break :blk vfs.sizeOf(&of.node);
        break :blk open_file.getOffset(of);
    };
    var chunk: [CHUNK]u8 = undefined;
    var done: u64 = 0;
    var failure: ?u64 = null;
    while (done < len) {
        const part = chunk[0..@intCast(@min(CHUNK, len - done))];
        uaccess.copyFromUser(part, ptr + done) catch {
            failure = err(.FAULT);
            break;
        };
        const n = vfs.write(&of.node, offset, part) catch |e| {
            failure = vfsError(e);
            break;
        };
        done += n;
        offset += n;
        if (n < part.len) {
            failure = err(.NOSPC);
            break;
        }
    }
    if (at == null) open_file.setOffset(of, offset);
    return if (done == 0) failure orelse 0 else done;
}

/// `pwrite64`: `write` to a file at `offset`, leaving the descriptor's
/// own offset alone. `ESPIPE` for what has no offsets, `EBADF` if it is
/// not open for writing.
fn sysPwrite(fd: u64, ptr: u64, count: u64, offset: u64) u64 {
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    if (of.kind != .file) return err(.SPIPE);
    if (!of.writable) return err(.BADF);
    if (offset > std.math.maxInt(i64)) return err(.INVAL);
    return fileWrite(of, ptr, @min(count, abi.MAX_RW_COUNT), offset);
}

/// `ftruncate` and `truncate`: make a file exactly `length` bytes, cutting
/// it short or letting it end in zeroes. `EINVAL` for a descriptor that
/// is not a file open for writing, or a negative length; `EFBIG`;
/// for a path also `EISDIR`, `ENOENT`, `EROFS`.
fn sysFtruncate(fd: u64, length: u64) u64 {
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    if (of.kind != .file or !of.writable or length > std.math.maxInt(i64)) return err(.INVAL);
    vfs.truncate(&of.node, length) catch |e| return vfsError(e);
    return 0;
}

fn sysTruncate(path_ptr: u64, length: u64) u64 {
    var given = switch (Path.from(CWD, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer given.deinit();
    if (length > std.math.maxInt(i64)) return err(.INVAL);
    switch (named(given.text)) {
        .none => return missing(given.text),
        .directory => return err(.ISDIR),
        .file => {},
        else => return err(.INVAL),
    }
    const node = fileAt(given.text) orelse return err(.NOENT);
    defer vfs.release(&node);
    vfs.truncate(&node, length) catch |e| return vfsError(e);
    return 0;
}

/// `mkdir` and `mkdirat`: make an empty directory. `EEXIST`, `ENOENT` or
/// `ENOTDIR` for the directory it is to go into, `EROFS`, `ENOSPC`.
fn sysMkdir(dirfd: u64, path_ptr: u64) u64 {
    var given = switch (Path.fromNoFollow(dirfd, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer given.deinit();
    if (named(given.text) != .none) return err(.EXIST);
    vfs.mkdir(given.text) catch |e| return vfsError(e);
    return 0;
}

/// `unlink`, `rmdir` and `unlinkat`: take a file's name away (the file
/// lives while it is open), or remove an empty directory. `ENOENT`,
/// `EISDIR` and `ENOTDIR` for the wrong one of the two, `ENOTEMPTY`,
/// `EROFS`, `EBUSY` for a mount point, `EINVAL` for unknown flags.
fn sysUnlink(dirfd: u64, path_ptr: u64, flags: u64) u64 {
    if (flags & ~@as(u64, abi.AT_REMOVEDIR) != 0) return err(.INVAL);
    var given = switch (Path.fromNoFollow(dirfd, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer given.deinit();
    const directory = flags & abi.AT_REMOVEDIR != 0;
    switch (named(given.text)) {
        .none => return missing(given.text),
        .file => if (directory or given.directory_wanted) return err(.NOTDIR),
        .directory => if (!directory) return err(.ISDIR),
        .symlink => if (directory) return err(.NOTDIR), // the link goes, not what it points to
        // A FIFO's name goes; its pipe stays with whoever has it open.
        .fifo => if (directory or given.directory_wanted) return err(.NOTDIR),
        // What this kernel itself puts into /proc and /dev stays.
        else => return err(.PERM),
    }
    (if (directory) vfs.rmdir(given.text) else vfs.unlink(given.text)) catch |e| return vfsError(e);
    return 0;
}

/// `rename`, `renameat` and `renameat2`: give a file or directory another
/// name, replacing a file of that name or an empty directory. Within one
/// filesystem (`EXDEV`). `ENOENT`, `EISDIR`, `ENOTDIR`, `ENOTEMPTY`,
/// `EINVAL` for a directory moved into itself or for flags (none is
/// supported), `EROFS`, `EBUSY`, `ENOSPC`.
fn sysRename(old_dirfd: u64, old_ptr: u64, new_dirfd: u64, new_ptr: u64, flags: u64) u64 {
    if (flags != 0) return err(.INVAL);
    var old = switch (Path.fromNoFollow(old_dirfd, old_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer old.deinit();
    var new = switch (Path.fromNoFollow(new_dirfd, new_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer new.deinit();
    switch (named(old.text)) {
        .none => return missing(old.text),
        .file, .directory, .symlink, .fifo => {},
        else => return err(.PERM),
    }
    vfs.rename(old.text, new.text) catch |e| return vfsError(e);
    return 0;
}

/// `fchmod`: there are no permissions; a file that can be written
/// accepts any, the rest is `EROFS`.
fn sysFchmod(fd: u64) u64 {
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    return if (of.kind == .file and of.generated == null and vfs.isWritable(&of.node)) 0 else err(.ROFS);
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
            .file => {
                if (!of.writable) return err(.BADF);
                return fileWrite(of, ptr, @min(count, abi.MAX_RW_COUNT), null);
            },
            .eventfd => return eventFdWrite(of, ptr, count),
            .pipe_read, .directory, .epoll => return err(.BADF),
            .signalfd => return err(.INVAL),
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

/// `readv`: `read` into up to 1024 buffers, one after the other; a
/// buffer that is not filled ends it, as it would end a single `read`.
/// `EINVAL` for too many buffers or lengths that do not add up, `EFAULT`
/// for a vector that cannot be read, and the errors of `read` if nothing
/// was read before they happened.
fn sysReadv(fd: u64, iov: u64, count: u64) u64 {
    if (count > abi.IOV_MAX) return err(.INVAL);
    if (!isOpen(fd)) return err(.BADF);
    var total: u64 = 0;
    for (0..count) |i| {
        const v = readIoVec(iov, i) orelse return err(.FAULT);
        total = std.math.add(u64, total, v.len) catch return err(.INVAL);
        if (total > abi.MAX_RW_COUNT) return err(.INVAL);
    }
    var done: u64 = 0;
    for (0..count) |i| {
        const v = readIoVec(iov, i) orelse break;
        if (v.len == 0) continue;
        const n = sysRead(fd, v.base, v.len);
        if (abi.isError(n)) return if (done == 0) n else done;
        done += n;
        if (n < v.len) break;
    }
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
        if ((of.kind == .file and !of.writable) or of.kind == .pipe_read or of.kind == .directory) return err(.BADF);
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
fn sysIoctl(fd: u64, request: u64, arg: u64) u64 {
    const of = getFile(fd) orelse return err(.BADF);
    const kind = of.kind;
    putFile(of);
    // Only the terminal has requests; for everything else this is how a
    // C library finds out that its output is not a terminal.
    if (kind != .console) return err(.NOTTY);
    switch (request) {
        abi.TIOC.TCGETS => return if (toUser(arg, tty.getAttributes())) 0 else err(.FAULT),
        abi.TIOC.TCSETS, abi.TIOC.TCSETSW, abi.TIOC.TCSETSF => {
            const t = fromUser(abi.Termios, arg) orelse return err(.FAULT);
            // TCSETSW waits for output to be sent; output is sent at once.
            tty.setAttributes(t, request == abi.TIOC.TCSETSF);
            return 0;
        },
        abi.TIOC.TIOCGWINSZ => return if (toUser(arg, tty.windowSize())) 0 else err(.FAULT),
        abi.TIOC.FIONREAD => return if (toUser(arg, @as(i32, @intCast(tty.available())))) 0 else err(.FAULT),
        abi.TIOC.TCFLSH => {
            // 0 and 2 flush what was typed; 1, output, has nothing waiting.
            if (arg > 2) return err(.INVAL);
            if (arg != 1) tty.flushInput();
            return 0;
        },
        // The foreground process group: the one Ctrl+C goes to. Until a
        // shell sets one, the caller's own group stands in.
        abi.TIOC.TIOCGPGRP => {
            const fg = proc.foregroundGroup();
            const p = thread.current().process.?;
            const g = if (fg != 0) fg else proc.groupOf(0, .group) orelse p.pid;
            return if (toUser(arg, @as(i32, @intCast(g)))) 0 else err(.FAULT);
        },
        abi.TIOC.TIOCSPGRP => {
            const g = fromUser(i32, arg) orelse return err(.FAULT);
            if (g <= 0) return err(.INVAL);
            // From the background: SIGTTOU to the caller's group, which
            // stops it, unless it blocks or ignores that (as shells do).
            if (backgroundStops(signal.SIG.TTOU)) |e| return e;
            return switch (proc.setForegroundGroup(@intCast(g))) {
                .ok => 0,
                .no_such => err(.PERM),
            };
        },
        else => return err(.INVAL),
    }
}

/// A process in the background that uses the terminal as only the
/// foreground may: `sig` (`SIGTTIN` for a read, `SIGTTOU`) goes to its
/// process group, which stops, and the call returns `EINTR`, to be made
/// again once it is continued. If the caller blocks or ignores `sig`,
/// nothing is sent: the call fails with `EIO` for a read and goes ahead
/// otherwise, as on Linux; in an orphaned group it fails with `EIO`.
/// Null: go ahead.
fn backgroundStops(sig: u32) ?u64 {
    if (!proc.inBackground()) return null;
    if (!signal.wouldTake(sig)) return if (sig == signal.SIG.TTIN) err(.IO) else null;
    if (proc.ownGroupOrphaned()) return err(.IO); // nobody to continue it
    const g = proc.groupOf(0, .group) orelse return null;
    _ = proc.signalGroup(g, sig);
    return err(.INTR);
}

/// `read` from the terminal: a line, or each key without line editing.
fn consoleRead(of: *OpenFile, ptr: u64, len: u64) u64 {
    if (!user_range.valid(ptr, len)) return err(.FAULT);
    if (backgroundStops(signal.SIG.TTIN)) |e| return e;
    var chunk: [CHUNK]u8 = undefined;
    const want: usize = @intCast(@min(CHUNK, len));
    switch (tty.read(chunk[0..want], nonblocking(of))) {
        .bytes => |n| {
            uaccess.copyToUser(ptr, chunk[0..n]) catch return err(.FAULT);
            return n;
        },
        .again => return err(.AGAIN),
        .killed => return err(.INTR),
    }
}

/// `arch_prctl`: set or read the FS or GS base of the calling thread,
/// where a program keeps its thread-local data. A base must be an address
/// in user space (`EPERM` otherwise, as on Linux): the kernel tells its own
/// GS base from a program's by exactly that (`idt.zig`). `EINVAL` for an
/// unknown code, `EFAULT` if the result cannot be stored.
fn sysArchPrctl(code: u64, addr: u64) u64 {
    switch (code) {
        abi.ARCH.SET_FS, abi.ARCH.SET_GS => {
            if (!user_range.valid(addr, 1)) return err(.PERM); // below the end of user space
            thread.setUserBase(if (code == abi.ARCH.SET_FS) .fs else .gs, addr);
            return 0;
        },
        abi.ARCH.GET_FS, abi.ARCH.GET_GS => {
            const bases = thread.userBases();
            const value = if (code == abi.ARCH.GET_FS) bases.fs else bases.gs;
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
    open_file.retain(of);
    return of;
}

/// Give back a reference from `getFile`; the file is freed with its last one.
fn putFile(of: *OpenFile) void {
    open_file.unref(of);
}

/// True if `fd` is an open file.
fn isOpen(fd: u64) bool {
    const of = getFile(fd) orelse return false;
    putFile(of);
    return true;
}

/// `open` and `openat`: open the file or directory at a path and return
/// the lowest free descriptor for it. Where the filesystem can be
/// written (`/tmp`), `O_CREAT` makes a file that is not there (`EEXIST`
/// with `O_EXCL` if it is), `O_TRUNC` empties one opened for writing and
/// `O_APPEND` sends every write to its end; elsewhere opening for
/// writing or creating is `EROFS`. The devices in `/dev` may be opened
/// for writing. A directory can be opened for
/// reading only (`EISDIR`), to be listed (`getdents64`) or to open what
/// is in it. `ENOTDIR` for `O_DIRECTORY` or a path ending in a slash that
/// names something else. `ENOENT`, `EMFILE`, `ENOMEM`, and what `Path.from`
/// says.
fn sysOpenAt(dirfd: u64, ptr: u64, flags: u64) u64 {
    // O_NOFOLLOW: a link as the last part is refused (ELOOP) instead of
    // followed.
    var given = switch (if (flags & abi.O.NOFOLLOW != 0) Path.fromNoFollow(dirfd, ptr) else Path.from(dirfd, ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer given.deinit();
    const path = given.text;
    const p = thread.current().process orelse return err(.BADF);
    const what = named(path);
    const directory_wanted = given.directory_wanted or flags & abi.O.DIRECTORY != 0;
    var opened: OpenFile = .{};
    const access = flags & abi.O.ACCMODE;
    if (access == abi.O.ACCMODE) return err(.INVAL);
    if (what != .none and flags & (abi.O.CREAT | abi.O.EXCL) == abi.O.CREAT | abi.O.EXCL) return err(.EXIST);
    switch (what) {
        .symlink => return err(.LOOP),
        .none => {
            if (flags & abi.O.CREAT == 0) return missing(path);
            if (directory_wanted) return err(.ISDIR); // Linux's answer to creating "name/"
            opened.node = vfs.create(path) catch |e| switch (e) {
                // Another thread made it between the look and now.
                error.Exists => if (flags & abi.O.EXCL != 0) return err(.EXIST) else vfs.lookup(path) orelse return err(.NOENT),
                else => return vfsError(e),
            };
            opened.readable = access != abi.O.WRONLY;
            opened.writable = access != abi.O.RDONLY;
            opened.append = flags & abi.O.APPEND != 0;
        },
        .directory => {
            if (access != abi.O.RDONLY) return err(.ISDIR);
            opened.kind = .directory;
            opened.path = heap.allocator.dupe(u8, path) catch return err(.NOMEM);
        },
        .device => |kind| {
            if (directory_wanted) return err(.NOTDIR);
            opened.kind = kind; // may be opened for writing: what is written is thrown away
        },
        .fifo => |id| {
            if (directory_wanted) return err(.NOTDIR);
            // One end of its pipe, after the other end has come
            // (`fifo.zig`); not both at once.
            if (access == abi.O.RDWR) return err(.INVAL);
            const end: kpipe.End = if (access == abi.O.RDONLY) .read else .write;
            opened.pipe = kfifo.open(id, end, flags & abi.O.NONBLOCK != 0) catch |e| return switch (e) {
                error.NoReader => err(.NXIO),
                error.Interrupted => err(.INTR),
                error.OutOfMemory => err(.NOMEM),
            };
            opened.kind = if (end == .read) .pipe_read else .pipe_write;
            opened.readable = end == .read;
            opened.writable = end == .write;
        },
        .file, .exe_link, .generated => {
            if (directory_wanted) return err(.NOTDIR);
            if (what == .generated) {
                if (access != abi.O.RDONLY) return err(.ROFS);
                const g = what.generated;
                const text = if (g.pid == 0 or g.pid == p.pid) procfs.generateArg(g.file, p, g.arg) catch return err(.NOMEM) else blk: {
                    const other = proc.findRetained(g.pid) orelse return err(.NOENT);
                    defer proc.release(other);
                    break :blk procfs.generate(g.file, other) catch return err(.NOMEM);
                };
                opened.generated = text;
                opened.node = open_file.memoryNode(text);
            } else {
                opened.node = fileAt(path) orelse return err(.NOENT);
                if (access != abi.O.RDONLY and !vfs.isWritable(&opened.node)) {
                    vfs.release(&opened.node);
                    return err(.ROFS);
                }
                opened.readable = access != abi.O.WRONLY;
                opened.writable = access != abi.O.RDONLY;
                opened.append = flags & abi.O.APPEND != 0;
                if (flags & abi.O.TRUNC != 0 and opened.writable) vfs.truncate(&opened.node, 0) catch |e| {
                    vfs.release(&opened.node);
                    return vfsError(e);
                };
            }
        },
    }
    opened.nonblock = flags & abi.O.NONBLOCK != 0;

    // Allocated before the table is locked, and freed again if it is full.
    const of = heap.allocator.create(OpenFile) catch {
        if (opened.kind == .file and opened.generated == null) vfs.release(&opened.node);
        open_file.freeContents(&opened);
        return err(.NOMEM);
    };
    of.* = opened;
    return installFileFlags(p, of, 0, flags & abi.O.CLOEXEC != 0) orelse {
        open_file.destroy(of);
        return err(.MFILE);
    };
}

/// Put `of` in the lowest free descriptor of `p` that is at least `from`
/// and within the process's limit, and return it; null if there is none.
/// The reference the caller holds becomes the descriptor's.
fn installFile(p: *proc.Process, of: *OpenFile, from: usize) ?usize {
    return installFileFlags(p, of, from, false);
}

/// `installFile`, with the descriptor closed by `execve` if `cloexec`.
fn installFileFlags(p: *proc.Process, of: *OpenFile, from: usize, cloexec: bool) ?usize {
    const limit = @min(proc.MAX_FILES, p.limits.max_files);
    while (true) {
        const len = blk: {
            const held = p.files_lock.acquire();
            defer p.files_lock.release(held);
            var fd = from;
            while (fd < @min(p.files.len, limit)) : (fd += 1) {
                if (p.files[fd] != null) continue;
                p.files[fd] = of;
                p.fd_cloexec[fd] = cloexec;
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
fn sysDup(fd: u64, from: u64, cloexec: bool) u64 {
    const p = thread.current().process orelse return err(.BADF);
    if (from >= @min(proc.MAX_FILES, p.limits.max_files)) return err(.INVAL);
    const of = getFile(fd) orelse return err(.BADF);
    // The reference from `getFile` becomes the new descriptor's.
    return installFileFlags(p, of, @intCast(from), cloexec) orelse {
        putFile(of);
        return err(.MFILE);
    };
}

/// `dup2` and `dup3`: make `new` refer to what `old` does, closing what
/// `new` referred to. With `same_is_error`, `old == new` is `EINVAL`
/// (`dup3`); otherwise it does nothing and returns `new` (`dup2`).
fn sysDup2(old: u64, new: u64, same_is_error: bool, cloexec: bool) u64 {
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
        const at = nospec.index(new, p.files.len);
        const before = p.files[at];
        p.files[at] = of; // with the reference from `getFile`
        p.fd_cloexec[at] = cloexec;
        break :blk before;
    };
    if (replaced) |r| putFile(r);
    return new;
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
        .file => if (!of.readable) return err(.BADF),
        .pipe_read => return pipeRead(of, ptr, @min(count, abi.MAX_RW_COUNT)),
        .null_device => return 0,
        .random_device => return sysGetRandom(ptr, count),
        .directory => return err(.ISDIR),
        .eventfd => return eventFdRead(of, ptr, count),
        .signalfd => return signalfdRead(of, ptr, count),
        .epoll => return err(.INVAL),
        .console => return consoleRead(of, ptr, @min(count, abi.MAX_RW_COUNT)),
        .pipe_write => return err(.BADF),
    }
    const start = open_file.getOffset(of);
    const done = readAt(of, start, ptr, @min(count, abi.MAX_RW_COUNT));
    if (abi.isError(done)) return done;
    // Two threads (or processes) reading one open file at once each get
    // data, and the offset moves by both amounts; which of them gets which
    // part is not defined, as on Linux.
    _ = open_file.advance(of, done);
    return done;
}

/// `pread64`: `read` from `offset`, leaving the file's own offset alone.
fn sysPread(fd: u64, ptr: u64, count: u64, offset: u64) u64 {
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    if (of.kind != .file) return err(.SPIPE);
    if (!of.readable) return err(.BADF);
    if (offset > std.math.maxInt(i64)) return err(.INVAL);
    return readAt(of, offset, ptr, @min(count, abi.MAX_RW_COUNT));
}

/// `lseek`: move the offset of the open file `fd` and return it. `ESPIPE`
/// for the standard streams, `EINVAL` for a position before the start or
/// an unknown `whence`.
fn sysLseek(fd: u64, offset: u64, whence: u64) u64 {
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    if (of.kind == .directory) {
        // A listing can be started again, and that is all.
        if (whence != abi.SEEK.SET or offset != 0) return err(.INVAL);
        open_file.setOffset(of, 0);
        return 0;
    }
    if (of.kind != .file) return err(.SPIPE);
    // The size is asked for before the lock is taken: a filesystem may
    // sleep to answer.
    const end: i64 = if (whence == abi.SEEK.END) @intCast(vfs.sizeOf(&of.node)) else 0;
    if (whence != abi.SEEK.SET and whence != abi.SEEK.CUR and whence != abi.SEEK.END) return err(.INVAL);
    // From the current offset: compared and swapped, so that a read or
    // seek through another descriptor meanwhile is not lost.
    var current = open_file.getOffset(of);
    while (true) {
        const base: i64 = switch (whence) {
            abi.SEEK.SET => 0,
            abi.SEEK.CUR => @intCast(current),
            else => end,
        };
        const new = std.math.add(i64, base, @bitCast(offset)) catch return err(.INVAL);
        if (new < 0) return err(.INVAL);
        current = @cmpxchgWeak(u64, &of.offset, current, @intCast(new), .monotonic, .monotonic) orelse return @intCast(new);
    }
}

/// `fstat`: what kind of thing `fd` is and, for a file, how large. The
/// standard streams are character devices.
/// What a path names.
const Named = union(enum) {
    /// Nothing.
    none,
    file,
    directory,
    /// A symbolic link to the program the calling process runs
    /// (`/proc/self/exe`).
    exe_link,
    /// A symbolic link of a filesystem, not followed (the path came from
    /// `Path.fromNoFollow`): what it points to is `vfs.readLink`'s.
    symlink,
    /// A text file made when it is opened (`procfs.zig`), about the
    /// process with the ID `pid` (0: none, the machine).
    generated: struct { file: procfs.File, pid: u64, arg: u8 = 0 },
    /// `/dev/null`, `/dev/urandom`, `/dev/random`.
    device: open_file.Kind,
    /// A FIFO (named pipe), by its number (`fifo.zig`).
    fifo: u64,
};

/// What `path` (absolute) names, without following a link at its end. The
/// filesystem's files and directories, and the few entries of `/proc` a
/// program finds itself by: `/proc`, `/proc/self` and `/proc/<its pid>`
/// are directories, and `exe` in the last two is a link to its program.
fn named(path: []const u8) Named {
    if (procEntry(path)) |entry| return entry;
    if (procfs.findSys(std.mem.trimEnd(u8, path, "/"))) |entry| return switch (entry) {
        .none => .none,
        .directory => .directory,
        .file => |f| .{ .generated = .{ .file = f.file, .pid = 0, .arg = f.arg } },
    };
    if (vfs.isLink(path)) return .symlink;
    if (std.mem.eql(u8, path, "/dev/null")) return .{ .device = .null_device };
    if (std.mem.eql(u8, path, "/dev/urandom") or std.mem.eql(u8, path, "/dev/random")) return .{ .device = .random_device };
    if (std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), "/dev")) return .directory;
    if (vfs.fifoAt(path)) |id| return .{ .fifo = id };
    if (vfs.lookup(path)) |node| {
        vfs.release(&node); // only asked whether it is there
        return .file;
    }
    return if (vfs.isDirectory(path)) .directory else .none;
}

/// The error for `path` (absolute), which names nothing: `ENOTDIR` if a
/// directory it goes through is a file (`/etc/motd/x`), `ENOENT`
/// otherwise, as on Linux.
fn missing(path: []const u8) u64 {
    var end: usize = 1;
    while (std.mem.indexOfScalarPos(u8, path, end, '/')) |slash| : (end = slash + 1) {
        if (slash <= 1) continue;
        switch (named(path[0..slash])) {
            .none => return err(.NOENT),
            .directory => {},
            else => return err(.NOTDIR),
        }
    }
    return err(.NOENT);
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
    const pid: u64 = if (std.mem.eql(u8, first, "self")) p.pid else std.fmt.parseInt(u64, first, 10) catch {
        if (slash == null) if (procfs.find(first, false)) |file| return .{ .generated = .{ .file = file, .pid = 0 } };
        return .none;
    };
    if (pid != p.pid) {
        const other = proc.findRetained(pid) orelse return .none;
        proc.release(other);
    }
    const name = rest[(slash orelse return .directory) + 1 ..];
    // Only a process's own directory has `exe` and `maps`.
    if (std.mem.eql(u8, name, "exe")) return if (pid == p.pid) .exe_link else .none;
    const file = procfs.find(name, true) orelse return .none;
    if (file == .maps and pid != p.pid) return .none;
    return .{ .generated = .{ .file = file, .pid = pid } };
}

/// The file `path` names, following the link if it is one. Null if it
/// names nothing or a directory. The node holds the file: `vfs.release`.
fn fileAt(path: []const u8) ?vfs.Node {
    return switch (named(path)) {
        .file => vfs.lookup(path), // null if it was removed just now
        .exe_link => vfs.lookup(thread.current().process.?.name),
        .none, .directory, .generated, .device, .symlink, .fifo => null,
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
    const size = vfs.sizeOf(&node);
    st.mode = abi.S.IFREG | @as(u32, if (vfs.isWritable(&node)) 0o644 else 0o555);
    st.size = @intCast(size);
    st.blocks = @intCast((size + 511) / 512);
    st.blksize = 4096;
    st.nlink = 1;
    // Two files are the same file if these two are equal: a dynamic
    // loader tells by them whether it has a library already.
    st.dev = 1;
    st.ino = node.ctx;
    // Its times where its filesystem keeps them (`/tmp`); those of the
    // image are when the system started.
    if (vfs.metaOf(&node)) |m| {
        st.atime = timeSpecOf(m.atime);
        st.mtime = timeSpecOf(m.mtime);
        st.ctime = timeSpecOf(m.ctime);
        st.nlink = m.nlink;
    } else {
        const boot: i64 = @intCast(kclock.wallNanos() -| kclock.nanos());
        st.atime = timeSpecOf(boot);
        st.mtime = st.atime;
        st.ctime = st.atime;
    }
    return st;
}

fn timeSpecOf(ns: i64) abi.TimeSpec {
    return .{ .sec = @divFloor(ns, 1_000_000_000), .nsec = @mod(ns, 1_000_000_000) };
}

/// `fallocate`: make room for `[offset, offset + len)` of a file open for
/// writing. Files here are in memory and take memory as they are written,
/// so this only makes the file at least that long (mode 0), or nothing
/// (`FALLOC_FL_KEEP_SIZE`). `EOPNOTSUPP` for punching holes and the other
/// modes, `EBADF`, `ESPIPE` for a pipe, `EINVAL`, `EFBIG`.
fn sysFallocate(fd: u64, mode: u64, offset: u64, len: u64) u64 {
    const KEEP_SIZE = 0x01;
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    if (of.kind == .pipe_read or of.kind == .pipe_write) return err(.SPIPE);
    if (of.kind != .file or !of.writable) return err(.BADF);
    if (len == 0 or offset > std.math.maxInt(i64) or len > std.math.maxInt(i64)) return err(.INVAL);
    if (mode & ~@as(u64, KEEP_SIZE) != 0) return err(.OPNOTSUPP);
    const end = std.math.add(u64, offset, len) catch return err(.FBIG);
    if (mode & KEEP_SIZE != 0) return 0;
    if (end > vfs.sizeOf(&of.node)) vfs.truncate(&of.node, end) catch |e| return vfsError(e);
    return 0;
}

/// `posix_fadvise` (`fadvise64`): advice on how a file will be read,
/// checked and taken (it changes nothing: files are in memory). `EINVAL`
/// for unknown advice, `ESPIPE` for a pipe, `EBADF`.
fn sysFadvise(fd: u64, advice: u64) u64 {
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    if (of.kind == .pipe_read or of.kind == .pipe_write) return err(.SPIPE);
    return if (advice <= 5) 0 else err(.INVAL); // NORMAL, RANDOM, SEQUENTIAL, WILLNEED, DONTNEED, NOREUSE
}

/// Write `data` from the kernel to `of` (a file at `at`, or its offset; a
/// pipe; the console; /dev/null): what `sendfile` and `copy_file_range`
/// write with. Returns the bytes written or an error value.
fn writeKernel(of: *OpenFile, data: []const u8, at: ?u64) u64 {
    switch (of.kind) {
        .file => {
            if (!of.writable) return err(.BADF);
            const offset = at orelse if (of.append) vfs.sizeOf(&of.node) else open_file.getOffset(of);
            const n = vfs.write(&of.node, offset, data) catch |e| return vfsError(e);
            if (at == null) open_file.setOffset(of, offset + n);
            return n;
        },
        .pipe_write => return switch (kpipe.write(of.pipe, data, nonblocking(of))) {
            .bytes => |n| n,
            .again => err(.AGAIN),
            .broken => blk: {
                const me = thread.current();
                _ = proc.withThread(me.process.?, me.id, signal.sendThreadLocked, 13); // SIGPIPE
                break :blk err(.PIPE);
            },
            .killed => err(.INTR),
        },
        .console => {
            root.print("{s}", .{data});
            return data.len;
        },
        .null_device => return data.len,
        else => return err(.BADF),
    }
}

/// `sendfile`: copy up to `count` bytes from the file `in_fd` (from its
/// offset, which moves; or from `*offset_ptr`, which moves instead) to
/// `out_fd` (a file, a pipe, the console), in the kernel. Returns the
/// bytes copied. `EINVAL` if `in_fd` is not a file, `EBADF`, `EFAULT`.
fn sysSendfile(out_fd: u64, in_fd: u64, offset_ptr: u64, count: u64) u64 {
    const in = getFile(in_fd) orelse return err(.BADF);
    defer putFile(in);
    const out = getFile(out_fd) orelse return err(.BADF);
    defer putFile(out);
    if (in.kind != .file or !in.readable) return err(.INVAL);
    var offset: u64 = if (offset_ptr != 0) fromUser(u64, offset_ptr) orelse return err(.FAULT) else open_file.getOffset(in);
    const total = @min(count, abi.MAX_RW_COUNT);
    var chunk: [CHUNK]u8 = undefined;
    var done: u64 = 0;
    while (done < total) {
        const n = vfs.read(&in.node, offset, chunk[0..@intCast(@min(CHUNK, total - done))]);
        if (n == 0) break;
        const w = writeKernel(out, chunk[0..n], null);
        if (abi.isError(w)) {
            if (done == 0) return w;
            break;
        }
        done += w;
        offset += w;
        if (w < n) break;
    }
    if (offset_ptr != 0) {
        if (!toUser(offset_ptr, offset)) return err(.FAULT);
    } else open_file.setOffset(in, offset);
    return done;
}

/// `copy_file_range`: copy up to `len` bytes from one file to another in
/// the kernel, each from its offset (which moves) or from the offset
/// given (which moves instead). `flags` must be 0. `EINVAL` for a pipe
/// or the same file with ranges that overlap, `EBADF`, `EFAULT`.
fn sysCopyFileRange(in_fd: u64, off_in_ptr: u64, out_fd: u64, off_out_ptr: u64, len: u64, flags: u64) u64 {
    if (flags != 0) return err(.INVAL);
    const in = getFile(in_fd) orelse return err(.BADF);
    defer putFile(in);
    const out = getFile(out_fd) orelse return err(.BADF);
    defer putFile(out);
    if (in.kind != .file or out.kind != .file) return err(.INVAL);
    if (!in.readable or !out.writable) return err(.BADF);
    if (out.append) return err(.BADF);
    var off_in: u64 = if (off_in_ptr != 0) fromUser(u64, off_in_ptr) orelse return err(.FAULT) else open_file.getOffset(in);
    var off_out: u64 = if (off_out_ptr != 0) fromUser(u64, off_out_ptr) orelse return err(.FAULT) else open_file.getOffset(out);
    const total = @min(len, abi.MAX_RW_COUNT);
    if (in.node.ctx == out.node.ctx and in.node.ops == out.node.ops and off_in < off_out + total and off_out < off_in + total) return err(.INVAL);
    var chunk: [CHUNK]u8 = undefined;
    var done: u64 = 0;
    while (done < total) {
        const n = vfs.read(&in.node, off_in, chunk[0..@intCast(@min(CHUNK, total - done))]);
        if (n == 0) break;
        const w = vfs.write(&out.node, off_out, chunk[0..n]) catch |e| {
            if (done == 0) return vfsError(e);
            break;
        };
        done += w;
        off_in += w;
        off_out += w;
        if (w < n) break;
    }
    if (off_in_ptr != 0) {
        if (!toUser(off_in_ptr, off_in)) return err(.FAULT);
    } else open_file.setOffset(in, off_in);
    if (off_out_ptr != 0) {
        if (!toUser(off_out_ptr, off_out)) return err(.FAULT);
    } else open_file.setOffset(out, off_out);
    return done;
}

/// `symlink` and `symlinkat`: a symbolic link at `path` to `target`,
/// stored as given (it need not exist). `EEXIST`, `ENOENT` or `ENOTDIR`
/// for where it goes, `EROFS` outside `/tmp`, `ENAMETOOLONG`.
fn sysSymlink(target_ptr: u64, dirfd: u64, path_ptr: u64) u64 {
    // On the heap: a path's worth of bytes is too much for a kernel stack.
    const target_buf = heap.allocator.alloc(u8, abi.PATH_MAX) catch return err(.NOMEM);
    defer heap.allocator.free(target_buf);
    const target = target_buf[0 .. uaccess.copyStringFromUser(target_buf, target_ptr) catch |e| return switch (e) {
        error.Fault => err(.FAULT),
        error.TooLong => err(.NAMETOOLONG),
    }];
    if (target.len == 0) return err(.NOENT);
    var given = switch (Path.fromNoFollow(dirfd, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer given.deinit();
    if (named(given.text) != .none) return err(.EXIST);
    vfs.symlink(given.text, target) catch |e| return vfsError(e);
    return 0;
}

/// `link` and `linkat`: a second name `new` for the file `old` (a hard
/// link), in the same filesystem (`EXDEV`). `EPERM` for a directory or a
/// FIFO; `AT_SYMLINK_FOLLOW` makes a link to what a symbolic link points
/// to (without it, Linux links the link itself: refused here, `EPERM`).
/// `EEXIST`, `ENOENT`, `EROFS`, `EINVAL` for other flags.
fn sysLink(old_dirfd: u64, old_ptr: u64, new_dirfd: u64, new_ptr: u64, flags: u64) u64 {
    if (flags & ~@as(u64, abi.AT_SYMLINK_FOLLOW | abi.AT_EMPTY_PATH) != 0) return err(.INVAL);
    var old = switch (if (flags & abi.AT_SYMLINK_FOLLOW != 0) Path.from(old_dirfd, old_ptr) else Path.fromNoFollow(old_dirfd, old_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer old.deinit();
    var new = switch (Path.fromNoFollow(new_dirfd, new_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer new.deinit();
    switch (named(old.text)) {
        .none => return missing(old.text),
        .file => {},
        .directory, .fifo, .symlink => return err(.PERM),
        else => return err(.XDEV), // what the kernel itself provides
    }
    if (named(new.text) != .none) return err(.EXIST);
    vfs.link(old.text, new.text) catch |e| return switch (e) {
        error.Invalid => err(.PERM),
        else => vfsError(e),
    };
    return 0;
}

/// `utimensat` (and `futimens`, which is it with a null path): set a
/// file's access and modification times, to now if `times` is null, or
/// as the two `timespec`s say (`UTIME_NOW`, `UTIME_OMIT` for one of them).
/// `AT_SYMLINK_NOFOLLOW` is accepted (links have no times of their own
/// here). `EROFS` for a file whose times are not kept (the image's),
/// `EINVAL` for a bad nanosecond value or flag, `ENOENT`, `EFAULT`.
fn sysUtimensat(dirfd: u64, path_ptr: u64, times_ptr: u64, flags: u64) u64 {
    if (flags & ~@as(u64, abi.AT_SYMLINK_NOFOLLOW | abi.AT_EMPTY_PATH) != 0) return err(.INVAL);
    const now: i64 = @intCast(kclock.wallNanos());
    var atime: ?i64 = now;
    var mtime: ?i64 = now;
    if (times_ptr != 0) {
        var ts: [2]abi.TimeSpec = undefined;
        uaccess.copyFromUser(std.mem.sliceAsBytes(&ts), times_ptr) catch return err(.FAULT);
        const pick = struct {
            fn one(t: abi.TimeSpec, current: i64) error{Invalid}!?i64 {
                if (t.nsec == abi.UTIME_OMIT) return null;
                if (t.nsec == abi.UTIME_NOW) return current;
                if (t.nsec < 0 or t.nsec >= 1_000_000_000) return error.Invalid;
                return t.sec *| 1_000_000_000 +| t.nsec;
            }
        };
        atime = pick.one(ts[0], now) catch return err(.INVAL);
        mtime = pick.one(ts[1], now) catch return err(.INVAL);
    }
    // A null path: the descriptor itself (`futimens`).
    if (path_ptr == 0) {
        const of = getFile(dirfd) orelse return err(.BADF);
        defer putFile(of);
        if (of.kind != .file or of.generated != null) return err(.ROFS);
        vfs.setTimes(&of.node, atime, mtime) catch |e| return vfsError(e);
        return 0;
    }
    var given = switch (Path.from(dirfd, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer given.deinit();
    const node = switch (named(given.text)) {
        .none => return missing(given.text),
        .file, .exe_link => fileAt(given.text) orelse return err(.NOENT),
        else => return err(.ROFS), // directories, devices, /proc: no times kept
    };
    defer vfs.release(&node);
    vfs.setTimes(&node, atime, mtime) catch |e| return vfsError(e);
    return 0;
}

/// `newfstatat`: `stat` of the file at a path, or of the descriptor
/// itself with an empty path and `AT_EMPTY_PATH`. `ENOENT`, `EINVAL`
/// for unknown flags, `EFAULT`.
fn sysNewfstatat(dirfd: u64, path_ptr: u64, stat_ptr: u64, flags: u64) u64 {
    return switch (statAt(dirfd, path_ptr, flags)) {
        .stat => |st| if (toUser(stat_ptr, st)) 0 else err(.FAULT),
        .fail => |e| e,
    };
}

const StatResult = union(enum) { stat: abi.Stat, fail: u64 };

/// What `newfstatat` says about `path_ptr` from `dirfd` with `flags`
/// (`AT_EMPTY_PATH`, `AT_SYMLINK_NOFOLLOW`, `AT_NO_AUTOMOUNT`).
fn statAt(dirfd: u64, path_ptr: u64, flags: u64) StatResult {
    if (flags & ~@as(u64, abi.AT_EMPTY_PATH | abi.AT_SYMLINK_NOFOLLOW | 0x800) != 0) return .{ .fail = err(.INVAL) }; // 0x800: AT_NO_AUTOMOUNT
    if (flags & abi.AT_EMPTY_PATH != 0) {
        const first = fromUser(u8, path_ptr) orelse return .{ .fail = err(.FAULT) };
        if (first == 0) return statFd(dirfd);
    }
    return statPath(dirfd, path_ptr, flags);
}

fn statPath(dirfd: u64, path_ptr: u64, flags: u64) StatResult {
    var given = switch ((if (flags & abi.AT_SYMLINK_NOFOLLOW != 0) Path.fromNoFollow(dirfd, path_ptr) else Path.from(dirfd, path_ptr))) {
        .path => |p| p,
        .fail => |e| return .{ .fail = e },
    };
    defer given.deinit();
    const path = given.text;
    const what = named(path);
    if (given.directory_wanted and what != .directory and what != .none) return .{ .fail = err(.NOTDIR) };
    const st = switch (what) {
        .none => return .{ .fail = missing(path) },
        .directory => directoryStat(),
        .file => blk: {
            const node = fileAt(path) orelse return .{ .fail = err(.NOENT) };
            defer vfs.release(&node);
            break :blk fileStat(node);
        },
        .generated => generatedStat(),
        .device => deviceStat(),
        .fifo => |id| blk: {
            var fifo_st: abi.Stat = .{};
            fifo_st.mode = abi.S.IFIFO | 0o644;
            fifo_st.dev = 3;
            fifo_st.ino = id;
            fifo_st.blksize = 4096;
            break :blk fifo_st;
        },
        // Only seen with AT_SYMLINK_NOFOLLOW: the link itself.
        .symlink => blk: {
            var link: abi.Stat = .{};
            link.mode = abi.S.IFLNK | 0o777;
            link.size = @intCast(vfs.readLink(path, &.{}) orelse 0);
            link.dev = 1;
            link.ino = std.hash.Wyhash.hash(0, path) | 1; // the same link, the same number
            break :blk link;
        },
        .exe_link => blk: {
            if (flags & abi.AT_SYMLINK_NOFOLLOW != 0) {
                var link: abi.Stat = .{};
                link.mode = abi.S.IFLNK | 0o777;
                link.dev = 1;
                link.ino = 3;
                break :blk link;
            }
            const node = fileAt(path) orelse return .{ .fail = err(.NOENT) };
            defer vfs.release(&node);
            break :blk fileStat(node);
        },
    };
    return .{ .stat = st };
}

/// `mknodat`: devices and FIFOs cannot be made anywhere: `EROFS` where
/// nothing can be made at all, `EPERM` otherwise (after the errors of
/// the path, and `EEXIST`).
fn sysMknod(dirfd: u64, path_ptr: u64, mode: u64) u64 {
    var given = switch (Path.fromNoFollow(dirfd, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer given.deinit();
    if (named(given.text) != .none) return err(.EXIST);
    if (!vfs.isWritablePath(given.text)) return err(.ROFS);
    const S_IFMT = 0o170000;
    return switch (mode & S_IFMT) {
        // A FIFO (`mkfifo`): a name whose pipe is the kernel's.
        0o010000 => if (vfs.makeFifo(given.text, kfifo.newId())) 0 else |e| vfsError(e),
        // A regular file, as `open` with `O_CREAT | O_EXCL` makes one.
        0, 0o100000 => blk: {
            const node = vfs.create(given.text) catch |e| break :blk vfsError(e);
            vfs.release(&node);
            break :blk 0;
        },
        // Devices cannot be made; sockets come with networking.
        0o020000, 0o060000 => err(.PERM),
        0o140000 => err(.OPNOTSUPP),
        else => err(.INVAL),
    };
}

/// `access`, `faccessat` and `faccessat2`: files can be read and run,
/// never written (`EROFS`). `ENOENT`, `EINVAL` for an unknown mode.
fn sysAccess(dirfd: u64, path_ptr: u64, mode: u64) u64 {
    if (mode & ~@as(u64, abi.ACCESS.R_OK | abi.ACCESS.W_OK | abi.ACCESS.X_OK) != 0) return err(.INVAL);
    var given = switch (Path.from(dirfd, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer given.deinit();
    const path = given.text;
    if (named(path) == .none) return missing(path);
    return if (mode & abi.ACCESS.W_OK != 0 and !vfs.isWritablePath(path)) err(.ROFS) else 0;
}

/// `readlink` and `readlinkat`: what a symbolic link points to, without
/// a NUL, cut to `size` bytes; returns the bytes stored. The one link is
/// `/proc/self/exe`, by which a program finds its own file. `EINVAL` for
/// what exists and is no link, or a size of zero; `ENOENT`; `EFAULT`.
fn sysReadlink(dirfd: u64, path_ptr: u64, buf: u64, size: u64) u64 {
    var given = switch (Path.fromNoFollow(dirfd, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer given.deinit();
    const path = given.text;
    if (size == 0) return err(.INVAL);
    var target_buf: [512]u8 = undefined; // most targets; longer ones on the heap
    var heap_buf: ?[]u8 = null;
    defer if (heap_buf) |h| heap.allocator.free(h);
    const target = switch (named(path)) {
        .none => return missing(path),
        .file, .directory, .generated, .device, .fifo => return err(.INVAL),
        .symlink => blk: {
            const len = vfs.readLink(path, &target_buf) orelse return err(.NOENT);
            if (len <= target_buf.len) break :blk target_buf[0..len];
            const big = heap.allocator.alloc(u8, len) catch return err(.NOMEM);
            heap_buf = big;
            const again = vfs.readLink(path, big) orelse return err(.NOENT);
            break :blk big[0..@min(again, big.len)];
        },
        // The name can change under another thread's feet only by the
        // process ending, and then this thread ends too.
        .exe_link => thread.current().process.?.name,
    };
    const n = @min(target.len, size);
    uaccess.copyToUser(buf, target[0..n]) catch return err(.FAULT);
    return n;
}

/// `getcwd`: the working directory is always "/". Returns the length
/// with the NUL, as the system call does; `ERANGE` if the buffer is
/// shorter, `EFAULT`.
fn sysGetcwd(buf: u64, size: u64) u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    // A copy, so that the program's memory is not touched under the lock.
    const copy = heap.allocator.alloc(u8, abi.PATH_MAX) catch return err(.NOMEM);
    defer heap.allocator.free(copy);
    const len = blk: {
        const held = p.files_lock.acquire();
        defer p.files_lock.release(held);
        @memcpy(copy[0..p.cwd.len], p.cwd); // normalized paths are shorter than PATH_MAX
        break :blk p.cwd.len;
    };
    copy[len] = 0;
    if (size < len + 1) return err(.RANGE);
    uaccess.copyToUser(buf, copy[0 .. len + 1]) catch return err(.FAULT);
    return len + 1;
}

/// `chdir` and `fchdir`: make the directory at a path, or the one a
/// descriptor is open on, the process's working directory, which relative
/// paths start from. `ENOENT`, `ENOTDIR`; `EBADF` for a descriptor that is
/// not open; `ENOMEM`.
fn sysChdir(path_ptr: u64) u64 {
    var given = switch (Path.from(CWD, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer given.deinit();
    return switch (named(given.text)) {
        .none => missing(given.text),
        .directory => setCwd(given.text),
        else => err(.NOTDIR),
    };
}

fn sysFchdir(fd: u64) u64 {
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    if (of.kind != .directory) return err(.NOTDIR);
    return setCwd(of.path);
}

fn setCwd(path: []const u8) u64 {
    const p = thread.current().process.?;
    const new = heap.allocator.dupe(u8, path) catch return err(.NOMEM);
    const old = blk: {
        const held = p.files_lock.acquire();
        defer p.files_lock.release(held);
        const before = p.cwd;
        p.cwd = new;
        break :blk before;
    };
    heap.allocator.free(old);
    return 0;
}

/// `getdents64`: the next entries of the directory `fd` is open on, as
/// many as fit in `count` bytes at `buf`, in Linux's `struct
/// linux_dirent64`. Returns the bytes stored, 0 at the end. "." and ".."
/// come first. `EBADF`, `ENOTDIR`, `EFAULT`, `EINVAL` if not even one
/// entry fits.
///
/// Two threads reading one directory descriptor at once each get entries;
/// which gets which is not defined, as with a file.
fn sysGetdents64(fd: u64, buf: u64, count: u64) u64 {
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    if (of.kind != .directory) return err(.NOTDIR);
    const len = @min(count, abi.MAX_RW_COUNT);
    if (!user_range.valid(buf, len)) return err(.FAULT);

    var position = open_file.getOffset(of);
    var done: u64 = 0;
    var name_buf: [vfs.NAME_MAX]u8 = undefined;
    var record: [abi.DIRENT_HEADER + vfs.NAME_MAX + 8]u8 align(8) = undefined;
    while (true) {
        const before = position;
        const entry = nextEntry(of.path, &position, &name_buf) orelse break;
        const size = std.mem.alignForward(usize, abi.DIRENT_HEADER + entry.name.len + 1, 8);
        if (size > len - done) {
            position = before; // it comes with the next call
            if (done == 0) return err(.INVAL);
            break;
        }
        @memset(record[0..size], 0);
        // An inode number, which is never 0: a hash of the name (FNV-1a;
        // the standard library's hashes take kilobytes of stack unoptimized).
        var ino: u64 = 0xcbf29ce484222325;
        for (entry.name) |c| ino = (ino ^ c) *% 0x100000001b3;
        std.mem.writeInt(u64, record[0..8], ino | 1, .little);
        std.mem.writeInt(u64, record[8..16], position, .little);
        std.mem.writeInt(u16, record[16..18], @intCast(size), .little);
        record[18] = entry.type;
        @memcpy(record[abi.DIRENT_HEADER..][0..entry.name.len], entry.name);
        uaccess.copyToUser(buf + done, record[0..size]) catch return err(.FAULT);
        done += size;
    }
    open_file.setOffset(of, position);
    return done;
}

/// One entry of a listing, for `getdents64`.
const ListEntry = struct { name: []const u8, type: u8 };

/// Positions of a listing before what the filesystem layer gives: "."
/// and "..", then what this file adds to a directory (`extraEntries`).
/// The filesystem layer's own positions follow, moved up by `LIST_BASE`.
const LIST_BASE = 16;

/// The entries of the directory `dir` of `procfs.sys_tree`.
fn sysChildren(comptime dir: []const u8) []const ListEntry {
    comptime {
        @setEvalBranchQuota(20_000);
        var list: []const ListEntry = &.{};
        for (procfs.sys_tree) |c| {
            const slash = std.mem.lastIndexOfScalar(u8, c.path, '/').?;
            if (!std.mem.eql(u8, c.path[0..slash], dir)) continue;
            list = list ++ &[_]ListEntry{.{ .name = c.path[slash + 1 ..], .type = if (c.file == null) abi.DT.DIR else abi.DT.REG }};
        }
        const final = list[0..list.len].*;
        return &final;
    }
}

/// The entries of `/proc`, `/dev` and `/` that no filesystem holds.
fn extraEntries(dir: []const u8) []const ListEntry {
    const DIR = abi.DT.DIR;
    const REG = abi.DT.REG;
    if (std.mem.eql(u8, dir, "/")) return &.{ .{ .name = "proc", .type = DIR }, .{ .name = "dev", .type = DIR }, .{ .name = "sys", .type = DIR } };
    inline for (procfs.sys_tree) |e| {
        if (e.file == null and std.mem.eql(u8, dir, e.path)) return comptime sysChildren(e.path);
    }
    if (std.mem.eql(u8, dir, "/dev")) return &.{
        .{ .name = "null", .type = abi.DT.CHR },
        .{ .name = "urandom", .type = abi.DT.CHR },
        .{ .name = "random", .type = abi.DT.CHR },
    };
    if (std.mem.eql(u8, dir, "/proc")) return &.{ .{ .name = "self", .type = DIR }, .{ .name = "meminfo", .type = REG }, .{ .name = "cpuinfo", .type = REG }, .{ .name = "syscalls", .type = REG }, .{ .name = "lockstat", .type = REG } };
    if (named(dir) == .directory and std.mem.startsWith(u8, dir, "/proc/")) {
        const own = std.mem.eql(u8, dir, "/proc/self") or blk: {
            var id_buf: [24]u8 = undefined;
            const me = thread.current().process orelse break :blk false;
            break :blk std.mem.eql(u8, dir, std.fmt.bufPrint(&id_buf, "/proc/{d}", .{me.pid}) catch break :blk false);
        };
        const all = &[_]ListEntry{
            .{ .name = "stat", .type = REG },
            .{ .name = "cmdline", .type = REG },
            .{ .name = "comm", .type = REG },
            .{ .name = "mountinfo", .type = REG },
            .{ .name = "cgroup", .type = REG },
            .{ .name = "schedstat", .type = REG },
            .{ .name = "exe", .type = abi.DT.LNK },
            .{ .name = "maps", .type = REG },
        };
        return if (own) all else all[0..6];
    }
    return &.{};
}

/// The entry of the directory `dir` at `position`, which is moved past it;
/// null at the end. Position 0 is the start.
fn nextEntry(dir: []const u8, position: *u64, name_buf: []u8) ?ListEntry {
    const extra = extraEntries(dir);
    if (position.* < LIST_BASE) {
        const index: usize = @intCast(position.*);
        position.* += 1;
        if (index == 0) return .{ .name = ".", .type = abi.DT.DIR };
        if (index == 1) return .{ .name = "..", .type = abi.DT.DIR };
        if (index - 2 < extra.len) return extra[index - 2];
        position.* = LIST_BASE;
    }
    if (std.mem.eql(u8, dir, "/proc")) {
        // Then a directory for each process, lowest ID first: the position
        // is LIST_BASE + the last ID listed, so processes that come and go
        // meanwhile move nothing.
        const next = proc.pidAfter(position.* - LIST_BASE) orelse return null;
        position.* = LIST_BASE + next;
        const name = std.fmt.bufPrint(name_buf, "{d}", .{next}) catch return null;
        return .{ .name = name, .type = abi.DT.DIR };
    }
    var cookie = position.* - LIST_BASE;
    defer position.* = cookie + LIST_BASE;
    while (vfs.next(dir, &cookie, name_buf)) |entry| {
        // Not twice, if the filesystem has a directory of that name too.
        var listed = false;
        for (extra) |e| listed = listed or std.mem.eql(u8, e.name, entry.name);
        if (listed) continue;
        return .{ .name = entry.name, .type = switch (entry.kind) {
            .directory => abi.DT.DIR,
            .file => abi.DT.REG,
            .symlink => abi.DT.LNK,
            .fifo => abi.DT.FIFO,
        } };
    }
    return null;
}

/// `rseq`: register the calling thread's restartable-sequence area, or
/// take it back (`rseq.zig`). `EINVAL` for a bad area, length or flag,
/// `EBUSY` for the same registration twice, `EPERM` for taking one back
/// with the wrong signature, `EFAULT` for an area that cannot be written.
fn sysRseq(area: u64, len: u64, flags: u64, sig: u64) u64 {
    const t = thread.current();
    if (flags & rseq.FLAG_UNREGISTER != 0 and t.rseq.area == area and t.rseq.sig != @as(u32, @truncate(sig))) return err(.PERM);
    rseq.register(t, area, @truncate(len), @truncate(flags), @truncate(sig)) catch |e| return switch (e) {
        error.Invalid => err(.INVAL),
        error.Busy => err(.BUSY),
        error.Fault => err(.FAULT),
    };
    return 0;
}

/// `getcpu`: the CPU the caller runs on, and its NUMA node (always 0),
/// at the addresses given (either may be null).
fn sysGetcpu(cpu_out: u64, node_out: u64) u64 {
    const id: u32 = @intCast(percpu.current().id);
    const node: u32 = 0;
    if (cpu_out != 0) uaccess.copyToUser(cpu_out, std.mem.asBytes(&id)) catch return err(.FAULT);
    if (node_out != 0) uaccess.copyToUser(node_out, std.mem.asBytes(&node)) catch return err(.FAULT);
    return 0;
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
    return switch (statFd(fd)) {
        .stat => |st| if (toUser(ptr, st)) 0 else err(.FAULT),
        .fail => |e| e,
    };
}

/// What `fstat` says about descriptor `fd`.
fn statFd(fd: u64) StatResult {
    var st: abi.Stat = .{};
    const of = getFile(fd) orelse return .{ .fail = err(.BADF) };
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
        .directory => st = directoryStat(),
        // No file of any kind: what Linux says of its anonymous files.
        .eventfd, .epoll, .signalfd => st.mode = 0o600,
        .file => st = fileStat(of.node),
    }
    return .{ .stat = st };
}

/// `statx`: `newfstatat` in Linux's newer structure, which the Zig
/// standard library uses. Every field `mask` may ask for is given
/// (`STATX_BASIC_STATS`); there are no birth times. `AT_STATX_*` sync
/// flags are accepted: nothing is cached elsewhere.
fn sysStatx(dirfd: u64, path_ptr: u64, flags: u64, mask: u64, buf: u64) u64 {
    _ = mask;
    const sync_bits: u64 = 0x6000; // AT_STATX_FORCE_SYNC, AT_STATX_DONT_SYNC
    const st = switch (statAt(dirfd, path_ptr, flags & ~sync_bits)) {
        .stat => |st| st,
        .fail => |e| return e,
    };
    const ts = struct {
        fn of(t: abi.TimeSpec) abi.StatxTimestamp {
            return .{ .sec = t.sec, .nsec = @intCast(t.nsec) };
        }
    }.of;
    const x: abi.Statx = .{
        .mask = 0x7FF, // STATX_BASIC_STATS
        .blksize = @intCast(st.blksize),
        .nlink = @intCast(st.nlink),
        .uid = st.uid,
        .gid = st.gid,
        .mode = @intCast(st.mode & 0xFFFF),
        .ino = st.ino,
        .size = @bitCast(st.size),
        .blocks = @bitCast(st.blocks),
        .atime = ts(st.atime),
        .ctime = ts(st.ctime),
        .mtime = ts(st.mtime),
        .rdev_major = @intCast((st.rdev >> 8) & 0xFFF),
        .rdev_minor = @intCast(st.rdev & 0xFF),
        .dev_major = @intCast((st.dev >> 8) & 0xFFF),
        .dev_minor = @intCast(st.dev & 0xFF),
    };
    return if (toUser(buf, x)) 0 else err(.FAULT);
}

/// `preadv` and `pwritev` (and their `2` forms with `flags` 0): `pread64`
/// and `pwrite64` over the buffers of an `iovec` array, one after the
/// other from `offset`. `ESPIPE` for what is not a file, as `pread64`.
fn sysPreadv(fd: u64, iov: u64, count: u64, offset: u64, write: bool) u64 {
    if (count > abi.IOV_MAX) return err(.INVAL);
    if (offset > std.math.maxInt(i64)) return err(.INVAL);
    var total: u64 = 0;
    for (0..count) |i| {
        const v = readIoVec(iov, i) orelse return err(.FAULT);
        total = std.math.add(u64, total, v.len) catch return err(.INVAL);
        if (total > abi.MAX_RW_COUNT) return err(.INVAL);
    }
    var done: u64 = 0;
    for (0..count) |i| {
        const v = readIoVec(iov, i) orelse break;
        if (v.len == 0) continue;
        const n = if (write) sysPwrite(fd, v.base, v.len, offset + done) else sysPread(fd, v.base, v.len, offset + done);
        if (abi.isError(n)) return if (done == 0) n else done;
        done += n;
        if (n < v.len) break;
    }
    return done;
}

/// `fcntl`: the descriptor and status flags can be read; setting them is
/// accepted and changes nothing (there is nothing they would change yet).
fn sysFcntl(fd: u64, command: u64, arg: u64) u64 {
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    const p = thread.current().process.?;
    switch (command) {
        0, 1030 => return sysDup(fd, arg, command == 1030), // F_DUPFD, F_DUPFD_CLOEXEC
        1, 2 => { // F_GETFD, F_SETFD: FD_CLOEXEC, the only descriptor flag
            const held = p.files_lock.acquire();
            defer p.files_lock.release(held);
            if (fd >= p.files.len or p.files[nospec.index(fd, p.files.len)] != of) return err(.BADF); // closed meanwhile
            const at = nospec.index(fd, p.files.len);
            if (command == 1) return @intFromBool(p.fd_cloexec[at]);
            p.fd_cloexec[at] = arg & 1 != 0;
            return 0;
        },
        3 => { // F_GETFL
            const access: u64 = switch (of.kind) {
                .console, .null_device, .random_device, .eventfd => abi.O.RDWR,
                .epoll, .signalfd => abi.O.RDONLY,
                .file => (if (!of.readable) @as(u64, abi.O.WRONLY) else if (of.writable) @as(u64, abi.O.RDWR) else abi.O.RDONLY) |
                    (if (of.append) @as(u64, abi.O.APPEND) else 0),
                .pipe_read => abi.O.RDONLY,
                .directory => abi.O.RDONLY | abi.O.DIRECTORY,
                .pipe_write => abi.O.WRONLY,
            };
            return access | if (nonblocking(of)) @as(u64, abi.O.NONBLOCK) else 0;
        },
        4 => { // F_SETFL: only O_NONBLOCK can change
            open_file.setNonblocking(of, arg & abi.O.NONBLOCK != 0);
            return 0;
        },
        abi.F_ADD_SEALS, abi.F_GET_SEALS => {
            // Only a memory object has seals (Linux: EINVAL for others).
            const o = (if (of.kind == .file) memfd.fromNode(&of.node) else null) orelse return err(.INVAL);
            if (command == abi.F_GET_SEALS) return memfd.getSeals(o);
            if (!of.writable) return err(.PERM);
            memfd.addSeals(o, @truncate(arg)) catch |e| return switch (e) {
                error.NotPermitted => err(.PERM),
                error.Busy => err(.BUSY),
                error.Invalid => err(.INVAL),
            };
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
/// before; either pointer may be null (`signal.zig` delivers them). `EINVAL` for a signal that does not exist, for changing
/// `SIGKILL` or `SIGSTOP`, and for a mask of the wrong size; `EFAULT`.
fn sysSigAction(sig: u64, act: u64, old: u64, set_size: u64) u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    if (set_size != abi.SIGSET_SIZE or sig < 1 or sig > abi.NSIG) return err(.INVAL);
    // Copied in and out without the lock: the program's memory may fault.
    var new: ?abi.SigAction = null;
    if (act != 0) {
        if (sig == abi.SIGKILL or sig == abi.SIGSTOP) return err(.INVAL);
        var a = fromUser(abi.SigAction, act) orelse return err(.FAULT);
        a.mask &= ~UNBLOCKABLE;
        new = a;
    }
    const before = blk: {
        const held = p.signal_lock.acquire();
        defer p.signal_lock.release(held);
        const slot = &p.signal_actions[nospec.index(sig - 1, abi.NSIG)];
        const b = slot.*;
        if (new) |a| slot.* = a;
        break :blk b;
    };
    // Set to ignored: what is pending of it goes (POSIX).
    if (new) |a| if (a.handler == 1) {
        _ = p.signal_pending.fetchAnd(~signal.bit(@intCast(sig)), .acq_rel);
    };
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
    const deadline: ?u64 = if (timeout < 0) null else deadlineAfter(timer.msToTicks(@intCast(timeout)));
    while (true) {
        const seq = readiness.now(); // before looking: a change after it ends the wait
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
        // Nothing yet: until one of the objects reports a change.
        switch (waitTill(seq, deadline)) {
            .changed => {},
            .timed_out => return 0,
            .interrupted => return err(.INTR),
        }
    }
}

/// What `poll` reports for an open file, of the events asked for; hang-up
/// and error are reported whether asked for or not.
fn pollState(of: *OpenFile, events: i16) i16 {
    switch (of.kind) {
        // The console can be written to, and read once a line is typed.
        .console => return events & (abi.POLL.OUT | if (tty.readable()) @as(i16, abi.POLL.IN) else 0),
        .null_device, .random_device => return events & (abi.POLL.IN | abi.POLL.OUT),
        .directory => return events & abi.POLL.IN,
        // A file can always be read.
        .file => return events & (abi.POLL.IN | abi.POLL.OUT),
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
        .eventfd => {
            const st = kepoll.eventState(of.eventfd);
            var r: i16 = 0;
            if (st.readable) r |= events & abi.POLL.IN;
            if (st.writable) r |= events & abi.POLL.OUT;
            return r;
        },
        // Ready when one of what it watches is; that is for `epoll_wait`
        // to find out, and nothing waits on an epoll inside another yet.
        .epoll => return 0,
        // Readable while a signal of its set is pending for the caller.
        .signalfd => {
            const t = thread.current();
            const pending = signal.pendingSet(t) & @atomicLoad(u64, &of.signal_mask, .acquire);
            return if (pending != 0) events & abi.POLL.IN else 0;
        },
    }
}

/// `flock`: an advisory lock on the whole file `fd` is open on, held by
/// its open file (`flock.zig`). `LOCK_SH`, `LOCK_EX`, `LOCK_UN`, with
/// `LOCK_NB` not to wait: then `EWOULDBLOCK` for a lock in the way.
/// What is not a file of a filesystem (a pipe, the terminal) is locked
/// by its open file alone. `EINVAL` for another operation, `EBADF`,
/// `EINTR`, `ENOLCK`.
fn sysFlock(fd: u64, op: u64) u64 {
    const what = op & ~@as(u64, abi.LOCK.NB);
    if (what != abi.LOCK.SH and what != abi.LOCK.EX and what != abi.LOCK.UN) return err(.INVAL);
    const of = getFile(fd) orelse return err(.BADF);
    defer putFile(of);
    const owner = open_file.id(of);
    const key: kflock.Key = if (of.kind == .file)
        .{ .a = @intFromPtr(of.node.ops), .b = of.node.ctx }
    else
        .{ .a = 0, .b = owner };
    if (what == abi.LOCK.UN) {
        kflock.release(key, owner);
        return 0;
    }
    @atomicStore(bool, &of.locked, true, .release);
    kflock.acquire(key, owner, what == abi.LOCK.EX, op & abi.LOCK.NB != 0) catch |e| return switch (e) {
        error.WouldBlock => err(.AGAIN),
        error.Interrupted => err(.INTR),
        error.NoLocks => err(.NOLCK),
    };
    return 0;
}

// ---------------------------------------------------------------------------
// Signals taken without a handler, and with a value.

/// `rt_sigqueueinfo` (`tid` null) and `rt_tgsigqueueinfo`: send `sig` to
/// the process `tgid` (or its thread `tid`) with the caller's `siginfo`,
/// whose value the receiver gets (`sigqueue`). A program may not claim
/// the kernel or `tgkill` sent it (`si_code` 0 or above, or `SI_TKILL`)
/// except to itself: `EPERM`, as on Linux. `EAGAIN` when the receiver has
/// as many signals queued as it may; `EINVAL`, `ESRCH`, `EFAULT`.
fn sysSigQueueInfo(tgid: u64, tid: ?u64, sig_arg: u64, info_ptr: u64) u64 {
    const me = thread.current().process orelse return err(.NOSYS);
    if (sig_arg > abi.NSIG) return err(.INVAL);
    const sig: u32 = @intCast(sig_arg);
    var info = fromUser(signal.SigInfo, info_ptr) orelse return err(.FAULT);
    if ((info.code >= 0 or info.code == signal.SI.TKILL) and tgid != me.pid) return err(.PERM);
    if (sig != 0) info.signo = @intCast(sig);
    if (tid) |one| {
        if (tgid != me.pid) return err(.SRCH); // other processes' threads: not reachable yet, as with tgkill
        return switch (proc.signalThreadInfo(me, one, sig, info)) {
            .sent => 0,
            .no_such, .zombie => err(.SRCH),
            .full => err(.AGAIN),
        };
    }
    return switch (proc.signalPidInfo(tgid, sig, info)) {
        .sent, .zombie => 0,
        .no_such => err(.SRCH),
        .full => err(.AGAIN),
    };
}

/// `rt_sigtimedwait`: take a pending signal of the set at `set_ptr`, the
/// calling thread's or its process's, without running a handler; wait
/// for one until the time at `ts_ptr` has passed (`EAGAIN`; for ever
/// without one). Returns the signal and writes its `siginfo`. The set is
/// usually blocked, so that nothing else takes them; while the thread
/// waits it takes them out of its mask, as Linux does, so that a signal of
/// the set sent to the process comes to it. `EINTR` for a signal outside
/// the set that a handler took; `EINVAL`, `EFAULT`.
fn sysSigTimedWait(set_ptr: u64, info_ptr: u64, ts_ptr: u64, size: u64) u64 {
    if (size != abi.SIGSET_SIZE) return err(.INVAL);
    const t = thread.current();
    const p = t.process orelse return err(.NOSYS);
    const set = (fromUser(u64, set_ptr) orelse return err(.FAULT)) & ~signal.UNBLOCKABLE;
    var deadline: ?u64 = null;
    if (ts_ptr != 0) {
        const ts = fromUser(abi.TimeSpec, ts_ptr) orelse return err(.FAULT);
        if (ts.sec < 0 or ts.nsec < 0 or ts.nsec >= NS_PER_SEC) return err(.INVAL);
        const ms: u64 = @as(u64, @intCast(ts.sec)) *| 1000 +| @as(u64, @intCast(ts.nsec)) / 1_000_000;
        deadline = if (ts.sec == 0 and ts.nsec == 0) timer.now() else deadlineAfter(timer.msToTicks(ms) + @intFromBool(@rem(ts.nsec, 1_000_000) != 0));
    }
    const saved = t.signal_mask;
    defer t.signal_mask = saved;
    while (true) {
        t.signal_mask = saved;
        if (signal.take(t, p, set)) |got| {
            if (info_ptr != 0) {
                var info = got.info orelse signal.SigInfo.fromProcess(got.sig, signal.SI.KERNEL, 0, 0);
                info.signo = @intCast(got.sig);
                if (!toUser(info_ptr, info)) return err(.FAULT);
            }
            return got.sig;
        }
        if (thread.interrupted()) return err(.INTR); // a signal outside the set, or the end
        const left: ?u64 = if (deadline) |d| d -| timer.now() else null;
        if (left != null and left.? == 0) return err(.AGAIN);
        t.signal_mask = saved & ~set;
        // One may have come before the mask let it wake this thread.
        if ((t.signal_pending.load(.acquire) | p.signal_pending.load(.acquire)) & set != 0) continue;
        _ = timer.sleepTicksKillable(left orelse timer.HZ);
    }
}

/// `signalfd` and `signalfd4`: a descriptor for the signals of the set at
/// `mask_ptr` (`fd` -1), or a new set for the signalfd `fd`. Reading it
/// takes the reader's pending signals of the set, as `rt_sigtimedwait`
/// does, one `signalfd_siginfo` record each; `poll` and `epoll` see it
/// readable while one is pending. `SFD_NONBLOCK`, `SFD_CLOEXEC`. `EINVAL`
/// for a size other than 8, other flags, or an `fd` that is no signalfd;
/// `EBADF`, `EFAULT`.
fn sysSignalfd(fd: u64, mask_ptr: u64, size: u64, flags: u64) u64 {
    if (size != abi.SIGSET_SIZE) return err(.INVAL);
    if (flags & ~@as(u64, abi.SFD.NONBLOCK | abi.SFD.CLOEXEC) != 0) return err(.INVAL);
    const p = thread.current().process orelse return err(.BADF);
    const mask = (fromUser(u64, mask_ptr) orelse return err(.FAULT)) & ~signal.UNBLOCKABLE;
    if (@as(i32, @truncate(@as(i64, @bitCast(fd)))) != -1) {
        const of = getFile(fd) orelse return err(.BADF);
        defer putFile(of);
        if (of.kind != .signalfd) return err(.INVAL);
        @atomicStore(u64, &of.signal_mask, mask, .release);
        return fd;
    }
    const of = heap.allocator.create(OpenFile) catch return err(.NOMEM);
    of.* = .{ .kind = .signalfd, .signal_mask = mask, .readable = true, .nonblock = flags & abi.SFD.NONBLOCK != 0 };
    return installFileFlags(p, of, 0, flags & abi.SFD.CLOEXEC != 0) orelse {
        open_file.destroy(of);
        return err(.MFILE);
    };
}

/// `read` of a signalfd: a record for each pending signal of its set, as
/// many as fit; waits for one unless the file is non-blocking.
fn signalfdRead(of: *OpenFile, ptr: u64, len: u64) u64 {
    const RECORD = @sizeOf(abi.SignalfdSiginfo);
    if (len < RECORD) return err(.INVAL);
    const t = thread.current();
    const p = t.process orelse return err(.BADF);
    var done: u64 = 0;
    while (true) {
        const seq = readiness.now(); // before looking: a signal after it ends the wait
        const mask = @atomicLoad(u64, &of.signal_mask, .acquire);
        while (done + RECORD <= len) {
            const got = signal.take(t, p, mask) orelse break;
            const info = got.info orelse signal.SigInfo.fromProcess(got.sig, signal.SI.KERNEL, 0, 0);
            const rec: abi.SignalfdSiginfo = .{
                .signo = got.sig,
                .errno = info.errno,
                .code = info.code,
                .pid = std.mem.readInt(u32, info.fields[0..4], .little),
                .uid = std.mem.readInt(u32, info.fields[4..8], .little),
                .int = std.mem.readInt(i32, info.fields[8..12], .little),
                .ptr = std.mem.readInt(u64, info.fields[8..16], .little),
                .addr = std.mem.readInt(u64, info.fields[0..8], .little),
            };
            if (!toUser(ptr + done, rec)) return if (done == 0) err(.FAULT) else done;
            done += RECORD;
        }
        if (done != 0) return done;
        if (nonblocking(of)) return err(.AGAIN);
        switch (readiness.waitForChange(seq, null)) {
            .changed, .timed_out => {},
            .interrupted => return err(.INTR),
        }
    }
}

/// `eventfd` and `eventfd2`: a new counter, starting at `initial`.
/// `EFD_SEMAPHORE`, `EFD_NONBLOCK`, `EFD_CLOEXEC`.
/// `memfd_create`: a file in memory only (`memfd.zig`), open for reading
/// and writing, which can be mapped shared. `EINVAL` for unknown flags,
/// `MFD_HUGETLB` (no large pages for it) or a name longer than 249 bytes;
/// `EFAULT` for a name that cannot be read.
fn sysMemfdCreate(name_ptr: u64, flags: u64) u64 {
    const known = abi.MFD.CLOEXEC | abi.MFD.ALLOW_SEALING | abi.MFD.HUGETLB | abi.MFD.NOEXEC_SEAL | abi.MFD.EXEC;
    if (flags & ~known != 0 or flags & abi.MFD.HUGETLB != 0) return err(.INVAL);
    const p = thread.current().process orelse return err(.BADF);
    var name_buf: [250]u8 = undefined;
    const len = uaccess.copyStringFromUser(&name_buf, name_ptr) catch |e| return switch (e) {
        error.Fault => err(.FAULT),
        error.TooLong => err(.INVAL),
    };
    // `MFD_NOEXEC_SEAL` seals the file (and allows sealing) as Linux does
    // (there are no execute permissions to take away).
    const sealable = flags & (abi.MFD.ALLOW_SEALING | abi.MFD.NOEXEC_SEAL) != 0;
    const o = memfd.create(name_buf[0..len], sealable) catch return err(.NOMEM);
    const of = heap.allocator.create(OpenFile) catch {
        memfd.release(o);
        return err(.NOMEM);
    };
    of.* = .{ .kind = .file, .node = memfd.node(o), .readable = true, .writable = true };
    return installFileFlags(p, of, 0, flags & abi.MFD.CLOEXEC != 0) orelse {
        open_file.destroy(of);
        return err(.MFILE);
    };
}

fn sysEventFd(initial: u64, flags: u64) u64 {
    if (flags & ~@as(u64, abi.EFD.SEMAPHORE | abi.EFD.NONBLOCK | abi.EFD.CLOEXEC) != 0) return err(.INVAL);
    const p = thread.current().process orelse return err(.BADF);
    const e = kepoll.createEventFd(@truncate(initial), flags & abi.EFD.SEMAPHORE != 0) catch return err(.NOMEM);
    const of = heap.allocator.create(OpenFile) catch {
        kepoll.destroyEventFd(e);
        return err(.NOMEM);
    };
    of.* = .{ .kind = .eventfd, .eventfd = e, .readable = true, .writable = true, .nonblock = flags & abi.EFD.NONBLOCK != 0 };
    return installFileFlags(p, of, 0, flags & abi.EFD.CLOEXEC != 0) orelse {
        open_file.destroy(of);
        return err(.MFILE);
    };
}

/// `read` of an eventfd: its 8-byte counter, taken. `EINVAL` for a
/// buffer shorter than 8 bytes.
fn eventFdRead(of: *OpenFile, ptr: u64, len: u64) u64 {
    if (len < 8) return err(.INVAL);
    return switch (kepoll.eventRead(of.eventfd, nonblocking(of))) {
        .value => |v| if (toUser(ptr, v)) 8 else err(.FAULT),
        .again => err(.AGAIN),
        .killed => err(.INTR),
    };
}

/// `write` to an eventfd: 8 bytes, added to its counter. `EINVAL` for a
/// shorter buffer or the value 2^64-1.
fn eventFdWrite(of: *OpenFile, ptr: u64, len: u64) u64 {
    if (len < 8) return err(.INVAL);
    const n = fromUser(u64, ptr) orelse return err(.FAULT);
    if (n == std.math.maxInt(u64)) return err(.INVAL);
    return switch (kepoll.eventWrite(of.eventfd, n, nonblocking(of))) {
        .value => 8,
        .again => err(.AGAIN),
        .killed => err(.INTR),
    };
}

/// `epoll_create` and `epoll_create1`: a new, empty instance.
fn sysEpollCreate(flags: u64) u64 {
    if (flags & ~@as(u64, abi.EPOLL.CLOEXEC) != 0) return err(.INVAL);
    const p = thread.current().process orelse return err(.BADF);
    const ep = kepoll.createEpoll() catch return err(.NOMEM);
    const of = heap.allocator.create(OpenFile) catch {
        kepoll.destroyEpoll(ep);
        return err(.NOMEM);
    };
    of.* = .{ .kind = .epoll, .epoll = ep };
    return installFileFlags(p, of, 0, flags & abi.EPOLL.CLOEXEC != 0) orelse {
        open_file.destroy(of);
        return err(.MFILE);
    };
}

/// `epoll_ctl`: watch `fd`, change how, or stop. `EBADF`, `EINVAL` for an
/// instance that is not one or watching itself, `EPERM` for what cannot be
/// waited on (files and directories, which are always ready, as on Linux),
/// `EEXIST`, `ENOENT`, `ENOSPC`, `ENOMEM`.
fn sysEpollCtl(epfd: u64, op_code: u64, fd: u64, event_ptr: u64) u64 {
    const ep_file = getFile(epfd) orelse return err(.BADF);
    defer putFile(ep_file);
    if (ep_file.kind != .epoll or epfd == fd) return err(.INVAL);
    const target = getFile(fd) orelse return err(.BADF);
    const kind = target.kind;
    putFile(target);
    switch (kind) {
        .file, .directory => return err(.PERM),
        .epoll => return err(.INVAL), // one inside another: not yet
        else => {},
    }
    const op: kepoll.Op = switch (op_code) {
        abi.EPOLL.CTL_ADD => .add,
        abi.EPOLL.CTL_DEL => .del,
        abi.EPOLL.CTL_MOD => .mod,
        else => return err(.INVAL),
    };
    var event: abi.EpollEvent = .{ .events = 0, .data = 0 };
    if (op != .del) event = fromUser(abi.EpollEvent, event_ptr) orelse return err(.FAULT);
    // The open file the descriptor is on now is what is watched.
    const watched = getFile(fd) orelse return err(.BADF);
    const watched_id = open_file.id(watched);
    putFile(watched);
    kepoll.control(ep_file.epoll, op, @intCast(fd), watched_id, event.events, event.data) catch |e| return switch (e) {
        error.Exists => err(.EXIST),
        error.NotFound => err(.NOENT),
        error.TooMany => err(.NOSPC),
        error.OutOfMemory => err(.NOMEM),
    };
    return 0;
}

/// `epoll_wait` and the `epoll_pwait` calls: the watched descriptors that
/// are ready, at most `max` of them, waiting up to `timeout_ms` (for ever
/// if negative) for one to be. With `sigmask`, those signals are blocked
/// instead while it waits. Interrupted by a signal: `EINTR`, never made
/// again. `EBADF`, `EINVAL`, `EFAULT`.
fn sysEpollWait(epfd: u64, events_ptr: u64, max: u64, timeout_ms: i64, sigmask_ptr: u64, sigsetsize: u64) u64 {
    const max_events: i32 = @truncate(@as(i64, @bitCast(max)));
    if (max_events <= 0 or max_events > 1 << 20) return err(.INVAL);
    if (!user_range.valid(events_ptr, @as(u64, @intCast(max_events)) * @sizeOf(abi.EpollEvent))) return err(.FAULT);
    const ep_file = getFile(epfd) orelse return err(.BADF);
    defer putFile(ep_file);
    if (ep_file.kind != .epoll) return err(.INVAL);
    const t = thread.current();
    if (sigmask_ptr != 0) {
        if (sigsetsize != abi.SIGSET_SIZE) return err(.INVAL);
        const mask = fromUser(u64, sigmask_ptr) orelse return err(.FAULT);
        t.signal_saved_mask = t.signal_mask;
        t.signal_mask = mask & ~signal.UNBLOCKABLE;
    }
    defer if (sigmask_ptr != 0) {
        // With a handler about to run, its frame takes the saved mask
        // (`signal.zig`); otherwise it is put back here.
        if (!signal.pending(t)) {
            if (t.signal_saved_mask) |m| t.signal_mask = m;
            t.signal_saved_mask = null;
        }
    };
    const deadline: ?u64 = if (timeout_ms < 0) null else deadlineAfter(timer.msToTicks(@intCast(timeout_ms)));
    var small: [16]kepoll.Interest = undefined;
    var big: []kepoll.Interest = &.{};
    defer heap.allocator.free(big);
    while (true) {
        const seq = readiness.now(); // before looking: a change after it ends the wait
        const watched = kepoll.snapshot(ep_file.epoll, &small) orelse blk: {
            if (big.len == 0) big = heap.allocator.alloc(kepoll.Interest, kepoll.MAX_WATCHED) catch return err(.NOMEM);
            break :blk kepoll.snapshot(ep_file.epoll, big).?;
        };
        var n: u64 = 0;
        for (watched) |w| {
            if (w.disabled or n == @as(u64, @intCast(max_events))) continue;
            const of = getFile(w.fd) orelse {
                kepoll.dropStale(ep_file.epoll, w.fd, w.file); // closed: the watch ends
                continue;
            };
            defer putFile(of);
            if (open_file.id(of) != w.file) {
                kepoll.dropStale(ep_file.epoll, w.fd, w.file); // another open file under the number now
                continue;
            }
            const asked: i16 = @truncate(@as(i32, @bitCast(w.events & (abi.EPOLL.IN | abi.EPOLL.OUT | abi.EPOLL.PRI))));
            const version = objectVersion(of);
            const ready = pollState(of, asked);
            if (ready == 0) continue;
            if (w.events & abi.EPOLL.ET != 0) {
                if (version == w.seen) continue; // reported, and nothing new since
                kepoll.setSeen(ep_file.epoll, w.fd, version);
            }
            const ev: abi.EpollEvent = .{ .events = @as(u32, @bitCast(@as(i32, ready))) & 0xFFFF, .data = w.data };
            if (!toUser(events_ptr + n * @sizeOf(abi.EpollEvent), ev)) return err(.FAULT);
            if (w.events & abi.EPOLL.ONESHOT != 0) kepoll.disable(ep_file.epoll, w.fd);
            n += 1;
        }
        if (n != 0) return n;
        switch (waitTill(seq, deadline)) {
            .changed => {},
            .timed_out => return 0,
            .interrupted => return err(.INTR),
        }
    }
}

/// The tick by which `ticks` whole ticks have passed: one more than that
/// from now, since the current tick has partly gone already (as
/// `timer.sleepTicks`). 0 ticks is no wait at all.
fn deadlineAfter(ticks: u64) u64 {
    return timer.now() + if (ticks == 0) 0 else ticks + 1;
}

/// Wait for a change any poller might care about, until the tick
/// `deadline` (null: for ever).
fn waitTill(seq: u64, deadline: ?u64) readiness.Outcome {
    const ticks: ?u64 = if (deadline) |d| d -| timer.now() else null;
    if (ticks != null and ticks.? == 0) return .timed_out;
    return readiness.waitForChange(seq, ticks);
}

/// How many times the object behind `of` has changed (pipe, terminal,
/// eventfd), for edge-triggered `epoll`; 0 for what never changes.
fn objectVersion(of: *OpenFile) u64 {
    return switch (of.kind) {
        .pipe_read, .pipe_write => kpipe.version(of.pipe),
        .console => tty.changeCount(),
        .eventfd => kepoll.eventVersion(of.eventfd),
        .signalfd => if (thread.current().process) |p| p.signal_version.load(.monotonic) else 0,
        else => 0,
    };
}

const NS_PER_SEC: u64 = 1_000_000_000;

/// Nanoseconds on `clock`, or null if there is no such clock.
fn clockNanos(clock: u64) ?u64 {
    return switch (clock) {
        abi.CLOCK.MONOTONIC, abi.CLOCK.MONOTONIC_RAW, abi.CLOCK.MONOTONIC_COARSE, abi.CLOCK.BOOTTIME => futex.monotonicNanos(),
        abi.CLOCK.REALTIME, abi.CLOCK.REALTIME_COARSE => kclock.wallNanos(),
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

/// Below this much time left, a sleep gives the CPU away with `yield`
/// until its deadline instead of sleeping a timer tick (10 ms), which
/// would overshoot by most of a tick: runtimes sleep for microseconds
/// while they spin (Go's `usleep(20)`).
const YIELD_BELOW_NS: u64 = 2_000_000;

/// Sleep until `deadline` (nanoseconds since boot). Whole timer ticks
/// while more than a tick is left, so the sleep ends at most a tick late;
/// under `YIELD_BELOW_NS`, giving the CPU to others until the deadline.
/// Returns 0, or `EINTR` if a signal or the process's end comes first.
fn sleepUntil(deadline: u64) u64 {
    while (true) {
        const now = futex.monotonicNanos();
        if (now >= deadline) return 0;
        const left = deadline - now;
        if (left < YIELD_BELOW_NS) {
            if (thread.interrupted()) return err(.INTR);
            thread.yield();
            continue;
        }
        // `sleepTicks(n)` sleeps n to n + 1 ticks: n is the whole ticks left
        // less one, so it ends before the deadline (or in the tick of it,
        // for less than two ticks left).
        const ticks = left / timer.NS_PER_TICK;
        if (!timer.sleepTicksKillable(ticks -| 1)) return err(.INTR);
    }
}

/// `nanosleep` and `clock_nanosleep`: sleep for the time at `request`, or
/// with `absolute` until that time on `clock`. A signal ends it with
/// `EINTR`, and a relative sleep then writes what was left at `remaining`
/// (if not null), as Linux does.
fn sysSleep(clock: u64, absolute: bool, request: u64, remaining: u64) u64 {
    const now = clockNanos(clock) orelse return err(.INVAL);
    const ns = switch (userNanos(request)) {
        .ns => |n| n,
        .fail => |e| return e,
    };
    const wait_ns = if (absolute) ns -| now else ns;
    const deadline = futex.monotonicNanos() +| wait_ns;
    const rc = sleepUntil(deadline);
    if (rc == err(.INTR) and !absolute and remaining != 0) {
        if (!toUser(remaining, timeSpec(deadline -| futex.monotonicNanos()))) return err(.FAULT);
    }
    return rc;
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
    if (thread.current().process == null) return err(.NOSYS);
    // The order of the last arguments is x86-64's: child_tid, then tls.
    const args: proc.CloneArgs = .{ .flags = flags & ~@as(u64, 0xFF), .stack = f.rsi, .parent_tid = f.rdx, .child_tid = f.r10, .tls = f.r8 };
    if (flags & proc.CLONE.THREAD == 0) return newProcess(f, args, @intCast(flags & 0xFF));
    if (flags & proc.CLONE.THREAD_FLAGS != proc.CLONE.THREAD_FLAGS) return err(.INVAL);
    const tid = proc.cloneThread(f, args) catch |e| return switch (e) {
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
    if ((args.stack == 0) != (args.stack_size == 0)) return err(.INVAL);
    const top = std.math.add(u64, args.stack, args.stack_size) catch return err(.INVAL);
    if (thread.current().process == null) return err(.NOSYS);
    if (args.flags & proc.CLONE.THREAD == 0) {
        if (args.exit_signal > abi.NSIG) return err(.INVAL);
        return newProcess(f, .{ .flags = args.flags, .stack = top, .parent_tid = args.parent_tid, .child_tid = args.child_tid, .tls = args.tls }, @intCast(args.exit_signal));
    }
    if (args.flags & proc.CLONE.THREAD_FLAGS != proc.CLONE.THREAD_FLAGS) return err(.INVAL);
    if (args.exit_signal != 0) return err(.INVAL);
    const tid = proc.cloneThread(f, .{ .flags = args.flags, .stack = top, .parent_tid = args.parent_tid, .child_tid = args.child_tid, .tls = args.tls }) catch |e| return switch (e) {
        error.OutOfMemory => err(.NOMEM),
        error.Fault => err(.FAULT),
        error.BadAddress => err(.PERM),
        error.ProcessEnding => err(.INTR),
    };
    return tid;
}

/// `clone` and `clone3` without `CLONE_THREAD`, `fork` and `vfork`: a new
/// process, a copy of this one (`proc.forkProcess`). `EINVAL` for what
/// only threads may ask (`CLONE_SIGHAND` without `CLONE_VM`, sharing the
/// descriptor table or the signal actions with another process),
/// `EAGAIN` past the descendant limit, `ENOMEM`.
fn newProcess(f: *const arch.Frame, args: proc.CloneArgs, exit_signal: u32) u64 {
    const C = proc.CLONE;
    const known = C.VM | C.FS | C.VFORK | C.SETTLS | C.PARENT_SETTID | C.CHILD_SETTID | C.CHILD_CLEARTID | C.SYSVSEM | C.DETACHED;
    if (args.flags & ~@as(u64, known) != 0) return err(.INVAL);
    if (exit_signal > abi.NSIG) return err(.INVAL);
    const pid = proc.forkProcess(f, args, exit_signal) catch |e| return switch (e) {
        error.OutOfMemory => err(.NOMEM),
        error.Fault => err(.FAULT),
        error.BadAddress => err(.PERM),
        error.TooManyProcesses => err(.AGAIN),
        error.Interrupted => err(.INTR),
    };
    return pid;
}

/// `wait4`: collect a child that has ended (`proc.waitChild`), writing its
/// status at `status_ptr` and nothing (zeroes) at `rusage_ptr`. `WNOHANG`
/// returns 0 if none has ended yet; `WUNTRACED` and `WCONTINUED` are
/// accepted and change nothing, as nothing stops yet. `ECHILD` if no child
/// matches, `EINTR`, `EINVAL`, `EFAULT`.
fn sysWait4(pid_arg: u64, status_ptr: u64, options: u64, rusage_ptr: u64) u64 {
    if (options & ~@as(u64, abi.WNOHANG | abi.WUNTRACED | abi.WCONTINUED) != 0) return err(.INVAL);
    if (thread.current().process == null) return err(.CHILD);
    const pid: i64 = @as(i32, @truncate(@as(i64, @bitCast(pid_arg))));
    return switch (proc.waitChild(pid, .{
        .nohang = options & abi.WNOHANG != 0,
        .stopped = options & abi.WUNTRACED != 0,
        .continued = options & abi.WCONTINUED != 0,
    })) {
        .exited => |x| blk: {
            if (status_ptr != 0 and !toUser(status_ptr, @as(i32, @bitCast(x.status)))) break :blk err(.FAULT);
            if (rusage_ptr != 0 and !toUser(rusage_ptr, rusageOf(x.run_cycles, 0, x.max_pages))) break :blk err(.FAULT);
            break :blk x.pid;
        },
        .none_yet => 0,
        .no_child => err(.CHILD),
        .interrupted => err(.INTR),
    };
}

/// `struct rusage` for `cycles` of CPU time (all of it counted as user
/// time: the kernel does not tell the two apart), `slices` time slices and
/// at most `pages` pages of memory.
fn rusageOf(cycles: u64, slices: u64, pages: u64) abi.RUsage {
    const hz = kclock.cycleHz();
    const us: u64 = if (hz == 0) 0 else @intCast(@as(u128, cycles) * 1_000_000 / hz);
    return .{
        .utime = .{ .sec = @intCast(us / 1_000_000), .usec = @intCast(us % 1_000_000) },
        .maxrss = @intCast(pages * 4), // in KiB
        .nvcsw = @intCast(slices),
    };
}

/// `waitid`: `wait4`, with what happened told in a `siginfo` (`SIGCHLD`,
/// `si_code` `CLD_EXITED`, `KILLED`, `STOPPED` or `CONTINUED`, the child's
/// ID and status). `P_ALL`, `P_PID`, `P_PGID` (0: the caller's group);
/// `WEXITED`, `WSTOPPED`, `WCONTINUED` (at least one), `WNOHANG` (then
/// `si_pid` 0 if nothing is ready), `WNOWAIT` (the child can be waited
/// for again). `EINVAL` for other flags or `P_PIDFD` (no pidfds yet).
fn sysWaitid(idtype: u64, id: u64, info_ptr: u64, options: u64, rusage_ptr: u64) u64 {
    const known = abi.WNOHANG | abi.WSTOPPED | abi.WEXITED | abi.WCONTINUED | abi.WNOWAIT;
    if (options & ~@as(u64, known) != 0) return err(.INVAL);
    if (options & (abi.WEXITED | abi.WSTOPPED | abi.WCONTINUED) == 0) return err(.INVAL);
    if (thread.current().process == null) return err(.CHILD);
    const pid: i64 = switch (idtype) {
        abi.P.ALL => -1,
        abi.P.PID => if (id == 0 or id > std.math.maxInt(i32)) return err(.INVAL) else @intCast(id),
        abi.P.PGID => if (id == 0) 0 else if (id > std.math.maxInt(i32)) return err(.INVAL) else -@as(i64, @intCast(id)),
        else => return err(.INVAL),
    };
    const result = proc.waitChild(pid, .{
        .nohang = options & abi.WNOHANG != 0,
        .exited = options & abi.WEXITED != 0,
        .stopped = options & abi.WSTOPPED != 0,
        .continued = options & abi.WCONTINUED != 0,
        .nowait = options & abi.WNOWAIT != 0,
    });
    var info = std.mem.zeroes([128]u8);
    switch (result) {
        .exited => |x| {
            const code: i32, const status: i32 = switch (x.how) {
                .exited => .{ abi.CLD.EXITED, @intCast((x.status >> 8) & 0xFF) },
                .killed => .{ abi.CLD.KILLED, @intCast(x.status & 0x7F) },
                .stopped => .{ abi.CLD.STOPPED, @intCast((x.status >> 8) & 0xFF) },
                .continued => .{ abi.CLD.CONTINUED, 18 }, // SIGCONT
            };
            std.mem.writeInt(i32, info[0..4], 17, .little); // SIGCHLD
            std.mem.writeInt(i32, info[8..12], code, .little);
            std.mem.writeInt(i32, info[16..20], @intCast(x.pid), .little);
            std.mem.writeInt(i32, info[24..28], status, .little);
            if (rusage_ptr != 0 and !toUser(rusage_ptr, rusageOf(x.run_cycles, 0, x.max_pages))) return err(.FAULT);
        },
        .none_yet => {}, // all zero: si_pid 0 says nothing was ready
        .no_child => return err(.CHILD),
        .interrupted => return err(.INTR),
    }
    if (info_ptr != 0) uaccess.copyToUser(info_ptr, &info) catch return err(.FAULT);
    return 0;
}

/// `getrusage`: CPU time (as user time) and the most memory used, of the
/// calling process (`RUSAGE_SELF`; `RUSAGE_THREAD` reports the same) or
/// of its children that were waited for (`RUSAGE_CHILDREN`). `EINVAL`
/// for another `who`.
fn sysGetrusage(who: u64, ptr: u64) u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    const w: i64 = @bitCast(who);
    const u = switch (w) {
        abi.RUSAGE.SELF, abi.RUSAGE.THREAD => proc.usage(p, false),
        abi.RUSAGE.CHILDREN => proc.usage(p, true),
        else => return err(.INVAL),
    };
    return if (toUser(ptr, rusageOf(u.run_cycles, u.slices, u.max_pages))) 0 else err(.FAULT);
}

/// `getpriority` and `setpriority` for a process (`PRIO_PROCESS`; `who`
/// 0 is the caller): its nice value, which is kept and reported (as
/// `20 - nice`, the system call's form) but does not change how the
/// scheduler treats it. `ESRCH` for no such process; `EINVAL` for
/// process groups and users, which are not offered.
fn sysGetpriority(which: u64, who: u64) u64 {
    if (which != abi.PRIO.PROCESS) return err(.INVAL);
    const nice = proc.getNice(who) orelse return err(.SRCH);
    return @intCast(20 - @as(i64, nice));
}

fn sysSetpriority(which: u64, who: u64, prio: u64) u64 {
    if (which != abi.PRIO.PROCESS) return err(.INVAL);
    return if (proc.setNice(who, @as(i32, @truncate(@as(i64, @bitCast(prio)))))) 0 else err(.SRCH);
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
    if (thread.current().process == null) return err(.NOSYS);
    return proc.groupOf(pid, .session) orelse err(.SRCH);
}

/// `setpgid`, `getpgid`, `getpgrp`, `setsid` (`proc.setGroup` and the
/// rest say how).
fn sysSetpgid(pid: u64, pgid: u64) u64 {
    if (@as(i64, @bitCast(pgid)) < 0) return err(.INVAL);
    proc.setGroup(pid, pgid) catch |e| return switch (e) {
        error.NoSuchProcess => err(.SRCH),
        error.NotPermitted => err(.PERM),
        error.Invalid => err(.INVAL),
    };
    return 0;
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

/// `prlimit64`, `getrlimit` and `setrlimit`: the caller's limits
/// (`proc.Limits`). The memory limit is `RLIMIT_DATA` (in bytes, whole
/// pages), the descriptor limit `RLIMIT_NOFILE`, the descendant limit
/// `RLIMIT_NPROC`; the others are kept and reported as they are set, and
/// not enforced. A limit may be set up to its ceiling, and the ceiling
/// lowered and never raised (`EPERM`). `EINVAL` for an unknown resource,
/// or a value above its ceiling; `ESRCH` for another process; `EFAULT`.
fn sysPrlimit(pid: u64, resource_arg: u64, new: u64, old: u64) u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    if (pid != 0 and pid != p.pid) return err(.SRCH);
    if (resource_arg >= abi.RLIMIT.COUNT) return err(.INVAL);
    const resource: u32 = @intCast(resource_arg);
    const enforced = p.limits.get(resource);
    const now = enforced orelse p.other_limits[resource];
    if (new != 0) {
        const want = fromUser(abi.RLimit, new) orelse return err(.FAULT);
        if (want.cur > want.max) return err(.INVAL);
        if (want.max > now.max) return err(.PERM);
        // The descriptor table holds no more than `MAX_FILES`.
        if (resource == abi.RLIMIT.NOFILE and want.max > proc.MAX_FILES) return err(.PERM);
        if (enforced != null) p.limits.set(resource, want) else p.other_limits[resource] = want;
    }
    if (old != 0 and !toUser(old, now)) return err(.FAULT);
    return 0;
}

/// `kill`: send `sig` to the process `pid`, which must be the caller's
/// own: other processes cannot be reached yet. Signal 0 only checks that
/// it exists. `EINVAL` for a number above 64, `ESRCH`.
fn sysKill(pid_arg: u64, sig: u64) u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    if (sig > abi.NSIG) return err(.INVAL);
    const pid: i64 = @as(i32, @truncate(@as(i64, @bitCast(pid_arg))));
    if (pid == -1) {
        // Everyone but init and the caller; then the caller too, as Linux.
        const n = proc.signalAll(@intCast(sig), p);
        if (sig != 0) proc.signalProcess(p, @intCast(sig));
        return if (n == 0 and sig != 0) 0 else 0;
    }
    // A process group: the caller's for 0.
    if (pid <= 0) {
        const g: u64 = if (pid == 0) proc.groupOf(0, .group).? else @intCast(-pid);
        return if (proc.signalGroup(g, @intCast(sig)) == 0) err(.SRCH) else 0;
    }
    return switch (proc.signalPid(@intCast(pid), @intCast(sig))) {
        .sent, .zombie => 0,
        .no_such => err(.SRCH),
        .full => err(.AGAIN),
    };
}

/// `tgkill`'s sending, from the caller (`SI_TKILL`). A real-time signal
/// that cannot be queued is lost (Linux: `EAGAIN`).
fn sendTkillLocked(p: *proc.Process, t: *thread.Thread, sig: u32) void {
    signal.sendFromCallerLocked(p, t, sig) catch {};
}

/// `tgkill` and `tkill`: send `sig` to the thread `tid` of the process
/// `tgid` (the caller's own). `ESRCH` for a thread that is not one of it.
fn sysTgkill(tgid: u64, tid: u64, sig: u64) u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    if (sig > abi.NSIG) return err(.INVAL);
    if (tgid != p.pid) return err(.SRCH);
    if (sig == 0) return if (proc.hasThread(p, tid)) 0 else err(.SRCH);
    return if (proc.withThread(p, tid, sendTkillLocked, @intCast(sig))) 0 else err(.SRCH);
}

/// `rt_sigpending`: the signals waiting for the calling thread that it
/// blocks.
fn sysSigPending(set: u64, size: u64) u64 {
    if (size != abi.SIGSET_SIZE) return err(.INVAL);
    const t = thread.current();
    const bits = signal.pendingSet(t) & t.signal_mask;
    return if (toUser(set, bits)) 0 else err(.FAULT);
}

/// `rt_sigsuspend` (and `pause`, with no `mask`): wait, with `mask`
/// blocked instead of the thread's own, until a signal is handled; the
/// own mask is back when the handler returns. Always `EINTR`.
fn sysSigSuspend(mask_ptr: u64, size: u64) u64 {
    if (size != abi.SIGSET_SIZE) return err(.INVAL);
    const t = thread.current();
    if (mask_ptr != 0) {
        const mask = fromUser(u64, mask_ptr) orelse return err(.FAULT);
        t.signal_saved_mask = t.signal_mask;
        t.signal_mask = mask & ~signal.UNBLOCKABLE;
    }
    while (!thread.interrupted()) _ = timer.sleepTicksKillable(timer.HZ);
    return err(.INTR);
}

/// `membarrier`: have every CPU that runs a thread of this process pass a
/// memory barrier before the call returns, so that such a thread has seen
/// what the caller wrote before it. Runtimes with a garbage collector use
/// it instead of making every thread pay for a barrier of its own (.NET's
/// collector on every collection). Only the CPUs that have the process's
/// address space loaded and are not idle are interrupted, as on Linux: a
/// CPU that loads it later passes a barrier on the way (CR3 is
/// serializing). `EINVAL` for a command that is not offered.
fn sysMembarrier(command: u64, flags: u64) u64 {
    if (flags != 0) return err(.INVAL);
    return switch (command) {
        abi.MEMBARRIER.QUERY => abi.MEMBARRIER.PRIVATE_EXPEDITED | abi.MEMBARRIER.REGISTER_PRIVATE_EXPEDITED,
        abi.MEMBARRIER.REGISTER_PRIVATE_EXPEDITED => 0,
        abi.MEMBARRIER.PRIVATE_EXPEDITED => blk: {
            const p = thread.current().process orelse break :blk err(.NOSYS);
            ipi.broadcastTo(.barrier, p.root);
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

/// `statfs`: the filesystems are in memory; `/proc`, `/sys` and
/// `/sys/fs/cgroup` say they are what Linux's are (`procfs.fsMagic`),
/// which is how a runtime finds control groups (v2) to read its limits
/// from. `ENOENT` for a path that does not exist.
fn sysStatfs(path_ptr: u64, ptr: u64) u64 {
    var given = switch (Path.from(CWD, path_ptr)) {
        .path => |p| p,
        .fail => |e| return e,
    };
    defer given.deinit();
    const path = given.text;
    if (named(path) == .none) return missing(path);
    const st: abi.StatFs = .{ .type = procfs.fsMagic(path) };
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
    const p = thread.current().process orelse return err(.NOSYS);
    if (len != 0 and !user_memory.isCovered(p, addr, len)) return err(.NOMEM); // not all mapped
    return 0;
}

/// The memory calls (`user_memory.zig`), for the calling thread's process.
fn memory(comptime call: enum { mmap, mprotect, munmap, mremap, brk, madvise }, f: *const arch.Frame) u64 {
    const p = thread.current().process orelse return err(.NOSYS);
    return switch (call) {
        .mmap => blk: {
            if (f.r9 % 4096 != 0) break :blk err(.INVAL); // checked for every mapping, as on Linux
            // The descriptor and the offset only mean something for a file.
            if (f.r10 & abi.MAP.ANONYMOUS != 0) break :blk user_memory.mmap(p, f.rdi, f.rsi, f.rdx, f.r10, null);
            const of = getFile(f.r8) orelse break :blk err(.BADF);
            defer putFile(of); // the mapping keeps the file, not the descriptor
            // A file that can change or go away cannot be mapped: a page
            // fault is handled where its filesystem's lock cannot be taken.
            // A memory object can (`memfd.zig`): it has a lock of its own.
            if (of.kind != .file or of.generated != null) break :blk err(.NODEV);
            if (vfs.isCounted(&of.node) and memfd.fromNode(&of.node) == null) break :blk err(.NODEV);
            if (!of.readable) break :blk err(.ACCES);
            break :blk user_memory.mmap(p, f.rdi, f.rsi, f.rdx, f.r10, .{ .node = of.node, .offset = f.r9, .writable = of.writable });
        },
        .mprotect => user_memory.mprotect(p, f.rdi, f.rsi, f.rdx),
        .munmap => user_memory.munmap(p, f.rdi, f.rsi),
        .mremap => user_memory.mremap(p, f.rdi, f.rsi, f.rdx, f.r10, f.r8),
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
    const number = f.rax;
    const start = kstats.syscallStart(number);
    dispatchCall(f);
    if (start) |t| kstats.syscallEnd(number, t); // a call that waits counts its wait
}

/// Log every system call of every program, with its first three arguments
/// when it starts and its result when it returns (calls that wait show
/// where a program is stuck). For finding out what a program does; off
/// by default.
pub var trace_all: bool = false;

fn dispatchCall(f: *arch.Frame) void {
    // It replaces every register, RAX included, with what the frame of
    // the signal handler that is returning says.
    if (f.rax == Sys.rt_sigreturn) {
        if (thread.current().process == null) {
            f.rax = err(.NOSYS);
            return;
        }
        return signal.sigreturn(f);
    }
    f.rax = switch (f.rax) {
        Sys.read => sysRead(f.rdi, f.rsi, f.rdx),
        Sys.write => sysWrite(f.rdi, f.rsi, f.rdx),
        Sys.open => sysOpenAt(CWD, f.rdi, f.rsi),
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
        Sys.stat => sysNewfstatat(CWD, f.rdi, f.rsi, 0),
        Sys.lstat => sysNewfstatat(CWD, f.rdi, f.rsi, abi.AT_SYMLINK_NOFOLLOW),
        Sys.unlink => sysUnlink(CWD, f.rdi, 0),
        Sys.rmdir => sysUnlink(CWD, f.rdi, abi.AT_REMOVEDIR),
        Sys.unlinkat => sysUnlink(f.rdi, f.rsi, f.rdx),
        Sys.mkdir => sysMkdir(CWD, f.rdi),
        Sys.mkdirat => sysMkdir(f.rdi, f.rsi),
        Sys.rename => sysRename(CWD, f.rdi, CWD, f.rsi, 0),
        Sys.renameat => sysRename(f.rdi, f.rsi, f.rdx, f.r10, 0),
        Sys.renameat2 => sysRename(f.rdi, f.rsi, f.rdx, f.r10, f.r8),
        Sys.mknodat => sysMknod(f.rdi, f.rsi, f.rdx),
        Sys.fchmod => sysFchmod(f.rdi),
        Sys.pwrite64 => sysPwrite(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.readv => sysReadv(f.rdi, f.rsi, f.rdx),
        Sys.preadv => sysPreadv(f.rdi, f.rsi, f.rdx, f.r10, false),
        Sys.pwritev => sysPreadv(f.rdi, f.rsi, f.rdx, f.r10, true),
        Sys.preadv2 => if (f.r9 != 0) err(.OPNOTSUPP) else if (f.r10 == std.math.maxInt(u64)) sysReadv(f.rdi, f.rsi, f.rdx) else sysPreadv(f.rdi, f.rsi, f.rdx, f.r10, false),
        Sys.pwritev2 => if (f.r9 != 0) err(.OPNOTSUPP) else if (f.r10 == std.math.maxInt(u64)) sysWritev(f.rdi, f.rsi, f.rdx) else sysPreadv(f.rdi, f.rsi, f.rdx, f.r10, true),
        Sys.statx => sysStatx(f.rdi, f.rsi, f.rdx, f.r10, f.r8),
        Sys.truncate => sysTruncate(f.rdi, f.rsi),
        // Nothing is ever waiting to be written.
        Sys.fsync, Sys.fdatasync => if (isOpen(f.rdi)) 0 else err(.BADF),
        Sys.ftruncate => sysFtruncate(f.rdi, f.rsi),
        // No networking yet (12): every address family is unsupported.
        Sys.socket => err(.AFNOSUPPORT),
        // Not offered yet; a runtime that wants one for mapping its
        // compiled code twice (writable here, executable there) maps it
        // once instead.
        Sys.memfd_create => sysMemfdCreate(f.rdi, f.rsi),
        Sys.access => sysAccess(CWD, f.rdi, f.rsi),
        Sys.faccessat => sysAccess(f.rdi, f.rsi, f.rdx),
        // Its flags: AT_EACCESS (no users: the same), AT_SYMLINK_NOFOLLOW,
        // AT_EMPTY_PATH.
        Sys.faccessat2 => if (f.r10 & ~@as(u64, 0x200 | abi.AT_SYMLINK_NOFOLLOW | abi.AT_EMPTY_PATH) != 0) err(.INVAL) else sysAccess(f.rdi, f.rsi, f.rdx),
        Sys.readlink => sysReadlink(CWD, f.rdi, f.rsi, f.rdx),
        Sys.readlinkat => sysReadlink(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.getcwd => sysGetcwd(f.rdi, f.rsi),
        Sys.chdir => sysChdir(f.rdi),
        Sys.fchdir => sysFchdir(f.rdi),
        Sys.getdents64 => sysGetdents64(f.rdi, f.rsi, f.rdx),
        Sys.set_robust_list => sysSetRobustList(f.rdi, f.rsi),
        Sys.rseq => sysRseq(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.getcpu => sysGetcpu(f.rdi, f.rsi),
        Sys.eventfd => sysEventFd(f.rdi, 0),
        Sys.flock => sysFlock(f.rdi, f.rsi),
        Sys.rt_sigqueueinfo => sysSigQueueInfo(f.rdi, null, f.rsi, f.rdx),
        Sys.rt_tgsigqueueinfo => sysSigQueueInfo(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.rt_sigtimedwait => sysSigTimedWait(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.signalfd => sysSignalfd(f.rdi, f.rsi, f.rdx, 0),
        Sys.signalfd4 => sysSignalfd(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.eventfd2 => sysEventFd(f.rdi, f.rsi),
        Sys.epoll_create => if (@as(i32, @truncate(@as(i64, @bitCast(f.rdi)))) <= 0) err(.INVAL) else sysEpollCreate(0),
        Sys.epoll_create1 => sysEpollCreate(f.rdi),
        Sys.epoll_ctl => sysEpollCtl(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.epoll_wait => sysEpollWait(f.rdi, f.rsi, f.rdx, @as(i32, @truncate(@as(i64, @bitCast(f.r10)))), 0, 0),
        Sys.epoll_pwait => sysEpollWait(f.rdi, f.rsi, f.rdx, @as(i32, @truncate(@as(i64, @bitCast(f.r10)))), f.r8, f.r9),
        Sys.epoll_pwait2 => blk: {
            // The timeout as a timespec, or null for ever.
            var ms: i64 = -1;
            if (f.r10 != 0) {
                const ts = fromUser(abi.TimeSpec, f.r10) orelse break :blk err(.FAULT);
                if (ts.sec < 0 or ts.nsec < 0 or ts.nsec >= 1_000_000_000) break :blk err(.INVAL);
                ms = @min(ts.sec, 1 << 40) * 1000 + @divTrunc(ts.nsec + 999_999, 1_000_000);
            }
            break :blk sysEpollWait(f.rdi, f.rsi, f.rdx, ms, f.r8, f.r9);
        },
        Sys.pipe => sysPipe(f.rdi, 0),
        Sys.pipe2 => sysPipe(f.rdi, f.rsi),
        Sys.dup => sysDup(f.rdi, 0, false),
        Sys.dup2 => sysDup2(f.rdi, f.rsi, false, false),
        Sys.dup3 => if (f.rdx & ~@as(u64, abi.O.CLOEXEC) != 0) err(.INVAL) else sysDup2(f.rdi, f.rsi, true, f.rdx & abi.O.CLOEXEC != 0),
        Sys.nanosleep => sysSleep(abi.CLOCK.MONOTONIC, false, f.rdi, f.rsi),
        Sys.clock_nanosleep => sysSleep(f.rdi, f.rsi & 1 != 0, f.rdx, f.r10),
        Sys.clock_gettime => sysClockGetTime(f.rdi, f.rsi),
        Sys.gettimeofday => sysGetTimeOfDay(f.rdi),
        Sys.getpid => if (thread.current().process) |p| p.pid else err(.NOSYS),
        Sys.clone => sysClone(f),
        Sys.fork => newProcess(f, .{ .flags = 0, .stack = 0, .parent_tid = 0, .child_tid = 0, .tls = 0 }, abi.SIGCHLD),
        Sys.vfork => newProcess(f, .{ .flags = proc.CLONE.VM | proc.CLONE.VFORK, .stack = 0, .parent_tid = 0, .child_tid = 0, .tls = 0 }, abi.SIGCHLD),
        Sys.wait4 => sysWait4(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.waitid => sysWaitid(f.rdi, f.rsi, f.rdx, f.r10, f.r8),
        Sys.symlink => sysSymlink(f.rdi, CWD, f.rsi),
        Sys.symlinkat => sysSymlink(f.rdi, f.rsi, f.rdx),
        Sys.link => sysLink(CWD, f.rdi, CWD, f.rsi, 0),
        Sys.linkat => sysLink(f.rdi, f.rsi, f.rdx, f.r10, f.r8),
        Sys.utimensat => sysUtimensat(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.fallocate => sysFallocate(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.fadvise64 => sysFadvise(f.rdi, f.r10),
        Sys.sendfile => sysSendfile(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.copy_file_range => sysCopyFileRange(f.rdi, f.rsi, f.rdx, f.r10, f.r8, f.r9),
        Sys.getrusage => sysGetrusage(f.rdi, f.rsi),
        Sys.getpriority => sysGetpriority(f.rdi, f.rsi),
        Sys.setpriority => sysSetpriority(f.rdi, f.rsi, f.rdx),
        Sys.execve => sysExecve(f, CWD, f.rdi, f.rsi, f.rdx),
        Sys.execveat => if (f.r8 != 0) err(.INVAL) else sysExecve(f, f.rdi, f.rsi, f.rdx, f.r10),
        Sys.getppid => if (thread.current().process) |me| proc.parentPid(me) else err(.NOSYS),
        Sys.clone3 => sysClone3(f),
        Sys.sched_setaffinity => sysSchedSetAffinity(f.rdi, f.rsi, f.rdx),
        Sys.sched_getscheduler => sysSchedPolicy(.get_policy, f),
        Sys.sched_getparam => sysSchedPolicy(.get_param, f),
        Sys.sched_setscheduler => sysSchedPolicy(.set_policy, f),
        Sys.sched_setparam => sysSchedPolicy(.set_param, f),
        Sys.sched_get_priority_max, Sys.sched_get_priority_min => sysSchedPriorityRange(f.rdi),
        Sys.getsid => sysGetsid(f.rdi),
        Sys.setpgid => if (thread.current().process == null) err(.NOSYS) else sysSetpgid(f.rdi, f.rsi),
        Sys.getpgid => if (thread.current().process == null) err(.NOSYS) else proc.groupOf(f.rdi, .group) orelse err(.SRCH),
        Sys.getpgrp => if (thread.current().process == null) err(.NOSYS) else proc.groupOf(0, .group).?,
        Sys.setsid => if (thread.current().process == null) err(.NOSYS) else proc.newSession() catch err(.PERM),
        Sys.time => sysTime(f.rdi),
        Sys.futex => sysFutex(f),
        Sys.sched_getaffinity => if (schedTarget(f.rdi)) |e| e else sysSchedGetAffinity(f.rsi, f.rdx),
        // GRND_NONBLOCK, GRND_RANDOM, GRND_INSECURE: the generator never
        // blocks, so they change nothing.
        Sys.getrandom => if (f.rdx & ~@as(u64, 7) != 0) err(.INVAL) else sysGetRandom(f.rdi, f.rsi),
        Sys.uname => sysUname(f.rdi),
        Sys.prlimit64 => sysPrlimit(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.getrlimit => sysPrlimit(0, f.rdi, 0, f.rsi),
        Sys.setrlimit => sysPrlimit(0, f.rdi, f.rsi, 0),
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
        Sys.tgkill => sysTgkill(f.rdi, f.rsi, f.rdx),
        Sys.tkill => if (thread.current().process) |p| sysTgkill(p.pid, f.rdi, f.rsi) else err(.NOSYS),
        Sys.rt_sigpending => sysSigPending(f.rdi, f.rsi),
        Sys.rt_sigsuspend => sysSigSuspend(f.rdi, f.rsi),
        Sys.pause => sysSigSuspend(0, abi.SIGSET_SIZE),
        Sys.poll => sysPoll(f.rdi, f.rsi, f.rdx),
        Sys.rt_sigaction => sysSigAction(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.rt_sigprocmask => sysSigProcMask(f.rdi, f.rsi, f.rdx, f.r10),
        Sys.sigaltstack => sysSigAltStack(f.rdi, f.rsi),
        Sys.mmap => memory(.mmap, f),
        Sys.mprotect => memory(.mprotect, f),
        Sys.munmap => memory(.munmap, f),
        Sys.brk => memory(.brk, f),
        Sys.madvise => memory(.madvise, f),
        Sys.ioctl => sysIoctl(f.rdi, f.rsi, f.rdx),
        Sys.writev => sysWritev(f.rdi, f.rsi, f.rdx),
        Sys.arch_prctl => sysArchPrctl(f.rdi, f.rsi),
        Sys.set_tid_address => sysSetTidAddress(f.rdi),
        Sys.exit => proc.exitThread(abi.exitStatus(f.rdi)),
        Sys.exit_group => proc.exit(abi.exitStatus(f.rdi)),
        Sys.gettid => thread.id(),
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
    proc.exitForFault(abi.SIGSEGV);
}

/// Enable the `syscall` instruction, which the arch layer routes to
/// `dispatch`. Called once during boot.
pub fn init() void {
    arch.init();
}
