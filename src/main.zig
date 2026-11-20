const std = @import("std");
const limine = @import("limine.zig");
const serial = @import("arch/x86_64/serial.zig");
const console = @import("kernel/console.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const heap = @import("heap.zig");
const acpi = @import("acpi.zig");
const apic = @import("apic.zig");
const cpu = @import("cpu.zig");

export var limine_base_revision linksection(".limine_requests") = [3]u64{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 3 };
export var fb_request linksection(".limine_requests") = limine.FramebufferRequest{};
export var memmap_request linksection(".limine_requests") = limine.MemmapRequest{};
export var hhdm_request linksection(".limine_requests") = limine.HhdmRequest{};
export var kaddr_request linksection(".limine_requests") = limine.KernelAddressRequest{};
export var rsdp_request linksection(".limine_requests") = limine.RsdpRequest{};

fn response(req: anytype) @typeInfo(@TypeOf(req.response)).optional.child {
    const v: *volatile @TypeOf(req.*) = req;
    return v.response orelse @panic("Limine request not answered");
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch "<print overflow>\n";
    serial.puts(s);
    if (console.ready) for (s) |c| console.putc(c);
}

pub const panic = std.debug.FullPanic(kernelPanic);

fn kernelPanic(msg: []const u8, _: ?usize) noreturn {
    print("PANIC: {s}\n", .{msg});
    halt();
}

fn keyboard(_: *idt.Frame) void {
    const scancode = cpu.inb(0x60); // must be read, or no further key IRQs arrive
    print("key: 0x{x}\n", .{scancode});
}

fn idle() noreturn {
    while (true) asm volatile ("sti; hlt"); // sleep until the next interrupt
}

pub fn halt() noreturn {
    while (true) asm volatile ("cli; hlt");
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
    idt.register(apic.IRQ_BASE + 1, keyboard);
    apic.route(1, apic.IRQ_BASE + 1);
    print("Boot complete. Press keys in the QEMU window.\n", .{});
    idle();
}
