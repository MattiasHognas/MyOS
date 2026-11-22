//! QEMU firmware configuration (fw_cfg) device, legacy I/O port interface.
//!
//! The host can pass named blobs to the guest with
//! `-fw_cfg name=opt/<name>,string=<value>`. The test kernel uses this to pick
//! an integration-test scenario. On machines without fw_cfg (real hardware)
//! the signature check fails and every lookup returns null.

const std = @import("std");
const cpu = @import("root").arch.x86_64.cpu;

const SELECTOR_PORT = 0x510;
const DATA_PORT = 0x511;
const KEY_SIGNATURE = 0x0000;
const KEY_FILE_DIR = 0x0019;

/// Select item `key`; following data-port reads return its bytes from the start.
fn select(key: u16) void {
    cpu.outw(SELECTOR_PORT, key);
}

/// Read the next `buf.len` bytes of the selected item into `buf`.
fn readBytes(buf: []u8) void {
    for (buf) |*b| b.* = cpu.inb(DATA_PORT);
}

/// Read the next big-endian integer of type `T` from the selected item.
fn readBe(comptime T: type) T {
    var b: [@sizeOf(T)]u8 = undefined;
    readBytes(&b);
    return std.mem.readInt(T, &b, .big);
}

/// Return true if a QEMU fw_cfg device is present.
pub fn present() bool {
    select(KEY_SIGNATURE);
    var sig: [4]u8 = undefined;
    readBytes(&sig);
    return std.mem.eql(u8, &sig, "QEMU");
}

/// Read the fw_cfg file `name` (e.g. "opt/myos/scenario") into `buf`.
/// Returns the bytes read (at most `buf.len`), or null if there is no fw_cfg
/// device or no such file.
pub fn readFile(name: []const u8, buf: []u8) ?[]u8 {
    if (!present()) return null;
    select(KEY_FILE_DIR);
    const count = readBe(u32);
    for (0..count) |_| {
        const size = readBe(u32);
        const key = readBe(u16);
        _ = readBe(u16); // reserved
        var entry_name: [56]u8 = undefined;
        readBytes(&entry_name);
        const len = std.mem.indexOfScalar(u8, &entry_name, 0) orelse entry_name.len;
        if (!std.mem.eql(u8, entry_name[0..len], name)) continue;

        select(key);
        const n = @min(size, buf.len);
        readBytes(buf[0..n]);
        return buf[0..n];
    }
    return null;
}
