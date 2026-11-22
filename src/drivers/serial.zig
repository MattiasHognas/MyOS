//! Polling driver for the COM1 serial port (16550 UART).
//!
//! Used for kernel logging from the very first instruction, before the
//! framebuffer console exists. QEMU forwards it to the host terminal.

const std = @import("std");
const COM1 = 0x3F8;

/// Write the byte `val` to I/O port `port`.
fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
    );
}

/// Read a byte from I/O port `port`.
fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

/// Send one character, waiting until the transmit buffer is empty.
/// `\n` is sent as `\r\n`.
fn putc(c: u8) void {
    if (c == '\n') putc('\r');
    while (inb(COM1 + 5) & 0x20 == 0) {}
    outb(COM1, c);
}

/// Configure COM1 for 115200 baud, 8 data bits, no parity, one stop bit, with
/// FIFOs enabled and interrupts disabled. Call before any other function here.
pub fn init() void {
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x80);
    outb(COM1 + 0, 0x01);
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03);
    outb(COM1 + 2, 0xC7);
    outb(COM1 + 4, 0x03);
}

/// Write the string `s` to the serial port.
pub fn puts(s: []const u8) void {
    for (s) |c| putc(c);
}

/// Format `args` with `fmt` and write the result to the serial port.
/// Output longer than 512 bytes is replaced by `<print overflow>`.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    puts(std.fmt.bufPrint(&buf, fmt, args) catch "<print overflow>\n");
}
