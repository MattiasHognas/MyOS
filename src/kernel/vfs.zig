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
    /// Something has that name already.
    Exists,
    /// A directory that still holds something.
    NotEmpty,
    /// The filesystem is full, or there is no memory for it.
    NoSpace,
    /// The filesystem cannot be changed.
    ReadOnly,
    /// What cannot be done to this file or directory at all: a directory
    /// moved into itself, the root removed.
    Invalid,
    /// Larger than a file can be.
    TooLarge,
    /// A mount point, or what leads to one, cannot be removed or renamed.
    Busy,
    /// A rename from one filesystem to another.
    CrossDevice,
    /// Forbidden for this file (a sealed memory object: `memfd.zig`).
    NotPermitted,
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
    kind: enum { file, directory, symlink, fifo },
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
    /// Write `data` at `offset`, growing the file as needed, and return
    /// the bytes written. Null for a file that cannot be written.
    write: ?*const fn (node: *const Node, offset: u64, data: []const u8) Error!usize = null,
    /// Make the file exactly `size` bytes.
    truncate: ?*const fn (node: *const Node, size: u64) Error!void = null,
    /// The file's size now, for a file whose size changes (`Node.size`
    /// is what it was when the node was made).
    size: ?*const fn (node: *const Node) u64 = null,
    /// A file that can go away while someone uses it is counted: every
    /// node `Fs.lookup` or `Fs.create` hands out holds the file until it
    /// is given to `release`; `retain` makes a second holder of one. Null
    /// where files stay for good.
    retain: ?*const fn (node: *const Node) void = null,
    release: ?*const fn (node: *const Node) void = null,
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
    /// What the symbolic link `path` points to, as it was stored (absolute,
    /// or relative to the directory the link is in); null if `path` is
    /// not a link. A filesystem without the function has none.
    readlink: ?*const fn (ctx: *anyopaque, path: []const u8) ?[]const u8 = null,
    /// The functions that change the filesystem; all null for one that
    /// cannot be changed. `create` makes an empty file and returns its
    /// node (to be released, like one from `lookup`).
    create: ?*const fn (ctx: *anyopaque, path: []const u8) Error!Node = null,
    mkdir: ?*const fn (ctx: *anyopaque, path: []const u8) Error!void = null,
    unlink: ?*const fn (ctx: *anyopaque, path: []const u8) Error!void = null,
    rmdir: ?*const fn (ctx: *anyopaque, path: []const u8) Error!void = null,
    rename: ?*const fn (ctx: *anyopaque, old: []const u8, new: []const u8) Error!void = null,
    /// FIFOs (named pipes): the number of the one at `path`, null if that
    /// is not one; and making one known by `id`. Their pipes are the
    /// kernel's (`fifo.zig`).
    fifo_at: ?*const fn (ctx: *anyopaque, path: []const u8) ?u64 = null,
    mkfifo: ?*const fn (ctx: *anyopaque, path: []const u8, id: u64) Error!void = null,
};

/// The number of the FIFO at `path` (normalized, absolute), or null if
/// there is none.
pub fn fifoAt(path: []const u8) ?u64 {
    const at = resolve(path) orelse return null;
    const f = at.fs.fifo_at orelse return null;
    return f(at.fs.ctx, at.rest);
}

/// Make a FIFO at `path`, known as `id`. `error.ReadOnly` on a filesystem
/// that cannot have one.
pub fn makeFifo(path: []const u8, id: u64) Error!void {
    const at = resolve(path) orelse return error.NotFound;
    const f = at.fs.mkfifo orelse return error.ReadOnly;
    return f(at.fs.ctx, at.rest, id);
}

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
fn resolve(path: []const u8) ?struct { fs: *const Fs, rest: []const u8, skipped: usize } {
    if (path.len == 0 or path[0] != '/') return null;
    // By pointer: a mount is large (all of a filesystem's functions), and
    // copies of the table would fill a kernel stack frame.
    var best: ?*const Mount = null;
    for (&mounts) |*slot| {
        const m = &(slot.* orelse continue);
        if (within(path, m.path) and (best == null or m.path.len > best.?.path.len)) best = m;
    }
    const m = best orelse return null;
    // How much of a path the mount point takes: nothing for the root.
    const skipped = if (m.path.len == 1) 0 else m.path.len;
    const rest = path[skipped..];
    return .{ .fs = &m.fs, .rest = if (rest.len == 0) "/" else rest, .skipped = skipped };
}

/// Look up the file at `path`. Returns null if there is none (or it is a
/// directory, or nothing is mounted). The node holds the file until it is
/// given to `release`.
pub fn lookup(path: []const u8) ?Node {
    const at = resolve(path) orelse return null;
    return at.fs.lookup(at.fs.ctx, at.rest);
}

/// Let go of a node from `lookup` or `create`.
pub fn release(node: *const Node) void {
    if (node.ops.release) |f| f(node);
}

/// A second holder of the file behind `node`, to be released as well.
pub fn retain(node: *const Node) void {
    if (node.ops.retain) |f| f(node);
}

/// Whether the file can go away while it is in use (and so is counted).
pub fn isCounted(node: *const Node) bool {
    return node.ops.release != null;
}

/// The size of the file now.
pub fn sizeOf(node: *const Node) u64 {
    return if (node.ops.size) |f| f(node) else node.size;
}

pub fn isWritable(node: *const Node) bool {
    return node.ops.write != null;
}

/// Write `data` to the file at `offset`: see `Ops.write`.
pub fn write(node: *const Node, offset: u64, data: []const u8) Error!usize {
    const f = node.ops.write orelse return error.ReadOnly;
    return f(node, offset, data);
}

/// Make the file exactly `size` bytes.
pub fn truncate(node: *const Node, size: u64) Error!void {
    const f = node.ops.truncate orelse return error.ReadOnly;
    return f(node, size);
}

/// Whether `path` is a mount point or has one below it: such a directory
/// stays where and what it is.
fn holdsMount(path: []const u8) bool {
    for (mounts) |slot| {
        const m = slot orelse continue;
        if (m.path.len > 1 and within(m.path, path)) return true;
    }
    return false;
}

/// Whether the filesystem `path` belongs to can be changed.
pub fn isWritablePath(path: []const u8) bool {
    const at = resolve(path) orelse return false;
    return at.fs.create != null;
}

/// Make an empty file at `path`; `error.Exists` if anything is there.
/// The node is to be released like one from `lookup`.
pub fn create(path: []const u8) Error!Node {
    const at = resolve(path) orelse return error.NotFound;
    const f = at.fs.create orelse return error.ReadOnly;
    if (at.rest.len == 1) return error.Exists; // a mount point is a directory
    return f(at.fs.ctx, at.rest);
}

pub fn mkdir(path: []const u8) Error!void {
    const at = resolve(path) orelse return error.NotFound;
    if (at.rest.len == 1 or isDirectory(path)) return error.Exists;
    const f = at.fs.mkdir orelse return error.ReadOnly;
    return f(at.fs.ctx, at.rest);
}

/// Remove the file at `path`.
pub fn unlink(path: []const u8) Error!void {
    const at = resolve(path) orelse return error.NotFound;
    if (holdsMount(path)) return error.IsDirectory;
    const f = at.fs.unlink orelse return if (lookupExists(path) or readLink(path) != null) error.ReadOnly else if (isDirectory(path)) error.IsDirectory else error.NotFound;
    return f(at.fs.ctx, at.rest);
}

/// Remove the empty directory at `path`.
pub fn rmdir(path: []const u8) Error!void {
    const at = resolve(path) orelse return error.NotFound;
    if (holdsMount(path)) return error.Busy;
    const f = at.fs.rmdir orelse return if (isDirectory(path)) error.ReadOnly else if (lookupExists(path)) error.NotDirectory else error.NotFound;
    return f(at.fs.ctx, at.rest);
}

/// Give what is at `old` the name `new`, within one filesystem.
pub fn rename(old: []const u8, new: []const u8) Error!void {
    const from = resolve(old) orelse return error.NotFound;
    const to = resolve(new) orelse return error.NotFound;
    if (holdsMount(old) or holdsMount(new)) return error.Busy;
    if (from.fs.ctx != to.fs.ctx or from.skipped != to.skipped) return error.CrossDevice;
    const f = from.fs.rename orelse return if (lookupExists(old) or isDirectory(old) or readLink(old) != null) error.ReadOnly else error.NotFound;
    return f(from.fs.ctx, from.rest, to.rest);
}

fn lookupExists(path: []const u8) bool {
    const node = lookup(path) orelse return false;
    release(&node);
    return true;
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

/// What the symbolic link at `path` (normalized; links before its last
/// part already followed) points to, or null if it is not one.
pub fn readLink(path: []const u8) ?[]const u8 {
    const at = resolve(path) orelse return null;
    if (at.rest.len == 1) return null; // a mount point is a directory
    const f = at.fs.readlink orelse return null;
    return f(at.fs.ctx, at.rest);
}

/// Most links one path may go through, as on Linux (`ELOOP` beyond).
pub const MAX_LINKS = 40;

/// Follow the symbolic links in the normalized path `path`, in every part
/// of it, the last too unless `follow_last` is false. The result, also
/// normalized, is in `out`; `scratch` is space of the same size to work
/// in. A link's target is taken relative to the directory the link is
/// in, unless it is absolute.
///
/// Paths are made plain before links are followed (`normalize`), so ".."
/// after a link goes back to where the link is, not up from where it
/// points: Linux does the latter. Programs rarely notice.
///
/// `error.Loop` after `MAX_LINKS` links, `error.NameTooLong` if the result
/// does not fit.
pub fn followLinks(out: []u8, scratch: []u8, path: []const u8, follow_last: bool) (Error || error{Loop})![]const u8 {
    if (out.len < path.len) return error.NameTooLong;
    @memcpy(out[0..path.len], path);
    var len = path.len;
    var hops: usize = 0;
    // Each pass looks at the parts of the path from the first on, and
    // starts again after replacing a link with its target.
    outer: while (true) {
        var end: usize = 1;
        while (end < len) {
            // The next part ends at the next slash or at the end.
            end = (std.mem.indexOfScalarPos(u8, out[0..len], end, '/') orelse len);
            const last = end == len;
            if (last and !follow_last) break;
            const target = readLink(out[0..end]) orelse {
                end += 1;
                continue;
            };
            hops += 1;
            if (hops > MAX_LINKS) return error.Loop;
            // What it comes to: the target in place of the link, the rest
            // of the path after it, made plain again.
            const dir_end = std.mem.lastIndexOfScalar(u8, out[0..end], '/').?;
            const base = if (dir_end == 0) "/" else out[0..dir_end];
            const rest = out[end..len];
            if (target.len + rest.len > scratch.len) return error.NameTooLong;
            @memcpy(scratch[0..target.len], target);
            @memcpy(scratch[target.len..][0..rest.len], rest);
            const joined = scratch[0 .. target.len + rest.len];
            // `normalize` writes `out` while reading `base` from it: the
            // base is copied first, behind the joined path.
            if (joined.len + base.len > scratch.len) return error.NameTooLong;
            @memcpy(scratch[joined.len..][0..base.len], base);
            const plain = try normalize(out, scratch[joined.len..][0..base.len], if (joined.len == 0) "." else joined);
            len = plain.len;
            continue :outer;
        }
        return out[0..len];
    }
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
