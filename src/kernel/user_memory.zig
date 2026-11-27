//! The memory of a running program: regions, and pages given on demand.
//!
//! A process's address space is described by its regions
//! (`vm_regions.zig`): the program's segments, the stack, the `brk` heap
//! and its `mmap`s. Anonymous memory is not there until it is touched:
//! `mmap` and `brk` only record a region, the first access to a page
//! faults, and `handleFault` gives it a zeroed page. So a program can
//! reserve address space far beyond the machine's memory (garbage
//! collectors reserve tens of gigabytes) and pay for what it uses.
//!
//! ## What a process pays
//!
//! Every page given on demand, and every page table that had to be added
//! for it, counts against the process's memory limit
//! (`process.Limits.max_pages`), like the pages of its program. `munmap`
//! and the like give the count back. Reserving costs nothing.
//!
//! ## Running out
//!
//! When a fault cannot be given a page (the machine has none left, or the
//! process is at its limit), the process is killed, as for any fault it
//! cannot recover from; nothing else is. A system call that needs memory
//! fails with `ENOMEM` instead.
//!
//! ## Permissions
//!
//! A region's permissions are in its pages' entries: writable or not,
//! executable or not. A region with no permissions (`PROT_NONE`) keeps
//! pages it already has, with the program locked out of them, so
//! protecting memory and unprotecting it again loses nothing.
//!
//! ## Locking
//!
//! A process's regions, `brk` and page tables are protected by its
//! address-space lock (`docs/locking.md`). The page-fault handler takes it
//! too. Pages are allocated under it; the list of regions may allocate
//! from the heap under it. Both rank after it.

const std = @import("std");

const abi = @import("abi");
const vmm = @import("../arch/x86_64/vmm.zig");
const heap = @import("heap.zig");
const pmm = @import("pmm.zig");
const proc = @import("process.zig");
const Process = proc.Process;
const SpinLock = @import("sync/spinlock.zig").SpinLock;
const vm_regions = @import("vm_regions.zig");
const vfs = @import("vfs.zig");
const Prot = vm_regions.Prot;

const PAGE = pmm.PAGE_SIZE;

/// The memory state of one process, part of `Process`.
pub const UserMemory = struct {
    lock: SpinLock = .{ .rank = .address_space },
    regions: vm_regions.Regions = .{},
    /// Where the `brk` heap starts (the page after the program) and its
    /// current end, which need not be page aligned.
    brk_start: u64 = 0,
    brk_end: u64 = 0,
    /// Mappings without a fixed address go below this: the bottom of the
    /// stack's reservation, less a gap.
    mmap_top: u64 = 0,
};

/// Lowest and highest address a mapping may have.
const MAP_MIN = proc.IMAGE_MIN;
const MAP_MAX = vmm.USER_MAP_END;
/// Address space kept free between the stack's reservation and the mappings.
const STACK_GAP: u64 = 256 * PAGE;

/// The page-table bits for a page of a region with permissions `prot`.
fn pteFlags(prot: Prot) u64 {
    if (!prot.any()) return vmm.NX; // present for the kernel's bookkeeping, not for the program
    var flags: u64 = vmm.USER;
    if (prot.write) flags |= vmm.WRITABLE;
    if (!prot.exec) flags |= vmm.NX;
    return flags;
}

fn protFromAbi(prot: u64) ?Prot {
    if (prot & ~@as(u64, abi.PROT.READ | abi.PROT.WRITE | abi.PROT.EXEC) != 0) return null;
    return .{
        .read = prot & abi.PROT.READ != 0,
        .write = prot & abi.PROT.WRITE != 0,
        .exec = prot & abi.PROT.EXEC != 0,
    };
}

/// Record a region of a process that is being created (its program
/// segments, its stack). No locking: nothing else can see the process yet.
pub fn addInitialRegion(p: *Process, start: u64, len: u64, prot: Prot, kind: vm_regions.Kind) !void {
    p.mem.regions.add(heap.allocator, start, len, prot, kind) catch |e| return switch (e) {
        error.OutOfMemory, error.TooManyRegions => error.OutOfMemory,
        else => error.BadSegment,
    };
}

/// Free what `p.mem` holds besides the address space itself. Called when
/// the process exits.
pub fn deinit(p: *Process) void {
    p.mem.regions.deinit(heap.allocator);
}

/// Why a page fault could not be resolved.
pub const FaultError = error{
    /// The address is in no region, or the region does not allow the access.
    BadAccess,
    /// It is a valid access to a page the process cannot be given.
    OutOfMemory,
};

/// What the program was doing when it faulted.
pub const Access = struct {
    write: bool,
    exec: bool,
    /// The page was mapped: the access broke its permissions.
    present: bool,
};

/// Resolve a page fault at `addr` in the address space of `p`: if the
/// address is in a region that allows the access and has no page there
/// yet, give it a zeroed one. Returns normally if the faulting instruction
/// can be run again. Interrupts are off. Called for faults from ring 3
/// and for faults on user addresses inside a user copy.
pub fn handleFault(p: *Process, addr: u64, access: Access) FaultError!void {
    if (addr >= vmm.USER_END) return error.BadAccess;
    const held = p.mem.lock.acquire();
    defer p.mem.lock.release(held);

    const region = p.mem.regions.find(addr) orelse return error.BadAccess;
    const allowed = if (access.exec) region.prot.exec else if (access.write) region.prot.write else region.prot.read;
    if (!allowed) return error.BadAccess;
    const page = addr & ~@as(u64, PAGE - 1);
    if (access.present) {
        // Permissions are right and the page is there: another CPU gave
        // it between the fault and now, or this CPU's TLB still had the
        // entry from before the permissions were widened. Run it again.
        const entry = vmm.leafEntry(p.root, page) orelse return error.BadAccess;
        const want = pteFlags(region.prot);
        if (entry & (vmm.USER | vmm.WRITABLE) == want & (vmm.USER | vmm.WRITABLE)) {
            vmm.flushLocal(page, 1);
            return;
        }
        return error.BadAccess;
    }
    if (vmm.leafEntry(p.root, page) != null) return; // given meanwhile

    if (p.pages + 1 > p.limits.max_pages) return error.OutOfMemory;
    // A page of a file is filled from it, and what is past the file's end
    // within its last page is zero. A page wholly past the end is not
    // there (Linux: SIGBUS).
    var node: vfs.Node = undefined;
    var file_offset: u64 = 0;
    if (region.kind == .file) {
        node = nodeOf(region.backing);
        file_offset = region.fileOffset(page);
        if (file_offset >= node.size) return error.BadAccess;
    }
    const phys = pmm.allocZeroed() orelse return error.OutOfMemory;
    if (region.kind == .file) {
        // (The file is in memory, so reading it cannot wait; a file on a
        // disk will have to be read before this lock is taken.)
        _ = node.ops.read(&node, file_offset, pmm.physToVirt(phys)[0..PAGE]);
    }
    var tables: usize = 0;
    vmm.mapCounting(p.root, page, phys, pteFlags(region.prot), &tables) catch |e| {
        pmm.free(phys);
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.AlreadyMapped => {},
        };
    };
    p.pages += 1 + tables;
}

/// Remove `[start, start + len)` from the regions of `p` and free what was
/// mapped there. The lock must be held.
fn unmapLocked(p: *Process, start: u64, len: u64) vm_regions.Error!void {
    try p.mem.regions.remove(heap.allocator, start, len);
    releasePages(p, start, start + len);
}

/// Free the pages mapped in `[start, end)` and give their count back. The
/// regions are left as they are. The lock must be held.
fn releasePages(p: *Process, start: u64, end: u64) void {
    const freed = vmm.unmapUserRange(p.root, start, end);
    p.pages -|= freed;
}

fn mapError(e: vm_regions.Error) u64 {
    return switch (e) {
        error.OutOfMemory, error.TooManyRegions, error.NotMapped => abi.err(.NOMEM),
        error.BadRange => abi.err(.INVAL),
        error.Overlap => abi.err(.EXIST),
    };
}

/// True if `[addr, addr + len)` is a page-aligned range a program may map.
fn mappable(addr: u64, len: u64) bool {
    if (addr % PAGE != 0 or addr < MAP_MIN or addr > MAP_MAX) return false;
    return len <= MAP_MAX - addr;
}

/// `mmap`: anonymous memory only. Returns the address, or an error value.
pub fn mmap(p: *Process, hint: u64, length: u64, prot_bits: u64, flags: u64, file: ?FileMap) u64 {
    const prot = protFromAbi(prot_bits) orelse return abi.err(.INVAL);
    if (length == 0) return abi.err(.INVAL);
    if (length > MAP_MAX) return abi.err(.NOMEM); // more than an address space holds
    const len = std.mem.alignForward(u64, length, PAGE);
    const sharing = flags & (abi.MAP.SHARED | abi.MAP.PRIVATE);
    if (sharing == 0 or sharing == (abi.MAP.SHARED | abi.MAP.PRIVATE)) return abi.err(.INVAL);
    const anonymous = flags & abi.MAP.ANONYMOUS != 0;
    if (!anonymous) {
        const f = file orelse return abi.err(.BADF);
        if (f.offset % PAGE != 0) return abi.err(.INVAL);
        if (f.offset > MAP_MAX or len > MAP_MAX - f.offset) return abi.err(.INVAL); // Linux: EOVERFLOW
        // Files cannot be written: a shared mapping may only be read, and
        // is then the same as a private one.
        if (sharing == abi.MAP.SHARED and prot.write) return abi.err(.ACCES);
    }
    const fixed = flags & (abi.MAP.FIXED | abi.MAP.FIXED_NOREPLACE) != 0;

    const held = p.mem.lock.acquire();
    defer p.mem.lock.release(held);

    var addr: u64 = undefined;
    if (fixed) {
        if (!mappable(hint, len)) return abi.err(if (hint % PAGE != 0) .INVAL else .NOMEM);
        addr = hint;
        if (flags & abi.MAP.FIXED_NOREPLACE != 0) {
            if (!p.mem.regions.isFree(addr, len)) return abi.err(.EXIST);
        } else unmapLocked(p, addr, len) catch |e| return mapError(e);
    } else {
        // The hint, if it is free; otherwise the highest free place.
        // (A hint beyond user space is no hint; rounding it up could wrap.)
        const wanted = if (hint <= MAP_MAX) std.mem.alignForward(u64, hint, PAGE) else 0;
        addr = if (wanted != 0 and mappable(wanted, len) and p.mem.regions.isFree(wanted, len))
            wanted
        else
            p.mem.regions.findFree(len, MAP_MIN, p.mem.mmap_top) orelse return abi.err(.NOMEM);
    }
    if (anonymous) {
        p.mem.regions.add(heap.allocator, addr, len, prot, .anon) catch |e| return mapError(e);
    } else {
        const f = file.?;
        const backing: vm_regions.Backing = .{ .file = .{ f.node.size, f.node.ctx, @intFromPtr(f.node.ops) }, .offset = f.offset };
        p.mem.regions.addBacked(heap.allocator, addr, len, prot, .file, backing) catch |e| return mapError(e);
    }
    return addr;
}

/// The file behind a mapping and where in it the mapping starts.
pub const FileMap = struct {
    node: vfs.Node,
    offset: u64,
};

/// The file a region was made for: its three words are the node's fields.
fn nodeOf(backing: vm_regions.Backing) vfs.Node {
    return .{ .size = backing.file[0], .ctx = backing.file[1], .ops = @ptrFromInt(backing.file[2]) };
}

/// `mremap`: change the size of the mapping at `addr` from `old_length`
/// to `new_length` and return its address.
///
/// Shrinking unmaps the end. Growing takes the addresses after the
/// mapping if they are free; the new part is anonymous memory with the
/// mapping's protection (or more of the file, for a file's mapping). If
/// they are not free, or the range is not the end of its mapping, the
/// mapping is moved with `MREMAP_MAYMOVE`: to free addresses, or to
/// `new_addr` with `MREMAP_FIXED` too, which first unmaps what is there.
/// Moving moves the pages (their page-table entries), not their contents.
///
/// `EINVAL` for an unaligned address, a zero length, unknown flags,
/// `MREMAP_FIXED` without `MREMAP_MAYMOVE`, or a fixed address that
/// overlaps the old range; `EFAULT` if the old range is not all mapped as
/// one mapping; `ENOMEM` if it cannot grow where it is and may not move,
/// or there is no room or memory to move it.
pub fn mremap(p: *Process, addr: u64, old_length: u64, new_length: u64, flags: u64, new_addr: u64) u64 {
    if (flags & ~@as(u64, abi.MREMAP.MAYMOVE | abi.MREMAP.FIXED) != 0) return abi.err(.INVAL);
    const may_move = flags & abi.MREMAP.MAYMOVE != 0;
    const fixed = flags & abi.MREMAP.FIXED != 0;
    if (fixed and !may_move) return abi.err(.INVAL);
    if (addr % PAGE != 0 or old_length == 0 or new_length == 0) return abi.err(.INVAL);
    if (old_length > MAP_MAX or new_length > MAP_MAX) return abi.err(.NOMEM);
    const old_len = std.mem.alignForward(u64, old_length, PAGE);
    const new_len = std.mem.alignForward(u64, new_length, PAGE);
    if (!mappable(addr, old_len)) return abi.err(.FAULT);
    if (fixed) {
        if (new_addr % PAGE != 0) return abi.err(.INVAL);
        if (!mappable(new_addr, new_len)) return abi.err(.NOMEM);
        if (new_addr < addr + old_len and addr < new_addr + new_len) return abi.err(.INVAL); // overlap
    }

    const held = p.mem.lock.acquire();
    defer p.mem.lock.release(held);
    const region = p.mem.regions.find(addr) orelse return abi.err(.FAULT);
    if (region.end - addr < old_len) return abi.err(.FAULT);
    if (!fixed) {
        if (new_len == old_len) return addr;
        if (new_len < old_len) {
            unmapLocked(p, addr + new_len, old_len - new_len) catch |e| return mapError(e);
            return addr;
        }
        // The end of a mapping can grow into free addresses where it is.
        const tail = addr + old_len;
        const more = new_len - old_len;
        if (tail == region.end and (region.kind == .anon or region.kind == .file) and mappable(tail, more) and
            tail + more <= p.mem.mmap_top and p.mem.regions.isFree(tail, more))
        {
            if (region.kind == .file) {
                var b = region.backing;
                b.offset = region.fileOffset(tail);
                p.mem.regions.addBacked(heap.allocator, tail, more, region.prot, .file, b) catch |e| return mapError(e);
            } else p.mem.regions.add(heap.allocator, tail, more, region.prot, .anon) catch |e| return mapError(e);
            return addr;
        }
        if (!may_move) return abi.err(.NOMEM);
    }
    return moveLocked(p, region, addr, old_len, new_len, if (fixed) new_addr else null);
}

/// The moving part of `mremap`: `[addr, addr + old_len)` of `region` goes
/// to `dest` (or the highest free place) as a mapping of `new_len` bytes.
/// The lock must be held.
fn moveLocked(p: *Process, region: vm_regions.Region, addr: u64, old_len: u64, new_len: u64, dest: ?u64) u64 {
    // Room first for what changes below (unmapping at the destination and
    // at the old place may each cut a region in two, and the new one is
    // one more), so that nothing can fail halfway for want of memory.
    p.mem.regions.reserve(heap.allocator, 6) catch |e| return mapError(e);
    if (dest) |d| unmapLocked(p, d, new_len) catch |e| return mapError(e);
    const to = dest orelse (p.mem.regions.findFree(new_len, MAP_MIN, p.mem.mmap_top) orelse return abi.err(.NOMEM));
    // The new mapping is what the old one was, from `addr` on: a file's
    // goes on at the same place in the file; anything else is anonymous
    // memory from now on (the stack and the heap keep their own regions).
    if (region.kind == .file) {
        var b = region.backing;
        b.offset = region.fileOffset(addr);
        p.mem.regions.addBacked(heap.allocator, to, new_len, region.prot, .file, b) catch |e| return mapError(e);
    } else p.mem.regions.add(heap.allocator, to, new_len, region.prot, .anon) catch |e| return mapError(e);

    // The pages that are there, one by one; on running out of memory (for
    // page tables at the new place), the moved ones go back, which needs
    // none: their old tables are still there.
    const moved = @min(old_len, new_len);
    var off: u64 = 0;
    var added: usize = 0;
    while (off < moved) : (off += PAGE) {
        var tables: usize = 0;
        if (p.pages + 3 > p.limits.max_pages) break; // room for the tables it may need
        _ = vmm.moveUserPage(p.root, addr + off, to + off, &tables) catch break;
        added += tables;
        p.pages += tables;
    }
    if (off < moved) {
        var back: u64 = 0;
        while (back < off) : (back += PAGE) {
            var none: usize = 0;
            _ = vmm.moveUserPage(p.root, to + back, addr + back, &none) catch unreachable;
        }
        vmm.flushUserRange(p.root, to, off / PAGE);
        p.mem.regions.remove(heap.allocator, to, new_len) catch {};
        releasePages(p, to, to + new_len); // the tables added for it
        return abi.err(.NOMEM);
    }
    vmm.flushUserRange(p.root, addr, old_len / PAGE);
    // The old range: out of the regions, and its emptied tables freed (its
    // pages are at the new place; beyond `new_len` when shrinking they are
    // still here, and go too).
    unmapLocked(p, addr, old_len) catch {};
    return to;
}

/// The mappings of `p` as `/proc/self/maps` lists them, one a line, lowest
/// first: `start-end perms offset dev inode name`, with the name given
/// for the stack and the heap. In memory the caller frees with
/// `heap.allocator`.
pub fn describe(p: *Process) error{OutOfMemory}![]u8 {
    const LINE = 96; // more than the longest line
    // The text is written with the lock held and the memory for it cannot
    // be got then: room for the regions there are now and some more, and
    // again from the start if they have become more than that meanwhile.
    var room: usize = 0;
    while (true) {
        {
            const held = p.mem.lock.acquire();
            defer p.mem.lock.release(held);
            room = @max(room, (p.mem.regions.items().len + 16) * LINE);
        }
        const buf = try heap.allocator.alloc(u8, room);
        var len: usize = 0;
        const fits = blk: {
            const held = p.mem.lock.acquire();
            defer p.mem.lock.release(held);
            for (p.mem.regions.items()) |r| {
                if (buf.len - len < LINE) break :blk false;
                const line = std.fmt.bufPrint(buf[len..], "{x:0>8}-{x:0>8} {c}{c}{c}p {x:0>8} 00:00 0 {s}\n", .{
                    r.start,
                    r.end,
                    @as(u8, if (r.prot.read) 'r' else '-'),
                    @as(u8, if (r.prot.write) 'w' else '-'),
                    @as(u8, if (r.prot.exec) 'x' else '-'),
                    if (r.kind == .file) r.backing.offset else 0,
                    switch (r.kind) {
                        .stack => "                         [stack]",
                        .heap => "                         [heap]",
                        .image, .anon, .file => "",
                    },
                }) catch break :blk false;
                len += line.len;
            }
            break :blk true;
        };
        defer heap.allocator.free(buf);
        if (fits) return heap.allocator.dupe(u8, buf[0..len]); // exactly as long as the text
        room *= 2;
    }
}

/// Whether `addr` is in one of the mappings of `p`: what tells a fault on
/// memory the program may not touch that way (`SEGV_ACCERR`) from one on
/// memory that is not there (`SEGV_MAPERR`).
pub fn isMapped(p: *Process, addr: u64) bool {
    const held = p.mem.lock.acquire();
    defer p.mem.lock.release(held);
    return p.mem.regions.find(addr) != null;
}

/// `munmap`.
pub fn munmap(p: *Process, addr: u64, length: u64) u64 {
    if (length == 0 or addr % PAGE != 0 or length > MAP_MAX) return abi.err(.INVAL);
    const len = std.mem.alignForward(u64, length, PAGE);
    if (!mappable(addr, len)) return abi.err(.INVAL);
    const held = p.mem.lock.acquire();
    defer p.mem.lock.release(held);
    unmapLocked(p, addr, len) catch |e| return mapError(e);
    return 0;
}

/// `mprotect`.
pub fn mprotect(p: *Process, addr: u64, length: u64, prot_bits: u64) u64 {
    const prot = protFromAbi(prot_bits) orelse return abi.err(.INVAL);
    if (addr % PAGE != 0 or length > MAP_MAX) return abi.err(.INVAL);
    if (length == 0) return 0;
    const len = std.mem.alignForward(u64, length, PAGE);
    if (!mappable(addr, len)) return abi.err(.NOMEM);
    const held = p.mem.lock.acquire();
    defer p.mem.lock.release(held);
    p.mem.regions.protect(heap.allocator, addr, len, prot) catch |e| return mapError(e);
    vmm.protectUserRange(p.root, addr, addr + len, pteFlags(prot));
    return 0;
}

/// `madvise`: `MADV_DONTNEED` and `MADV_FREE` give the pages back (they
/// read as zeroes when touched again); other advice is accepted and
/// ignored, as it may be.
pub fn madvise(p: *Process, addr: u64, length: u64, advice: u64) u64 {
    if (addr % PAGE != 0 or length > MAP_MAX) return abi.err(.INVAL);
    if (length == 0) return 0;
    const len = std.mem.alignForward(u64, length, PAGE);
    if (!mappable(addr, len)) return abi.err(.NOMEM);
    const held = p.mem.lock.acquire();
    defer p.mem.lock.release(held);
    if (!p.mem.regions.isCovered(addr, len)) return abi.err(.NOMEM);
    switch (advice) {
        abi.MADV.DONTNEED, abi.MADV.FREE => {
            // Only anonymous memory can be given back and come back as
            // zeroes; the program's own segments keep their contents.
            var at = addr;
            while (at < addr + len) {
                const region = p.mem.regions.find(at).?;
                const end = @min(region.end, addr + len);
                if (region.kind != .image) releasePages(p, at, end);
                at = end;
            }
        },
        else => {},
    }
    return 0;
}

/// `brk`: move the end of the heap to `addr` and return where it is now.
/// A request that cannot be met (below the start, into another mapping, or
/// no memory for the bookkeeping) changes nothing and returns the current
/// end, which is how the call reports failure.
pub fn brk(p: *Process, addr: u64) u64 {
    const held = p.mem.lock.acquire();
    defer p.mem.lock.release(held);
    const m = &p.mem;
    if (addr < m.brk_start or addr > MAP_MAX) return m.brk_end;
    const old_top = std.mem.alignForward(u64, m.brk_end, PAGE);
    const new_top = std.mem.alignForward(u64, addr, PAGE);
    if (new_top > old_top) {
        m.regions.add(heap.allocator, old_top, new_top - old_top, Prot.rw, .heap) catch return m.brk_end;
        // One region for the whole heap, however it grew.
        mergeHeap(p);
    } else if (new_top < old_top) {
        unmapLocked(p, new_top, old_top - new_top) catch return m.brk_end;
    }
    m.brk_end = addr;
    return addr;
}

/// The heap grows by adding a region above it; make the two one.
fn mergeHeap(p: *Process) void {
    const list = p.mem.regions.list.items;
    for (list, 0..) |*r, i| {
        if (r.kind != .heap or i + 1 >= list.len) continue;
        const next = list[i + 1];
        if (next.kind == .heap and next.start == r.end and next.prot.eql(r.prot)) {
            r.end = next.end;
            _ = p.mem.regions.list.orderedRemove(i + 1);
            return;
        }
    }
}
