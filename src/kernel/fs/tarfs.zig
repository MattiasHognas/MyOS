const std = @import("std");
const root = @import("root");
const vfs = @import("../vfs.zig");

var archive: []const u8 = &.{};

const Entry = struct { name: []const u8, typ: u8, data: []const u8 };
const ops = vfs.Ops{ .read = read };

// Read an octal number from a byte slice. The caller must ensure that the slice is large enough.
fn octal(field: []const u8) u64 {
    var v: u64 = 0;
    for (field) |c| {
        if (c < '0' or c > '7') break;
        v = v * 8 + (c - '0');
    }
    return v;
}

// Read a null-terminated string from a byte slice. The caller must ensure that the slice is large enough.
fn cstr(field: []const u8) []const u8 {
    return field[0 .. std.mem.indexOfScalar(u8, field, 0) orelse field.len];
}

// "./bin/hello" and "/bin/hello" -> "bin/hello"
fn normalize(name: []const u8) []const u8 {
    var n = name;
    if (std.mem.startsWith(u8, n, "./")) n = n[2..];
    return std.mem.trim(u8, n, "/");
}

// Return the next entry in the archive, or null if there are no more entries. Updates `off` to point to the next entry.
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

// Return true if the entry is a regular file. The entry's name is normalized, so it does not start with "./" or "/".
fn isFile(e: Entry) bool {
    return e.typ == '0' or e.typ == 0;
}

// Return true if the entry is a directory. The entry's name is normalized, so it does not start with "./" or "/".
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

// Read from a file node. Returns the number of bytes read, or 0 if `offset` is at or beyond the end of the file.
fn read(node: *const vfs.Node, offset: u64, buf: []u8) usize {
    if (offset >= node.size) return 0;
    const data: [*]const u8 = @ptrFromInt(node.ctx);
    const n = @min(buf.len, node.size - offset);
    @memcpy(buf[0..n], data[offset..][0..n]);
    return n;
}

// Initialize the tar filesystem with the given archive image. The image must be a valid tar archive, and must remain valid for the lifetime of the filesystem. Returns a `vfs.Fs` that can be used to look up files in the archive.
pub fn init(image: []const u8) vfs.Fs {
    archive = image;
    var off: usize = 0;
    while (next(&off)) |e| {
        if (isFile(e)) root.print("initrd: /{s} ({d} bytes)\n", .{ e.name, e.data.len });
    }
    return .{ .ctx = undefined, .lookup = lookup };
}
