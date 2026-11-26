//! Driver for the COM1 serial port (16550 UART).
//!
//! Output is polled: it is used for kernel logging from the very first
//! instruction, before the framebuffer console exists, and from panics.
//! QEMU forwards it to the host terminal. Input comes by interrupt (IRQ 4,
//! `initInput`) and goes to the terminal like a typed key, so that a
//! session can be driven over the serial line, by a person or a test.

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

/// Where received characters go (`initInput`).
var receiver: ?*const fn (u8) void = null;

/// IRQ 4: take every character the UART has received.
fn onIrq() void {
    while (inb(COM1 + 5) & 0x01 != 0) {
        const c = inb(COM1);
        if (receiver) |f| f(c);
    }
}

/// Have the UART interrupt when a character arrives, and give each one to
/// `to`. The caller routes IRQ 4 to `irqHandler`.
pub fn initInput(to: *const fn (u8) void) void {
    receiver = to;
    while (inb(COM1 + 5) & 0x01 != 0) _ = inb(COM1); // what came before
    outb(COM1 + 4, 0x0B); // DTR, RTS and OUT2: OUT2 lets the interrupt reach the CPU
    outb(COM1 + 1, 0x01); // interrupt on received data
}

/// The handler to register for IRQ 4.
pub fn irqHandler() void {
    onIrq();
}

/// Write the string `s` to the serial port.
pub fn puts(s: []const u8) void {
    for (s) |c| putc(c);
}
