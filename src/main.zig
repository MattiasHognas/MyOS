//! MyOS kernel entry point.
//!
//! Declares the Limine boot requests, brings up every subsystem in order in
//! `kmain` (CPU tables, memory, ACPI/APIC/timers, PCI, syscalls, the initrd)
//! and finally starts `/bin/sh` as the first user process. Also provides the
//! kernel-wide `print`, `halt` and panic handler that other modules reach via
//! `@import("root")`, plus the callbacks used by the in-kernel test suite.

const std = @import("std");
const build_options = @import("build_options");
/// CPU-architecture specific code.
pub const arch = struct {
    /// x86-64: descriptor tables, interrupts, paging, context switching and the syscall entry path.
    pub const x86_64 = struct {
        pub const apic = @import("arch/x86_64/apic.zig");
        pub const context = @import("arch/x86_64/context.zig");
        pub const cpu = @import("arch/x86_64/cpu.zig");
        pub const gdt = @import("arch/x86_64/gdt.zig");
        pub const idt = @import("arch/x86_64/idt.zig");
        pub const syscall = @import("arch/x86_64/syscall.zig");
        pub const vmm = @import("arch/x86_64/vmm.zig");
    };
};

/// Bootloader interface.
pub const boot = struct {
    pub const limine = @import("boot/limine.zig");
};

/// Hardware device drivers.
pub const drivers = struct {
    pub const fw_cfg = @import("drivers/fw_cfg.zig");
    pub const hpet = @import("drivers/hpet.zig");
    pub const nvme = @import("drivers/nvme.zig");
    pub const pci = @import("drivers/pci.zig");
    pub const ps2_keyboard = @import("drivers/ps2_keyboard.zig");
    pub const serial = @import("drivers/serial.zig");
};

/// Firmware tables provided by the platform.
pub const firmware = struct {
    pub const acpi = @import("firmware/acpi.zig");
};

/// Architecture-independent kernel core: memory, threads, processes, syscalls and files.
pub const kernel = struct {
    pub const console = @import("kernel/console.zig");
    pub const elf = @import("kernel/elf.zig");
    pub const heap = @import("kernel/heap.zig");
    pub const pmm = @import("kernel/pmm.zig");
    pub const process = @import("kernel/process.zig");
    pub const syscall = @import("kernel/syscall.zig");
    pub const thread = @import("kernel/thread.zig");
    pub const vfs = @import("kernel/vfs.zig");

    /// Debugging aids: assertions, backtraces, symbol lookup and log formatting.
    pub const debug = struct {
        pub const assert = @import("kernel/debug/assert.zig");
        pub const backtrace = @import("kernel/debug/backtrace.zig");
        pub const log_format = @import("kernel/debug/log_format.zig");
        pub const symbols = @import("kernel/debug/symbols.zig");
    };

    /// Filesystem implementations.
    pub const fs = struct {
        pub const tarfs = @import("kernel/fs/tarfs.zig");
    };
};

// Short names used in this file.
const limine = boot.limine;
const serial = drivers.serial;
const console = kernel.console;
const gdt = arch.x86_64.gdt;
const idt = arch.x86_64.idt;
const pmm = kernel.pmm;
const vmm = arch.x86_64.vmm;
const heap = kernel.heap;
const acpi = firmware.acpi;
const apic = arch.x86_64.apic;
const cpu = arch.x86_64.cpu;
const hpet = drivers.hpet;
const keyboard = drivers.ps2_keyboard;
const thread = kernel.thread;
const context = arch.x86_64.context;
const syscall = kernel.syscall;
const process = kernel.process;
const vfs = kernel.vfs;
const tarfs = kernel.fs.tarfs;
const pci = drivers.pci;
const nvme = drivers.nvme;
const fw_cfg = drivers.fw_cfg;
const assert = kernel.debug.assert;
const backtrace = kernel.debug.backtrace;
const log_format = kernel.debug.log_format;
const log = std.log.scoped(.boot);

/// Route `std.log` through `logFn`, at the level chosen with `-Dlog-level`.
pub const std_options: std.Options = .{
    .log_level = @field(std.log.Level, @tagName(build_options.log_level)),
    .logFn = logFn,
};

/// Limine request for boot modules (the initrd).
export var module_request linksection(".limine_requests") = limine.ModuleRequest{};
/// Limine base revision tag: the protocol revision (3) this kernel expects.
export var limine_base_revision linksection(".limine_requests") = [3]u64{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 3 };
/// Limine request for the framebuffer used by the console.
export var fb_request linksection(".limine_requests") = limine.FramebufferRequest{};
/// Limine request for the physical memory map.
export var memmap_request linksection(".limine_requests") = limine.MemmapRequest{};
/// Limine request for the higher-half direct map offset.
export var hhdm_request linksection(".limine_requests") = limine.HhdmRequest{};
/// Limine request for the kernel's physical and virtual load address.
export var kaddr_request linksection(".limine_requests") = limine.KernelAddressRequest{};
/// Limine request for the ACPI RSDP address.
export var rsdp_request linksection(".limine_requests") = limine.RsdpRequest{};
/// Limine request for the kernel's own ELF file, used to symbolize backtraces.
export var exec_file_request linksection(".limine_requests") = limine.ExecutableFileRequest{};

/// Timer interrupts received since the APIC timer was started (100 Hz).
var ticks: u64 = 0;

// Built-in ring 3 test program: write("Hello from ring 3!\n") and yield,
// three times, then exit(0).
comptime {
    asm (
        \\.section .rodata
        \\.global user_prog_start
        \\user_prog_start:
        \\  mov $3, %r12d
        \\1:
        \\  mov $0, %eax
        \\  lea user_msg(%rip), %rdi
        \\  mov $(user_msg_end - user_msg), %esi
        \\  syscall
        \\  mov $2, %eax
        \\  syscall
        \\  dec %r12d
        \\  jnz 1b
        \\  mov $1, %eax
        \\  xor %edi, %edi
        \\  syscall
        \\  ud2
        \\user_msg:
        \\  .ascii "Hello from ring 3!\n"
        \\user_msg_end:
        \\.global user_prog_end
        \\user_prog_end:
    );
}

/// Start of the built-in ring 3 test program.
extern const user_prog_start: u8;
/// End of the built-in ring 3 test program.
extern const user_prog_end: u8;

/// Kernel panic handler, used for `@panic` and safety checks anywhere in the kernel.
pub const panic = std.debug.FullPanic(kernelPanic);

const USER_CODE: u64 = 0x40_0000; // 4 MiB
const USER_STACK: u64 = 0x80_0000; // top of the user stack (8 MiB)

/// Initialize the NVMe controller `dev` and print the start of LBA 0 as a
/// string (up to the first NUL byte). Errors are printed, not propagated.
fn diskTest(dev: pci.Device) void {
    nvme.init(dev) catch |e| return log.err("nvme init failed: {s}", .{@errorName(e)});
    var sector: [4096]u8 = undefined;
    nvme.read(0, 1, &sector) catch |e| return log.err("nvme read failed: {s}", .{@errorName(e)});
    const end = std.mem.indexOfScalar(u8, &sector, 0) orelse 64;
    log.info("disk LBA 0: \"{s}\"", .{sector[0..end]});
}

/// Return the contents of the first boot module whose path ends with `name`,
/// or null if there is none. Panics if Limine did not answer the module request.
fn findModule(name: []const u8) ?[]const u8 {
    const mods = response(&module_request);
    for (mods.modules[0..mods.module_count]) |m| {
        if (std.mem.endsWith(u8, std.mem.span(m.path), name))
            return @as([*]const u8, @ptrFromInt(m.address))[0..m.size];
    }
    return null;
}

/// Timer interrupt handler: count the tick and let the scheduler preempt the
/// current thread when its time slice is used up.
fn onTick(_: *idt.Frame) void {
    ticks += 1;
    thread.tick();
}

/// Return the response pointer of the Limine request `req`, panicking if the
/// bootloader did not answer it. The field is read through a volatile pointer
/// because the bootloader writes it behind the compiler's back.
fn response(req: anytype) @typeInfo(@TypeOf(req.response)).optional.child {
    const v: *volatile @TypeOf(req.*) = req;
    return v.response orelse @panic("Limine request not answered");
}

/// Set while a panic is being reported, so a panic inside the panic handler
/// (e.g. while printing the backtrace) halts instead of recursing.
var panicking = false;

/// Panic handler behind `panic`: print the message and a symbolized
/// backtrace, then halt. In the test kernel, report failure and exit QEMU.
fn kernelPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    _ = cpu.saveAndDisableInterrupts();
    if (panicking) {
        serial.puts("PANIC while panicking\n");
        halt();
    }
    panicking = true;
    print("PANIC: {s}\n", .{msg});
    backtrace.print(.{ .return_address = ret_addr orelse @returnAddress() }, @frameAddress());
    if (comptime build_options.is_test) serial.puts("MYOS_TEST_FAIL\n");
    halt();
}

/// Idle loop run by the boot thread after initialization: yield to any ready
/// thread, otherwise sleep until the next interrupt. Never returns.
fn idle() noreturn {
    while (true) {
        thread.yield(); // let anything that's ready run
        asm volatile ("sti; hlt"); // otherwise sleep until an interrupt
    }
}

/// Built-in kernel-mode shell that reads lines from the keyboard and echoes
/// them back. Superseded by the user-space `/bin/sh`; kept for debugging.
fn shell() noreturn {
    var line: [128]u8 = undefined;
    var len: usize = 0;
    print("> ", .{});

    while (true) {
        while (keyboard.getChar()) |c| switch (c) {
            '\n' => {
                print("\n", .{});
                if (len > 0) print("you typed: {s}\n", .{line[0..len]});
                len = 0;
                print("> ", .{});
            },
            0x08 => if (len > 0) {
                len -= 1;
                print("\x08 \x08", .{}); // back, blank it out, back again
            },
            3 => { // Ctrl+C
                print("^C\n> ", .{});
                len = 0;
            },
            else => if (c >= ' ' and len < line.len) {
                line[len] = c;
                len += 1;
                print("{c}", .{c});
            },
        };
        thread.yield();
        asm volatile ("sti; hlt"); // sleep until the next key or timer tick
    }
}

/// Format `args` with `fmt` and write the result to the serial port and, once
/// it is initialized, the framebuffer console. Interrupts are disabled while
/// writing so messages are not interleaved. Output longer than 512 bytes is
/// replaced by `<print overflow>`. Other modules call this as `root.print`.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    write(std.fmt.bufPrint(&buf, fmt, args) catch "<print overflow>\n");
}

/// Write `s` to the serial port and (once initialized) the console, with
/// interrupts disabled so the whole message comes out in one piece.
fn write(s: []const u8) void {
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);
    serial.puts(s);
    if (console.ready) for (s) |c| console.putc(c);
}

/// `std.log` handler: format the message as `level(scope): message` and
/// write it like `print`. Messages above `-Dlog-level` are compiled out.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    var buf: [512]u8 = undefined;
    write(log_format.format(&buf, level, scope, fmt, args));
}

/// Stop the CPU for good: disable interrupts and halt forever. In the test
/// kernel, exit QEMU with a failure status instead, so a halted test run
/// ends immediately rather than timing out.
pub fn halt() noreturn {
    if (comptime build_options.is_test) {
        serial.puts("MYOS_HALT\n");
        @import("qemu_exit").exit(1);
    }
    while (true) asm volatile ("cli; hlt");
}

// Test-only service callbacks passed to the kernel test suite. Using callbacks
// avoids importing a second copy of PMM/VFS into the test module (which would
// duplicate module global state).

/// Test callback: write `s` to the serial port.
fn testLog(s: []const u8) void {
    serial.puts(s);
}

/// Test callback: return the number of free physical pages.
fn testFreePages() usize {
    return pmm.free_pages;
}

/// Test callback: return true if a file exists at `path`.
fn testHasFile(path: []const u8) bool {
    return vfs.lookup(path) != null;
}

/// Test callback: return the size of the file at `path`, or null if it doesn't exist.
fn testFileSize(path: []const u8) ?u64 {
    const node = vfs.lookup(path) orelse return null;
    return node.size;
}

/// Test callback: read from the file at `path` starting at `offset` into
/// `buf`. Returns the number of bytes read, or null if the file doesn't exist.
fn testReadFileAt(
    path: []const u8,
    offset: u64,
    buf: []u8,
) ?usize {
    const node = vfs.lookup(path) orelse return null;
    return vfs.read(&node, offset, buf);
}

/// Test callback: write a pattern to both ends of physical page `page` through
/// the HHDM and return true if it reads back correctly.
fn testPageRw(page: u64) bool {
    const memory =
        pmm.physToVirt(page)[0..pmm.PAGE_SIZE];

    memory[0] = 0xA5;
    memory[pmm.PAGE_SIZE - 1] = 0x5A;

    return memory[0] == 0xA5 and
        memory[pmm.PAGE_SIZE - 1] == 0x5A;
}

/// Test callback: allocate 257 bytes from the kernel heap, fill and verify
/// them, then free them. Returns false on allocation failure or mismatch.
fn testHeapRoundtrip() bool {
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

/// Test callback: create and destroy an address space and return true if
/// exactly one page was used and all pages were given back.
fn testAddressSpaceRoundtrip() bool {
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

/// Test callback: return true if spawning a process from a non-ELF image fails.
fn testInvalidElfRejected() bool {
    const invalid = "not an ELF";

    const child = process.spawn(
        "invalid",
        invalid,
        null,
    ) catch return true;

    _ = child;
    return false;
}

/// Test callback: return the name of the function containing code address
/// `addr`, or null if it can't be symbolized.
fn testSymbolize(addr: u64) ?[]const u8 {
    const sym = backtrace.symbolize(addr) orelse return null;
    return sym.name;
}

/// Test callback: store the return addresses of the caller's frame chain in
/// `out`, innermost first (the first one points into the caller).
noinline fn testCaptureBacktrace(out: []u64) usize {
    return backtrace.capture(@frameAddress(), out);
}

/// Test callback: in a fresh address space, map one user page, check that
/// `vmm.translate` finds it (including an offset into the page) and that
/// neighbouring pages are unmapped, then destroy the address space and check
/// that no physical pages leaked.
fn testVmmMapTranslate() bool {
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

/// Test callback: check that the heap usage counters track an allocation,
/// a shrink and a free, and return to their starting value.
fn testHeapStats() bool {
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

/// Test callback: read the fw_cfg file `name` into `buf`.
fn testFwCfgRead(name: []const u8, buf: []u8) ?[]u8 {
    return fw_cfg.readFile(name, buf);
}

/// Integration-test scenario "panic": fail a subsystem assertion two calls
/// deep, so the panic output must contain a symbolized backtrace through
/// these functions.
noinline fn scenarioPanic() void {
    scenarioPanicInner(true);
}

/// Inner frame of `scenarioPanic`.
noinline fn scenarioPanicInner(fail: bool) void {
    assert.check(.scenario, !fail, "deliberate test panic", .{});
}

/// Integration-test scenario "fault": write to an unmapped kernel address, so
/// the page-fault report must show CR2 and a symbolized backtrace.
noinline fn scenarioFault() void {
    const p: *volatile u64 = @ptrFromInt(0xFFFF_B000_0000_0000);
    p.* = 0xDEAD;
}

/// Run the test kernel: pick the scenario passed by the host through fw_cfg
/// (`opt/myos/scenario`, default "tests") and run it. Never returns; every
/// scenario ends by exiting QEMU.
fn runTestScenario() noreturn {
    var buf: [32]u8 = undefined;
    const scenario = fw_cfg.readFile("opt/myos/scenario", &buf) orelse "tests";
    log.info("test scenario: {s}", .{scenario});
    if (std.mem.eql(u8, scenario, "panic")) scenarioPanic();
    if (std.mem.eql(u8, scenario, "fault")) scenarioFault();
    if (!std.mem.eql(u8, scenario, "tests")) std.debug.panic("unknown test scenario '{s}'", .{scenario});

    @import("kernel_tests").run(.{
        .log = testLog,
        .alloc_page = pmm.alloc,
        .free_page = pmm.free,
        .free_pages = testFreePages,
        .has_file = testHasFile,
        .file_size = testFileSize,
        .read_file_at = testReadFileAt,
        .page_rw = testPageRw,
        .heap_roundtrip = testHeapRoundtrip,
        .heap_stats = testHeapStats,
        .address_space_roundtrip = testAddressSpaceRoundtrip,
        .vmm_map_translate = testVmmMapTranslate,
        .invalid_elf_rejected = testInvalidElfRejected,
        .symbolize = testSymbolize,
        .capture_backtrace = testCaptureBacktrace,
        .fw_cfg_read = testFwCfgRead,
    });
}

/// Kernel entry point, jumped to by Limine.
///
/// Initializes the subsystems in dependency order, mounts the initrd as the
/// root filesystem, then either runs the kernel test suite (test builds) or
/// starts `/bin/sh` and becomes the idle thread. Never returns.
export fn kmain() callconv(.c) noreturn {
    serial.init();
    gdt.init();
    idt.init();

    const fb = response(&fb_request);
    console.init(fb.framebuffers[0]);
    print("MyOS booting\n", .{});

    const mm = response(&memmap_request);
    const hhdm = response(&hhdm_request).offset;
    pmm.init(mm, hhdm);
    vmm.init(mm, response(&kaddr_request), hhdm);
    log.info("memory: {d} MiB free", .{pmm.free_pages * pmm.PAGE_SIZE / (1024 * 1024)});

    const exec_file: *volatile @TypeOf(exec_file_request) = &exec_file_request;
    if (exec_file.response) |r| {
        const f = r.executable_file;
        const elf_image = @as([*]const u8, @ptrFromInt(f.address))[0..f.size];
        if (backtrace.init(elf_image)) log.debug("kernel symbols loaded", .{}) else log.warn("kernel ELF has no symbol table", .{});
    } else log.warn("no kernel executable file from bootloader; backtraces will not be symbolized", .{});

    acpi.init(response(&rsdp_request).address, hhdm);
    apic.init();
    hpet.init();

    pci.scan();
    if (pci.find(0x01, 0x08, 0x02)) |dev| diskTest(dev) else log.warn("no NVMe controller", .{});

    idt.register(apic.TIMER_VECTOR, onTick);
    apic.timerInit(100);
    log.info("APIC timer: {d} ticks/ms, running at 100 Hz", .{apic.ticks_per_ms});

    syscall.init();

    const initrd = findModule("initrd.tar") orelse @panic("no initrd.tar module");
    vfs.mountRoot(tarfs.init(initrd));

    // The test kernel runs an integration-test scenario instead of the shell.
    if (comptime build_options.is_test) runTestScenario();

    keyboard.init();
    _ = process.spawnPath("/bin/sh", null) catch |e| log.err("failed to start /bin/sh: {s}", .{@errorName(e)});
    print("Boot complete.\n", .{});
    idle();
}
