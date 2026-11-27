//! MyOS kernel entry point.
//!
//! Declares the Limine boot requests, brings up every subsystem in order in
//! `kmain` (CPU tables, memory, ACPI/APIC/timers, PCI, syscalls, the initrd)
//! and finally starts `/bin/sh` as the first user process. Also provides the
//! kernel-wide `print`, `halt` and panic handler that other modules reach via
//! `@import("root")`. The test kernel (`kernel-test.elf`) hands control to
//! `tests/kernel/` after boot instead of starting the shell.

const std = @import("std");
const build_options = @import("build_options");

/// The user/kernel ABI shared with user programs: Linux's syscall numbers and error values.
pub const abi = @import("abi");

/// CPU-architecture specific code.
pub const arch = struct {
    /// x86-64: descriptor tables, interrupts, paging, context switching and the syscall entry path.
    pub const x86_64 = struct {
        pub const apic = @import("arch/x86_64/apic.zig");
        pub const context = @import("arch/x86_64/context.zig");
        pub const cpu = @import("arch/x86_64/cpu.zig");
        pub const fpu = @import("arch/x86_64/fpu.zig");
        pub const gdt = @import("arch/x86_64/gdt.zig");
        pub const idt = @import("arch/x86_64/idt.zig");
        pub const ipi = @import("arch/x86_64/ipi.zig");
        pub const meltdown = @import("arch/x86_64/meltdown.zig");
        pub const nospec = @import("arch/x86_64/nospec.zig");
        pub const percpu = @import("arch/x86_64/percpu.zig");
        pub const smp = @import("arch/x86_64/smp.zig");
        pub const syscall = @import("arch/x86_64/syscall.zig");
        pub const sysret = @import("arch/x86_64/sysret.zig");
        pub const usercopy = @import("arch/x86_64/usercopy.zig");
        pub const vmm = @import("arch/x86_64/vmm.zig");
    };
};

/// Bootloader interface.
pub const boot = struct {
    pub const limine = @import("boot/limine.zig");
};

/// Hardware device drivers.
pub const drivers = struct {
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
    pub const tty = @import("kernel/tty.zig");
    pub const console = @import("kernel/console.zig");
    pub const elf = @import("kernel/elf.zig");
    pub const elf_image = @import("kernel/elf_image.zig");
    pub const heap = @import("kernel/heap.zig");
    pub const kstack = @import("kernel/kstack.zig");
    pub const pmm = @import("kernel/pmm.zig");
    pub const process = @import("kernel/process.zig");
    pub const random = @import("kernel/random.zig");
    pub const random_core = @import("kernel/random_core.zig");
    pub const syscall = @import("kernel/syscall.zig");
    pub const thread = @import("kernel/thread.zig");
    pub const timer = @import("kernel/timer.zig");
    pub const uaccess = @import("kernel/uaccess.zig");
    pub const user_range = @import("kernel/user_range.zig");
    pub const vfs = @import("kernel/vfs.zig");

    /// Locks, wait queues and the timer queue.
    pub const sync = struct {
        pub const mutex = @import("kernel/sync/mutex.zig");
        pub const lock_order = @import("kernel/sync/lock_order.zig");
        pub const raw_spinlock = @import("kernel/sync/raw_spinlock.zig");
        pub const spinlock = @import("kernel/sync/spinlock.zig");
        pub const timer_queue = @import("kernel/sync/timer_queue.zig");
        pub const wait_queue = @import("kernel/sync/wait_queue.zig");
    };

    /// Debugging aids: assertions, backtraces, symbol lookup and log formatting.
    pub const debug = struct {
        pub const assert = @import("kernel/debug/assert.zig");
        pub const backtrace = @import("kernel/debug/backtrace.zig");
        pub const log_format = @import("kernel/debug/log_format.zig");
        pub const panic = @import("kernel/debug/panic.zig");
        pub const symbols = @import("kernel/debug/symbols.zig");
    };

    /// Filesystem implementations.
    pub const fs = struct {
        pub const tarfs = @import("kernel/fs/tarfs.zig");
        pub const tmpfs = @import("kernel/fs/tmpfs.zig");
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
const kstack = kernel.kstack;
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
const tmpfs = kernel.fs.tmpfs;
const pci = drivers.pci;
const nvme = drivers.nvme;
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
/// Limine request to start the other CPUs and park them (`arch/x86_64/smp.zig`).
export var mp_request linksection(".limine_requests") = limine.MpRequest{};
/// Limine request for the kernel's own ELF file, used to symbolize backtraces.
export var exec_file_request linksection(".limine_requests") = limine.ExecutableFileRequest{};

/// Kernel panic handler, used for `@panic` and safety checks anywhere in the kernel.
/// Messages are formatted in a small buffer (`kernel/debug/panic.zig`), not
/// the 4 KiB one of `std.debug.FullPanic`, to keep stack frames small.
pub const panic = kernel.debug.panic.Handler(kernelPanic);

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

/// Timer interrupt handler, on every CPU: the boot CPU advances time and
/// runs the timers that are due, and each CPU lets the scheduler preempt
/// its current thread when the time slice is used up.
fn onTick(_: *idt.Frame) void {
    if (arch.x86_64.percpu.current().id == 0) kernel.timer.tick(); // first: a thread a timer wakes can run right away
    thread.tick();
}

/// Return the response pointer of the Limine request `req`, panicking if the
/// bootloader did not answer it. The field is read through a volatile pointer
/// because the bootloader writes it behind the compiler's back.
fn response(req: anytype) @typeInfo(@TypeOf(req.response)).optional.child {
    const v: *volatile @TypeOf(req.*) = req;
    return v.response orelse @panic("Limine request not answered");
}

/// The initrd image. Public so tests can mount other archives and restore it.
pub var initrd_image: []const u8 = &.{};

/// True once the NVMe controller has been initialized successfully.
pub var nvme_ready = false;

/// Set while a panic is being reported, so a panic inside the panic handler
/// (e.g. while printing the backtrace) halts instead of recursing.
var panicking = false;

/// Protects the serial port and the framebuffer console, so that messages
/// come out whole. Innermost in the lock order: anything may print.
var console_lock: kernel.sync.spinlock.SpinLock = .{ .rank = .console };
/// Set by a CPU that is going down (`seizeConsole`); never cleared.
var console_seized = false;

/// Make this CPU's output go out without waiting for the console lock, and
/// stop the lock-order checks. For a CPU that reports a panic or a kernel
/// fault and then halts: it may be the one holding the console lock, or
/// whichever lock the fault happened under, and its report matters more
/// than a tidy log. Interrupts must be off.
///
/// The other CPUs are halted first, so nothing else runs or prints while
/// this one reports. If another CPU got there first, this one is among
/// those it halts: it stops here and reports nothing.
pub fn seizeConsole() void {
    if (!arch.x86_64.ipi.stopOthers()) arch.x86_64.ipi.haltIfStopped();
    console_seized = true;
    kernel.sync.spinlock.stopChecking();
}

/// The stack a crash report is printed on: after `seizeConsole` only one
/// CPU reports, so one stack is enough, and the CPU may be on a small
/// emergency stack (`gdt.IST_STACK_SIZE`) or a broken one. Formatting and
/// symbolizing take about 4 KiB in a Debug build.
var crash_stack: [8 * 1024]u8 align(16) = undefined;
var crash_job: *const fn () noreturn = undefined;

/// After `seizeConsole`: carry on with `job` on the crash stack. Whatever
/// it needs from the stack it leaves is to be copied out first.
pub fn onCrashStack(job: *const fn () noreturn) noreturn {
    crash_job = job;
    arch.x86_64.context.runOnStack(@intFromPtr(&crash_stack) + crash_stack.len, &crashEntry);
}

fn crashEntry() callconv(.c) noreturn {
    crash_job();
}

var panic_msg: []const u8 = "";
var panic_ret: usize = 0;
var panic_rbp: usize = 0;

/// Panic handler behind `panic`: print the message and a symbolized
/// backtrace, then halt. In the test kernel, report failure and exit QEMU.
fn kernelPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    _ = cpu.saveAndDisableInterrupts();
    seizeConsole();
    if (panicking) {
        serial.puts("PANIC while panicking\n");
        halt();
    }
    panicking = true;
    panic_msg = msg;
    panic_ret = ret_addr orelse @returnAddress();
    panic_rbp = @frameAddress();
    onCrashStack(&panicReport);
}

fn panicReport() noreturn {
    print("PANIC: {s}\n", .{panic_msg});
    backtrace.print(.{ .return_address = panic_ret }, panic_rbp);
    if (comptime build_options.is_test) serial.puts("MYOS_TEST_FAIL\n");
    halt();
}

/// Format `args` with `fmt` and write the result to the serial port and, once
/// it is initialized, the framebuffer console, as one piece. Output longer
/// than 512 bytes is replaced by `<print overflow>`. Other modules call this
/// as `root.print`.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    // Formatted a little at a time, under the console lock so the message
    // comes out whole: a crash report prints on an emergency stack, and a
    // buffer for the whole line took a good part of it.
    var buf: [96]u8 = undefined;
    var w: std.Io.Writer = .{ .vtable = &.{ .drain = drainToConsole }, .buffer = &buf };
    if (console_seized) {
        w.print(fmt, args) catch {};
        w.flush() catch {};
        return;
    }
    const held = console_lock.acquire();
    defer console_lock.release(held);
    w.print(fmt, args) catch {};
    w.flush() catch {};
}

/// Where `print`'s writer sends what it formats: the console lock is held
/// (or the console seized).
fn drainToConsole(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    writeUnlocked(w.buffered());
    w.end = 0;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |d| {
        writeUnlocked(d);
        n += d.len;
    }
    const last = data[data.len - 1];
    for (0..splat) |_| writeUnlocked(last);
    return n + last.len * splat;
}

fn serialIrq(_: *idt.Frame) void {
    serial.irqHandler();
}

/// Write `s` to the serial port and (once initialized) the console, under
/// the console lock so the whole message comes out in one piece.
pub fn write(s: []const u8) void {
    if (console_seized) return writeUnlocked(s);
    const held = console_lock.acquire();
    defer console_lock.release(held);
    writeUnlocked(s);
}

fn writeUnlocked(s: []const u8) void {
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

/// Kernel entry point, jumped to by Limine on the bootloader's stack.
///
/// Brings up the CPU tables, the console and memory management, then moves
/// to a guarded kernel stack and continues in `kmainOnStack`. Never returns.
export fn kmain() callconv(.c) noreturn {
    serial.init();
    gdt.init();
    arch.x86_64.percpu.init(); // after gdt.init: loading GS resets its base
    thread.init();
    idt.init();

    const fb = response(&fb_request);
    console.init(fb.framebuffers[0]);
    print("MyOS {s} booting\n", .{build_options.version});

    const mm = response(&memmap_request);
    const hhdm = response(&hhdm_request).offset;
    pmm.init(mm, hhdm);
    vmm.init(mm, response(&kaddr_request), hhdm);
    arch.x86_64.usercopy.init(); // SMEP/SMAP: from here on, user memory only through kernel.uaccess
    arch.x86_64.meltdown.init(); // refuses CPUs on which user programs can read kernel memory
    arch.x86_64.fpu.init(); // SSE/AVX for user code, and how their state is saved
    kernel.random.init(); // before anything that wants a secret: canaries, address randomization
    log.info("memory: {d} MiB free", .{pmm.free_pages * pmm.PAGE_SIZE / (1024 * 1024)});

    // The bootloader's stack has no guard page; leave it as early as possible.
    const stack = kstack.alloc() orelse @panic("no memory for the boot thread's stack");
    thread.adoptBootStack(stack);
    context.runOnStack(@intFromPtr(stack.ptr) + stack.len, &kmainOnStack);
}

/// Second half of boot, on the boot thread's own kernel stack.
///
/// Initializes the remaining subsystems in dependency order, mounts the
/// initrd as the root filesystem, then either runs the kernel test suite
/// (test builds) or starts `/bin/sh` and blocks for good. Never returns.
fn kmainOnStack() callconv(.c) noreturn {
    const hhdm = response(&hhdm_request).offset;

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
    if (pci.find(0x01, 0x08, 0x02)) |dev| {
        if (nvme.init(dev)) {
            nvme_ready = true;
        } else |e| log.err("nvme init failed: {s}", .{@errorName(e)});
    } else log.warn("no NVMe controller", .{});

    idt.register(apic.TIMER_VECTOR, onTick);
    apic.timerInit(kernel.timer.HZ);
    log.info("APIC timer: {d} ticks/ms, running at {d} Hz", .{ apic.ticks_per_ms, kernel.timer.HZ });

    syscall.init();

    // The other CPUs, now that the boot CPU is set up the way each of them must be.
    arch.x86_64.ipi.init();
    const mp: *volatile @TypeOf(mp_request) = &mp_request;
    arch.x86_64.smp.init(mp.response);

    initrd_image = findModule("initrd.tar") orelse @panic("no initrd.tar module");
    vfs.mountRoot(tarfs.init(initrd_image));
    // The image cannot be written to; /tmp can, and forgets at power-off.
    vfs.mount("/tmp", tmpfs.init()) catch unreachable; // the second of eight mounts

    // The terminal: keys from the keyboard and the serial line, what is
    // shown for them on the console.
    kernel.tty.init(write);
    serial.initInput(kernel.tty.input);
    idt.register(apic.IRQ_BASE + 4, serialIrq);
    apic.route(4, apic.IRQ_BASE + 4);

    // The test kernel runs an integration-test scenario (tests/kernel/) instead of the shell.
    if (comptime build_options.is_test) @import("kernel_tests").run();

    keyboard.init();
    // Nobody waits for the shell: give up the reference right away.
    if (process.spawnPath("/bin/sh", .{})) |shell| process.release(shell) else |e| log.err("failed to start /bin/sh: {s}", .{@errorName(e)});
    print("Boot complete.\n", .{});
    if (thread.recordStackUsage()) |bytes| log.debug("boot used {d} of {d} bytes of kernel stack", .{ bytes, kstack.STACK_SIZE });
    // The boot thread has nothing left to do. It does not become an idle
    // thread that takes turns with the others: the scheduler has none.
    thread.retire();
}
