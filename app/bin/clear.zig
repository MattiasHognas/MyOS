//! `clear`: clear the terminal and put the cursor at the top.

const u = @import("util");

pub fn main() u8 {
    _ = u.writeAll(1, "\x1b[H\x1b[2J\x1b[3J");
    return 0;
}
