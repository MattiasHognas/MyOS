//! Turning what the RTC says (BCD or binary, 12- or 24-hour, a two-digit
//! year) into seconds since 1970. No kernel dependencies: tested on the
//! host.

pub const Fields = struct {
    sec: u8,
    min: u8,
    hour: u8,
    day: u8,
    month: u8,
    /// The year within its century, and the century (0: not known, then
    /// 20 is taken).
    year: u8,
    century: u8,
    /// The fields are BCD (most RTCs), not binary.
    bcd: bool,
    /// The hour is 1 to 12, with bit 7 for PM.
    hour_12: bool,
};

fn fromBcd(v: u8) ?u8 {
    const hi = v >> 4;
    const lo = v & 0x0F;
    if (hi > 9 or lo > 9) return null;
    return hi * 10 + lo;
}

/// Days from 1970-01-01 to the first day of `month` (1-12) of `year`,
/// plus `day` - 1.
pub fn daysSinceEpoch(year: u64, month: u64, day: u64) u64 {
    // Counted from March, so the leap day is last (the usual civil
    // calendar arithmetic).
    const y = if (month <= 2) year - 1 else year;
    const era = y / 400;
    const yoe = y - era * 400;
    const mp = (month + 9) % 12;
    const doy = (153 * mp + 2) / 5 + day - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

/// Seconds since 1970-01-01 00:00 for the RTC's fields, or null if they
/// are not a valid date and time from 1970 on.
pub fn unixSeconds(f: Fields) ?u64 {
    const pm = f.hour_12 and f.hour & 0x80 != 0;
    const conv = struct {
        fn of(v: u8, bcd: bool) ?u8 {
            return if (bcd) fromBcd(v) else v;
        }
    }.of;
    const sec = conv(f.sec, f.bcd) orelse return null;
    const min = conv(f.min, f.bcd) orelse return null;
    var hour = conv(f.hour & 0x7F, f.bcd) orelse return null;
    const day = conv(f.day, f.bcd) orelse return null;
    const month = conv(f.month, f.bcd) orelse return null;
    const yy = conv(f.year, f.bcd) orelse return null;
    const cc: u8 = if (f.century == 0) 20 else conv(f.century, f.bcd) orelse return null;
    if (f.hour_12) {
        if (hour < 1 or hour > 12) return null;
        hour = (hour % 12) + @as(u8, if (pm) 12 else 0);
    }
    if (sec > 59 or min > 59 or hour > 23 or day < 1 or day > 31 or month < 1 or month > 12 or yy > 99) return null;
    const year: u64 = @as(u64, cc) * 100 + yy;
    if (year < 1970) return null;
    return daysSinceEpoch(year, month, day) * 86400 + @as(u64, hour) * 3600 + @as(u64, min) * 60 + sec;
}
