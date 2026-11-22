const std = @import("std");
const build_options = @import("build_options");
const limine = @import("boot/limine.zig");
const serial = @import("drivers/serial.zig");
const console = @import("kernel/console.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const pmm = @import("kernel/pmm.zig");
const vmm = @import("arch/x86_64/vmm.zig");
const heap = @import("kernel/heap.zig");
const acpi = @import("firmware/acpi.zig");
const apic = @import("arch/x86_64/apic.zig");
const cpu = @import("arch/x86_64/cpu.zig");
const hpet = @import("drivers/hpet.zig");
const keyboard = @import("drivers/ps2_keyboard.zig");
const thread = @import("kernel/thread.zig");
const context = @import("arch/x86_64/context.zig");
const syscall = @import("kernel/syscall.zig");
const process = @import("kernel/process.zig");
const vfs = @import("kernel/vfs.zig");
const tarfs = @import("kernel/fs/tarfs.zig");
const pci = @import("drivers/pci.zig");
const nvme = @import("drivers/nvme.zig");

export var module_request linksection(".limine_requests") = limine.ModuleRequest{};
export var limine_base_revision linksection(".limine_requests") = [3]u64{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 3 };
export var fb_request linksection(".limine_requests") = limine.FramebufferRequest{};
export var memmap_request linksection(".limine_requests") = limine.MemmapRequest{};
export var hhdm_request linksection(".limine_requests") = limine.HhdmRequest{};
export var kaddr_request linksection(".limine_requests") = limine.KernelAddressRequest{};
export var rsdp_request linksection(".limine_requests") = limine.RsdpRequest{};

var ticks: u64 = 0;

// write("Hello from ring 3!\n") and yield, three times, then exit(0).
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

extern const user_prog_start: u8;
extern const user_prog_end: u8;

pub const panic = std.debug.FullPanic(kernelPanic);

const USER_CODE: u64 = 0x40_0000; // 4 MiB
const USER_STACK: u64 = 0x80_0000; // top of the user stack (8 MiB)

/// Test the NVMe driver by reading the first sector of the disk and printing it to the console.
fn diskTest(dev: pci.Device) void {
    nvme.init(dev) catch |e| return print("nvme init failed: {s}\n", .{@errorName(e)});
    var sector: [4096]u8 = undefined;
    nvme.read(0, 1, &sector) catch |e| return print("nvme read failed: {s}\n", .{@errorName(e)});
    const end = std.mem.indexOfScalar(u8, &sector, 0) orelse 64;
    print("disk LBA 0: \"{s}\"\n", .{sector[0..end]});
}

/// Return the GSI for an IRQ, taking into account any overrides in the MADT.
fn findModule(name: []const u8) ?[]const u8 {
    const mods = response(&module_request);
    for (mods.modules[0..mods.module_count]) |m| {
        if (std.mem.endsWith(u8, std.mem.span(m.path), name))
            return @as([*]const u8, @ptrFromInt(m.address))[0..m.size];
    }
    return null;
}

/// Return the number of milliseconds since boot.
fn onTick(_: *idt.Frame) void {
    ticks += 1;
    thread.tick();
}

/// Return the Limine response for a request, or panic if the request was not answered.
fn response(req: anytype) @typeInfo(@TypeOf(req.response)).optional.child {
    const v: *volatile @TypeOf(req.*) = req;
    return v.response orelse @panic("Limine request not answered");
}

/// Convert a Limine physical address to a virtual address, using the HHDM offset.
fn kernelPanic(msg: []const u8, _: ?usize) noreturn {
    print("PANIC: {s}\n", .{msg});
    if (comptime build_options.is_test) {
        serial.puts("MYOS_TEST_FAIL\n");
        @import("qemu_exit").exit(1);
    }
    halt();
}

/// The idle thread runs when no other threads are ready. It yields to any ready threads, then sleeps until the next interrupt.
fn idle() noreturn {
    while (true) {
        thread.yield(); // let anything that's ready run
        asm volatile ("sti; hlt"); // otherwise sleep until an interrupt
    }
}

/// A simple shell that reads lines from the keyboard and echoes them back.
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

/// Print to both the serial port and the framebuffer console. The framebuffer console is not ready until after the kernel has initialized it, so we check `console.ready` before printing to it.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch "<print overflow>\n";
    const flags = cpu.saveAndDisableInterrupts(); // whole message at once
    defer cpu.restoreInterrupts(flags);
    serial.puts(s);
    if (console.ready) for (s) |c| console.putc(c);
}

/// The kernel's main entry point. Called by the bootloader.
pub fn halt() noreturn {
    while (true) asm volatile ("cli; hlt");
}

/// Read a file into a buffer, for the test module. Returns null if the file doesn't exist.
fn testReadFile(path: []const u8, buf: []u8) ?usize {
    const node = vfs.lookup(path) orelse return null;
    return vfs.read(&node, 0, buf);
}

/// Test-only service callbacks. Using callbacks avoids importing a second copy
/// of PMM/VFS into the test module (which would duplicate module global state).
fn testLog(s: []const u8) void {
    serial.puts(s);
}

/// Return the number of free pages, for the test module.
fn testFreePages() usize {
    return pmm.free_pages;
}

/// Return true if the file exists, for the test module.
fn testHasFile(path: []const u8) bool {
    return vfs.lookup(path) != null;
}

fn testFileSize(path: []const u8) ?u64 {
    const node = vfs.lookup(path) orelse return null;
    return node.size;
}

fn testReadFileAt(
    path: []const u8,
    offset: u64,
    buf: []u8,
) ?usize {
    const node = vfs.lookup(path) orelse return null;
    return vfs.read(&node, offset, buf);
}

fn testPageRw(page: u64) bool {
    const memory =
        pmm.physToVirt(page)[0..pmm.PAGE_SIZE];

    memory[0] = 0xA5;
    memory[pmm.PAGE_SIZE - 1] = 0x5A;

    return memory[0] == 0xA5 and
        memory[pmm.PAGE_SIZE - 1] == 0x5A;
}

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

/// The kernel's main entry point.
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
    print("Memory: {d} MiB free\n", .{pmm.free_pages * pmm.PAGE_SIZE / (1024 * 1024)});

    acpi.init(response(&rsdp_request).address, hhdm);
    apic.init();
    hpet.init();

    pci.scan();
    if (pci.find(0x01, 0x08, 0x02)) |dev| diskTest(dev) else print("no NVMe controller\n", .{});

    idt.register(apic.TIMER_VECTOR, onTick);
    apic.timerInit(100);
    print("APIC timer: {d} ticks/ms, running at 100 Hz\n", .{apic.ticks_per_ms});

    syscall.init();

    const initrd = findModule("initrd.tar") orelse @panic("no initrd.tar module");
    vfs.mountRoot(tarfs.init(initrd));

    // Execute real kernel integration tests without launching an interactive shell.
    if (comptime build_options.is_test) {
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
            .address_space_roundtrip = testAddressSpaceRoundtrip,
            .invalid_elf_rejected = testInvalidElfRejected,
        });
    }

    keyboard.init();
    _ = process.spawnPath("/bin/sh", null) catch |e| print("failed to start /bin/sh: {s}\n", .{@errorName(e)});
    print("Boot complete.\n", .{});
    idle();
}
