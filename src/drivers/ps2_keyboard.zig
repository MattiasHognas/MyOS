//! PS/2 keyboard driver.
//!
//! The IRQ 1 handler translates scancode set 1 (US layout) into ASCII,
//! tracking Shift, Ctrl and Caps Lock, and pushes characters into a lock-free
//! single-producer/single-consumer ring buffer read by `getChar`.

const std = @import("std");
const root = @import("root");

const apic = @import("../arch/x86_64/apic.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const idt = @import("../arch/x86_64/idt.zig");
const WaitQueue = @import("../kernel/sync/wait_queue.zig").WaitQueue;

// Scancode set 1, US layout, indexed by scancode 0x00-0x39. 0 = no character.
const normal = "\x00\x1b1234567890-=\x08\tqwertyuiop[]\n\x00asdfghjkl;'`\x00\\zxcvbnm,./\x00*\x00 ";
const shifted = "\x00\x1b!@#$%^&*()_+\x08\tQWERTYUIOP{}\n\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?\x00*\x00 ";

var shift = false;
var ctrl = false;
var caps = false;
var extended = false; // previous byte was the 0xE0 prefix

// Ring buffer: written by the IRQ handler, read by getChar.
var buf: [256]u8 = undefined;
var head: u8 = 0; // next write (u8 wraps at 256 by itself)
var tail: u8 = 0; // next read

/// Threads waiting for a key. A reader that finds the buffer empty waits
/// here (with interrupts off between the look and the wait); the IRQ
/// handler wakes the one that has waited longest for each key.
pub var readers: WaitQueue = .{};

/// Append `c` to the ring buffer. Drops the character if the buffer is full.
/// Only called from the IRQ handler (the single producer).
fn push(c: u8) void {
    const h = head;
    if (h +% 1 == @atomicLoad(u8, &tail, .acquire)) return; // full: drop the key
    buf[h] = c;
    @atomicStore(u8, &head, h +% 1, .release);
}

/// IRQ 1 handler: read one scancode from the controller, update the modifier
/// state, translate key presses to ASCII, queue the character and wake
/// a waiting reader. Extended (0xE0-prefixed) keys and key releases produce no
/// characters.
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
    _ = readers.wakeOne();
}

/// Queue the character `c` as if it had been typed, and wake a waiting
/// reader. For input that does not come from the keyboard controller: the
/// tests today, other input sources later. Interrupts must be off, as in
/// the IRQ handler (there is one producer at a time).
pub fn inject(c: u8) void {
    push(c);
    _ = readers.wakeOne();
}

/// Take the next character from the ring buffer, or return null if it is
/// empty. Never blocks; callers that want to wait use `readers`.
pub fn getChar() ?u8 {
    const t = tail;
    if (t == @atomicLoad(u8, &head, .acquire)) return null;
    const c = buf[t];
    @atomicStore(u8, &tail, t +% 1, .release);
    return c;
}

/// Discard any stale bytes in the controller's output buffer, install the IRQ
/// handler and route IRQ 1 through the I/O APIC. Requires `apic.init`.
pub fn init() void {
    while ((cpu.inb(0x64) & 1) != 0) _ = cpu.inb(0x60); // discard stale bytes
    idt.register(apic.IRQ_BASE + 1, onIrq);
    apic.route(1, apic.IRQ_BASE + 1);
}
