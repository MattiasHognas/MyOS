const std = @import("std");
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

export var limine_base_revision linksection(".limine_requests") = [3]u64{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 3 };
export var fb_request linksection(".limine_requests") = limine.FramebufferRequest{};
export var memmap_request linksection(".limine_requests") = limine.MemmapRequest{};
export var hhdm_request linksection(".limine_requests") = limine.HhdmRequest{};
export var kaddr_request linksection(".limine_requests") = limine.KernelAddressRequest{};
export var rsdp_request linksection(".limine_requests") = limine.RsdpRequest{};

var ticks: u64 = 0;

pub const panic = std.debug.FullPanic(kernelPanic);

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch "<print overflow>\n";
    serial.puts(s);
    if (console.ready) for (s) |c| console.putc(c);
}

pub fn halt() noreturn {
    while (true) asm volatile ("cli; hlt");
}

fn onTick(_: *idt.Frame) void {
    ticks += 1;
    if (ticks % 100 == 0) print("uptime: {d} s\n", .{ticks / 100});
}

fn response(req: anytype) @typeInfo(@TypeOf(req.response)).optional.child {
    const v: *volatile @TypeOf(req.*) = req;
    return v.response orelse @panic("Limine request not answered");
}

fn kernelPanic(msg: []const u8, _: ?usize) noreturn {
    print("PANIC: {s}\n", .{msg});
    halt();
}

fn idle() noreturn {
    while (true) asm volatile ("sti; hlt"); // sleep until the next interrupt
}

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
        asm volatile ("sti; hlt"); // sleep until the next key or timer tick
    }
}

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
    idt.register(apic.TIMER_VECTOR, onTick);
    apic.timerInit(100);
    print("APIC timer: {d} ticks/ms, running at 100 Hz\n", .{apic.ticks_per_ms});

    keyboard.init();
    print("Boot complete.\n", .{});
    shell();
}
