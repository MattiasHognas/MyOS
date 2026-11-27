//! The PC's battery-backed real-time clock (the CMOS RTC, ports 0x70 and
//! 0x71): the date and time when the machine boots, which the wall clock
//! starts from (`clock.zig`). Read once; the clock runs on from there.

const cpu = @import("../arch/x86_64/cpu.zig");
const calendar = @import("../kernel/calendar.zig");

fn read(reg: u8) u8 {
    cpu.outb(0x70, reg | 0x80); // bit 7: NMIs stay masked while we read
    return cpu.inb(0x71);
}

fn updating() bool {
    return read(0x0A) & 0x80 != 0;
}

const Raw = struct { sec: u8, min: u8, hour: u8, day: u8, month: u8, year: u8, century: u8 };

fn sample() Raw {
    while (updating()) {}
    return .{
        .sec = read(0x00),
        .min = read(0x02),
        .hour = read(0x04),
        .day = read(0x07),
        .month = read(0x08),
        .year = read(0x09),
        .century = read(0x32), // the ACPI century register; 0 if there is none
    };
}

fn eql(a: Raw, b: Raw) bool {
    return a.sec == b.sec and a.min == b.min and a.hour == b.hour and a.day == b.day and a.month == b.month and a.year == b.year;
}

/// Seconds since 1970-01-01 00:00 UTC as the RTC says now (it is taken to
/// keep UTC, as Linux takes it to), or null if what it says is not a date.
pub fn readUnixSeconds() ?u64 {
    // Twice the same, so the clock did not move halfway through the reads.
    var a = sample();
    while (true) {
        const b = sample();
        if (eql(a, b)) break;
        a = b;
    }
    const status_b = read(0x0B);
    return calendar.unixSeconds(.{
        .sec = a.sec,
        .min = a.min,
        .hour = a.hour,
        .day = a.day,
        .month = a.month,
        .year = a.year,
        .century = a.century,
        .bcd = status_b & 0x04 == 0,
        .hour_12 = status_b & 0x02 == 0,
    });
}
