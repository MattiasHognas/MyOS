//! Text console on the bootloader's framebuffer.
//!
//! Renders characters with a PSF1/PSF2 bitmap font embedded at compile time,
//! wraps at the right edge and scrolls when the cursor passes the last row.

const std = @import("std");

const limine = @import("../boot/limine.zig");

var fb: [*]u32 = undefined;
var stride: usize = 0; // pixels per row
var cols: usize = 0;
var rows: usize = 0;
var col: usize = 0;
var row: usize = 0;
const fg: u32 = 0xE0E0E0;
const bg: u32 = 0x101820;

/// Glyph size in pixels, bytes per glyph and the glyph bitmaps.
const Font = struct { w: usize, h: usize, bpg: usize, glyphs: []const u8 };

/// The console font, parsed at compile time; a bad font file is a compile error.
const font: Font = blk: {
    const d = @embedFile("../assets/font.psf");
    if (d[0] == 0x36 and d[1] == 0x04) { // PSF1
        break :blk .{ .w = 8, .h = d[3], .bpg = d[3], .glyphs = d[4..] };
    }
    if (std.mem.readInt(u32, d[0..4], .little) == 0x864ab572) { // PSF2
        const r = struct {
            fn f(b: []const u8, o: usize) usize {
                return std.mem.readInt(u32, b[o..][0..4], .little);
            }
        }.f;
        break :blk .{ .w = r(d, 28), .h = r(d, 24), .bpg = r(d, 20), .glyphs = d[r(d, 8)..] };
    }
    @compileError("font.psf is not a PSF font");
};

/// True once `init` has run and `putc` may be called.
pub var ready = false;

/// Draw character `c` at character cell (`cx`, `cy`), overwriting the whole cell.
fn drawGlyph(c: u8, cx: usize, cy: usize) void {
    const glyph = font.glyphs[@as(usize, c) * font.bpg ..][0..font.bpg];
    const bytes_per_row = (font.w + 7) / 8;
    for (0..font.h) |y| {
        const line = fb + (cy * font.h + y) * stride + cx * font.w;
        for (0..font.w) |x| {
            const bit = @as(u8, 0x80) >> @intCast(x % 8);
            const on = (glyph[y * bytes_per_row + x / 8] & bit) != 0;
            line[x] = if (on) fg else bg;
        }
    }
}

/// Move every text row up by one and clear the bottom row.
///
/// The move is one `rep movsl` (source above destination, so copying
/// upwards is safe). A copy loop in Zig does the same on a real CPU, but
/// under QEMU's emulation its speed depends on where the linker happens to
/// put it: when the loop straddles a page boundary it runs at half speed,
/// and since nearly every line printed scrolls the screen, so does
/// everything that prints. That made test runs twice as slow from one
/// build to the next for no reason in the code.
fn scroll() void {
    const line_px = stride * font.h;
    const total = line_px * rows;
    var dst: [*]u32 = fb;
    var src: [*]u32 = fb + line_px;
    var count: usize = total - line_px;
    asm volatile ("rep movsl"
        : [dst] "={rdi}" (dst),
          [src] "={rsi}" (src),
          [count] "={rcx}" (count),
        : [d] "{rdi}" (dst),
          [s] "{rsi}" (src),
          [c] "{rcx}" (count),
        : .{ .memory = true });
    @memset(fb[total - line_px .. total], bg);
}

/// Write one character at the cursor and advance it.
///
/// `\n` moves to the start of the next line and backspace (0x08) moves the
/// cursor one cell left without erasing. Lines wrap at the right edge and the
/// screen scrolls at the bottom. Requires `init` (check `ready`).
pub fn putc(c: u8) void {
    if (c == 0x08) {
        if (col > 0) col -= 1;
        return;
    }
    if (c == '\n') {
        col = 0;
        row += 1;
    } else {
        drawGlyph(c, col, row);
        col += 1;
        if (col == cols) {
            col = 0;
            row += 1;
        }
    }
    if (row == rows) {
        scroll();
        row = rows - 1;
    }
}

/// Set up the console on framebuffer `f`, clear the screen and set `ready`.
/// Panics if the framebuffer is not 32 bits per pixel.
pub fn init(f: *const limine.Framebuffer) void {
    if (f.bpp != 32) @panic("framebuffer is not 32 bpp");
    fb = @ptrCast(@alignCast(f.address));
    stride = f.pitch / 4;
    cols = f.width / font.w;
    rows = f.height / font.h;
    @memset(fb[0 .. stride * f.height], bg);
    ready = true;
}
