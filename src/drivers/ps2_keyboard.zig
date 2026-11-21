const std = @import("std");
const cpu = @import("../arch/x86_64/cpu.zig");
const idt = @import("../arch/x86_64/idt.zig");
const apic = @import("../arch/x86_64/apic.zig");
const root = @import("root");
const thread = @import("../kernel/thread.zig");

// Scancode set 1, US layout, indexed by scancode 0x00-0x39. 0 = no character.
const normal = "\x00\x1b1234567890-=\x08\tqwertyuiop[]\n\x00asdfghjkl;'`\x00\\zxcvbnm,./\x00*\x00 ";
const shifted = "\x00\x1b!@#$%^&*()_+\x08\tQWERTYUIOP{}\n\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?\x00*\x00 ";

var shift = false;
var ctrl = false;
var caps = false;
var extended = false; // previous byte was the 0xE0 prefix

// Ring buffer: written by the IRQ handler, read by the main loop
var buf: [256]u8 = undefined;
var head: u8 = 0; // next write (u8 wraps at 256 by itself)
var tail: u8 = 0; // next read

pub var waiter: ?*thread.Thread = null; // set by the getchar syscall

// Push a character into the ring buffer. If the buffer is full, the character is dropped.
fn push(c: u8) void {
    const h = head;
    if (h +% 1 == @atomicLoad(u8, &tail, .acquire)) return; // full: drop the key
    buf[h] = c;
    @atomicStore(u8, &head, h +% 1, .release);
}

// IRQ handler for the PS/2 keyboard. Reads a scancode from the keyboard controller, translates it to a character, and pushes it into the ring buffer. Wakes any thread waiting for a character.
fn onIrq(_: *idt.Frame) void {
    const sc = cpu.inb(0x60);
    if (sc == 0xE0) {
        extended = true;
        return;
    }
    defer extended = false;

    const released = (sc & 0x80) != 0;
    const code = sc & 0x7F;

    switch (code) {
        0x2A, 0x36 => {
            shift = !released;
            return;
        }, // left/right shift
        0x1D => {
            ctrl = !released;
            return;
        }, // left ctrl (right ctrl = E0 1D)
        0x3A => {
            if (!released) caps = !caps;
            return;
        },
        else => {},
    }
    if (released or extended or code >= normal.len) return; // arrows etc. later

    var c = (if (shift) shifted else normal)[code];
    if (c == 0) return;
    if (caps and std.ascii.isAlphabetic(c)) c ^= 0x20; // flip case
    if (ctrl and std.ascii.isAlphabetic(c)) c &= 0x1F; // Ctrl+C = 3, etc.
    push(c);
    if (waiter) |w| {
        waiter = null;
        thread.wake(w);
    }
}

// Get a character from the keyboard. Blocks until a character is available. Returns the character, or null if the thread was woken by another thread.
pub fn getChar() ?u8 {
    const t = tail;
    if (t == @atomicLoad(u8, &head, .acquire)) return null;
    const c = buf[t];
    @atomicStore(u8, &tail, t +% 1, .release);
    return c;
}

// Initialize the PS/2 keyboard driver. Registers the IRQ handler and discards any stale bytes in the keyboard controller's output buffer.
pub fn init() void {
    while ((cpu.inb(0x64) & 1) != 0) _ = cpu.inb(0x60); // discard stale bytes
    idt.register(apic.IRQ_BASE + 1, onIrq);
    apic.route(1, apic.IRQ_BASE + 1);
}
