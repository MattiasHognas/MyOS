//! The ustar archive format, as far as a read-only filesystem needs it:
//! walking the 512-byte headers of an archive in memory and comparing
//! names. No kernel dependencies, so it is tested on the host; `tarfs.zig`
//! makes a filesystem of it.

const std = @import("std");

/// One archive member: normalized name, ustar type flag and contents. A
/// name longer than 100 bytes is stored in two parts, `prefix` and `name`,
/// with a slash between them that is not stored.
pub const Entry = struct {
    prefix: []const u8,
    name: []const u8,
    typ: u8,
    data: []const u8,
    /// For a symbolic link (type '2'): what it points to, as stored.
    link: []const u8 = "",

    /// Whether the entry's full name is `want` (normalized).
    pub fn named(e: Entry, want: []const u8) bool {
        if (e.prefix.len == 0) return std.mem.eql(u8, e.name, want);
        return want.len == e.prefix.len + 1 + e.name.len and
            std.mem.startsWith(u8, want, e.prefix) and want[e.prefix.len] == '/' and
            std.mem.endsWith(u8, want, e.name);
    }

    /// Whether the entry is somewhere below the directory `dir`
    /// (normalized, not empty): its full name starts with `dir` and a slash.
    pub fn below(e: Entry, dir: []const u8) bool {
        if (e.prefix.len == 0) return e.name.len > dir.len and std.mem.startsWith(u8, e.name, dir) and e.name[dir.len] == '/';
        // The full name is prefix + "/" + name.
        if (dir.len < e.prefix.len) return std.mem.startsWith(u8, e.prefix, dir) and e.prefix[dir.len] == '/';
        if (dir.len == e.prefix.len) return std.mem.eql(u8, e.prefix, dir);
        const rest = dir[e.prefix.len..];
        return std.mem.startsWith(u8, dir, e.prefix) and rest[0] == '/' and
            e.name.len > rest.len - 1 and std.mem.startsWith(u8, e.name, rest[1..]) and e.name[rest.len - 1] == '/';
    }
};

/// The entry's whole name in `buf` (its two parts with a slash between
/// them), or null if it does not fit.
pub fn fullName(e: Entry, buf: []u8) ?[]const u8 {
    if (e.prefix.len == 0) {
        if (e.name.len > buf.len) return null;
        @memcpy(buf[0..e.name.len], e.name);
        return buf[0..e.name.len];
    }
    const len = e.prefix.len + 1 + e.name.len;
    if (len > buf.len) return null;
    @memcpy(buf[0..e.prefix.len], e.prefix);
    buf[e.prefix.len] = '/';
    @memcpy(buf[e.prefix.len + 1 ..][0..e.name.len], e.name);
    return buf[0..len];
}

/// What a name contributes to a listing of the directory `dir`
/// (normalized; empty for the root): the name of the entry of `dir` it is
/// or is below, and whether it is that entry itself (`exact`) or
/// something inside it, which makes the entry a directory. Null if the
/// name is not below `dir`.
pub fn childOf(full: []const u8, dir: []const u8) ?struct { name: []const u8, exact: bool } {
    var rest = full;
    if (dir.len != 0) {
        if (full.len <= dir.len + 1 or !std.mem.startsWith(u8, full, dir) or full[dir.len] != '/') return null;
        rest = full[dir.len + 1 ..];
    }
    if (rest.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return .{ .name = rest, .exact = true };
    return .{ .name = rest[0..slash], .exact = false };
}

/// Longest whole name `fullName` can give: both parts and the slash.
pub const MAX_NAME = 155 + 1 + 100;

/// The next entry of the directory `dir` (normalized; empty for the root)
/// in `archive`, starting at the header at `offset.*`, which is moved past
/// the member that gave it. Each name is given once, where it first
/// appears: as a file, as a directory with an entry of its own, or as a
/// directory that exists only because something is inside it.
pub fn nextInDirectory(archive: []const u8, dir: []const u8, offset: *usize, name_buf: []u8) ?struct { name: []const u8, directory: bool, link: bool = false } {
    var full_buf: [MAX_NAME]u8 = undefined;
    var earlier_buf: [MAX_NAME]u8 = undefined;
    while (true) {
        const at = offset.*;
        const e = next(archive, offset) orelse return null;
        const full = fullName(e, &full_buf) orelse continue;
        const child = childOf(full, dir) orelse continue;
        // Seen before? Then an earlier member had the same name here.
        var seen = false;
        var scan: usize = 0;
        while (scan < at) {
            const other = next(archive, &scan) orelse break;
            const other_full = fullName(other, &earlier_buf) orelse continue;
            const other_child = childOf(other_full, dir) orelse continue;
            if (std.mem.eql(u8, other_child.name, child.name)) {
                seen = true;
                break;
            }
        }
        if (seen or child.name.len > name_buf.len) continue;
        // A directory, unless it is a file itself. (A name that is a file
        // here and has something inside it there is a broken archive; the
        // first word on it stands.)
        var directory = !child.exact or !isFile(e);
        if (!directory) {
            // ... or a later member lies inside it.
            var ahead = offset.*;
            while (next(archive, &ahead)) |later| {
                const later_full = fullName(later, &earlier_buf) orelse continue;
                const later_child = childOf(later_full, dir) orelse continue;
                if (!later_child.exact and std.mem.eql(u8, later_child.name, child.name)) directory = true;
            }
        }
        @memcpy(name_buf[0..child.name.len], child.name);
        const link = child.exact and isLink(e);
        return .{ .name = name_buf[0..child.name.len], .directory = directory and !link, .link = link };
    }
}

/// Whether `e` is a symbolic link (type flag '2').
pub fn isLink(e: Entry) bool {
    return e.typ == '2';
}

/// The target of the symbolic link `path` (normalized) in `archive`, or
/// null if no member of that name is one.
pub fn linkTarget(archive: []const u8, path: []const u8) ?[]const u8 {
    var off: usize = 0;
    while (next(archive, &off)) |e| {
        if (isLink(e) and e.named(path)) return e.link;
    }
    return null;
}

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
pub fn normalize(name: []const u8) []const u8 {
    var n = name;
    if (std.mem.startsWith(u8, n, "./")) n = n[2..];
    return std.mem.trim(u8, n, "/");
}

/// Return the entry of `archive` whose header starts at `off.*` and advance
/// `off` to the next header. Returns null at the end-of-archive marker or if the archive
/// is truncated.
pub fn next(archive: []const u8, off: *usize) ?Entry {
    if (off.* + 512 > archive.len) return null;
    const h = archive[off.*..][0..512];
    if (h[0] == 0) return null; // end-of-archive marker
    const size = octal(h[124..136]);
    const start = off.* + 512;
    if (start + size > archive.len) return null; // truncated archive
    off.* = start + std.mem.alignForward(u64, size, 512);
    // The prefix field belongs to the ustar format only ("ustar" at 257).
    const prefix = if (std.mem.eql(u8, h[257..262], "ustar")) normalize(cstr(h[345..500])) else "";
    return .{ .prefix = prefix, .name = normalize(cstr(h[0..100])), .typ = h[156], .data = archive[start..][0..size], .link = cstr(h[157..257]) };
}

/// Return true if `e` is a regular file (type flag '0', or NUL in old archives).
pub fn isFile(e: Entry) bool {
    return e.typ == '0' or e.typ == 0;
}
