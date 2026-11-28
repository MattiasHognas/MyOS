//! The filesystem in memory as the kernel mounts it (at `/tmp`):
//! `ramfs.zig` with pages for its blocks and one lock around it.
//!
//! The lock is a spinlock (rank `memory_object`): what is done under it
//! allocates and copies within the kernel and never waits, and a page
//! fault of a mapping of a file here takes it. A file's blocks are pages
//! of the page allocator: a shared mapping maps them themselves (one
//! more owner each, `pmm.share`), so a block freed by the file stays
//! while a mapping has it.
//!
//! It may hold half of the machine's memory, as Linux's tmpfs does by
//! default. What it holds is not charged to any process yet.

const std = @import("std");

const heap = @import("../heap.zig");
const SpinLock = @import("../sync/spinlock.zig").SpinLock;
const pmm = @import("../pmm.zig");
const ramfs = @import("ramfs.zig");
const vfs = @import("../vfs.zig");
const clock = @import("../clock.zig");

/// The wall clock, for files' times.
fn now() i64 {
    return @intCast(clock.wallNanos());
}

const PageBlocks = struct {
    pub fn alloc() ?*[ramfs.BLOCK]u8 {
        const phys = pmm.alloc() orelse return null;
        return @ptrCast(pmm.physToVirt(phys));
    }

    pub fn free(block: *[ramfs.BLOCK]u8) void {
        // One owner less: a shared mapping may have it still.
        pmm.release(pmm.virtToPhys(@intFromPtr(block)));
    }
};

const Fs = ramfs.RamFs(PageBlocks);

/// A spinlock, not a mutex: a page fault of a shared mapping of a file
/// here takes it (under the address-space lock), and nothing done under
/// it sleeps (it allocates and copies within the kernel). The rank of a
/// memory object's lock, which it is to a mapping; the two never nest.
var lock: SpinLock = .{ .rank = .memory_object };
var fs: Fs = undefined;

const ops = vfs.Ops{
    .read = read,
    .write = write,
    .truncate = truncate,
    .size = size,
    .retain = retain,
    .release = release,
    .meta = meta,
    .set_times = setTimes,
    .map_page = mapPage,
    .hold_map = holdMap,
    .set_mode = setNodeMode,
};

fn setNodeMode(node: *const vfs.Node, mode: u16) vfs.Error!void {
    const held = lock.acquire();
    defer lock.release(held);
    const f = fileOf(node);
    f.mode = mode & 0o7777;
    f.ctime = now();
}

fn modeOf(_: *anyopaque, path: []const u8) ?u16 {
    if (path.len == 1) return 0o1777; // the mount point, as Linux's /tmp: anyone, sticky
    const held = lock.acquire();
    defer lock.release(held);
    return fs.modeOf(path);
}

fn setMode(_: *anyopaque, path: []const u8, mode: u16) vfs.Error!void {
    const held = lock.acquire();
    defer lock.release(held);
    fs.setMode(path, mode) catch |e| return toVfs(e);
    if (fs.fileAt(path)) |f| f.ctime = now();
}

/// The block at `offset` of the file, as a page for a shared mapping:
/// made (zeroed) where there is none, with one more owner for the
/// mapping. Past the end (rounded up to a page): `error.PastEnd`.
fn mapPage(node: *const vfs.Node, offset: u64) vfs.MapError!u64 {
    const held = lock.acquire();
    defer lock.release(held);
    const f = fileOf(node);
    if (offset >= std.mem.alignForward(u64, f.size, ramfs.BLOCK)) return error.PastEnd;
    const block = fs.blockAt(f, @intCast(offset / ramfs.BLOCK)) catch return error.OutOfMemory;
    const phys = pmm.virtToPhys(@intFromPtr(block));
    if (!pmm.share(phys)) return error.OutOfMemory;
    return phys;
}

/// A mapping's region holds the file as an open file does.
fn holdMap(node: *const vfs.Node, take: bool, _: bool) void {
    if (take) retain(node) else release(node);
}

/// The filesystem, empty, to be mounted. Call once.
pub fn init() vfs.Fs {
    fs = .{ .gpa = heap.allocator, .blocks_max = pmm.totalPages() / 2 };
    return .{
        .ctx = undefined,
        .lookup = lookup,
        .is_dir = isDirectory,
        .next = next,
        .create = create,
        .mkdir = mkdir,
        .unlink = unlink,
        .rmdir = rmdir,
        .rename = rename,
        .fifo_at = fifoAt,
        .mkfifo = mkfifo,
        .readlink = readLink,
        .symlink = symlink,
        .link = link,
        .mode_of = modeOf,
        .set_mode = setMode,
    };
}

/// Blocks in use, for tests.
pub fn blocksUsed() usize {
    const held = lock.acquire();
    defer lock.release(held);
    return fs.blocks_used;
}

fn nodeOf(file: *Fs.File) vfs.Node {
    return .{ .size = file.size, .ctx = @intFromPtr(file), .ops = &ops };
}

fn fileOf(node: *const vfs.Node) *Fs.File {
    return @ptrFromInt(node.ctx);
}

fn toVfs(e: ramfs.Error) vfs.Error {
    return switch (e) {
        error.NotFound => error.NotFound,
        error.NotDirectory => error.NotDirectory,
        error.IsDirectory => error.IsDirectory,
        error.Exists => error.Exists,
        error.NotEmpty => error.NotEmpty,
        error.NoSpace => error.NoSpace,
        error.Invalid => error.Invalid,
        error.TooLarge => error.TooLarge,
    };
}

fn lookup(_: *anyopaque, path: []const u8) ?vfs.Node {
    const held = lock.acquire();
    defer lock.release(held);
    return nodeOf(fs.open(path) catch return null);
}

fn isDirectory(_: *anyopaque, path: []const u8) bool {
    const held = lock.acquire();
    defer lock.release(held);
    const info = fs.info(path) orelse return false;
    return info.kind == .directory;
}

fn next(_: *anyopaque, dir: []const u8, cookie: *u64, name_buf: []u8) ?vfs.DirEntry {
    const held = lock.acquire();
    defer lock.release(held);
    const entry = fs.next(dir, cookie, name_buf) orelse return null;
    return .{ .name = entry.name, .kind = switch (entry.kind) {
        .directory => .directory,
        .file => .file,
        .fifo => .fifo,
        .symlink => .symlink,
    } };
}

fn create(_: *anyopaque, path: []const u8) vfs.Error!vfs.Node {
    const held = lock.acquire();
    defer lock.release(held);
    const f = fs.create(path) catch |e| return toVfs(e);
    const t = now();
    f.atime = t;
    f.mtime = t;
    f.ctime = t;
    return nodeOf(f);
}

fn readLink(_: *anyopaque, path: []const u8, buf: []u8) ?usize {
    const held = lock.acquire();
    defer lock.release(held);
    const target = fs.readlink(path) orelse return null;
    const n = @min(target.len, buf.len);
    @memcpy(buf[0..n], target[0..n]); // copied under the lock: the link may go after
    return target.len;
}

fn symlink(_: *anyopaque, path: []const u8, target: []const u8) vfs.Error!void {
    const held = lock.acquire();
    defer lock.release(held);
    return fs.symlink(path, target) catch |e| toVfs(e);
}

fn link(_: *anyopaque, old: []const u8, new: []const u8) vfs.Error!void {
    const held = lock.acquire();
    defer lock.release(held);
    const f = fs.link(old, new) catch |e| return toVfs(e);
    f.ctime = now();
}

fn meta(node: *const vfs.Node) vfs.Meta {
    const held = lock.acquire();
    defer lock.release(held);
    const f = fileOf(node);
    return .{ .atime = f.atime, .mtime = f.mtime, .ctime = f.ctime, .nlink = f.nlink, .mode = f.mode };
}

fn setTimes(node: *const vfs.Node, atime: ?i64, mtime: ?i64) vfs.Error!void {
    const held = lock.acquire();
    defer lock.release(held);
    const f = fileOf(node);
    if (atime) |t| f.atime = t;
    if (mtime) |t| f.mtime = t;
    f.ctime = now();
}

fn fifoAt(_: *anyopaque, path: []const u8) ?u64 {
    const held = lock.acquire();
    defer lock.release(held);
    return fs.fifoAt(path);
}

fn mkfifo(_: *anyopaque, path: []const u8, id: u64) vfs.Error!void {
    const held = lock.acquire();
    defer lock.release(held);
    return fs.mkfifo(path, id) catch |e| toVfs(e);
}

fn mkdir(_: *anyopaque, path: []const u8) vfs.Error!void {
    const held = lock.acquire();
    defer lock.release(held);
    return fs.mkdir(path) catch |e| toVfs(e);
}

fn unlink(_: *anyopaque, path: []const u8) vfs.Error!void {
    const held = lock.acquire();
    defer lock.release(held);
    if (fs.fileAt(path)) |f| f.ctime = now(); // one name fewer
    return fs.unlink(path) catch |e| toVfs(e);
}

fn rmdir(_: *anyopaque, path: []const u8) vfs.Error!void {
    const held = lock.acquire();
    defer lock.release(held);
    return fs.rmdir(path) catch |e| toVfs(e);
}

fn rename(_: *anyopaque, old: []const u8, new: []const u8) vfs.Error!void {
    const held = lock.acquire();
    defer lock.release(held);
    return fs.rename(old, new) catch |e| toVfs(e);
}

fn read(node: *const vfs.Node, offset: u64, buf: []u8) usize {
    const held = lock.acquire();
    defer lock.release(held);
    return fs.read(fileOf(node), offset, buf);
}

fn write(node: *const vfs.Node, offset: u64, data: []const u8) vfs.Error!usize {
    const held = lock.acquire();
    defer lock.release(held);
    const f = fileOf(node);
    const n = fs.write(f, offset, data) catch |e| return toVfs(e);
    const t = now();
    f.mtime = t;
    f.ctime = t;
    return n;
}

fn truncate(node: *const vfs.Node, new_size: u64) vfs.Error!void {
    const held = lock.acquire();
    defer lock.release(held);
    const f = fileOf(node);
    fs.truncate(f, new_size) catch |e| return toVfs(e);
    const t = now();
    f.mtime = t;
    f.ctime = t;
}

fn size(node: *const vfs.Node) u64 {
    const held = lock.acquire();
    defer lock.release(held);
    return fileOf(node).size;
}

fn retain(node: *const vfs.Node) void {
    const held = lock.acquire();
    defer lock.release(held);
    fs.retain(fileOf(node));
}

fn release(node: *const vfs.Node) void {
    const held = lock.acquire();
    defer lock.release(held);
    fs.release(fileOf(node));
}
