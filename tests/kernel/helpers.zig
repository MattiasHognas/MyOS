//! Kernel-side helpers for the in-kernel tests.
//!
//! These reach into the running kernel through `@import("root")`, so they use
//! the kernel's own module instances (and their global state) rather than
//! second copies. Each helper does one measurable thing and reports the
//! result; the test cases in `main.zig` decide what is expected.

const std = @import("std");
const kernel_root = @import("root");
const cpu = kernel_root.arch.x86_64.cpu;
const vmm = kernel_root.arch.x86_64.vmm;
const usercopy = kernel_root.arch.x86_64.usercopy;
const idt = kernel_root.arch.x86_64.idt;
const gdt = kernel_root.arch.x86_64.gdt;
const uaccess = kernel_root.kernel.uaccess;
const nvme = kernel_root.drivers.nvme;
const elf = kernel_root.kernel.elf;
const heap = kernel_root.kernel.heap;
const kstack = kernel_root.kernel.kstack;
const pmm = kernel_root.kernel.pmm;
const process = kernel_root.kernel.process;
const thread = kernel_root.kernel.thread;
const vfs = kernel_root.kernel.vfs;
const tarfs = kernel_root.kernel.fs.tarfs;
const backtrace = kernel_root.kernel.debug.backtrace;
const percpu = kernel_root.arch.x86_64.percpu;
const fpu = kernel_root.arch.x86_64.fpu;
const apic = kernel_root.arch.x86_64.apic;
const arch_syscall = kernel_root.arch.x86_64.syscall;
const abi = kernel_root.abi;
const hpet = kernel_root.drivers.hpet;
/// Where program images may be loaded and how large they may be.
pub const image_limits = process.image_limits;
/// The limits a process gets by default.
pub const Limits = process.Limits;
/// Bytes in a kernel stack, and the usage above which the run should fail.
pub const STACK_SIZE = kstack.STACK_SIZE;
pub const STACK_WARN_BYTES = kstack.WARN_BYTES;

/// Result of loading an ELF image for inspection (see `elfProbe`).
pub const ElfProbe = struct {
    /// Entry point returned by the loader.
    entry: u64,
    /// Leaf page-table entry mapping the probed address, or 0 if unmapped.
    pte: u64,
};

/// Return the number of free physical pages.
pub fn freePages() usize {
    return pmm.free_pages;
}

/// Return true if a file exists at `path`.
pub fn hasFile(path: []const u8) bool {
    return vfs.lookup(path) != null;
}

/// Return the size of the file at `path`, or null if it doesn't exist.
pub fn fileSize(path: []const u8) ?u64 {
    const node = vfs.lookup(path) orelse return null;
    return node.size;
}

/// Read from the file at `path` starting at `offset` into
/// `buf`. Returns the number of bytes read, or null if the file doesn't exist.
pub fn readFileAt(
    path: []const u8,
    offset: u64,
    buf: []u8,
) ?usize {
    const node = vfs.lookup(path) orelse return null;
    return vfs.read(&node, offset, buf);
}

/// Write a pattern to both ends of physical page `page` through
/// The HHDM and return true if it reads back correctly.
pub fn pageRw(page: u64) bool {
    const memory =
        pmm.physToVirt(page)[0..pmm.PAGE_SIZE];

    memory[0] = 0xA5;
    memory[pmm.PAGE_SIZE - 1] = 0x5A;

    return memory[0] == 0xA5 and
        memory[pmm.PAGE_SIZE - 1] == 0x5A;
}

/// Allocate 257 bytes from the kernel heap, fill and verify
/// Them, then free them. Returns false on allocation failure or mismatch.
pub fn heapRoundtrip() bool {
    const memory = heap.allocator.alloc(
        u8,
        257,
    ) catch return false;

    defer heap.allocator.free(memory);

    @memset(memory, 0xBC);

    for (memory) |byte| {
        if (byte != 0xBC) return false;
    }

    return true;
}

/// Create and destroy an address space and return true if
/// Exactly one page was used and all pages were given back.
pub fn addressSpaceRoundtrip() bool {
    const before = pmm.free_pages;
    const address_space =
        vmm.createAddressSpace() catch return false;

    if (pmm.free_pages + 1 != before) {
        vmm.destroyAddressSpace(address_space);
        return false;
    }

    vmm.destroyAddressSpace(address_space);

    return pmm.free_pages == before;
}

/// Load the ELF `image` into a fresh address space, then report
/// Its entry point and the leaf page-table entry mapping `addr`, and copy the
/// Bytes at `addr` (up to the end of that page) into `out`. Returns null if
/// Loading fails. The address space is always destroyed again.
pub fn elfProbe(image: []const u8, addr: u64, out: []u8) ?ElfProbe {
    const root = vmm.createAddressSpace() catch return null;
    defer vmm.destroyAddressSpace(root);
    const entry = (elf.load(root, image, process.image_limits) catch return null).entry;
    const pte = vmm.leafEntry(root, addr) orelse 0;
    if (vmm.translate(root, addr)) |phys| {
        const n = @min(out.len, pmm.PAGE_SIZE - (addr % pmm.PAGE_SIZE));
        @memcpy(out[0..n], pmm.physToVirt(phys)[0..n]);
    }
    return .{ .entry = entry, .pte = pte };
}

/// Load the ELF `image` into a fresh address space, destroy it again and
/// return the loader's error, or null if the image loaded.
pub fn elfLoadError(image: []const u8) ?elf.Error {
    const root = vmm.createAddressSpace() catch return error.OutOfMemory;
    defer vmm.destroyAddressSpace(root);
    _ = elf.load(root, image, process.image_limits) catch |e| return e;
    return null;
}

/// `elfProbe` on the file at `path`.
pub fn elfProbePath(path: []const u8, addr: u64, out: []u8) ?ElfProbe {
    const node = vfs.lookup(path) orelse return null;
    const image = heap.allocator.alloc(u8, node.size) catch return null;
    defer heap.allocator.free(image);
    if (vfs.read(&node, 0, image) != node.size) return null;
    return elfProbe(image, addr, out);
}

/// Return true if `process.spawn` rejects `image` and leaves
/// Physical memory and the heap exactly as they were (full rollback).
pub fn spawnFailsCleanly(image: []const u8) bool {
    const pages = pmm.free_pages;
    const in_use = heap.stats().bytes_in_use;
    _ = process.spawn("bad", image, .{}) catch
        return pmm.free_pages == pages and heap.stats().bytes_in_use == in_use;
    return false; // it started; the test fails (the process runs on its own)
}

/// Run the program at `path` as a child process of the current
/// Thread and wait for it. Returns its exit code (255 if it was killed by a
/// Fault), or null if it could not be started.
pub fn runProgram(path: []const u8) ?u64 {
    return runProgramLimited(path, .{});
}

/// `runProgram` with `limits` on the new process (and, by inheritance, on
/// everything it starts).
pub fn runProgramLimited(path: []const u8, limits: Limits) ?u64 {
    const me = thread.current();
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    _ = process.spawnPath(path, .{ .waiter = me, .limits = limits }) catch return null;
    thread.block(); // until the child calls process.exit
    return me.wake_value;
}

/// Try to start the program at `path` with `limits` and return the error
/// that stopped it. Null means it started (and now runs on its own).
pub fn spawnError(path: []const u8, limits: Limits) ?anyerror {
    _ = process.spawnPath(path, .{ .limits = limits }) catch |e| return e;
    return null;
}

/// Bytes currently allocated from the kernel heap.
pub fn heapInUse() usize {
    return heap.stats().bytes_in_use;
}

// State shared by the scheduler test's worker threads.
var sched_log: [8]u8 = undefined;
var sched_len: usize = 0;
var sched_done: usize = 0;
var sched_waiter: ?*thread.Thread = null;

/// Scheduler test worker: append `tag` to the log three times, yielding after
/// Each, then report completion. Interrupts stay off so only the explicit
/// Yields switch threads, which makes the interleaving deterministic.
fn schedWorker(tag: u8) void {
    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    for (0..3) |_| {
        if (sched_len < sched_log.len) sched_log[sched_len] = tag;
        sched_len += 1;
        thread.yield();
    }
    sched_done += 1;
    if (sched_done == 2) thread.wake(sched_waiter.?);
}

/// First scheduler test worker.
fn schedWorkerA() void {
    schedWorker('A');
}

/// Second scheduler test worker.
fn schedWorkerB() void {
    schedWorker('B');
}

/// Run two kernel threads that yield to each other and check
/// That they alternate in FIFO order, that the waiting thread is woken when
/// Both are done, and that their stacks and thread structs are freed.
pub fn schedulerRoundRobin() bool {
    const in_use = heap.stats().bytes_in_use;
    const stacks = kstack.inUse();
    const pages = pmm.free_pages;
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    sched_len = 0;
    sched_done = 0;
    sched_waiter = thread.current();
    const a = thread.spawn(schedWorkerA, null) catch return false;
    const b = thread.spawn(schedWorkerB, null) catch return false;
    if (b.id <= a.id or a.state != .ready) return false;
    while (sched_done < 2) thread.block();
    return sched_len == 6 and
        std.mem.eql(u8, sched_log[0..6], "ABABAB") and
        heap.stats().bytes_in_use == in_use and // both threads reaped,
        kstack.inUse() == stacks and pmm.free_pages == pages; // with their stacks
}

/// A wake that arrives before `block` must make `block`
/// Return immediately (otherwise this test hangs and times out).
pub fn wakeBeforeBlock() bool {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const me = thread.current();
    thread.wake(me);
    if (!me.wake_pending or me.state != .running) return false;
    thread.block();
    return !me.wake_pending and me.state == .running;
}

/// Mount the tar archive `image`, read the file at `path` from
/// `offset` into `buf`, then remount the initrd. Returns the bytes read, or
/// Null if the file is not found.
pub fn tarfsRead(image: []const u8, path: []const u8, offset: u64, buf: []u8) ?usize {
    const fs = tarfs.init(image);
    defer _ = tarfs.init(kernel_root.initrd_image);
    const node = fs.lookup(fs.ctx, path) orelse return null;
    return vfs.read(&node, offset, buf);
}

/// Read the sector at `lba` from the NVMe disk into `buf`.
/// Returns the sector's bytes, or null if there is no working NVMe disk or
/// The read fails.
pub fn nvmeRead(lba: u64, buf: []u8) ?[]u8 {
    if (!kernel_root.nvme_ready) return null;
    nvme.read(lba, 1, buf) catch return null;
    return buf[0..nvme.sector_size];
}

/// Return the name of the function containing code address
/// `addr`, or null if it can't be symbolized.
pub fn symbolize(addr: u64) ?[]const u8 {
    const sym = backtrace.symbolize(addr) orelse return null;
    return sym.name;
}

/// Store the return addresses of the caller's frame chain in
/// `out`, innermost first (the first one points into the caller).
pub noinline fn captureBacktrace(out: []u64) usize {
    return backtrace.capture(@frameAddress(), out);
}

/// In a fresh address space, map one user page, check that
/// `vmm.translate` finds it (including an offset into the page) and that
/// Neighbouring pages are unmapped, then destroy the address space and check
/// That no physical pages leaked.
pub fn vmmMapTranslate() bool {
    const before = pmm.free_pages;
    const root = vmm.createAddressSpace() catch return false;
    const virt: u64 = 0x40_0000;
    const phys = pmm.alloc() orelse {
        vmm.destroyAddressSpace(root);
        return false;
    };
    vmm.map(root, virt, phys, vmm.USER | vmm.WRITABLE, false) catch return false;
    const ok = vmm.translate(root, virt) == phys and
        vmm.translate(root, virt + 0x123) == phys + 0x123 and
        vmm.translate(root, virt + pmm.PAGE_SIZE) == null and
        vmm.translate(root, virt - pmm.PAGE_SIZE) == null and
        vmm.translate(root, 0x7FFF_0000_0000) == null;
    vmm.destroyAddressSpace(root); // frees the mapped page and its tables too
    return ok and pmm.free_pages == before;
}

/// Check that the heap usage counters track an allocation,
/// A shrink and a free, and return to their starting value.
pub fn heapStats() bool {
    const s0 = heap.stats();
    const mem = heap.allocator.alloc(u8, 100) catch return false;
    const s1 = heap.stats();
    const shrunk = heap.allocator.resize(mem, 20);
    const s2 = heap.stats();
    heap.allocator.free(mem[0..20]);
    const s3 = heap.stats();
    return s1.allocs == s0.allocs + 1 and
        s1.bytes_in_use == s0.bytes_in_use + 112 and // 100 rounded up to 16
        s1.peak_bytes >= s1.bytes_in_use and
        shrunk and s2.bytes_in_use == s0.bytes_in_use + 32 and
        s3.frees == s0.frees + 1 and
        s3.bytes_in_use == s0.bytes_in_use and
        s3.bytes_mapped >= s3.bytes_in_use;
}

/// Address of the user page mapped by `enterUserPageSpace`.
pub const USER_PAGE: u64 = 0x40_0000;

/// Allocate a zeroed page and map it at `virt` in `root` with `flags`.
/// Returns its physical address, or null if memory ran out.
fn mapUserPage(root: u64, virt: u64, flags: u64) ?u64 {
    const phys = pmm.alloc() orelse return null;
    @memset(pmm.physToVirt(phys)[0..pmm.PAGE_SIZE], 0);
    vmm.map(root, virt, phys, flags, false) catch {
        pmm.free(phys);
        return null;
    };
    return phys;
}

/// True if copying `len` bytes from user address `addr` fails with a fault.
fn readFaults(addr: u64, len: usize) bool {
    var buf: [32]u8 = undefined;
    return uaccess.copyFromUser(buf[0..len], addr) == error.Fault;
}

/// True if copying `len` bytes to user address `addr` fails with a fault.
fn writeFaults(addr: u64, len: usize) bool {
    const buf: [32]u8 = @splat(0xEE);
    return uaccess.copyToUser(addr, buf[0..len]) == error.Fault;
}

/// Exercise `copyFromUser`/`copyToUser` against a private address space with
/// two writable pages at 0x400000, a hole at 0x402000 and a read-only page
/// at 0x403000. Returns 0 if everything behaves, otherwise the number of the
/// first failing check.
pub fn userCopyChecks() u32 {
    const flags = cpu.saveAndDisableInterrupts(); // no thread switch while the root is swapped
    defer cpu.restoreInterrupts(flags);
    const pages_before = pmm.free_pages;
    const root = vmm.createAddressSpace() catch return 99;
    const rw = vmm.USER | vmm.WRITABLE | vmm.NX;
    const p0 = mapUserPage(root, 0x40_0000, rw);
    const p1 = mapUserPage(root, 0x40_1000, rw);
    const ro = mapUserPage(root, 0x40_3000, vmm.USER | vmm.NX);
    vmm.loadRoot(root);
    const failed = userCopyChecksIn(p0, p1, ro);
    vmm.loadRoot(vmm.kernel_root);
    vmm.destroyAddressSpace(root);
    if (failed != 0) return failed;
    return if (pmm.free_pages == pages_before) 0 else 100;
}

/// The checks of `userCopyChecks`, run with its address space loaded.
/// `p0`, `p1` and `ro` are the physical pages behind 0x400000, 0x401000 and 0x403000.
fn userCopyChecksIn(p0: ?u64, p1: ?u64, ro: ?u64) u32 {
    const first = pmm.physToVirt(p0 orelse return 1);
    const second = pmm.physToVirt(p1 orelse return 1);
    const readonly = pmm.physToVirt(ro orelse return 1);
    const end = kernel_root.kernel.user_range.USER_END;
    var buf: [16]u8 = undefined;

    // A buffer crossing a page boundary is written and read back whole.
    const msg = "0123456789abcdef";
    uaccess.copyToUser(0x40_0FF8, msg) catch return 2;
    if (!std.mem.eql(u8, first[0xFF8..0x1000], msg[0..8])) return 3;
    if (!std.mem.eql(u8, second[0..8], msg[8..])) return 4;
    uaccess.copyFromUser(&buf, 0x40_0FF8) catch return 5;
    if (!std.mem.eql(u8, &buf, msg)) return 6;

    // Unmapped page, null, and never-mapped parts of user space.
    if (!readFaults(0x40_2000, 8) or !writeFaults(0x40_2000, 8)) return 7;
    if (!readFaults(0, 8) or !writeFaults(0, 8)) return 8;
    if (!readFaults(0x7000_0000_0000, 8)) return 9;

    // Partly mapped: starts in the second page, runs into the hole. The
    // bytes before the hole were written, as documented.
    if (!readFaults(0x40_1FF8, 16) or !writeFaults(0x40_1FF8, 16)) return 10;
    if (second[0xFFF] != 0xEE) return 11;
    // The last mapped bytes on their own are fine.
    uaccess.copyFromUser(buf[0..8], 0x40_1FF8) catch return 12;

    // Read-only page: readable, not writable, contents untouched.
    readonly[0] = 0x77;
    uaccess.copyFromUser(buf[0..1], 0x40_3000) catch return 13;
    if (buf[0] != 0x77) return 14;
    if (!writeFaults(0x40_3000, 8) or readonly[0] != 0x77) return 15;
    // Starting in the read-only page and running off its end fails as well.
    if (!writeFaults(0x40_3FF8, 16)) return 16;

    // Kernel pointers, the end of user space, and address + length overflow
    // are rejected before any memory is touched.
    if (!readFaults(@intFromPtr(&buf), 8) or !writeFaults(@intFromPtr(&buf), 8)) return 17;
    if (!readFaults(0xFFFF_8000_0000_0000, 8) or !readFaults(end, 1)) return 18;
    if (!readFaults(end - 4, 8) or !writeFaults(end - 4, 8)) return 19;
    if (!readFaults(std.math.maxInt(u64) - 3, 8) or !writeFaults(std.math.maxInt(u64) - 3, 8)) return 20;
    if (!readFaults(0x8000_0000_0000 + 0x1000, 8)) return 21; // non-canonical

    // Empty copies succeed without touching memory, even at unmapped addresses.
    uaccess.copyFromUser(buf[0..0], 0x40_2000) catch return 22;
    uaccess.copyToUser(end, buf[0..0]) catch return 23;

    // The user-access window is closed again after successful and failed copies.
    if (cpu.readFlags() & (1 << 18) != 0) return 24; // RFLAGS.AC
    return 0;
}

/// True if write protection in ring 0, UMIP, SMEP and SMAP are all switched
/// on, both in the kernel's bookkeeping and in the control registers.
pub fn userProtectionOn() bool {
    const cr4 = cpu.readCr4();
    return usercopy.umip_enabled and usercopy.smep_enabled and usercopy.smapEnabled() and
        cr4 & (1 << 11) != 0 and cr4 & (1 << 20) != 0 and cr4 & (1 << 21) != 0 and
        cpu.readCr0() & (1 << 16) != 0;
}

const RFLAGS_AC: u64 = 1 << 18;
/// A vector no device uses, for `acClearedOnKernelEntry`.
const AC_TEST_VECTOR = 0xF0;
var ac_seen_in_handler: ?bool = null;

/// Interrupt handler for `acClearedOnKernelEntry`: record RFLAGS.AC.
fn acProbe(_: *idt.Frame) void {
    ac_seen_in_handler = cpu.readFlags() & RFLAGS_AC != 0;
}

/// Check that SMAP's user-access override (RFLAGS.AC) cannot leak into the
/// kernel: an interrupt taken while AC is set runs its handler with AC clear
/// and gives the interrupted code its AC back, and the `syscall` flag mask
/// clears AC on entry. Returns 0, or the number of the first failing check.
pub fn acClearedOnKernelEntry() u32 {
    if (!usercopy.smapEnabled()) return 1; // `stac` would be an invalid opcode
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    ac_seen_in_handler = null;
    idt.register(AC_TEST_VECTOR, acProbe);
    asm volatile (
        \\ .byte 0x0f, 0x01, 0xcb   # stac
        \\ int $0xF0
    );
    const ac_after = cpu.readFlags() & RFLAGS_AC != 0;
    asm volatile (".byte 0x0f, 0x01, 0xca"); // clac
    const seen = ac_seen_in_handler orelse return 2; // the handler never ran
    if (seen) return 3; // the handler ran with user access allowed
    if (!ac_after) return 4; // the interrupted code lost its AC
    if (cpu.readFlags() & RFLAGS_AC != 0) return 5;
    if (cpu.rdmsr(0xC0000084) & RFLAGS_AC == 0) return 6; // SFMASK must clear AC on syscall
    return 0;
}

/// A vector no device uses, for `emergencyStacks`.
const IST_TEST_VECTOR = 0xF1;
var ist_probe_frame: u64 = 0;

/// Interrupt handler for `emergencyStacks`: record where the CPU pushed the
/// interrupt frame, which tells which stack the handler runs on.
fn istProbe(f: *idt.Frame) void {
    ist_probe_frame = @intFromPtr(f);
}

/// True if `addr` lies in the emergency stack with IST index `index`.
fn onIstStack(index: u3, addr: u64) bool {
    const stack = gdt.istStack(index);
    const low = @intFromPtr(stack.ptr);
    return addr >= low and addr < low + stack.len;
}

/// Raise `IST_TEST_VECTOR` with its gate set to IST index `ist` and return
/// the address of the frame its handler saw (0 if the handler never ran).
fn istProbeFrame(ist: u3) u64 {
    ist_probe_frame = 0;
    idt.setGateIst(IST_TEST_VECTOR, ist);
    asm volatile ("int $0xF1");
    idt.setGateIst(IST_TEST_VECTOR, 0);
    return ist_probe_frame;
}

/// Check the emergency stacks: the double-fault, NMI and debug gates name their own
/// IST entries, the TSS points those at the ends of three separate, 16-byte
/// aligned stacks, no other exception uses an IST stack, and the CPU really
/// switches to such a stack (and back) when a gate asks for it. Returns 0, or
/// the number of the first failing check.
pub fn emergencyStacks() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);

    if (idt.gateIst(8) != gdt.IST_DOUBLE_FAULT) return 1;
    if (idt.gateIst(2) != gdt.IST_NMI) return 2;
    if (idt.gateIst(1) != gdt.IST_DEBUG) return 14;
    for (0..256) |vec| {
        if (vec != 8 and vec != 2 and vec != 1 and idt.gateIst(@intCast(vec)) != 0) return 3;
    }
    const dbg = gdt.istStack(gdt.IST_DEBUG);
    const dbg_low = @intFromPtr(dbg.ptr);
    if (gdt.istTop(gdt.IST_DEBUG) != dbg_low + dbg.len or gdt.istTop(gdt.IST_DEBUG) % 16 != 0) return 15;

    const df = gdt.istStack(gdt.IST_DOUBLE_FAULT);
    const nmi = gdt.istStack(gdt.IST_NMI);
    if (gdt.istTop(gdt.IST_DOUBLE_FAULT) != @intFromPtr(df.ptr) + df.len) return 4;
    if (gdt.istTop(gdt.IST_NMI) != @intFromPtr(nmi.ptr) + nmi.len) return 5;
    if (gdt.istTop(gdt.IST_DOUBLE_FAULT) % 16 != 0 or gdt.istTop(gdt.IST_NMI) % 16 != 0) return 6;
    const df_low = @intFromPtr(df.ptr);
    const nmi_low = @intFromPtr(nmi.ptr);
    if (df_low < nmi_low + nmi.len and nmi_low < df_low + df.len) return 7; // they overlap
    if (dbg_low < nmi_low + nmi.len and nmi_low < dbg_low + dbg.len) return 16;
    if (dbg_low < df_low + df.len and df_low < dbg_low + dbg.len) return 17;
    for (4..8) |index| {
        if (gdt.istTop(@intCast(index)) != 0) return 8;
    }

    idt.register(IST_TEST_VECTOR, istProbe);
    const plain = istProbeFrame(0);
    if (plain == 0) return 9; // the handler never ran
    if (onIstStack(gdt.IST_DOUBLE_FAULT, plain) or onIstStack(gdt.IST_NMI, plain)) return 10;
    if (!onIstStack(gdt.IST_DOUBLE_FAULT, istProbeFrame(gdt.IST_DOUBLE_FAULT))) return 11;
    if (!onIstStack(gdt.IST_NMI, istProbeFrame(gdt.IST_NMI))) return 12;
    // Back on the thread's own stack: a local is not on an emergency stack.
    var here: u8 = 0;
    const here_addr = @intFromPtr(&here);
    here = 1;
    if (onIstStack(gdt.IST_DOUBLE_FAULT, here_addr) or onIstStack(gdt.IST_NMI, here_addr)) return 13;
    return 0;
}

/// True if `addr` is mapped in the kernel's page tables.
fn kernelMapped(addr: u64) bool {
    return vmm.translate(vmm.kernel_root, addr) != null;
}

/// Check the kernel stack allocator: a stack is `STACK_SIZE` bytes of
/// writable, non-executable pages with an unmapped guard page right below
/// it; two stacks never touch; freeing unmaps the pages, returns them to the
/// PMM and releases the slot for reuse; and the current thread (the boot
/// thread included) runs on such a stack. Returns 0, or the number of the
/// first failing check.
pub fn kernelStacks() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);

    // The page tables of the first slots exist by now, so pages balance exactly.
    const pages = pmm.free_pages;
    const in_use = kstack.inUse();

    const a = kstack.alloc() orelse return 1;
    const b = kstack.alloc() orelse return 2;
    const a_low = @intFromPtr(a.ptr);
    const b_low = @intFromPtr(b.ptr);
    if (a.len != kstack.STACK_SIZE or a_low % pmm.PAGE_SIZE != 0) return 3;
    if (!kstack.owns(a) or !kstack.owns(b)) return 4;
    if (kstack.inUse() != in_use + 2) return 5;
    if (pmm.free_pages != pages - 2 * kstack.STACK_PAGES) return 6;

    // Guard pages: unmapped below each stack, and recognized as guards.
    if (kernelMapped(a_low - 1) or kernelMapped(b_low - 1)) return 7;
    if (!kstack.isGuard(a_low - 1) or !kstack.isGuard(a_low - pmm.PAGE_SIZE)) return 8;
    if (kstack.isGuard(a_low) or kstack.isGuard(a_low + a.len - 1)) return 9;
    if (kstack.isGuard(@intFromPtr(&kernelStacks)) or kstack.isGuard(0)) return 10;
    // The stacks do not overlap and a guard page lies between them.
    const lower = @min(a_low, b_low);
    const upper = @max(a_low, b_low);
    if (upper < lower + kstack.STACK_SIZE + pmm.PAGE_SIZE) return 11;

    // Every page is mapped writable and not executable, to distinct frames.
    var frames: [kstack.STACK_PAGES]u64 = undefined;
    for (0..kstack.STACK_PAGES) |i| {
        const virt = a_low + i * pmm.PAGE_SIZE;
        const e = vmm.leafEntry(vmm.kernel_root, virt) orelse return 12;
        if (e & vmm.WRITABLE == 0 or e & vmm.NX == 0 or e & vmm.USER != 0) return 13;
        frames[i] = vmm.translate(vmm.kernel_root, virt).?;
        for (frames[0..i]) |other| if (other == frames[i]) return 14;
    }
    @memset(a, 0xA5); // the whole stack is usable
    @memset(b, 0x5A);
    if (a[0] != 0xA5 or a[a.len - 1] != 0xA5 or b[0] != 0x5A) return 15;

    // Freeing unmaps everything and gives pages and slot back.
    kstack.free(a);
    if (kernelMapped(a_low) or kernelMapped(a_low + a.len - 1)) return 16;
    if (kstack.inUse() != in_use + 1 or pmm.free_pages != pages - kstack.STACK_PAGES) return 17;
    const again = kstack.alloc() orelse return 18;
    if (@intFromPtr(again.ptr) != a_low) return 19; // the slot is reused
    again[0] = 1; // and its new pages are reachable (no stale TLB entry)
    kstack.free(again);
    kstack.free(b);
    if (kstack.inUse() != in_use or pmm.free_pages != pages) return 20;

    // This thread runs on a kernel stack from the allocator.
    const mine = thread.current().stack orelse return 21;
    if (!kstack.owns(mine)) return 22;
    var here: u8 = 0;
    const here_addr = @intFromPtr(&here);
    here = 1;
    if (here_addr < @intFromPtr(mine.ptr) or here_addr >= @intFromPtr(mine.ptr) + mine.len) return 23;
    return 0;
}

/// Use at least `bytes` of stack, write to all of it and return the lowest
/// address written. The buffer's address escapes, so the optimizer has to
/// keep it on the stack.
noinline fn touchStack(comptime bytes: usize) usize {
    var pad: [bytes]u8 = undefined;
    @memset(&pad, 0xEE);
    std.mem.doNotOptimizeAway(&pad);
    return @intFromPtr(&pad);
}

// State of the stack usage test's worker thread.
var usage_needed: ?usize = null;
var usage_measured: ?usize = null;
var usage_waiter: ?*thread.Thread = null;

/// Stack usage test worker: write to 1 KiB of stack and compare the measured
/// usage with how deep that write really was. Nothing is assumed about how
/// much of the stack was used before: a timer interrupt may already have run
/// on it before this function turned interrupts off.
fn stackUsageWorker() void {
    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    const mine = thread.current().stack.?;
    const lowest = touchStack(1024);
    usage_needed = @intFromPtr(mine.ptr) + mine.len - lowest;
    usage_measured = kstack.used(mine);
    thread.wake(usage_waiter.?);
}

/// Check the stack high-water mark: a fresh stack counts as unused, writing
/// to it is measured from the top, a thread's usage covers the deepest
/// address it wrote to, exited threads are recorded when reaped, and nothing in this test
/// run has come close to filling its stack. Returns 0, or the number of the
/// first failing check.
pub fn stackUsage() u32 {
    if (!kstack.track_usage) return 1; // the test kernel always measures
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);

    // A fresh stack is unused; usage is the distance from the top to the lowest write.
    const s = kstack.alloc() orelse return 2;
    if (kstack.used(s) != 0) return 3;
    s[s.len - 8] = 0;
    if (kstack.used(s) != 8) return 4;
    s[s.len - 1000] = 0;
    if (kstack.used(s) != 1000) return 5;
    s[0] = 0;
    if (kstack.used(s) != kstack.STACK_SIZE) return 6;
    kstack.free(s);
    const again = kstack.alloc() orelse return 7; // a reused slot starts clean
    if (kstack.used(again) != 0) return 8;
    kstack.free(again);

    // A thread's usage is at least as deep as the lowest address it wrote to.
    usage_needed = null;
    usage_measured = null;
    usage_waiter = thread.current();
    _ = thread.spawn(stackUsageWorker, null) catch return 9;
    thread.block();
    const needed = usage_needed orelse return 10;
    const measured = usage_measured orelse return 11;
    if (needed < 1024 or measured < needed or measured > kstack.STACK_SIZE) return 12;
    // The worker has exited and was reaped when this thread was switched
    // back to, which recorded its usage.
    thread.yield();
    if (kstack.peak() < measured) return 13;

    // This thread's own usage is plausible and can be recorded.
    const mine = thread.recordStackUsage() orelse return 14;
    if (mine == 0 or mine > kstack.STACK_SIZE) return 15;
    if (kstack.peak() < mine) return 16;
    return 0;
}

/// Record the current (boot) thread's stack usage and return the largest
/// usage any thread has had in this run, for the end-of-run report.
pub fn stackPeak() usize {
    _ = thread.recordStackUsage();
    return kstack.peak();
}

/// Recurse without end, using some stack in every call. `noinline` and the
/// volatile buffer keep the optimizer from turning it into a loop.
noinline fn recurseForever(depth: usize) usize {
    var pad: [128]u8 = undefined;
    const p: *volatile [128]u8 = &pad;
    p[depth % pad.len] = @truncate(depth);
    return recurseForever(depth + 1) + p[0];
}

/// Thread body for the `stack_overflow` scenario.
fn stackOverflowThread() void {
    _ = cpu.saveAndDisableInterrupts();
    _ = recurseForever(0);
}

/// For the `stack_overflow` scenario: overflow the kernel stack of a thread
/// with unbounded recursion. Returns only if the thread could not be started.
pub fn overflowStackInThread() void {
    _ = thread.spawn(stackOverflowThread, null) catch return;
    for (0..100) |_| thread.yield();
}

/// Thread body for the `double_fault` scenario: point RSP at unmapped kernel
/// memory and push. The page fault cannot be delivered on that stack, so the
/// CPU raises a double fault. This is what a kernel stack overflow into a
/// guard page looks like.
fn doubleFaultThread() void {
    _ = cpu.saveAndDisableInterrupts();
    asm volatile (
        \\ movabs $0xFFFFB00000001000, %%rsp
        \\ push %%rax
    );
}

/// For the `double_fault` scenario: run `doubleFaultThread` in a kernel
/// thread of its own, so the report can compare RSP with a thread stack.
/// Returns only if the thread could not be started or survived.
pub fn doubleFaultInThread() void {
    _ = thread.spawn(doubleFaultThread, null) catch return;
    for (0..100) |_| thread.yield();
}

// State shared by the PMM stress workers.
var pmm_stress_done: usize = 0;
var pmm_stress_errors: usize = 0;
var pmm_stress_waiter: ?*thread.Thread = null;
var pmm_stress_next_tag: u64 = 1;

/// PMM stress worker: with interrupts on (so the timer preempts it), keep
/// allocating a batch of pages, stamping each with this worker's tag, and
/// checking that every stamp is still there before freeing the batch. A page
/// handed to both workers shows up as a foreign stamp or a duplicate.
fn pmmStressWorker() void {
    const irq = cpu.saveAndDisableInterrupts();
    const tag = pmm_stress_next_tag;
    pmm_stress_next_tag += 1;
    cpu.restoreInterrupts(irq);

    var pages: [32]u64 = undefined;
    var errors: usize = 0;
    for (0..1500) |round| {
        var n: usize = 0;
        while (n < pages.len) : (n += 1) {
            const p = pmm.alloc() orelse break;
            for (pages[0..n]) |other| {
                if (other == p) errors += 1;
            }
            const word: *volatile u64 = @ptrCast(@alignCast(pmm.physToVirt(p)));
            word.* = (tag << 32) | round;
            pages[n] = p;
        }
        for (pages[0..n]) |p| {
            const word: *volatile u64 = @ptrCast(@alignCast(pmm.physToVirt(p)));
            if (word.* != (tag << 32) | round) errors += 1;
            pmm.free(p);
        }
    }

    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    pmm_stress_errors += errors;
    pmm_stress_done += 1;
    if (pmm_stress_done == 2) thread.wake(pmm_stress_waiter.?);
}

/// Run two preemptible kernel threads that allocate and free pages at the
/// same time. Returns true if no page was ever handed out twice and the free
/// count is back where it started.
pub fn pmmConcurrentStress() bool {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const before = pmm.free_pages;
    pmm_stress_done = 0;
    pmm_stress_errors = 0;
    pmm_stress_waiter = thread.current();
    _ = thread.spawn(pmmStressWorker, null) catch return false;
    _ = thread.spawn(pmmStressWorker, null) catch return false;
    while (pmm_stress_done < 2) thread.block();
    return pmm_stress_errors == 0 and pmm.free_pages == before and pmm.consistent();
}

/// For the `smap` and `smep` scenarios: switch to a new address space with
/// one user-accessible, writable, executable page at `USER_PAGE` that holds a
/// single `ret` instruction. Interrupts stay off so the scheduler keeps this
/// address space loaded. Returns false if memory ran out.
pub fn enterUserPageSpace() bool {
    _ = cpu.saveAndDisableInterrupts();
    const root = vmm.createAddressSpace() catch return false;
    const phys = mapUserPage(root, USER_PAGE, vmm.USER | vmm.WRITABLE) orelse return false;
    pmm.physToVirt(phys)[0] = 0xC3; // ret
    vmm.loadRoot(root);
    return true;
}

// ---------------------------------------------------------------------------
// Syscall and context-switch correctness (roadmap 2.5)

// State shared by `runPair` and its two runner threads.
var pair_path: []const u8 = "";
var pair_codes: [2]?u64 = .{ null, null };
var pair_done: usize = 0;
var pair_waiter: ?*thread.Thread = null;

/// Runner thread `index`: run the program and report its exit status.
fn pairRunner(index: usize) void {
    const code = runProgram(pair_path);
    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    pair_codes[index] = code;
    pair_done += 1;
    if (pair_done == 2) thread.wake(pair_waiter.?);
}

fn pairRunnerA() void {
    pairRunner(0);
}

fn pairRunnerB() void {
    pairRunner(1);
}

/// Run two copies of the program at `path` at the same time, each started
/// by a kernel thread of its own, and wait for both. Returns true if both
/// exited with status 0.
pub fn runPair(path: []const u8) bool {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    pair_path = path;
    pair_codes = .{ null, null };
    pair_done = 0;
    pair_waiter = thread.current();
    _ = thread.spawn(pairRunnerA, null) catch return false;
    _ = thread.spawn(pairRunnerB, null) catch return false;
    while (pair_done < 2) thread.block();
    return pair_codes[0] == 0 and pair_codes[1] == 0;
}

const RFLAGS_IF: u64 = 1 << 9;
const RFLAGS_DF: u64 = 1 << 10;

/// Test-only syscall numbers handled by `syscallProbe`; must match
/// `tests/user/bad_return.zig`.
const SYS_VIA_IRET = abi.Sys.PRIVATE_BASE + 0x100;
const SYS_BAD_FLAGS = abi.Sys.PRIVATE_BASE + 0x101;
const SYS_BAD_STATE = abi.Sys.PRIVATE_BASE + 0x102;

/// What `SYS_BAD_STATE` does to the saved state.
pub const BadState = enum {
    /// Return address in the non-canonical hole.
    noncanonical_rip,
    /// Return address in kernel memory.
    kernel_rip,
    /// Kernel code selector: a return to ring 0.
    kernel_cs,
    /// Kernel stack selector.
    kernel_ss,
};

/// What the probes saw. Cleared by `installProbes`.
pub const Probes = struct {
    /// Syscalls that went through `syscallProbe`.
    syscalls: usize = 0,
    /// Timer interrupts that arrived in ring 3.
    user_ticks: usize = 0,
    /// Timer interrupts that arrived in ring 0 on a process's thread: in
    /// the middle of a syscall.
    syscall_ticks: usize = 0,
    /// `SYS_VIA_IRET` calls, each of which must return through `iretq`.
    via_iret: usize = 0,
    /// Number of the first invariant that did not hold; 0 if all did.
    violation: u32 = 0,
};

pub var probes: Probes = .{};
var bad_state: BadState = .noncanonical_rip;
var real_syscall_handler: ?arch_syscall.Handler = null;
var real_tick_handler: ?idt.Handler = null;

/// Record the first violated invariant.
fn violated(number: u32) void {
    if (probes.violation == 0) probes.violation = number;
}

/// Invariants that hold whenever the kernel runs on behalf of a process:
/// the GS base is the per-CPU area (and the user's value is parked), the
/// process's address space is loaded, and both ways into the kernel from
/// ring 3 lead to the top of this thread's kernel stack.
fn checkKernelState(base: u32) void {
    const t = thread.current();
    const p = t.process orelse return violated(base + 1);
    const stack = t.stack orelse return violated(base + 2);
    const top = @intFromPtr(stack.ptr) + stack.len;
    const gs = cpu.rdmsr(percpu.MSR_GS_BASE);
    if (gs != @intFromPtr(percpu.current()) or gs >> 63 == 0) violated(base + 3);
    if (cpu.rdmsr(percpu.MSR_KERNEL_GS_BASE) != 0) violated(base + 4);
    if (percpu.current().kernel_rsp != top) violated(base + 5);
    if (gdt.kernelStack() != top) violated(base + 6);
    if (cpu.readCr3() & ~@as(u64, 0xFFF) != p.root) violated(base + 7);
    const rsp = @frameAddress();
    if (rsp < @intFromPtr(stack.ptr) or rsp >= top) violated(base + 8);
}

/// Syscall handler installed by `installProbes`: check the state every
/// syscall starts and ends in, serve the test-only numbers, and pass
/// everything else to the real handler.
fn syscallProbe(f: *arch_syscall.Frame) void {
    probes.syscalls += 1;
    const t = thread.current();
    const flags = cpu.readFlags();
    // Interrupts are on while a syscall runs; the flags a program could
    // have set to confuse the kernel are off.
    if (flags & RFLAGS_IF == 0) violated(1);
    if (flags & (RFLAGS_AC | RFLAGS_DF) != 0) violated(2);
    // The frame is the first thing on this thread's kernel stack, aligned.
    if (t.stack) |stack| {
        if (@intFromPtr(f) + @sizeOf(arch_syscall.Frame) != @intFromPtr(stack.ptr) + stack.len) violated(3);
    }
    if (@intFromPtr(f) % 16 != 0) violated(4);
    // The saved state is a ring 3 state with interrupts on.
    if (f.cs != gdt.USER_CODE or f.ss != gdt.USER_DATA) violated(5);
    if (f.rflags & RFLAGS_IF == 0 or f.rip >= vmm.USER_END) violated(6);
    checkKernelState(10);

    switch (f.rax) {
        SYS_VIA_IRET => {
            probes.via_iret += 1;
            f.rax = 0x1234;
            f.rflags |= 1 << 16; // RF: sysretq cannot restore it
        },
        SYS_BAD_FLAGS => {
            f.rax = 0x1234;
            f.rflags = (f.rflags & ~RFLAGS_IF) | 0x3000 | 0x4000; // IOPL 3, NT, interrupts off
        },
        SYS_BAD_STATE => switch (bad_state) {
            .noncanonical_rip => f.rip = 0x0000_8000_0000_0000,
            .kernel_rip => f.rip = @intFromPtr(&syscallProbe),
            .kernel_cs => f.cs = gdt.KERNEL_CODE,
            .kernel_ss => f.ss = gdt.KERNEL_DATA,
        },
        else => {
            real_syscall_handler.?(f);
            // Whatever the syscall did (block, switch threads, fail), it
            // comes back with interrupts on and the same kernel state.
            if (cpu.readFlags() & RFLAGS_IF == 0) violated(20);
            checkKernelState(30);
        },
    }
}

/// Timer handler installed by `installProbes`: check where the interrupt
/// frame is and which address space is loaded, then run the real handler
/// (which may switch threads).
fn tickProbe(f: *idt.Frame) void {
    const t = thread.current();
    if (cpu.readFlags() & RFLAGS_IF != 0) violated(40); // interrupt gates mask interrupts
    if (f.cs & 3 == 3) {
        probes.user_ticks += 1;
        // From ring 3 the CPU switched to the top of the thread's kernel stack.
        if (t.stack) |stack| {
            if (@intFromPtr(f) + @sizeOf(idt.Frame) != @intFromPtr(stack.ptr) + stack.len) violated(41);
        }
        if (f.rflags & RFLAGS_IF == 0) violated(42);
        checkKernelState(50);
    } else if (t.process != null) {
        probes.syscall_ticks += 1;
        // From ring 0 there is no stack switch: the frame is on the stack
        // the syscall was using, and the kernel state is already set up.
        if (t.stack) |stack| {
            const at = @intFromPtr(f);
            if (at < @intFromPtr(stack.ptr) or at >= @intFromPtr(stack.ptr) + stack.len) violated(43);
        }
        checkKernelState(60);
    }
    real_tick_handler.?(f);
}

/// Route syscalls and timer interrupts through the probes, with `state` as
/// what `SYS_BAD_STATE` does, and clear `probes`.
pub fn installProbes(state: BadState) void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    probes = .{};
    bad_state = state;
    if (real_syscall_handler == null) real_syscall_handler = arch_syscall.setHandler(syscallProbe);
    if (real_tick_handler == null) {
        real_tick_handler = idt.registered(apic.TIMER_VECTOR);
        idt.register(apic.TIMER_VECTOR, tickProbe);
    }
}

/// Put the real syscall and timer handlers back.
pub fn removeProbes() void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    if (real_syscall_handler) |h| _ = arch_syscall.setHandler(h);
    if (real_tick_handler) |h| idt.register(apic.TIMER_VECTOR, h);
    real_syscall_handler = null;
    real_tick_handler = null;
}

/// Check the GS bases as seen from a kernel thread: the active one is this
/// CPU's per-CPU area (whose first field points at itself), the parked one
/// is the user's (0). Returns 0, or the number of the first failing check.
pub fn gsBases() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const gs = cpu.rdmsr(percpu.MSR_GS_BASE);
    if (gs >> 63 == 0) return 1; // not a kernel address
    if (gs != @intFromPtr(percpu.current())) return 2;
    if (percpu.current().self != percpu.current()) return 3;
    if (cpu.rdmsr(percpu.MSR_KERNEL_GS_BASE) != 0) return 4;
    const t = thread.current();
    const stack = t.stack orelse return 5;
    if (percpu.current().kernel_rsp != @intFromPtr(stack.ptr) + stack.len) return 6;
    return 0;
}

/// Check how extended CPU state is set up: the control-register bits, the
/// mechanism (`want_xsave` says which one this CPU should get) and the save
/// area. Returns 0, or the number of the first failing check.
pub fn extendedStateSetup(want_xsave: bool) u32 {
    const cr0 = cpu.readCr0();
    const cr4 = cpu.readCr4();
    if (cr0 & (1 << 2) != 0 or cr0 & (1 << 3) != 0) return 1; // EM, TS: would trap SSE
    if (cr0 & (1 << 1) == 0 or cr0 & (1 << 5) == 0) return 2; // MP, NE
    if (cr4 & (1 << 9) == 0 or cr4 & (1 << 10) == 0) return 3; // OSFXSR, OSXMMEXCPT
    const leaf1 = cpu.cpuid(1, 0);
    const cpu_xsave = leaf1.ecx & (1 << 26) != 0;
    if (cpu_xsave != want_xsave) return 4; // QEMU was not started as the scenario expects
    if ((fpu.currentMode() == .xsave) != want_xsave) return 5;
    if ((cr4 & (1 << 18) != 0) != want_xsave) return 6; // OSXSAVE
    if (want_xsave) {
        const cpu_avx = leaf1.ecx & (1 << 28) != 0;
        if (fpu.avxEnabled() != cpu_avx) return 7;
        if (fpu.enabledFeatures() != @as(u64, if (cpu_avx) 7 else 3)) return 8;
        if (fpu.areaSize() != cpu.cpuid(0xD, 0).ebx) return 9;
        if (cpu_avx and fpu.areaSize() != 832) return 10;
    } else {
        if (fpu.avxEnabled() or fpu.areaSize() != 512) return 11;
    }
    if (fpu.areaSize() > fpu.MAX_AREA_SIZE) return 12;
    // Kernel threads carry no saved state.
    if (thread.current().fpuArea() != null) return 13;
    return 0;
}

/// The syscalls that returned through `iretq` since boot.
pub fn iretReturns() usize {
    return arch_syscall.iret_returns;
}

// What `debugProbe` saw.
var debug_probe_runs: usize = 0;
var debug_probe_gs: u64 = 0;
var debug_probe_frame: u64 = 0;

/// Debug-exception handler for `debugTrapEntry`: record the GS base the
/// handler runs with and where the CPU pushed the frame.
fn debugProbe(f: *idt.Frame) void {
    debug_probe_runs += 1;
    debug_probe_gs = cpu.rdmsr(percpu.MSR_GS_BASE);
    debug_probe_frame = @intFromPtr(f);
}

/// Raise a debug exception in ring 0 and return the GS base seen right
/// after it returns. With `user_gs` the exception is raised while the
/// user's GS base is loaded, as at the first instruction of `syscall_entry`.
fn raiseDebug(user_gs: bool) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    if (user_gs) {
        asm volatile (
            \\ swapgs
            \\ int $1
            \\ mov $0xC0000101, %%ecx
            \\ rdmsr
            \\ swapgs
            : [lo] "={eax}" (lo),
              [hi] "={edx}" (hi),
            :
            : .{ .rcx = true, .memory = true });
    } else {
        asm volatile (
            \\ int $1
            \\ mov $0xC0000101, %%ecx
            \\ rdmsr
            : [lo] "={eax}" (lo),
              [hi] "={edx}" (hi),
            :
            : .{ .rcx = true, .memory = true });
    }
    return @as(u64, hi) << 32 | lo;
}

/// Check the entry path of debug exceptions (shared with NMIs, double
/// faults and machine checks, which cannot be raised and returned from): the
/// handler runs on the debug emergency stack with the kernel's GS base
/// whichever base was loaded when the exception hit, and the interrupted
/// code gets its own base back. Returns 0, or the number of the first
/// failing check.
pub fn debugTrapEntry() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const kernel_gs = @intFromPtr(percpu.current());
    const before = idt.registered(1);
    idt.register(1, debugProbe);
    defer idt.setHandler(1, before);
    debug_probe_runs = 0;

    // With the kernel's GS base: nothing to switch.
    if (raiseDebug(false) != kernel_gs) return 1;
    if (debug_probe_runs != 1) return 2;
    if (debug_probe_gs != kernel_gs) return 3;
    if (!onIstStack(gdt.IST_DEBUG, debug_probe_frame)) return 4;

    // With the user's GS base, in ring 0: the saved CS says "kernel", and
    // only the GS base itself shows that it must be switched.
    const after = raiseDebug(true);
    if (debug_probe_runs != 2) return 5;
    if (debug_probe_gs != kernel_gs) return 6; // the handler ran with the user's base
    if (after != 0) return 7; // the interrupted code did not get the user's base back
    if (!onIstStack(gdt.IST_DEBUG, debug_probe_frame)) return 8;
    if (cpu.rdmsr(percpu.MSR_GS_BASE) != kernel_gs or cpu.rdmsr(percpu.MSR_KERNEL_GS_BASE) != 0) return 9;
    return 0;
}

// ---------------------------------------------------------------------------
// Memory-management correctness (roadmap 2.6)

/// Check that the physical allocator refuses every free that is not of an
/// allocated page, and that a refusal changes nothing. Returns 0, or the
/// number of the first failing check.
pub fn pmmRejectsBadFrees() u32 {
    const before = pmm.free_pages;
    const page = pmm.alloc() orelse return 1;

    // Not the start of a page.
    if (pmm.tryFree(page + 1) != error.Misaligned) return 2;
    if (pmm.tryFree(page + 0x800) != error.Misaligned) return 3;
    if (pmm.tryFree(page + pmm.PAGE_SIZE - 1) != error.Misaligned) return 4;
    // Beyond the memory the machine has.
    const beyond = @as(u64, pmm.totalPages()) * pmm.PAGE_SIZE;
    if (pmm.tryFree(beyond) != error.OutOfRange) return 5;
    if (pmm.tryFree(0x0000_7FFF_FFFF_F000) != error.OutOfRange) return 6;
    if (pmm.tryFree(0xFFFF_FFFF_FFFF_F000) != error.OutOfRange) return 7;
    // Memory the allocator never hands out: page 0 and the legacy video
    // hole, which is device memory on every PC.
    if (pmm.tryFree(0) != error.NotManaged) return 8;
    if (pmm.tryFree(0xA_0000) != error.NotManaged) return 9;
    if (pmm.isAllocated(0) or pmm.isAllocated(0xA_0000)) return 10;
    // All of that left the page allocated and the count alone.
    if (!pmm.isAllocated(page) or pmm.free_pages != before - 1) return 11;

    // The real free works once...
    pmm.tryFree(page) catch return 12;
    if (pmm.isAllocated(page) or pmm.free_pages != before) return 13;
    // ...and only once.
    if (pmm.tryFree(page) != error.NotAllocated) return 14;
    if (pmm.free_pages != before) return 15;
    // A page that was never handed out is not allocated either: the next
    // allocation returns the lowest free page at or after the hint, so the
    // page just freed comes back, and it is usable.
    const again = pmm.alloc() orelse return 16;
    pmm.free(again);
    if (pmm.free_pages != before or !pmm.consistent()) return 17;
    return 0;
}

// Pages taken by `drainMemory`, chained through their first word.
var drained_head: u64 = 0;
var drained_count: usize = 0;

/// Allocate physical pages until only `leave` are free, and keep them until
/// `releaseDrained`. Returns the number of free pages afterwards.
pub fn drainMemory(leave: usize) usize {
    while (pmm.free_pages > leave) {
        const page = pmm.alloc() orelse break;
        const link: *u64 = @ptrCast(@alignCast(pmm.physToVirt(page)));
        link.* = drained_head;
        drained_head = page;
        drained_count += 1;
    }
    return pmm.free_pages;
}

/// Give `count` of the drained pages back (all of them if there are fewer).
pub fn releaseSome(count: usize) void {
    var n: usize = 0;
    while (n < count and drained_head != 0) : (n += 1) {
        const page = drained_head;
        const link: *u64 = @ptrCast(@alignCast(pmm.physToVirt(page)));
        drained_head = link.*;
        drained_count -= 1;
        pmm.free(page);
    }
}

/// Give every drained page back.
pub fn releaseDrained() void {
    releaseSome(drained_count);
}

/// Everything the kernel holds on to, in one comparable value: memory that
/// is neither free nor part of the heap's pool, heap bytes in use, and
/// kernel stacks. The heap keeps pages it has grown by, so free pages alone
/// go down the first time something large is allocated.
pub const Footprint = struct {
    pages: usize,
    heap_bytes: usize,
    stacks: usize,

    pub fn eql(a: Footprint, b: Footprint) bool {
        return a.pages == b.pages and a.heap_bytes == b.heap_bytes and a.stacks == b.stacks;
    }
};

pub fn footprint() Footprint {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const h = heap.stats();
    return .{
        .pages = pmm.free_pages + h.bytes_mapped / pmm.PAGE_SIZE,
        .heap_bytes = h.bytes_in_use,
        .stacks = kstack.inUse(),
    };
}

const VM_A: u64 = 0x40_0000;
/// 2 MiB above `VM_A`: another page table under the same page directory.
const VM_B: u64 = VM_A + 0x20_0000;
/// In another PML4 slot: nothing shared with `VM_A` below the root.
const VM_FAR: u64 = 0x7000_0000_0000;
/// A kernel address nothing uses, in a PML4 slot of its own.
const VM_KERNEL: u64 = 0xFFFF_B800_0000_0000;
const USER_RW = vmm.USER | vmm.WRITABLE | vmm.NX;

/// Check that `map` refuses to replace a mapping, of either page size, and
/// leaves the existing one and the free-page count alone. Returns 0, or
/// the number of the first failing check.
pub fn vmmMapConflicts() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const start = pmm.free_pages;
    const root = vmm.createAddressSpace() catch return 1;
    const p1 = pmm.alloc() orelse return 2;
    const p2 = pmm.alloc() orelse return 3;

    vmm.map(root, VM_A, p1, USER_RW, false) catch return 4;
    const pte = vmm.leafEntry(root, VM_A) orelse return 5;
    const mapped = pmm.free_pages;
    // A second mapping of the same address, with other flags or not.
    if (vmm.map(root, VM_A, p2, USER_RW, false) != error.AlreadyMapped) return 6;
    if (vmm.map(root, VM_A, p2, vmm.USER, false) != error.AlreadyMapped) return 7;
    if (vmm.map(root, VM_A, p1, USER_RW, false) != error.AlreadyMapped) return 8;
    if (vmm.leafEntry(root, VM_A) != pte or vmm.translate(root, VM_A) != p1) return 9;
    if (pmm.free_pages != mapped) return 10;
    // A 2 MiB page where a table of 4 KiB pages already is.
    if (vmm.map(root, VM_A, 0x20_0000, USER_RW, true) != error.AlreadyMapped) return 11;
    if (vmm.translate(root, VM_A) != p1 or pmm.free_pages != mapped) return 12;
    // A 4 KiB page inside a 2 MiB page: the direct map of physical memory.
    const hhdm_page = @intFromPtr(pmm.physToVirt(0x20_0000));
    const hhdm_before = vmm.leafEntry(vmm.kernel_root, hhdm_page);
    if (vmm.map(vmm.kernel_root, hhdm_page, p2, vmm.WRITABLE | vmm.NX, false) != error.AlreadyMapped) return 13;
    if (vmm.leafEntry(vmm.kernel_root, hhdm_page) != hhdm_before or pmm.free_pages != mapped) return 14;
    // The neighbouring page is free to map.
    vmm.map(root, VM_A + pmm.PAGE_SIZE, p2, USER_RW, false) catch return 15;
    if (vmm.translate(root, VM_A + pmm.PAGE_SIZE) != p2 or vmm.translate(root, VM_A) != p1) return 16;

    vmm.destroyAddressSpace(root); // frees p1 and p2 with the tables
    return if (pmm.free_pages == start and pmm.consistent()) 0 else 17;
}

/// Check `unmap`: the translation goes away, the page comes back to the
/// caller, page tables that became empty are freed (and only those), and
/// the shared kernel tables stay. Returns 0, or the number of the first
/// failing check.
pub fn vmmUnmap() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const start = pmm.free_pages;
    const root = vmm.createAddressSpace() catch return 1;
    const p1 = pmm.alloc() orelse return 2;
    const p2 = pmm.alloc() orelse return 3;
    const empty = pmm.free_pages; // an address space with nothing mapped

    // One page: three tables appear, and all three go again.
    if (vmm.unmap(root, VM_A) != null) return 4; // nothing there yet
    vmm.map(root, VM_A, p1, USER_RW, false) catch return 5;
    if (pmm.free_pages != empty - 3) return 6; // PDPT, PD, PT
    if (vmm.unmap(root, VM_A) != p1) return 7;
    if (vmm.translate(root, VM_A) != null or vmm.leafEntry(root, VM_A) != null) return 8;
    if (pmm.free_pages != empty) return 9;
    if (vmm.unmap(root, VM_A) != null) return 10; // a second unmap finds nothing
    if (!pmm.isAllocated(p1)) return 11; // the page itself is the caller's to free

    // Two pages in one page table: the table stays until both are gone.
    vmm.map(root, VM_A, p1, USER_RW, false) catch return 12;
    vmm.map(root, VM_A + pmm.PAGE_SIZE, p2, USER_RW, false) catch return 13;
    if (pmm.free_pages != empty - 3) return 14;
    if (vmm.unmap(root, VM_A) != p1 or pmm.free_pages != empty - 3) return 15;
    if (vmm.translate(root, VM_A + pmm.PAGE_SIZE) != p2) return 16;
    if (vmm.unmap(root, VM_A + pmm.PAGE_SIZE) != p2 or pmm.free_pages != empty) return 17;

    // Two page tables under one page directory: only the empty one goes.
    vmm.map(root, VM_A, p1, USER_RW, false) catch return 18;
    vmm.map(root, VM_B, p2, USER_RW, false) catch return 19;
    if (pmm.free_pages != empty - 4) return 20; // PDPT, PD, two PTs
    if (vmm.unmap(root, VM_A) != p1 or pmm.free_pages != empty - 3) return 21;
    if (vmm.translate(root, VM_B) != p2) return 22;
    if (vmm.unmap(root, VM_B) != p2 or pmm.free_pages != empty) return 23;

    // Kernel addresses: the table the PML4 points at is shared by every
    // address space and must stay; the ones below it go.
    const kernel_free = pmm.free_pages;
    vmm.map(vmm.kernel_root, VM_KERNEL, p1, vmm.WRITABLE | vmm.NX, false) catch return 24;
    if (pmm.free_pages != kernel_free - 2) return 25; // PD and PT only
    if (vmm.translate(root, VM_KERNEL) != p1) return 26; // visible in every address space
    if (vmm.unmap(vmm.kernel_root, VM_KERNEL) != p1 or pmm.free_pages != kernel_free) return 27;
    if (vmm.translate(root, VM_KERNEL) != null) return 28;
    vmm.map(vmm.kernel_root, VM_KERNEL, p1, vmm.WRITABLE | vmm.NX, false) catch return 29; // still usable
    if (vmm.unmap(vmm.kernel_root, VM_KERNEL) != p1 or pmm.free_pages != kernel_free) return 30;

    // Many rounds leave nothing behind.
    for (0..2000) |round| {
        const a = VM_A + (round % 7) * pmm.PAGE_SIZE;
        vmm.map(root, a, p1, USER_RW, false) catch return 31;
        vmm.map(root, VM_FAR, p2, USER_RW, false) catch return 32;
        if (vmm.unmap(root, a) != p1 or vmm.unmap(root, VM_FAR) != p2) return 33;
    }
    if (pmm.free_pages != empty) return 34;

    // Tearing down an address space frees pages and tables in every part of it.
    vmm.map(root, VM_A, p1, USER_RW, false) catch return 35;
    vmm.map(root, VM_FAR, p2, USER_RW, false) catch return 36;
    if (pmm.free_pages != empty - 6) return 37;
    vmm.destroyAddressSpace(root);
    return if (pmm.free_pages == start and pmm.consistent()) 0 else 38;
}

/// The first byte at user address `addr`, read through the page tables
/// (and so through the TLB), or null if the read faults.
fn userByte(addr: u64) ?u8 {
    var b: [1]u8 = undefined;
    uaccess.copyFromUser(&b, addr) catch return null;
    return b[0];
}

/// Check that `unmap` flushes the TLB: after a page has been read through
/// its mapping (so the translation is cached), unmapping makes the next
/// access fault, and mapping another page there shows that page's contents,
/// never the old one's. Returns 0, or the number of the first failing check.
pub fn vmmTlbFlush() u32 {
    const flags = cpu.saveAndDisableInterrupts(); // no thread switch while the root is swapped
    defer cpu.restoreInterrupts(flags);
    const start = pmm.free_pages;
    const root = vmm.createAddressSpace() catch return 1;
    const p1 = pmm.alloc() orelse return 2;
    const p2 = pmm.alloc() orelse return 3;
    pmm.physToVirt(p1)[0] = 0x11;
    pmm.physToVirt(p2)[0] = 0x22;
    vmm.loadRoot(root);
    defer vmm.loadRoot(vmm.kernel_root);

    var failed: u32 = 0;
    for (0..50) |_| {
        vmm.map(root, VM_A, p1, USER_RW, false) catch return 4;
        if (userByte(VM_A) != 0x11) failed = 5; // now cached in the TLB
        if (vmm.unmap(root, VM_A) != p1) failed = 6;
        if (userByte(VM_A) != null) failed = 7; // a stale entry would still read 0x11
        vmm.map(root, VM_A, p2, USER_RW, false) catch return 8;
        if (userByte(VM_A) != 0x22) failed = 9; // a stale entry would read 0x11
        // A write goes to the new page too.
        uaccess.copyToUser(VM_A, &.{0x33}) catch {
            failed = 10;
        };
        if (pmm.physToVirt(p2)[0] != 0x33 or pmm.physToVirt(p1)[0] != 0x11) failed = 11;
        pmm.physToVirt(p2)[0] = 0x22;
        if (vmm.unmap(root, VM_A) != p2) failed = 12;
        if (userByte(VM_A) != null) failed = 13;
        if (failed != 0) break;
    }
    vmm.loadRoot(vmm.kernel_root);
    pmm.free(p1);
    pmm.free(p2);
    vmm.destroyAddressSpace(root);
    if (failed != 0) return failed;
    return if (pmm.free_pages == start) 0 else 14;
}

/// Entry for the thread `memoryExhaustion` must not be able to start.
fn neverRuns() void {}

/// Check that running out of physical memory is an error everywhere and
/// corrupts nothing: with no page left, and with too few for the page
/// tables a mapping needs, `map` fails and leaves the address space as it
/// was; address spaces, kernel stacks, heap blocks, threads and processes
/// cannot be created and leave nothing behind. Returns 0, or the number of
/// the first failing check.
pub fn memoryExhaustion() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const before = footprint();
    const root = vmm.createAddressSpace() catch return 1;
    const p1 = pmm.alloc() orelse return 2;
    const p2 = pmm.alloc() orelse return 3;
    vmm.map(root, VM_A, p1, USER_RW, false) catch return 4;
    const pte = vmm.leafEntry(root, VM_A);

    var failed: u32 = 0;
    check: {
        if (drainMemory(0) != 0 or pmm.alloc() != null) {
            failed = 5;
            break :check;
        }
        // Next to an existing mapping only one table is missing; with no
        // page free that fails as well.
        if (vmm.map(root, VM_B, p2, USER_RW, false) != error.OutOfMemory) failed = 11;
        // A mapping that needs three new tables, with 0, 1 and 2 pages
        // free: never enough, and nothing may be left half-built.
        for (0..3) |have| {
            if (pmm.free_pages != have) failed = 6;
            if (vmm.map(root, VM_FAR, p2, USER_RW, false) != error.OutOfMemory) failed = 7;
            if (pmm.free_pages != have) failed = 8; // tables it had added were freed again
            if (vmm.leafEntry(root, VM_FAR) != null) failed = 9;
            if (vmm.leafEntry(root, VM_A) != pte) failed = 10; // the old mapping is intact
            if (pmm.free_pages != have) failed = 12;
            releaseSome(1);
        }
        // With 3 pages the same mapping works, and uses exactly those.
        vmm.map(root, VM_FAR, p2, USER_RW, false) catch {
            failed = 13;
            break :check;
        };
        if (pmm.free_pages != 0 or vmm.translate(root, VM_FAR) != p2) failed = 14;
        if (vmm.unmap(root, VM_FAR) != p2 or pmm.free_pages != 3) failed = 15;

        // Everything else that allocates fails cleanly with nothing free.
        if (drainMemory(0) != 0) failed = 16;
        const stacks = kstack.inUse();
        const in_use = heap.stats().bytes_in_use;
        if (vmm.createAddressSpace()) |r| {
            vmm.destroyAddressSpace(r);
            failed = 17;
        } else |_| {}
        if (kstack.alloc() != null) failed = 18;
        if (heap.allocator.alloc(u8, 64 * 1024 * 1024)) |block| {
            heap.allocator.free(block);
            failed = 19;
        } else |_| {}
        if (thread.spawn(neverRuns, null)) |_| {
            failed = 20;
        } else |_| {}
        if (process.spawnPath("/bin/hello", .{})) |_| {
            failed = 21;
        } else |e| {
            if (e != error.OutOfMemory) failed = 22;
        }
        if (kstack.inUse() != stacks or heap.stats().bytes_in_use != in_use) failed = 23;
        if (pmm.free_pages != 0) failed = 24;
        // One stack's worth short of a kernel stack: the pages it did get go back.
        releaseSome(kstack.STACK_PAGES - 1);
        if (kstack.alloc() != null or pmm.free_pages != kstack.STACK_PAGES - 1) failed = 25;
        if (vmm.leafEntry(root, VM_A) != pte) failed = 26;
    }
    releaseDrained();
    pmm.free(p2);
    vmm.destroyAddressSpace(root);
    if (failed != 0) return failed;
    if (!pmm.consistent()) return 27;
    return if (footprint().eql(before)) 0 else 28;
}

/// Start `/bin/hello` again and again, each time letting one more page
/// allocation succeed before the allocator starts failing, until a start
/// succeeds. Every failed start must report out-of-memory and leave nothing
/// behind, whichever allocation it was that failed: a page table, a page of
/// the program, the user stack, the kernel stack, heap growth. Returns 0,
/// or the number of the first failing check; `failures.*` is the number of
/// allocation points that were made to fail.
pub fn spawnAllocationFailures(failures: *usize) u32 {
    failures.* = 0;
    const me = thread.current();
    // Stands in for a parent process, to see what is counted against it.
    var parent: process.Process = .{ .root = 0, .entry = 0, .name = "test parent" };
    var n: usize = 0;
    while (n < 2000) : (n += 1) {
        const flags = cpu.saveAndDisableInterrupts();
        const before = footprint();
        pmm.fail_after = n;
        const result = process.spawnPath("/bin/hello", .{ .waiter = me, .parent = &parent });
        pmm.fail_after = null;
        if (result) |_| {
            const counted = parent.descendants;
            thread.block(); // it started: let it run and finish
            const code = me.wake_value;
            cpu.restoreInterrupts(flags);
            if (code != 0) return 1;
            if (counted != 1 or parent.descendants != 0) return 6; // alive, then gone
            return if (failures.* > 10) 0 else 2; // too few: the sweep tested nothing
        } else |e| {
            const after = footprint();
            cpu.restoreInterrupts(flags);
            if (e != error.OutOfMemory) return 3;
            if (!after.eql(before)) return 4;
            if (parent.descendants != 0) return 7; // a process that never started is not counted
            failures.* += 1;
        }
    }
    return 5; // it never succeeded
}

/// Allocate enough kernel stacks to need new page tables on the way, and
/// before each one make every allocation inside `kstack.alloc` fail in
/// turn: a failed attempt must give back the pages it had taken. Returns 0,
/// or the number of the first failing check.
pub fn kstackAllocationFailures() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const before = footprint();
    const count = 220; // 5 pages per slot: at least two page-table boundaries
    const stacks = heap.allocator.alloc(?[]u8, count) catch return 1;
    @memset(stacks, null);

    var failed: u32 = 0;
    var needed_table = false;
    for (stacks) |*slot| {
        var n: usize = 0;
        while (n < 8) : (n += 1) {
            const pages = pmm.free_pages;
            const in_use = kstack.inUse();
            pmm.fail_after = n;
            const stack = kstack.alloc();
            pmm.fail_after = null;
            if (stack) |s| {
                if (n > kstack.STACK_PAGES) needed_table = true;
                slot.* = s;
                break;
            }
            if (pmm.free_pages != pages or kstack.inUse() != in_use) failed = 2;
        }
        if (slot.* == null) failed = 3;
        if (failed != 0) break;
    }
    for (stacks) |slot| {
        if (slot) |s| kstack.free(s);
    }
    heap.allocator.free(stacks); // before the footprint is compared
    if (failed != 0) return failed;
    if (!needed_table) return 4; // no attempt had to allocate a page table
    return if (footprint().eql(before) and pmm.consistent()) 0 else 5;
}

/// Make the heap grow one page at a time across a page-table boundary, with
/// the allocation of that page table failing: the page the heap had taken
/// for the spot must go back to the PMM. Each attempt asks for far more
/// than can be had while only one page allocation is allowed, so the heap
/// keeps the single page it could map and the request fails. 600 attempts
/// cover more than the 512 pages of one page table. Returns 0, or the
/// number of the first failing check.
pub fn heapGrowthFailures() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const before = footprint();
    var stuck: usize = 0; // attempts that could not grow at all: a table was needed
    for (0..600) |_| {
        const mapped = heap.stats().bytes_mapped;
        pmm.fail_after = 1;
        const block = heap.allocator.alloc(u8, 512 * 1024 * 1024);
        pmm.fail_after = null;
        if (block) |b| {
            heap.allocator.free(b);
            return 1;
        } else |_| {}
        if (heap.stats().bytes_mapped == mapped) stuck += 1;
    }
    if (stuck == 0) return 2; // never reached a page-table boundary
    // The heap kept what it mapped; nothing else is gone.
    return if (footprint().eql(before) and pmm.consistent()) 0 else 3;
}

// State of `pmmLockHolds` and its hook.
var lock_workers: [2]usize = .{ 0, 0 }; // thread IDs the hook acts on
var lock_inside: usize = 0;
var lock_entries: usize = 0;
var lock_overlaps: usize = 0;
var lock_irq_on: usize = 0;
var lock_errors: usize = 0;
var lock_done: usize = 0;
var lock_waiter: ?*thread.Thread = null;

/// Longer than a time slice (50 ms), so a thread that could be preempted
/// while it waits is preempted.
const LOCK_HOLD_NS = 70 * 1000 * 1000;

/// `pmm.critical_hook` for `pmmLockHolds`: stay inside the allocator's
/// critical section for longer than a time slice, and notice if another
/// thread is in there at the same time.
fn lockHook() void {
    const id = thread.id();
    if (id != lock_workers[0] and id != lock_workers[1]) return;
    lock_entries += 1;
    if (cpu.readFlags() & RFLAGS_IF != 0) lock_irq_on += 1;
    lock_inside += 1;
    if (lock_inside != 1) lock_overlaps += 1;
    const until = hpet.nanos() + LOCK_HOLD_NS;
    while (hpet.nanos() < until) {}
    if (lock_inside != 1) lock_overlaps += 1;
    lock_inside -= 1;
}

/// Worker for `pmmLockHolds`: allocate and free with interrupts on, so the
/// timer can preempt it anywhere the allocator lets it.
fn lockWorker() void {
    for (0..2) |_| {
        if (pmm.alloc()) |page| pmm.free(page) else lock_errors += 1;
    }
    _ = cpu.saveAndDisableInterrupts(); // restored when the thread exits
    lock_done += 1;
    if (lock_done == 2) thread.wake(lock_waiter.?);
}

/// Prove that the physical allocator's critical sections exclude other
/// threads. Two preemptible threads allocate and free while a hook holds
/// each of them inside the critical section for longer than a time slice.
/// With the lock (interrupts off) the other thread cannot run in that time;
/// without it the timer switches to the other thread, which enters the
/// critical section too. Returns 0, or the number of the first failing check.
pub fn pmmLockHolds() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const before = pmm.free_pages;
    lock_inside = 0;
    lock_entries = 0;
    lock_overlaps = 0;
    lock_irq_on = 0;
    lock_errors = 0;
    lock_done = 0;
    lock_waiter = thread.current();
    const a = thread.spawn(lockWorker, null) catch return 1;
    const b = thread.spawn(lockWorker, null) catch return 1;
    lock_workers = .{ a.id, b.id };
    pmm.critical_hook = lockHook;
    while (lock_done < 2) thread.block();
    pmm.critical_hook = null;
    lock_workers = .{ 0, 0 };

    if (lock_errors != 0) return 2;
    if (lock_entries < 8) return 3; // two threads, two allocations and two frees each
    if (lock_overlaps != 0) return 4; // two threads inside at once
    if (lock_irq_on != 0) return 5; // inside the critical section with interrupts on
    return if (pmm.free_pages == before and pmm.consistent()) 0 else 6;
}

/// Start the program at `path`, compare the pages the kernel charged to
/// the new process with the pages that actually left the allocator (its
/// program, stack, page tables and kernel stack), and wait for it. Returns
/// the charged number, or null if the two differ or it could not start.
pub fn chargedPages(path: []const u8) ?u64 {
    const me = thread.current();
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    const before = footprint();
    const p = process.spawnPath(path, .{ .waiter = me }) catch return null;
    const taken = before.pages - footprint().pages; // it has not run yet
    const charged = p.pages;
    thread.block(); // until it exits; `p` is gone after this
    if (charged != taken) return null;
    return charged;
}
