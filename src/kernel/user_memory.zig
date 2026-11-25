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
    const phys = pmm.allocZeroed() orelse return error.OutOfMemory;
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
pub fn mmap(p: *Process, hint: u64, length: u64, prot_bits: u64, flags: u64, fd: u64) u64 {
    _ = fd; // ignored with MAP_ANONYMOUS, as on Linux
    const prot = protFromAbi(prot_bits) orelse return abi.err(.INVAL);
    if (length == 0) return abi.err(.INVAL);
    if (length > MAP_MAX) return abi.err(.NOMEM); // more than an address space holds
    const len = std.mem.alignForward(u64, length, PAGE);
    if (flags & abi.MAP.ANONYMOUS == 0) return abi.err(.NODEV); // no file mappings yet
    const sharing = flags & (abi.MAP.SHARED | abi.MAP.PRIVATE);
    if (sharing == 0 or sharing == (abi.MAP.SHARED | abi.MAP.PRIVATE)) return abi.err(.INVAL);
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
        const wanted = std.mem.alignForward(u64, hint, PAGE);
        addr = if (hint != 0 and mappable(wanted, len) and p.mem.regions.isFree(wanted, len))
            wanted
        else
            p.mem.regions.findFree(len, MAP_MIN, p.mem.mmap_top) orelse return abi.err(.NOMEM);
    }
    p.mem.regions.add(heap.allocator, addr, len, prot, .anon) catch |e| return mapError(e);
    return addr;
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
