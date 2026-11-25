//! PS/2 keyboard driver.
//!
//! The IRQ 1 handler translates scancode set 1 (US layout) into ASCII,
//! tracking Shift, Ctrl and Caps Lock, and puts characters into a ring
//! buffer. `read` takes them out, sleeping while there is none.
//!
//! One spinlock protects the buffer, the modifier state and the queue of
//! waiting readers: "is there a key" is the condition the readers wait
//! for, and the interrupt handler takes the same lock to add a key and
//! wake one of them (`docs/locking.md`).

const std = @import("std");

const apic = @import("../arch/x86_64/apic.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const idt = @import("../arch/x86_64/idt.zig");
const SpinLock = @import("../kernel/sync/spinlock.zig").SpinLock;
const WaitQueue = @import("../kernel/sync/wait_queue.zig").WaitQueue;

// Scancode set 1, US layout, indexed by scancode 0x00-0x39. 0 = no character.
const normal = "\x00\x1b1234567890-=\x08\tqwertyuiop[]\n\x00asdfghjkl;'`\x00\\zxcvbnm,./\x00*\x00 ";
const shifted = "\x00\x1b!@#$%^&*()_+\x08\tQWERTYUIOP{}\n\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?\x00*\x00 ";

/// Protects everything below.
var lock: SpinLock = .{ .rank = .condition };

var shift = false;
var ctrl = false;
var caps = false;
var extended = false; // previous byte was the 0xE0 prefix

// Ring buffer: written by the IRQ handler, read by `read` and `getChar`.
var buf: [256]u8 = undefined;
var head: u8 = 0; // next write (u8 wraps at 256 by itself)
var tail: u8 = 0; // next read

/// Threads waiting for a key.
var readers: WaitQueue = .{};
/// Readers are served in the order they asked: each takes a number, and
/// the reader whose number is `serving` gets the next key. Being woken
/// first is not enough for that with several CPUs: two readers woken for
/// two keys run at the same time, and the one that started waiting later
/// could reach the buffer first.
var next_ticket: u64 = 0;
var serving: u64 = 0;

/// Append `c` to the ring buffer and wake the waiting readers, of which
/// the one whose turn it is takes it. Drops the character if the buffer is
/// full. The lock must be held.
fn push(c: u8) void {
    if (head +% 1 == tail) return; // full: drop the key
    buf[head] = c;
    head +%= 1;
    _ = readers.wakeAll();
}

/// Take the next character out of the ring buffer, or return null if it is
/// empty. The lock must be held.
fn pop() ?u8 {
    if (tail == head) return null;
    const c = buf[tail];
    tail +%= 1;
    return c;
}

/// IRQ 1 handler: read one scancode from the controller, update the modifier
/// state, translate key presses to ASCII, queue the character and wake
/// a waiting reader. Extended (0xE0-prefixed) keys and key releases produce no
/// characters.
fn onIrq(_: *idt.Frame) void {
    const held = lock.acquire();
    defer lock.release(held);
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
}

/// Queue the character `c` as if it had been typed, and wake a waiting
/// reader. For input that does not come from the keyboard controller: the
/// tests today, other input sources later.
pub fn inject(c: u8) void {
    const held = lock.acquire();
    defer lock.release(held);
    push(c);
}

/// Take the next character from the ring buffer, or return null if it is
/// empty or a thread is waiting in `read`, whose key it would be. Never
/// blocks.
pub fn getChar() ?u8 {
    const held = lock.acquire();
    defer lock.release(held);
    if (serving != next_ticket) return null;
    return pop();
}

/// Return the next character, sleeping until one is typed. Readers are
/// served in the order they called. Not for interrupt handlers.
pub fn read() u8 {
    const held = lock.acquire();
    defer lock.release(held);
    const ticket = next_ticket;
    next_ticket += 1;
    while (true) {
        if (ticket == serving) {
            if (pop()) |c| {
                serving += 1;
                // The next reader's key may be there already.
                if (tail != head) _ = readers.wakeAll();
                return c;
            }
        }
        readers.wait(&lock); // until a key arrives or it is this reader's turn
    }
}

/// Number of threads waiting in `read`.
pub fn waitingReaders() usize {
    const held = lock.acquire();
    defer lock.release(held);
    return readers.waiting();
}

/// Discard any stale bytes in the controller's output buffer, install the IRQ
/// handler and route IRQ 1 through the I/O APIC. Requires `apic.init`.
pub fn init() void {
    while ((cpu.inb(0x64) & 1) != 0) _ = cpu.inb(0x60); // discard stale bytes
    idt.register(apic.IRQ_BASE + 1, onIrq);
    apic.route(1, apic.IRQ_BASE + 1);
}
