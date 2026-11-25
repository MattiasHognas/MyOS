//! Virtual filesystem layer.
//!
//! Filesystems are mounted at paths: one at "/", others below it (`mount`).
//! A path goes to the filesystem mounted at its longest matching prefix,
//! which is asked with the rest of the path. Filesystems turn paths into
//! `Node`s for files, say which paths are directories, and list them. All
//! paths here are absolute and normalized (`normalize`): no "." or "..",
//! no doubled or trailing slashes.
//!
//! This module has no kernel dependencies, so it is also tested natively
//! on the host.

const std = @import("std");

/// What can go wrong with a path or a file. `syscall.zig` gives each its
/// Linux error number.
pub const Error = error{
    /// Nothing has that name.
    NotFound,
    /// A part of the path that has to be a directory is not one.
    NotDirectory,
    /// A directory where a file is needed.
    IsDirectory,
    /// The path or one of its parts is too long.
    NameTooLong,
};

/// Longest name of one file or directory, as on Linux.
pub const NAME_MAX = 255;

const Mount = struct {
    /// Where it is mounted: "/" or a normalized path. Not copied.
    path: []const u8,
    fs: Fs,
};

/// More mounts than a small system has; the table is searched in full
/// for every path.
pub const MAX_MOUNTS = 8;
var mounts: [MAX_MOUNTS]?Mount = @splat(null);

/// What is in a directory, one entry at a time.
pub const DirEntry = struct {
    /// In the buffer the caller gave.
    name: []const u8,
    kind: enum { file, directory },
};

/// A file as the rest of the kernel sees it.
pub const Node = struct {
    /// File size in bytes.
    size: u64,
    /// Filesystem-specific data (e.g. a pointer to the file contents).
    ctx: usize,
    /// Operations implemented by the node's filesystem.
    ops: *const Ops,
};

/// Operations a filesystem implements for its nodes.
pub const Ops = struct {
    /// Copy up to `buf.len` bytes starting at `offset` into `buf`. Returns the
    /// number of bytes copied, or 0 at or past the end of the file.
    read: *const fn (node: *const Node, offset: u64, buf: []u8) usize,
};

/// A mounted filesystem: turns paths into nodes.
pub const Fs = struct {
    /// Filesystem-specific state passed back to `lookup`.
    ctx: *anyopaque,
    /// Return the node for `path`, or null if it doesn't exist.
    lookup: *const fn (ctx: *anyopaque, path: []const u8) ?Node,
    /// Whether `path` is a directory. A filesystem without the function
    /// has none but its root.
    is_dir: ?*const fn (ctx: *anyopaque, path: []const u8) bool = null,
    /// The next entry of the directory `dir` after the place `cookie`
    /// stands for (0: the first), with its name in `name_buf`; null at the
    /// end. `cookie` is moved past the entry returned; what it means is
    /// the filesystem's business, as long as it stays below 2^63. A
    /// filesystem without the function has only empty directories.
    next: ?*const fn (ctx: *anyopaque, dir: []const u8, cookie: *u64, name_buf: []u8) ?DirEntry = null,
};

/// Mount `fs` as the root filesystem, replacing any previous one. The
/// kernel calls this once during boot.
pub fn mountRoot(fs: Fs) void {
    for (&mounts) |*slot| {
        if (slot.*) |m| {
            if (m.path.len == 1) slot.* = null;
        }
    }
    mount("/", fs) catch unreachable; // a slot was just freed, or none was taken
}

/// Mount `fs` at `path`, which must be normalized and stay valid. Paths
/// at and below it go to `fs` from now on, whatever was there before.
pub fn mount(path: []const u8, fs: Fs) error{TooManyMounts}!void {
    for (&mounts) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .path = path, .fs = fs };
            return;
        }
    }
    return error.TooManyMounts;
}

/// Remove every mount: for tests.
pub fn unmountAll() void {
    mounts = @splat(null);
}

/// Whether `path` is `dir` or below it. Both normalized.
fn within(path: []const u8, dir: []const u8) bool {
    if (dir.len == 1) return true; // everything is below "/"
    return std.mem.startsWith(u8, path, dir) and (path.len == dir.len or path[dir.len] == '/');
}

/// The filesystem `path` belongs to and the path inside it (which starts
/// with a slash; the mount point itself is "/").
fn resolve(path: []const u8) ?struct { fs: Fs, rest: []const u8, skipped: usize } {
    if (path.len == 0 or path[0] != '/') return null;
    var best: ?Mount = null;
    for (mounts) |slot| {
        const m = slot orelse continue;
        if (within(path, m.path) and (best == null or m.path.len > best.?.path.len)) best = m;
    }
    const m = best orelse return null;
    // How much of a path the mount point takes: nothing for the root.
    const skipped = if (m.path.len == 1) 0 else m.path.len;
    const rest = path[skipped..];
    return .{ .fs = m.fs, .rest = if (rest.len == 0) "/" else rest, .skipped = skipped };
}

/// Look up the file at `path`. Returns null if there is none (or it is a
/// directory, or nothing is mounted).
pub fn lookup(path: []const u8) ?Node {
    const at = resolve(path) orelse return null;
    return at.fs.lookup(at.fs.ctx, at.rest);
}

/// Whether `path` is a directory: a mount point, something a mount point
/// is below, or what its filesystem says is one.
pub fn isDirectory(path: []const u8) bool {
    const at = resolve(path) orelse return false;
    if (at.rest.len == 1) return true; // the root of a filesystem
    for (mounts) |slot| {
        const m = slot orelse continue;
        if (m.path.len > path.len and within(m.path, path)) return true;
    }
    const is_dir = at.fs.is_dir orelse return false;
    return is_dir(at.fs.ctx, at.rest);
}

/// The name mount `index` puts into the directory `dir`: the part of its
/// path right after `dir`, whether the mount point is that or lies
/// further down. Null if there is no such mount or it is not below `dir`.
fn mountNameIn(index: usize, dir: []const u8) ?[]const u8 {
    const m = mounts[index] orelse return null;
    if (m.path.len <= dir.len or !within(m.path, dir)) return null;
    const rest = m.path[(if (dir.len == 1) 1 else dir.len + 1)..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
}

/// Set in a listing's cookie once the filesystem's own entries are done
/// and the mount points directly in the directory follow.
const MOUNTS_PHASE: u64 = 1 << 63;

/// The next entry of the directory `dir`: see `Fs.next`. After the
/// filesystem's own entries come the directories that mounts put into
/// `dir` (a mount point, or the way to one) and that the filesystem does
/// not have itself. Start with `cookie` 0.
pub fn next(dir: []const u8, cookie: *u64, name_buf: []u8) ?DirEntry {
    const at = resolve(dir) orelse return null;
    if (cookie.* & MOUNTS_PHASE == 0) {
        if (at.fs.next) |next_fn| {
            if (next_fn(at.fs.ctx, at.rest, cookie, name_buf)) |entry| return entry;
        }
        cookie.* = MOUNTS_PHASE;
    }
    var index: usize = @intCast(cookie.* & ~MOUNTS_PHASE);
    while (index < mounts.len) {
        defer index += 1;
        const name = mountNameIn(index, dir) orelse continue;
        if (name.len > name_buf.len) continue;
        // Once only: not if a mount earlier in the table gives the same
        // name, nor if the filesystem has listed a directory of that name.
        var seen = false;
        for (0..index) |earlier| {
            if (mountNameIn(earlier, dir)) |other| seen = seen or std.mem.eql(u8, other, name);
        }
        if (seen) continue;
        if (at.fs.is_dir) |is_dir| {
            const end = @intFromPtr(name.ptr) + name.len - @intFromPtr(mounts[index].?.path.ptr);
            if (is_dir(at.fs.ctx, mounts[index].?.path[at.skipped..end])) continue;
        }
        @memcpy(name_buf[0..name.len], name);
        cookie.* = MOUNTS_PHASE | (index + 1);
        return .{ .name = name_buf[0..name.len], .kind = .directory };
    }
    cookie.* = MOUNTS_PHASE | mounts.len;
    return null;
}

/// Make an absolute, normalized path of `path` in `out`: relative to the
/// directory `base` (itself normalized) unless it starts with a slash,
/// with "." and empty parts dropped and ".." taking the part before it
/// away (at the root it does nothing). The result has no slash at its
/// end; the root is "/".
///
/// `error.NotFound` for an empty path, as Linux has it;
/// `error.NameTooLong` if the result does not fit `out` or a part is
/// longer than `NAME_MAX`.
pub fn normalize(out: []u8, base: []const u8, path: []const u8) Error![]const u8 {
    if (path.len == 0) return error.NotFound;
    var len: usize = 0;
    if (path[0] != '/' and base.len > 1) {
        if (base.len > out.len) return error.NameTooLong;
        @memcpy(out[0..base.len], base);
        len = base.len;
    }
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            len = std.mem.lastIndexOfScalar(u8, out[0..len], '/') orelse 0;
            continue;
        }
        if (part.len > NAME_MAX or len + 1 + part.len > out.len) return error.NameTooLong;
        out[len] = '/';
        @memcpy(out[len + 1 ..][0..part.len], part);
        len += 1 + part.len;
    }
    if (len == 0) {
        if (out.len == 0) return error.NameTooLong;
        out[0] = '/';
        len = 1;
    }
    return out[0..len];
}

/// Read up to `buf.len` bytes from `node` starting at `offset`. Returns the
/// number of bytes read, or 0 if `offset` is at or beyond the end of the file.
pub fn read(node: *const Node, offset: u64, buf: []u8) usize {
    return node.ops.read(node, offset, buf);
}
