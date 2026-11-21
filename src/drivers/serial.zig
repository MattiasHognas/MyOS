const std = @import("std");
const COM1 = 0x3F8;

// Write a byte to the given I/O port.
fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
    );
}

// Read a byte from the given I/O port.
fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

// Write a character to the serial port. The caller must ensure that the serial port is initialized.
fn putc(c: u8) void {
    if (c == '\n') putc('\r');
    while (inb(COM1 + 5) & 0x20 == 0) {}
    outb(COM1, c);
}

// Initialize the serial port. This must be called before any other functions in this file.
pub fn init() void {
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x80);
    outb(COM1 + 0, 0x01);
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03);
    outb(COM1 + 2, 0xC7);
    outb(COM1 + 4, 0x03);
}

// Write a string to the serial port. The caller must ensure that the serial port is initialized.
pub fn puts(s: []const u8) void {
    for (s) |c| putc(c);
}

// Write a formatted string to the serial port. The caller must ensure that the serial port is initialized.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    puts(std.fmt.bufPrint(&buf, fmt, args) catch "<print overflow>\n");
}
