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

/// Result of loading an ELF image for inspection (see `elfProbe`).
pub const ElfProbe = struct {
    /// Entry point returned by the loader.
    entry: u64,
    /// Leaf page-table entry mapping the probed address, or 0 if unmapped.
    pte: u64,
};

/// Where program images may be loaded and how large they may be.
pub const image_limits = process.image_limits;

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
        vmm.createAddressSpace();

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
    const root = vmm.createAddressSpace();
    defer vmm.destroyAddressSpace(root);
    const entry = elf.load(root, image, process.image_limits) catch return null;
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
    const root = vmm.createAddressSpace();
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
    _ = process.spawn("bad", image, null) catch
        return pmm.free_pages == pages and heap.stats().bytes_in_use == in_use;
    return false; // it started; the test fails (the process runs on its own)
}

/// Run the program at `path` as a child process of the current
/// Thread and wait for it. Returns its exit code (255 if it was killed by a
/// Fault), or null if it could not be started.
pub fn runProgram(path: []const u8) ?u64 {
    const me = thread.current();
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    _ = process.spawnPath(path, me) catch return null;
    thread.block(); // until the child calls process.exit
    return me.wake_value;
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
    const root = vmm.createAddressSpace();
    const virt: u64 = 0x40_0000;
    const phys = pmm.alloc() orelse {
        vmm.destroyAddressSpace(root);
        return false;
    };
    vmm.map(root, virt, phys, vmm.USER | vmm.WRITABLE, false);
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
    vmm.map(root, virt, phys, flags, false);
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
    const root = vmm.createAddressSpace();
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

/// Check the emergency stacks: the double-fault and NMI gates name their own
/// IST entries, the TSS points those at the ends of two separate, 16-byte
/// aligned stacks, no other exception uses an IST stack, and the CPU really
/// switches to such a stack (and back) when a gate asks for it. Returns 0, or
/// the number of the first failing check.
pub fn emergencyStacks() u32 {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);

    if (idt.gateIst(8) != gdt.IST_DOUBLE_FAULT) return 1;
    if (idt.gateIst(2) != gdt.IST_NMI) return 2;
    for (0..256) |vec| {
        if (vec != 8 and vec != 2 and idt.gateIst(@intCast(vec)) != 0) return 3;
    }

    const df = gdt.istStack(gdt.IST_DOUBLE_FAULT);
    const nmi = gdt.istStack(gdt.IST_NMI);
    if (gdt.istTop(gdt.IST_DOUBLE_FAULT) != @intFromPtr(df.ptr) + df.len) return 4;
    if (gdt.istTop(gdt.IST_NMI) != @intFromPtr(nmi.ptr) + nmi.len) return 5;
    if (gdt.istTop(gdt.IST_DOUBLE_FAULT) % 16 != 0 or gdt.istTop(gdt.IST_NMI) % 16 != 0) return 6;
    const df_low = @intFromPtr(df.ptr);
    const nmi_low = @intFromPtr(nmi.ptr);
    if (df_low < nmi_low + nmi.len and nmi_low < df_low + df.len) return 7; // they overlap
    for (3..8) |index| {
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

/// Bytes in a kernel stack, and the usage above which the run should fail.
pub const STACK_SIZE = kstack.STACK_SIZE;
pub const STACK_WARN_BYTES = kstack.WARN_BYTES;

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
    return pmm_stress_errors == 0 and pmm.free_pages == before;
}

/// For the `smap` and `smep` scenarios: switch to a new address space with
/// one user-accessible, writable, executable page at `USER_PAGE` that holds a
/// single `ret` instruction. Interrupts stay off so the scheduler keeps this
/// address space loaded. Returns false if memory ran out.
pub fn enterUserPageSpace() bool {
    _ = cpu.saveAndDisableInterrupts();
    const root = vmm.createAddressSpace();
    const phys = mapUserPage(root, USER_PAGE, vmm.USER | vmm.WRITABLE) orelse return false;
    pmm.physToVirt(phys)[0] = 0xC3; // ret
    vmm.loadRoot(root);
    return true;
}
