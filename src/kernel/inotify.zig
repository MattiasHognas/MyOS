//! `inotify`: being told what happens to files and directories, as Linux
//! tells it (`inotify_init1`, `inotify_add_watch`, `inotify_rm_watch`, and
//! `read` of `struct inotify_event` records). .NET's `FileSystemWatcher`
//! is built on it, and ASP.NET watches its configuration files with one.
//!
//! An instance holds watches, each on a path with a mask of the events
//! wanted, and a queue of events to be read. The calls that change files
//! (`open` with `O_CREAT`, `write`, `mkdir`, `unlink`, `rename`, ...)
//! report what they did through `notify` once they have done it; a watch
//! on a directory gets the events of the entries in it, with the entry's
//! name, and a watch on the thing itself gets its own (`IN_DELETE_SELF`,
//! then `IN_IGNORED` as the watch goes). A rename is `IN_MOVED_FROM` and
//! `IN_MOVED_TO` with one cookie. A queue that is full takes one
//! `IN_Q_OVERFLOW` and drops the rest, as on Linux.
//!
//! Not as on Linux: a watch is on a path, not on the file or directory
//! behind it. A watched directory that is renamed or removed is told so
//! (`IN_MOVE_SELF`, `IN_DELETE_SELF`), but the watch then goes, rather
//! than following it to its new name. And only what goes through the
//! system calls is seen (the files of the image never change).
//!
//! Nothing is spent while no instance exists (`active`). One lock (rank
//! `condition`) covers every instance, its watches and its queue: the
//! events are few, the readers wait on it.

const std = @import("std");

const heap = @import("heap.zig");
const readiness = @import("readiness.zig");
const SpinLock = @import("sync/spinlock.zig").SpinLock;
const WaitQueue = @import("sync/wait_queue.zig").WaitQueue;

pub const IN = struct {
    pub const ACCESS: u32 = 0x1;
    pub const MODIFY: u32 = 0x2;
    pub const ATTRIB: u32 = 0x4;
    pub const CLOSE_WRITE: u32 = 0x8;
    pub const CLOSE_NOWRITE: u32 = 0x10;
    pub const OPEN: u32 = 0x20;
    pub const MOVED_FROM: u32 = 0x40;
    pub const MOVED_TO: u32 = 0x80;
    pub const CREATE: u32 = 0x100;
    pub const DELETE: u32 = 0x200;
    pub const DELETE_SELF: u32 = 0x400;
    pub const MOVE_SELF: u32 = 0x800;
    pub const ALL_EVENTS: u32 = 0xFFF;
    pub const UNMOUNT: u32 = 0x2000;
    pub const Q_OVERFLOW: u32 = 0x4000;
    pub const IGNORED: u32 = 0x8000;
    pub const ONLYDIR: u32 = 0x0100_0000;
    pub const DONT_FOLLOW: u32 = 0x0200_0000;
    pub const EXCL_UNLINK: u32 = 0x0400_0000;
    pub const MASK_CREATE: u32 = 0x1000_0000;
    pub const MASK_ADD: u32 = 0x2000_0000;
    pub const ISDIR: u32 = 0x4000_0000;
    pub const ONESHOT: u32 = 0x8000_0000;
};

/// Events an instance keeps before it overflows (Linux's default
/// `max_queued_events`).
pub const MAX_EVENTS = 16384;
/// Watches an instance may have.
pub const MAX_WATCHES = 8192;

const Watch = struct {
    wd: i32,
    path: []u8,
    mask: u32,
    next: ?*Watch = null,
};

const Event = struct {
    wd: i32,
    mask: u32,
    cookie: u32,
    /// The entry's name, for an event of a watched directory; owned.
    name: []u8,
    next: ?*Event = null,
};

pub const Instance = struct {
    watches: ?*Watch = null,
    next_wd: i32 = 1,
    watch_count: usize = 0,
    head: ?*Event = null,
    tail: ?*Event = null,
    queued: usize = 0,
    /// Moves on with every event, for edge-triggered `epoll`.
    version: u64 = 0,
    readers: WaitQueue = .{},
    next: ?*Instance = null,
};

var lock: SpinLock = .{};
var instances: ?*Instance = null;
/// Instances there are: `notify` returns at once while there are none.
var active: std.atomic.Value(usize) = .init(0);
var next_cookie: std.atomic.Value(u32) = .init(1);

pub fn create() error{OutOfMemory}!*Instance {
    const inst = try heap.allocator.create(Instance);
    inst.* = .{};
    const held = lock.acquire();
    defer lock.release(held);
    inst.next = instances;
    instances = inst;
    _ = active.fetchAdd(1, .release);
    return inst;
}

/// The last descriptor of `inst` is closed: it goes, with its watches and
/// what was not read.
pub fn destroy(inst: *Instance) void {
    {
        const held = lock.acquire();
        defer lock.release(held);
        var link = &instances;
        while (link.*) |one| : (link = &one.next) {
            if (one == inst) {
                link.* = inst.next;
                break;
            }
        }
        _ = active.fetchSub(1, .release);
    }
    var w = inst.watches;
    while (w) |one| {
        w = one.next;
        heap.allocator.free(one.path);
        heap.allocator.destroy(one);
    }
    freeEvents(inst.head);
    heap.allocator.destroy(inst);
}

fn freeEvents(first: ?*Event) void {
    var e = first;
    while (e) |one| {
        e = one.next;
        heap.allocator.free(one.name);
        heap.allocator.destroy(one);
    }
}

pub const WatchError = error{ OutOfMemory, TooMany, Exists, Invalid };

/// `inotify_add_watch` for the normalized `path`: the watch descriptor,
/// the same one again for a path already watched (its mask replaced, or
/// added to with `IN_MASK_ADD`; `IN_MASK_CREATE` refuses it: `Exists`).
pub fn addWatch(inst: *Instance, path: []const u8, mask: u32) WatchError!i32 {
    if (mask & IN.MASK_ADD != 0 and mask & IN.MASK_CREATE != 0) return error.Invalid;
    if (mask & IN.ALL_EVENTS == 0) return error.Invalid;
    const copy = try heap.allocator.dupe(u8, path);
    errdefer heap.allocator.free(copy);
    const fresh = try heap.allocator.create(Watch);
    errdefer heap.allocator.destroy(fresh);
    const held = lock.acquire();
    defer lock.release(held);
    var w = inst.watches;
    while (w) |one| : (w = one.next) {
        if (!std.mem.eql(u8, one.path, path)) continue;
        if (mask & IN.MASK_CREATE != 0) return error.Exists;
        one.mask = if (mask & IN.MASK_ADD != 0) one.mask | mask else mask;
        heap.allocator.free(copy);
        heap.allocator.destroy(fresh);
        return one.wd;
    }
    if (inst.watch_count >= MAX_WATCHES) return error.TooMany;
    fresh.* = .{ .wd = inst.next_wd, .path = copy, .mask = mask, .next = inst.watches };
    inst.next_wd += 1;
    inst.watches = fresh;
    inst.watch_count += 1;
    return fresh.wd;
}

/// `inotify_rm_watch`: the watch goes, with an `IN_IGNORED` event. False
/// if there is no such watch.
pub fn removeWatch(inst: *Instance, wd: i32) bool {
    const event = heap.allocator.create(Event) catch null;
    const held = lock.acquire();
    defer lock.release(held);
    const gone = unlinkWatchLocked(inst, wd) orelse {
        if (event) |e| heap.allocator.destroy(e);
        return false;
    };
    heap.allocator.free(gone.path);
    heap.allocator.destroy(gone);
    if (event) |e| {
        e.* = .{ .wd = wd, .mask = IN.IGNORED, .cookie = 0, .name = &.{} };
        enqueueLocked(inst, e);
    }
    return true;
}

fn unlinkWatchLocked(inst: *Instance, wd: i32) ?*Watch {
    var link = &inst.watches;
    while (link.*) |one| : (link = &one.next) {
        if (one.wd != wd) continue;
        link.* = one.next;
        inst.watch_count -= 1;
        return one;
    }
    return null;
}

/// Put `e` at the end of the queue (or, past `MAX_EVENTS`, one overflow
/// event instead), and tell readers. The lock held.
fn enqueueLocked(inst: *Instance, e: *Event) void {
    if (inst.queued >= MAX_EVENTS) {
        // One overflow event at the end, and nothing more until it is read.
        const last = inst.tail.?;
        heap.allocator.free(e.name);
        if (last.mask == IN.Q_OVERFLOW) {
            heap.allocator.destroy(e);
            return;
        }
        e.* = .{ .wd = -1, .mask = IN.Q_OVERFLOW, .cookie = 0, .name = &.{} };
    }
    if (inst.tail) |t| t.next = e else inst.head = e;
    inst.tail = e;
    inst.queued += 1;
    inst.version +%= 1;
    _ = inst.readers.wakeAll();
    readiness.changed();
}

/// A new cookie for the two events of one rename.
pub fn newCookie() u32 {
    return next_cookie.fetchAdd(1, .monotonic);
}

fn parentOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    return if (slash == 0) "/" else path[0..slash];
}

/// `mask` happened to the thing at the normalized `path` (a directory if
/// `is_dir`): every watch on its directory hears it with its name, every
/// watch on it hears it without. `cookie` pairs the two halves of a
/// rename. A watch on it goes after `IN_DELETE_SELF` or `IN_MOVE_SELF`,
/// with `IN_IGNORED`.
pub fn notify(path: []const u8, mask: u32, cookie: u32, is_dir: bool) void {
    if (active.load(.acquire) == 0) return; // nobody watches anything
    if (path.len <= 1) return;
    const parent = parentOf(path);
    const name = path[(if (parent.len == 1) 1 else parent.len + 1)..];
    const dir_bit: u32 = if (is_dir) IN.ISDIR else 0;
    const self_mask: u32 = switch (mask) {
        IN.DELETE => IN.DELETE_SELF,
        IN.MOVED_FROM => IN.MOVE_SELF,
        IN.MOVED_TO, IN.CREATE => 0,
        else => mask,
    };
    const held = lock.acquire();
    defer lock.release(held);
    var inst = instances;
    while (inst) |one| : (inst = one.next) {
        var link = &one.watches;
        while (link.*) |w| {
            var remove = false;
            if (std.mem.eql(u8, w.path, parent) and w.mask & mask != 0) {
                queueLocked(one, w.wd, mask | dir_bit, cookie, name);
                if (w.mask & IN.ONESHOT != 0) remove = true;
            } else if (std.mem.eql(u8, w.path, path) and self_mask != 0 and (w.mask & self_mask != 0 or self_mask == IN.DELETE_SELF or self_mask == IN.MOVE_SELF)) {
                if (w.mask & self_mask != 0) queueLocked(one, w.wd, self_mask | (if (self_mask == IN.DELETE_SELF or self_mask == IN.MOVE_SELF) 0 else dir_bit), 0, "");
                // Gone from here: the watch goes (`IN_IGNORED`).
                if (self_mask == IN.DELETE_SELF or self_mask == IN.MOVE_SELF or w.mask & IN.ONESHOT != 0) remove = true;
            }
            if (remove) {
                link.* = w.next;
                one.watch_count -= 1;
                queueLocked(one, w.wd, IN.IGNORED, 0, "");
                heap.allocator.free(w.path);
                heap.allocator.destroy(w);
                continue;
            }
            link = &w.next;
        }
    }
}

/// An event made and queued with the lock held (the heap ranks after it);
/// dropped if there is no memory, as an overflow would drop it.
fn queueLocked(inst: *Instance, wd: i32, mask: u32, cookie: u32, name: []const u8) void {
    const e = heap.allocator.create(Event) catch return;
    const copy = heap.allocator.dupe(u8, name) catch {
        heap.allocator.destroy(e);
        return;
    };
    e.* = .{ .wd = wd, .mask = mask, .cookie = cookie, .name = copy };
    enqueueLocked(inst, e);
}

/// The size `struct inotify_event` takes for a name of `len` bytes: the
/// name with its NUL, padded to 16 bytes as Linux pads it (0 for none).
fn recordSize(len: usize) usize {
    const name_len = if (len == 0) 0 else std.mem.alignForward(usize, len + 1, 16);
    return 16 + name_len;
}

pub const ReadResult = union(enum) {
    /// Records written into the buffer: their length.
    bytes: usize,
    /// Nothing queued and the caller would not wait.
    again,
    /// The first record does not fit the buffer (`EINVAL`).
    too_small,
    /// A signal came, or the process is ending (`EINTR`).
    interrupted,
};

/// Take as many whole records as fit into `buf`, waiting for the first
/// unless `nonblock`.
pub fn read(inst: *Instance, buf: []u8, nonblock: bool) ReadResult {
    var taken: ?*Event = null;
    var taken_tail: ?*Event = null;
    var len: usize = 0;
    {
        const held = lock.acquire();
        defer lock.release(held);
        while (inst.head == null) {
            if (nonblock) return .again;
            if (!inst.readers.waitKillable(&lock)) return .interrupted;
        }
        if (recordSize(inst.head.?.name.len) > buf.len) return .too_small;
        while (inst.head) |e| {
            const size = recordSize(e.name.len);
            if (len + size > buf.len) break;
            const rec = buf[len..][0..size];
            @memset(rec, 0);
            std.mem.writeInt(i32, rec[0..4], e.wd, .little);
            std.mem.writeInt(u32, rec[4..8], e.mask, .little);
            std.mem.writeInt(u32, rec[8..12], e.cookie, .little);
            std.mem.writeInt(u32, rec[12..16], @intCast(size - 16), .little);
            @memcpy(rec[16..][0..e.name.len], e.name);
            len += size;
            inst.head = e.next;
            if (inst.head == null) inst.tail = null;
            inst.queued -= 1;
            e.next = null;
            if (taken_tail) |t| t.next = e else taken = e;
            taken_tail = e;
        }
    }
    freeEvents(taken);
    return .{ .bytes = len };
}

/// Whether there is something to read (`poll`), and the version (`epoll`).
pub fn state(inst: *Instance) struct { readable: bool, version: u64 } {
    const held = lock.acquire();
    defer lock.release(held);
    return .{ .readable = inst.head != null, .version = inst.version };
}

/// Instances there are, for tests.
pub fn count() usize {
    return active.load(.acquire);
}
