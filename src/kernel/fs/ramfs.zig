//! A filesystem in memory: files and directories that can be made,
//! written, renamed and removed, and are gone at power-off.
//!
//! `RamFs(Blocks)` keeps a table of entries, one for each file and
//! directory, by path. A file's contents are blocks of 4 KiB, which
//! `Blocks` hands out and takes back (pages in the kernel, the host's
//! allocator in the host tests); a block that was never written does not
//! exist and reads as zeroes. A file that is removed while it is open
//! lives on, nameless, until the last one who has it open lets go
//! (`retain`, `release`).
//!
//! Nothing here locks: whoever uses it lets one thread in at a time
//! (`tmpfs.zig` in the kernel). No kernel dependencies, so it is tested on
//! the host. Paths are normalized, absolute within the filesystem, and
//! the root is "/".

const std = @import("std");

pub const BLOCK = 4096;

pub const Error = error{
    NotFound,
    /// A part of the path that has to be a directory is a file.
    NotDirectory,
    IsDirectory,
    Exists,
    /// A directory that still holds something.
    NotEmpty,
    /// No memory, or the filesystem has reached the size it may have.
    NoSpace,
    /// A directory moved into itself, or the root renamed or removed.
    Invalid,
    /// Larger than a file can be.
    TooLarge,
};

pub const Kind = enum { file, directory, fifo, symlink };

/// What a path names: the kind, and for a file its size.
pub const Info = struct { kind: Kind, size: u64 };

pub fn RamFs(comptime Blocks: type) type {
    return struct {
        gpa: std.mem.Allocator,
        entries: std.ArrayListUnmanaged(Entry) = .empty,
        /// Blocks all files hold together, and how many they may.
        blocks_used: usize = 0,
        blocks_max: usize,

        const Self = @This();

        /// Most a file can hold: what its block table can describe before
        /// the table itself becomes unreasonable (1 GiB).
        pub const MAX_FILE = 1 << 30;

        pub const File = struct {
            /// The first `size` bytes are the file. A null block is zeroes.
            blocks: std.ArrayListUnmanaged(?*[BLOCK]u8) = .empty,
            size: u64 = 0,
            /// Who holds it: each of its names and everyone who has it open.
            refs: usize = 1,
            /// Its names (`link` adds one; `stat`'s `st_nlink`).
            nlink: u32 = 1,
            /// Last access, change of contents and change of anything, in
            /// nanoseconds since 1970: kept for the owner, who sets them.
            atime: i64 = 0,
            mtime: i64 = 0,
            ctime: i64 = 0,
        };

        const Entry = struct {
            /// Owned. Not "/": the root is not in the table.
            path: []u8,
            /// Null for a directory or a FIFO.
            file: ?*File,
            /// For a FIFO (a named pipe, `mkfifo`): the number its owner
            /// knows it by, never 0. Its pipe is not here: the kernel's.
            fifo: u64 = 0,
            /// For a symbolic link: what it points to. Owned.
            link: ?[]u8 = null,

            fn isDir(e: Entry) bool {
                return e.file == null and e.fifo == 0 and e.link == null;
            }

            fn kind(e: Entry) Kind {
                return if (e.file != null) .file else if (e.fifo != 0) .fifo else if (e.link != null) .symlink else .directory;
            }
        };

        /// Free what an entry owns besides its path.
        fn dropEntry(self: *Self, e: Entry) void {
            if (e.file) |f| {
                f.nlink -= 1;
                self.release(f);
            }
            if (e.link) |l| self.gpa.free(l);
        }

        fn find(self: *const Self, path: []const u8) ?usize {
            for (self.entries.items, 0..) |e, i| {
                if (std.mem.eql(u8, e.path, path)) return i;
            }
            return null;
        }

        fn parentOf(path: []const u8) []const u8 {
            const slash = std.mem.lastIndexOfScalar(u8, path, '/').?;
            return if (slash == 0) "/" else path[0..slash];
        }

        /// What `path` names, or null.
        pub fn info(self: *const Self, path: []const u8) ?Info {
            if (path.len == 1) return .{ .kind = .directory, .size = 0 };
            const e = self.entries.items[self.find(path) orelse return null];
            return if (e.file) |f| .{ .kind = .file, .size = f.size } else .{ .kind = e.kind(), .size = 0 };
        }

        /// The directory a new entry at `path` would go into must be one.
        fn checkParent(self: *const Self, path: []const u8) Error!void {
            const parent = self.info(parentOf(path)) orelse return error.NotFound;
            if (parent.kind != .directory) return error.NotDirectory;
        }

        fn addEntry(self: *Self, path: []const u8, file: ?*File) Error!void {
            const copy = self.gpa.dupe(u8, path) catch return error.NoSpace;
            self.entries.append(self.gpa, .{ .path = copy, .file = file }) catch {
                self.gpa.free(copy);
                return error.NoSpace;
            };
        }

        /// The file at `path`, with one more holder (`release` it).
        pub fn open(self: *Self, path: []const u8) Error!*File {
            if (path.len == 1) return error.IsDirectory;
            const e = self.entries.items[self.find(path) orelse return error.NotFound];
            if (e.fifo != 0 or e.link != null) return error.Invalid; // opened through its owner, or followed
            const f = e.file orelse return error.IsDirectory;
            f.refs += 1;
            return f;
        }

        /// Make an empty file at `path` and return it with one more holder,
        /// as `open` does. `error.Exists` if anything has the name.
        pub fn create(self: *Self, path: []const u8) Error!*File {
            if (path.len == 1 or self.find(path) != null) return error.Exists;
            try self.checkParent(path);
            const f = self.gpa.create(File) catch return error.NoSpace;
            f.* = .{};
            self.addEntry(path, f) catch |e| {
                self.gpa.destroy(f);
                return e;
            };
            f.refs += 1;
            return f;
        }

        pub fn mkdir(self: *Self, path: []const u8) Error!void {
            if (path.len == 1 or self.find(path) != null) return error.Exists;
            try self.checkParent(path);
            try self.addEntry(path, null);
        }

        /// Make a FIFO at `path`, known as `id` (not 0).
        pub fn mkfifo(self: *Self, path: []const u8, id: u64) Error!void {
            if (path.len == 1 or self.find(path) != null) return error.Exists;
            try self.checkParent(path);
            try self.addEntry(path, null);
            self.entries.items[self.entries.items.len - 1].fifo = id;
        }

        /// Make a symbolic link at `path` to `target`.
        pub fn symlink(self: *Self, path: []const u8, target: []const u8) Error!void {
            if (path.len == 1 or self.find(path) != null) return error.Exists;
            try self.checkParent(path);
            const copy = self.gpa.dupe(u8, target) catch return error.NoSpace;
            self.addEntry(path, null) catch |e| {
                self.gpa.free(copy);
                return e;
            };
            self.entries.items[self.entries.items.len - 1].link = copy;
        }

        /// What the symbolic link `path` points to, or null if it is not one.
        /// The memory is the filesystem's, valid until the link changes.
        pub fn readlink(self: *const Self, path: []const u8) ?[]const u8 {
            if (path.len == 1) return null;
            return self.entries.items[self.find(path) orelse return null].link;
        }

        /// Give the file at `old` a second name, `new` (a hard link). Not a
        /// directory, FIFO or symbolic link (`error.Invalid`, the caller's
        /// `EPERM`).
        pub fn link(self: *Self, old: []const u8, new: []const u8) Error!*File {
            if (old.len == 1) return error.Invalid;
            const e = self.entries.items[self.find(old) orelse return error.NotFound];
            const f = e.file orelse return error.Invalid;
            if (new.len == 1 or self.find(new) != null) return error.Exists;
            try self.checkParent(new);
            try self.addEntry(new, f);
            f.refs += 1;
            f.nlink += 1;
            return f;
        }

        /// The file at `path` (no holder taken: the caller holds the
        /// filesystem's lock while using it), or null.
        pub fn fileAt(self: *const Self, path: []const u8) ?*File {
            if (path.len == 1) return null;
            return self.entries.items[self.find(path) orelse return null].file;
        }

        /// The number of the FIFO at `path`, or null if it is not one.
        pub fn fifoAt(self: *const Self, path: []const u8) ?u64 {
            if (path.len == 1) return null;
            const e = self.entries.items[self.find(path) orelse return null];
            return if (e.fifo != 0) e.fifo else null;
        }

        /// One more holder of `f`.
        pub fn retain(_: *Self, f: *File) void {
            f.refs += 1;
        }

        /// One holder of `f` less; its memory goes with the last.
        pub fn release(self: *Self, f: *File) void {
            f.refs -= 1;
            if (f.refs != 0) return;
            self.freeBlocks(f, 0);
            f.blocks.deinit(self.gpa);
            self.gpa.destroy(f);
        }

        /// Free the blocks of `f` from index `from` on.
        fn freeBlocks(self: *Self, f: *File, from: usize) void {
            if (from >= f.blocks.items.len) return;
            for (f.blocks.items[from..]) |slot| {
                if (slot) |block| {
                    Blocks.free(block);
                    self.blocks_used -= 1;
                }
            }
            f.blocks.shrinkRetainingCapacity(from);
        }

        /// Take the name `path` away from its file. The file itself goes
        /// when nobody has it open any more.
        pub fn unlink(self: *Self, path: []const u8) Error!void {
            if (path.len == 1) return error.IsDirectory;
            const i = self.find(path) orelse return error.NotFound;
            const e = self.entries.items[i];
            if (e.isDir()) return error.IsDirectory;
            _ = self.entries.swapRemove(i);
            self.gpa.free(e.path);
            self.dropEntry(e); // a FIFO's pipe is its owner's
            self.trim();
        }

        /// An empty filesystem holds no memory: the table goes with its
        /// last entry (and comes back with the next).
        fn trim(self: *Self) void {
            if (self.entries.items.len == 0) self.entries.clearAndFree(self.gpa);
        }

        /// Whether anything is inside the directory `path`.
        fn hasChildren(self: *const Self, path: []const u8) bool {
            for (self.entries.items) |e| {
                if (isBelow(e.path, path)) return true;
            }
            return false;
        }

        fn isBelow(path: []const u8, dir: []const u8) bool {
            if (dir.len == 1) return true;
            return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
        }

        pub fn rmdir(self: *Self, path: []const u8) Error!void {
            if (path.len == 1) return error.Invalid;
            const i = self.find(path) orelse return error.NotFound;
            if (!self.entries.items[i].isDir()) return error.NotDirectory;
            if (self.hasChildren(path)) return error.NotEmpty;
            self.gpa.free(self.entries.swapRemove(i).path);
            self.trim();
        }

        /// Give what is at `old` the name `new`, with everything inside it
        /// if it is a directory. A file at `new` is replaced; so is an
        /// empty directory if `old` is a directory. Either all of it
        /// happens or nothing.
        pub fn rename(self: *Self, old: []const u8, new: []const u8) Error!void {
            if (old.len == 1 or new.len == 1) return error.Invalid;
            const from = self.find(old) orelse return error.NotFound;
            if (std.mem.eql(u8, old, new)) return;
            const moving_dir = self.entries.items[from].isDir();
            if (moving_dir and isBelow(new, old)) return error.Invalid;
            try self.checkParent(new);
            if (self.find(new)) |to| {
                const target_dir = self.entries.items[to].isDir();
                if (moving_dir and !target_dir) return error.NotDirectory;
                if (!moving_dir and target_dir) return error.IsDirectory;
                if (target_dir and self.hasChildren(new)) return error.NotEmpty;
            }
            // The new names first, all of them, so that running out of
            // memory half-way changes nothing.
            var renamed: std.ArrayListUnmanaged([]u8) = .empty;
            defer renamed.deinit(self.gpa);
            errdefer for (renamed.items) |path| self.gpa.free(path);
            for (self.entries.items) |e| {
                if (!std.mem.eql(u8, e.path, old) and !(moving_dir and isBelow(e.path, old))) continue;
                const path = self.gpa.alloc(u8, new.len + e.path.len - old.len) catch return error.NoSpace;
                @memcpy(path[0..new.len], new);
                @memcpy(path[new.len..], e.path[old.len..]);
                renamed.append(self.gpa, path) catch {
                    self.gpa.free(path);
                    return error.NoSpace;
                };
            }
            // From here nothing fails. What had the new name goes.
            if (self.find(new)) |to| {
                // (In order: the new names were made in the order the
                // entries have, and must be handed out in it.)
                const e = self.entries.orderedRemove(to);
                self.gpa.free(e.path);
                self.dropEntry(e);
            }
            var taken: usize = 0;
            for (self.entries.items) |*e| {
                if (!std.mem.eql(u8, e.path, old) and !(moving_dir and isBelow(e.path, old))) continue;
                self.gpa.free(e.path);
                e.path = renamed.items[taken];
                taken += 1;
            }
        }

        /// The entry of the directory `dir` after the place `cookie` stands
        /// for (0: the first), which is moved past it; null at the end.
        /// The name is in `name_buf`; a name that does not fit is left out.
        pub fn next(self: *const Self, dir: []const u8, cookie: *u64, name_buf: []u8) ?struct { name: []const u8, kind: Kind } {
            while (cookie.* < self.entries.items.len) {
                const e = self.entries.items[@intCast(cookie.*)];
                cookie.* += 1;
                if (!isBelow(e.path, dir)) continue;
                const name = e.path[(if (dir.len == 1) 1 else dir.len + 1)..];
                if (std.mem.indexOfScalar(u8, name, '/') != null or name.len > name_buf.len) continue;
                @memcpy(name_buf[0..name.len], name);
                return .{ .name = name_buf[0..name.len], .kind = e.kind() };
            }
            return null;
        }

        /// Copy up to `buf.len` bytes of `f` from `offset` on; 0 at the end.
        pub fn read(_: *const Self, f: *const File, offset: u64, buf: []u8) usize {
            if (offset >= f.size) return 0;
            const n: usize = @intCast(@min(buf.len, f.size - offset));
            var done: usize = 0;
            while (done < n) {
                const at = offset + done;
                const index: usize = @intCast(at / BLOCK);
                const in_block: usize = @intCast(at % BLOCK);
                const part = @min(n - done, BLOCK - in_block);
                const block = if (index < f.blocks.items.len) f.blocks.items[index] else null;
                if (block) |b| @memcpy(buf[done..][0..part], b[in_block..][0..part]) else @memset(buf[done..][0..part], 0);
                done += part;
            }
            return n;
        }

        /// The block at `index` of `f`, made (zeroed) if there is none
        /// yet: for a mapping of the file, which writes it directly.
        pub fn blockAt(self: *Self, f: *File, index: usize) Error!*[BLOCK]u8 {
            try self.reach(f, index);
            if (f.blocks.items[index]) |b| return b;
            if (self.blocks_used >= self.blocks_max) return error.NoSpace;
            const new = Blocks.alloc() orelse return error.NoSpace;
            @memset(new, 0);
            self.blocks_used += 1;
            f.blocks.items[index] = new;
            return new;
        }

        /// Make sure the block table of `f` reaches block `index`.
        fn reach(self: *Self, f: *File, index: usize) Error!void {
            if (index < f.blocks.items.len) return;
            f.blocks.appendNTimes(self.gpa, null, index + 1 - f.blocks.items.len) catch return error.NoSpace;
        }

        /// Write `data` into `f` at `offset`, growing it as needed; a gap
        /// between the old end and `offset` reads as zeroes. Returns the
        /// bytes written, which is less than asked for only when the
        /// space runs out part-way; `error.NoSpace` if none could be.
        pub fn write(self: *Self, f: *File, offset: u64, data: []const u8) Error!usize {
            if (data.len == 0) return 0;
            const end = std.math.add(u64, offset, data.len) catch return error.TooLarge;
            if (end > MAX_FILE) return error.TooLarge;
            var done: usize = 0;
            while (done < data.len) {
                const at = offset + done;
                const index: usize = @intCast(at / BLOCK);
                const in_block: usize = @intCast(at % BLOCK);
                const part = @min(data.len - done, BLOCK - in_block);
                self.reach(f, index) catch break;
                const block = f.blocks.items[index] orelse blk: {
                    if (self.blocks_used >= self.blocks_max) break;
                    const new = Blocks.alloc() orelse break;
                    @memset(new, 0);
                    self.blocks_used += 1;
                    f.blocks.items[index] = new;
                    break :blk new;
                };
                @memcpy(block[in_block..][0..part], data[done..][0..part]);
                done += part;
                f.size = @max(f.size, at + part);
            }
            return if (done == 0) error.NoSpace else done;
        }

        /// Make `f` exactly `size` bytes: cut off what is beyond, or let
        /// it end in zeroes that take no memory.
        pub fn truncate(self: *Self, f: *File, size: u64) Error!void {
            if (size > MAX_FILE) return error.TooLarge;
            if (size < f.size) {
                const keep: usize = @intCast((size + BLOCK - 1) / BLOCK);
                self.freeBlocks(f, keep);
                // What is left of the last block past the new end is
                // zeroed, so that growing again does not bring it back.
                const tail: usize = @intCast(size % BLOCK);
                if (tail != 0 and keep - 1 < f.blocks.items.len) {
                    if (f.blocks.items[keep - 1]) |b| @memset(b[tail..], 0);
                }
            }
            f.size = size;
        }

        /// Remove everything. Files someone still has open stay theirs.
        pub fn deinit(self: *Self) void {
            for (self.entries.items) |e| {
                self.gpa.free(e.path);
                self.dropEntry(e);
            }
            self.entries.deinit(self.gpa);
            self.entries = .empty;
        }
    };
}
