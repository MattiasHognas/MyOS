//! The filesystem in memory as the kernel mounts it (at `/tmp`):
//! `ramfs.zig` with pages for its blocks and one lock around it.
//!
//! The lock is a mutex: an operation here may allocate and copy, and the
//! threads that wait for it sleep. So none of this may be called with a
//! spinlock held or from an interrupt handler; system calls and process
//! start are where it is called from. A file's pages cannot be mapped
//! into a program (`mmap`): a page fault is handled under a spinlock.
//!
//! It may hold half of the machine's memory, as Linux's tmpfs does by
//! default. What it holds is not charged to any process yet.

const std = @import("std");

const heap = @import("../heap.zig");
const Mutex = @import("../sync/mutex.zig").Mutex;
const pmm = @import("../pmm.zig");
const ramfs = @import("ramfs.zig");
const vfs = @import("../vfs.zig");

const PageBlocks = struct {
    pub fn alloc() ?*[ramfs.BLOCK]u8 {
        const phys = pmm.alloc() orelse return null;
        return @ptrCast(pmm.physToVirt(phys));
    }

    pub fn free(block: *[ramfs.BLOCK]u8) void {
        pmm.free(pmm.virtToPhys(@intFromPtr(block)));
    }
};

const Fs = ramfs.RamFs(PageBlocks);

var lock: Mutex = .{};
var fs: Fs = undefined;

const ops = vfs.Ops{
    .read = read,
    .write = write,
    .truncate = truncate,
    .size = size,
    .retain = retain,
    .release = release,
};

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
    };
}

/// Blocks in use, for tests.
pub fn blocksUsed() usize {
    lock.lock();
    defer lock.unlock();
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
    lock.lock();
    defer lock.unlock();
    return nodeOf(fs.open(path) catch return null);
}

fn isDirectory(_: *anyopaque, path: []const u8) bool {
    lock.lock();
    defer lock.unlock();
    const info = fs.info(path) orelse return false;
    return info.kind == .directory;
}

fn next(_: *anyopaque, dir: []const u8, cookie: *u64, name_buf: []u8) ?vfs.DirEntry {
    lock.lock();
    defer lock.unlock();
    const entry = fs.next(dir, cookie, name_buf) orelse return null;
    return .{ .name = entry.name, .kind = switch (entry.kind) {
        .directory => .directory,
        .file => .file,
        .fifo => .fifo,
    } };
}

fn create(_: *anyopaque, path: []const u8) vfs.Error!vfs.Node {
    lock.lock();
    defer lock.unlock();
    return nodeOf(fs.create(path) catch |e| return toVfs(e));
}

fn fifoAt(_: *anyopaque, path: []const u8) ?u64 {
    lock.lock();
    defer lock.unlock();
    return fs.fifoAt(path);
}

fn mkfifo(_: *anyopaque, path: []const u8, id: u64) vfs.Error!void {
    lock.lock();
    defer lock.unlock();
    return fs.mkfifo(path, id) catch |e| toVfs(e);
}

fn mkdir(_: *anyopaque, path: []const u8) vfs.Error!void {
    lock.lock();
    defer lock.unlock();
    return fs.mkdir(path) catch |e| toVfs(e);
}

fn unlink(_: *anyopaque, path: []const u8) vfs.Error!void {
    lock.lock();
    defer lock.unlock();
    return fs.unlink(path) catch |e| toVfs(e);
}

fn rmdir(_: *anyopaque, path: []const u8) vfs.Error!void {
    lock.lock();
    defer lock.unlock();
    return fs.rmdir(path) catch |e| toVfs(e);
}

fn rename(_: *anyopaque, old: []const u8, new: []const u8) vfs.Error!void {
    lock.lock();
    defer lock.unlock();
    return fs.rename(old, new) catch |e| toVfs(e);
}

fn read(node: *const vfs.Node, offset: u64, buf: []u8) usize {
    lock.lock();
    defer lock.unlock();
    return fs.read(fileOf(node), offset, buf);
}

fn write(node: *const vfs.Node, offset: u64, data: []const u8) vfs.Error!usize {
    lock.lock();
    defer lock.unlock();
    return fs.write(fileOf(node), offset, data) catch |e| toVfs(e);
}

fn truncate(node: *const vfs.Node, new_size: u64) vfs.Error!void {
    lock.lock();
    defer lock.unlock();
    return fs.truncate(fileOf(node), new_size) catch |e| toVfs(e);
}

fn size(node: *const vfs.Node) u64 {
    lock.lock();
    defer lock.unlock();
    return fileOf(node).size;
}

fn retain(node: *const vfs.Node) void {
    lock.lock();
    defer lock.unlock();
    fs.retain(fileOf(node));
}

fn release(node: *const vfs.Node) void {
    lock.lock();
    defer lock.unlock();
    fs.release(fileOf(node));
}
