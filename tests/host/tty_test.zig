//! Host tests for the terminal's line discipline
//! (`src/kernel/tty_core.zig`).

const std = @import("std");
const tty_core = @import("tty_core");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

const Harness = struct {
    tty: tty_core.Tty = .{},
    echo_buf: [256]u8 = undefined,
    echo: std.ArrayListUnmanaged(u8) = .empty,
    /// The strongest thing `input` asked for since `type` was called.
    asked: tty_core.Action = .none,

    /// Type `keys`; what was shown for them is `shown()`.
    fn typeKeys(h: *Harness, keys: []const u8) void {
        h.echo = .initBuffer(&h.echo_buf);
        h.asked = .none;
        for (keys) |k| {
            const action = h.tty.input(k, &h.echo);
            if (@backingInt(action) > @backingInt(h.asked)) h.asked = action;
        }
    }

    fn shown(h: *const Harness) []const u8 {
        return h.echo.items;
    }

    var read_buf: [8192]u8 = undefined;

    fn read(h: *Harness, max: usize) ?[]const u8 {
        const n = h.tty.read(read_buf[0..max]) orelse return null;
        return read_buf[0..n];
    }
};

test "tty: a line is handed over when Enter is typed, corrections and all" {
    var h: Harness = .{};
    h.typeKeys("helo");
    try testing.expectEqualStrings("helo", h.shown());
    try expectEqual(.none, h.asked);
    try expectEqual(null, h.read(64)); // nothing to read before Enter
    try expect(!h.tty.readable());

    h.typeKeys("\x7flo\x08\x08lo\n"); // two kinds of backspace
    try testing.expectEqualStrings("\x08 \x08lo\x08 \x08\x08 \x08lo\n", h.shown());
    try expectEqual(.readable, h.asked);
    try testing.expectEqualStrings("hello\n", h.read(64).?);
    try expectEqual(null, h.read(64));

    // Backspace on an empty line does and shows nothing.
    h.typeKeys("\x7f\x7f");
    try testing.expectEqualStrings("", h.shown());
    // Ctrl+U takes the whole line back.
    h.typeKeys("wrong\x15right\n");
    try testing.expectEqualStrings("wrong" ++ "\x08 \x08\x08 \x08\x08 \x08\x08 \x08\x08 \x08" ++ "right\n", h.shown());
    try testing.expectEqualStrings("right\n", h.read(64).?);
    // Enter on a serial line is a carriage return.
    h.typeKeys("serial\r");
    try testing.expectEqualStrings("serial\n", h.read(64).?);
    // Control characters that mean nothing here are not taken; tab is.
    h.typeKeys("a\x01\x1bb\tc\n");
    try testing.expectEqualStrings("ab\tc\n", h.read(64).?);
}

test "tty: a read gets one line, in pieces if its buffer is small" {
    var h: Harness = .{};
    h.typeKeys("first\nsecond\n\nfourth\n");
    try expectEqual(21, h.tty.available());
    try testing.expectEqualStrings("first\n", h.read(64).?);
    try testing.expectEqualStrings("sec", h.read(3).?); // the rest of the line stays
    try testing.expectEqualStrings("ond", h.read(3).?);
    try testing.expectEqualStrings("\n", h.read(3).?);
    try testing.expectEqualStrings("\n", h.read(64).?); // the empty line
    try testing.expectEqualStrings("fourth\n", h.read(64).?);
    try expectEqual(null, h.read(64));
    try expectEqual(0, h.tty.available());
}

test "tty: Ctrl+D is the end of input, or of what has been typed" {
    var h: Harness = .{};
    h.typeKeys("\x04");
    try expectEqual(.readable, h.asked);
    try testing.expectEqualStrings("", h.shown());
    try testing.expectEqualStrings("", h.read(64).?); // end of file
    try expectEqual(null, h.read(64)); // once

    h.typeKeys("partial\x04");
    try testing.expectEqualStrings("partial", h.read(64).?); // without a newline
    try expectEqual(null, h.read(64));

    // After a line, on an empty one: the line, then the end.
    h.typeKeys("last\n\x04more\n");
    try testing.expectEqualStrings("last\n", h.read(64).?);
    try testing.expectEqualStrings("", h.read(64).?);
    try testing.expectEqualStrings("more\n", h.read(64).?);
    // A line given up in pieces ends where it was given up.
    h.typeKeys("abcdef\x04");
    try testing.expectEqualStrings("abcd", h.read(4).?);
    try testing.expectEqualStrings("ef", h.read(4).?);
    try expectEqual(null, h.read(4));
}

test "tty: Ctrl+C throws the line away and asks for an interrupt" {
    var h: Harness = .{};
    h.typeKeys("rm -rf /\x03");
    try expectEqual(.interrupt, h.asked);
    try testing.expectEqualStrings("rm -rf /^C\n", h.shown());
    try expectEqual(null, h.read(64));
    h.typeKeys("ls\n");
    try testing.expectEqualStrings("ls\n", h.read(64).?); // what follows is a new line
    // With signals off it is a character like any other control character.
    h.tty.configure(.{ .signals = false });
    h.typeKeys("a\x03b\n");
    try expectEqual(.readable, h.asked);
    try testing.expectEqualStrings("ab\n", h.read(64).?);
}

test "tty: without line editing every key goes through at once" {
    var h: Harness = .{};
    h.tty.configure(.{ .canonical = false, .echo = false });
    h.typeKeys("a");
    try expectEqual(.readable, h.asked);
    try testing.expectEqualStrings("", h.shown()); // not shown
    try testing.expectEqualStrings("a", h.read(64).?);
    h.typeKeys("\x7f\x15\x04\x1b[A\n"); // editing keys are just bytes now
    try testing.expectEqualStrings("\x7f\x15\x04\x1b[A\n", h.read(64).?);
    try expectEqual(null, h.read(64));
    h.typeKeys("\x03"); // but Ctrl+C still interrupts, until that is off too
    try expectEqual(.interrupt, h.asked);
    h.tty.configure(.{ .canonical = false, .echo = false, .signals = false, .cr_to_nl = false });
    h.typeKeys("\x03\r");
    try testing.expectEqualStrings("\x03\r", h.read(64).?);
    // Echo without editing shows the key as it is.
    h.tty.configure(.{ .canonical = false });
    h.typeKeys("x");
    try testing.expectEqualStrings("x", h.shown());
    _ = h.read(64);

    // Changing over with a line half typed hands it over; changing back
    // with lines waiting counts them again.
    h.tty.configure(.{});
    h.typeKeys("half");
    h.tty.configure(.{ .canonical = false });
    try testing.expectEqualStrings("half", h.read(64).?);
    h.typeKeys("one\ntwo\nthr");
    h.tty.configure(.{});
    try testing.expectEqualStrings("one\n", h.read(64).?);
    try testing.expectEqualStrings("two\n", h.read(64).?);
    try expectEqual(null, h.read(64)); // "thr" has no end yet
    h.typeKeys("\n");
    try testing.expectEqualStrings("thr\n", h.read(64).?);
}

test "tty: full buffers refuse, and nothing is lost or made up" {
    var h: Harness = .{};
    // A line longer than can be edited: the rest is not taken, Enter is.
    for (0..tty_core.LINE_MAX + 50) |_| h.typeKeys("x");
    try testing.expectEqualStrings("", h.shown()); // the last one was not shown either
    h.typeKeys("\n");
    const line = h.read(8192).?;
    try expectEqual(tty_core.LINE_MAX, line.len);
    try expect(line[line.len - 1] == '\n' and std.mem.allEqual(u8, line[0 .. line.len - 1], 'x'));

    // Nobody reads: lines pile up until there is no room, and Enter then
    // does nothing until there is.
    var typed: usize = 0;
    while (typed < 3 * tty_core.READY_MAX) : (typed += 100) {
        h.typeKeys(&@as([99]u8, @splat('x')) ++ "\n"); // a hundred with the newline
    }
    try expect(h.tty.ready_len <= tty_core.READY_MAX);
    const kept = h.tty.lines;
    try expect(kept >= tty_core.READY_MAX / 100 - 1 and kept <= tty_core.READY_MAX / 100);
    for (0..kept) |_| try expectEqual(100, h.read(8192).?.len);
    // The line that did not fit is still being edited, with what was
    // typed after it, up to the longest a line can be; Enter takes it now.
    try expectEqual(null, h.read(8192));
    h.typeKeys("\n");
    try expectEqual(tty_core.LINE_MAX, h.read(8192).?.len);

    // Raw input with nobody reading: dropped when full, never beyond.
    h.tty.configure(.{ .canonical = false, .echo = false });
    for (0..tty_core.READY_MAX + 500) |_| h.typeKeys("r");
    try expectEqual(tty_core.READY_MAX, h.read(8192).?.len);
    try expectEqual(null, h.read(8192));
    // Flushing forgets everything.
    h.tty.configure(.{});
    h.typeKeys("line\nhalf");
    h.tty.flush();
    try expectEqual(null, h.read(64));
    h.typeKeys("\n");
    try testing.expectEqualStrings("\n", h.read(64).?);
}

test "tty: random typing against a simple model" {
    // The model: the text the readers must get is what was typed with
    // the corrections applied, cut at each Enter.
    var prng: std.Random.DefaultPrng = .init(0x7474792d74657374);
    const random = prng.random();
    var h: Harness = .{};
    var expected: std.ArrayListUnmanaged(u8) = .empty;
    defer expected.deinit(testing.allocator);
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(testing.allocator);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(testing.allocator);

    for (0..20_000) |_| {
        const key: u8 = switch (random.uintLessThan(u8, 20)) {
            0 => '\n',
            1, 2 => 0x7F,
            3 => 0x15,
            else => 'a' + random.uintLessThan(u8, 26),
        };
        h.typeKeys(&.{key});
        switch (key) {
            '\n' => {
                try expected.appendSlice(testing.allocator, line.items);
                try expected.append(testing.allocator, '\n');
                line.clearRetainingCapacity();
            },
            0x7F => _ = line.pop(),
            0x15 => line.clearRetainingCapacity(),
            else => try line.append(testing.allocator, key),
        }
        // Read now and then, with buffers of every size.
        if (random.uintLessThan(u8, 8) == 0) {
            while (h.read(random.uintLessThan(usize, 40) + 1)) |part| try got.appendSlice(testing.allocator, part);
        }
    }
    while (h.read(64)) |part| try got.appendSlice(testing.allocator, part);
    try testing.expectEqualStrings(expected.items, got.items);
}
