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
    return .{ .prefix = prefix, .name = normalize(cstr(h[0..100])), .typ = h[156], .data = archive[start..][0..size] };
}

/// Return true if `e` is a regular file (type flag '0', or NUL in old archives).
pub fn isFile(e: Entry) bool {
    return e.typ == '0' or e.typ == 0;
}
