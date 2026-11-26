//! PS/2 keyboard driver.
//!
//! The IRQ 1 handler translates scancode set 1 (US layout) into ASCII,
//! tracking Shift, Ctrl and Caps Lock, and hands each character to the
//! terminal (`kernel/tty.zig`), which edits lines and serves readers.
//!
//! A spinlock protects the modifier state; it is released before the
//! character goes on.

const std = @import("std");

const apic = @import("../arch/x86_64/apic.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const idt = @import("../arch/x86_64/idt.zig");
const SpinLock = @import("../kernel/sync/spinlock.zig").SpinLock;
const tty = @import("../kernel/tty.zig");

// Scancode set 1, US layout, indexed by scancode 0x00-0x39. 0 = no character.
const normal = "\x00\x1b1234567890-=\x08\tqwertyuiop[]\n\x00asdfghjkl;'`\x00\\zxcvbnm,./\x00*\x00 ";
const shifted = "\x00\x1b!@#$%^&*()_+\x08\tQWERTYUIOP{}\n\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?\x00*\x00 ";

/// Protects the modifier state below.
var lock: SpinLock = .{ .rank = .condition };

var shift = false;
var ctrl = false;
var caps = false;
var extended = false; // previous byte was the 0xE0 prefix

/// IRQ 1 handler: read one scancode from the controller, update the modifier
/// state, translate key presses to ASCII and give the character to the
/// terminal. Extended (0xE0-prefixed) keys and key releases produce no
/// characters.
fn onIrq(_: *idt.Frame) void {
    // To the terminal once the modifier state is no longer looked at:
    // the terminal shows the key and may end a program.
    const c = translate() orelse return;
    tty.input(c);
}

/// Read one scancode, update the modifier state, and return the character
/// the key stands for, if it stands for one.
fn translate() ?u8 {
    const held = lock.acquire();
    defer lock.release(held);
    const sc = cpu.inb(0x60);
    if (sc == 0xE0) {
        extended = true;
        return null;
    }
    defer extended = false;

    const released = (sc & 0x80) != 0;
    const code = sc & 0x7F;

    switch (code) {
        0x2A, 0x36 => {
            shift = !released;
            return null;
        }, // left/right shift
        0x1D => {
            ctrl = !released;
            return null;
        }, // left ctrl (right ctrl = E0 1D)
        0x3A => {
            if (!released) caps = !caps;
            return null;
        },
        else => {},
    }
    if (released or extended or code >= normal.len) return null; // arrows etc. later

    var c = (if (shift) shifted else normal)[code];
    if (c == 0) return null;
    if (caps and std.ascii.isAlphabetic(c)) c ^= 0x20; // flip case
    if (ctrl and std.ascii.isAlphabetic(c)) c &= 0x1F; // Ctrl+C = 3, etc.
    return c;
}

/// Discard any stale bytes in the controller's output buffer, install the IRQ
/// handler and route IRQ 1 through the I/O APIC. Requires `apic.init`.
pub fn init() void {
    while ((cpu.inb(0x64) & 1) != 0) _ = cpu.inb(0x60); // discard stale bytes
    idt.register(apic.IRQ_BASE + 1, onIrq);
    apic.route(1, apic.IRQ_BASE + 1);
}
