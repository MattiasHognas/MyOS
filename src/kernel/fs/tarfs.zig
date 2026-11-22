//! Read-only filesystem backed by a ustar archive in memory (the initrd).
//!
//! Files are found by scanning the archive's 512-byte headers on every lookup;
//! file data is served directly from the archive without copying.

const std = @import("std");
const vfs = @import("../vfs.zig");
const log = std.log.scoped(.tarfs);

var archive: []const u8 = &.{};

/// One archive member: normalized name, ustar type flag and contents.
const Entry = struct { name: []const u8, typ: u8, data: []const u8 };
/// Node operations shared by every tarfs file. `Node.ctx` holds a pointer to the file data.
const ops = vfs.Ops{ .read = read };

/// Parse an octal number from a tar header field, stopping at the first
/// non-octal character (NUL or space).
fn octal(field: []const u8) u64 {
    var v: u64 = 0;
    for (field) |c| {
        if (c < '0' or c > '7') break;
        v = v * 8 + (c - '0');
    }
    return v;
}

/// Return `field` up to its first NUL byte, or the whole field if it has none.
fn cstr(field: []const u8) []const u8 {
    return field[0 .. std.mem.indexOfScalar(u8, field, 0) orelse field.len];
}

/// Strip a leading "./" and any leading or trailing slashes, so that
/// "./bin/hello" and "/bin/hello" both become "bin/hello".
fn normalize(name: []const u8) []const u8 {
    var n = name;
    if (std.mem.startsWith(u8, n, "./")) n = n[2..];
    return std.mem.trim(u8, n, "/");
}

/// Return the entry whose header starts at `off.*` and advance `off` to the
/// next header. Returns null at the end-of-archive marker or if the archive
/// is truncated.
fn next(off: *usize) ?Entry {
    if (off.* + 512 > archive.len) return null;
    const h = archive[off.*..][0..512];
    if (h[0] == 0) return null; // end-of-archive marker
    const size = octal(h[124..136]);
    const start = off.* + 512;
    if (start + size > archive.len) return null; // truncated archive
    off.* = start + std.mem.alignForward(u64, size, 512);
    return .{ .name = normalize(cstr(h[0..100])), .typ = h[156], .data = archive[start..][0..size] };
}

/// Return true if `e` is a regular file (type flag '0', or NUL in old archives).
fn isFile(e: Entry) bool {
    return e.typ == '0' or e.typ == 0;
}

/// `vfs.Fs.lookup` implementation: find the regular file at `path` and return
/// a node for it, or null if there is none. Directories are not returned.
fn lookup(_: *anyopaque, path: []const u8) ?vfs.Node {
    const want = normalize(path);
    var off: usize = 0;
    while (next(&off)) |e| {
        if (isFile(e) and std.mem.eql(u8, e.name, want)) {
            return .{ .size = e.data.len, .ctx = @intFromPtr(e.data.ptr), .ops = &ops };
        }
    }
    return null;
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
    while (next(&off)) |e| {
        if (isFile(e)) log.debug("/{s} ({d} bytes)", .{ e.name, e.data.len });
    }
    return .{ .ctx = undefined, .lookup = lookup };
}
