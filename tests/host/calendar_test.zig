const std = @import("std");
const cal = @import("calendar");

test "days since 1970, across leap years and centuries" {
    try std.testing.expectEqual(@as(u64, 0), cal.daysSinceEpoch(1970, 1, 1));
    try std.testing.expectEqual(@as(u64, 59), cal.daysSinceEpoch(1970, 3, 1));
    try std.testing.expectEqual(@as(u64, 10957), cal.daysSinceEpoch(2000, 1, 1));
    try std.testing.expectEqual(@as(u64, 11017), cal.daysSinceEpoch(2000, 3, 1)); // 2000 has a 29 February
    try std.testing.expectEqual(@as(u64, 20454), cal.daysSinceEpoch(2026, 1, 1));
}

test "BCD and binary, 24- and 12-hour" {
    // 2026-11-27 13:45:30, as most RTCs keep it: BCD, 24-hour.
    const want: u64 = 1795787130;
    try std.testing.expectEqual(want, cal.unixSeconds(.{ .sec = 0x30, .min = 0x45, .hour = 0x13, .day = 0x27, .month = 0x11, .year = 0x26, .century = 0x20, .bcd = true, .hour_12 = false }).?);
    try std.testing.expectEqual(want, cal.unixSeconds(.{ .sec = 30, .min = 45, .hour = 13, .day = 27, .month = 11, .year = 26, .century = 20, .bcd = false, .hour_12 = false }).?);
    // 1 PM in 12-hour mode: hour 1 with the PM bit.
    try std.testing.expectEqual(want, cal.unixSeconds(.{ .sec = 0x30, .min = 0x45, .hour = 0x81, .day = 0x27, .month = 0x11, .year = 0x26, .century = 0, .bcd = true, .hour_12 = true }).?);
    // 12 AM is midnight, 12 PM noon.
    const midnight = cal.unixSeconds(.{ .sec = 0, .min = 0, .hour = 12, .day = 1, .month = 1, .year = 26, .century = 20, .bcd = false, .hour_12 = true }).?;
    const noon = cal.unixSeconds(.{ .sec = 0, .min = 0, .hour = 0x80 | 12, .day = 1, .month = 1, .year = 26, .century = 20, .bcd = false, .hour_12 = true }).?;
    try std.testing.expectEqual(@as(u64, 20454 * 86400), midnight);
    try std.testing.expectEqual(midnight + 12 * 3600, noon);
}

test "what is not a date is refused" {
    try std.testing.expect(cal.unixSeconds(.{ .sec = 0x6A, .min = 0, .hour = 0, .day = 1, .month = 1, .year = 0x26, .century = 0, .bcd = true, .hour_12 = false }) == null); // not BCD
    try std.testing.expect(cal.unixSeconds(.{ .sec = 0, .min = 0, .hour = 24, .day = 1, .month = 1, .year = 26, .century = 20, .bcd = false, .hour_12 = false }) == null);
    try std.testing.expect(cal.unixSeconds(.{ .sec = 0, .min = 0, .hour = 0, .day = 0, .month = 1, .year = 26, .century = 20, .bcd = false, .hour_12 = false }) == null);
    try std.testing.expect(cal.unixSeconds(.{ .sec = 0, .min = 0, .hour = 0, .day = 1, .month = 13, .year = 26, .century = 20, .bcd = false, .hour_12 = false }) == null);
    try std.testing.expect(cal.unixSeconds(.{ .sec = 0, .min = 0, .hour = 0, .day = 1, .month = 1, .year = 60, .century = 19, .bcd = false, .hour_12 = false }) == null); // before 1970
}
