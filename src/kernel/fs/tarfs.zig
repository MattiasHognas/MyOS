//! Read-only filesystem backed by a ustar archive in memory (the initrd).
//!
//! Files are found by scanning the archive's 512-byte headers on every lookup;
//! file data is served directly from the archive without copying.
//!
//! A directory is whatever some file is in: `bin` exists because
//! `bin/hello` does, whether or not the archive has an entry for it.

const std = @import("std");

const tar = @import("tar.zig");
const vfs = @import("../vfs.zig");

const log = std.log.scoped(.tarfs);

var archive: []const u8 = &.{};

/// Node operations shared by every tarfs file. `Node.ctx` holds a pointer to the file data.
const ops = vfs.Ops{ .read = read };

/// `vfs.Fs.lookup` implementation: find the regular file at `path` and return
/// a node for it, or null if there is none. Directories are not returned.
fn lookup(_: *anyopaque, path: []const u8) ?vfs.Node {
    const want = tar.normalize(path);
    var off: usize = 0;
    while (tar.next(archive, &off)) |e| {
        if (tar.isFile(e) and e.named(want)) {
            return .{ .size = e.data.len, .ctx = @intFromPtr(e.data.ptr), .ops = &ops };
        }
    }
    return null;
}

/// `vfs.Fs.is_dir` implementation: `path` is a directory if a file is
/// somewhere below it, or the archive has a directory entry for it.
fn isDirectory(_: *anyopaque, path: []const u8) bool {
    const want = tar.normalize(path);
    if (want.len == 0) return true;
    var off: usize = 0;
    while (tar.next(archive, &off)) |e| {
        if (e.below(want)) return true;
        if (e.typ == '5' and e.named(want)) return true;
    }
    return false;
}

/// `vfs.Ops.read` implementation: copy up to `buf.len` bytes starting at
/// `offset` into `buf`. Returns the number of bytes copied, or 0 if `offset`
/// is at or beyond the end of the file.
fn read(node: *const vfs.Node, offset: u64, buf: []u8) usize {
    if (offset >= node.size) return 0;
    const data: [*]const u8 = @ptrFromInt(node.ctx);
    const n = @min(buf.len, node.size - offset);
    @memcpy(buf[0..n], data[offset..][0..n]);
    return n;
}

/// Use the tar archive `image` as the filesystem and log (at debug level) the files it contains.
///
/// `image` is not copied and must stay valid for as long as the filesystem is
/// used. Returns a `vfs.Fs` to pass to `vfs.mountRoot`.
pub fn init(image: []const u8) vfs.Fs {
    archive = image;
    var off: usize = 0;
    while (tar.next(archive, &off)) |e| {
        if (tar.isFile(e)) log.debug("/{s}{s}{s} ({d} bytes)", .{ e.prefix, if (e.prefix.len != 0) "/" else "", e.name, e.data.len });
    }
    return .{ .ctx = undefined, .lookup = lookup, .is_dir = isDirectory };
}
