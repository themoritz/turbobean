const std = @import("std");
const epoch = std.time.epoch;

pub const Date = struct {
    year: u32,
    month: u4,
    day: u5,

    /// Compares two dates with another. If `date2` happens after `date1`,
    /// then the `TimeComparison.after` is returned. If `date2` happens before `date1`,
    /// then `TimeComparison.before` is returned. If both represent the same date,
    /// `TimeComparison.equal` is returned;
    ///
    /// Read: date1.compare(date2) == .before <=> date2 .before date1
    pub fn compare(date1: Date, date2: Date) Comparison {
        if (date1.year > date2.year) {
            return .before;
        } else if (date1.year < date2.year) {
            return .after;
        }

        if (date1.month > date2.month) {
            return .before;
        } else if (date1.month < date2.month) {
            return .after;
        }

        if (date1.day > date2.day) {
            return .before;
        } else if (date1.day < date2.day) {
            return .after;
        }

        return .equal;
    }

    pub fn fromSlice(bytes: []const u8) !Date {
        if (bytes.len != 10) return error.InvalidDate;
        const dash_date = bytes[4] == '-' and bytes[7] == '-';
        const slash_date = bytes[4] == '/' and bytes[7] == '/';
        if (!dash_date and !slash_date) return error.InvalidDate;
        const year = try std.fmt.parseInt(u32, bytes[0..4], 10);
        const month = try std.fmt.parseInt(u4, bytes[5..7], 10);
        const day = try std.fmt.parseInt(u5, bytes[8..10], 10);
        if (month > 12 or day > 31) return error.InvalidDate;
        if (month < 1 or day < 1) return error.InvalidDate;
        return Date{ .year = year, .month = month, .day = day };
    }

    pub fn today() Date {
        const epochSeconds = std.time.epoch.EpochSeconds{ .secs = @intCast(std.time.timestamp()) };
        const epochDay = epochSeconds.getEpochDay();
        const yearDay = epochDay.calculateYearDay();
        const monthDay = yearDay.calculateMonthDay();
        return Date{
            .year = @intCast(yearDay.year),
            .month = @intFromEnum(monthDay.month),
            .day = monthDay.day_index + 1,
        };
    }

    pub fn format(self: Date, writer: *std.Io.Writer) !void {
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day });
    }

    pub fn toEpochDay(self: Date) epoch.EpochDay {
        // Calculate day of year
        var day_of_year: u32 = self.day;
        var m: u4 = 1;
        while (m < self.month) : (m += 1) {
            day_of_year += std.time.epoch.getDaysInMonth(@intCast(self.year), @enumFromInt(m));
        }

        // Calculate days from epoch (1970-01-01)
        var days: i32 = 0;
        var year: i32 = 1970;
        while (year < self.year) : (year += 1) {
            days += std.time.epoch.getDaysInYear(@intCast(year));
        }
        days += @intCast(day_of_year - 1);

        return .{ .day = @intCast(days) };
    }

    pub fn fromEpochDay(epoch_day: epoch.EpochDay) Date {
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        return Date{
            .year = @intCast(year_day.year),
            .month = @intFromEnum(month_day.month),
            .day = month_day.day_index + 1,
        };
    }

    pub fn weekday(self: Date) Weekday {
        // Epoch (1970-01-01) was a Thursday
        const epoch_day = self.toEpochDay();
        const day_of_week = @mod(epoch_day.day + 4, 7);
        return @enumFromInt(day_of_week);
    }

    pub fn addDays(self: Date, days: i32) Date {
        const epoch_day = self.toEpochDay();
        const new_day = @as(i64, epoch_day.day) + @as(i64, days);
        return Date.fromEpochDay(.{ .day = @intCast(new_day) });
    }

    pub fn nextDay(self: Date) Date {
        return self.addDays(1);
    }

    pub fn nextWeek(self: Date) Date {
        const days_until_sunday = (7 - @intFromEnum(self.weekday())) % 7;
        if (days_until_sunday == 0) {
            return self.addDays(7);
        }
        return self.addDays(days_until_sunday);
    }

    pub fn nextYear(self: Date) Date {
        if (self.month == 12 and self.day == 31) {
            return Date{ .year = self.year + 1, .month = 12, .day = 31 };
        }
        return Date{ .year = self.year, .month = 12, .day = 31 };
    }

    pub fn nextQuarter(self: Date) Date {
        if (self.month >= 10) {
            // Q4: target is Dec 31
            if (self.month == 12 and self.day == 31) {
                return Date{ .year = self.year + 1, .month = 3, .day = 31 };
            }
            return Date{ .year = self.year, .month = 12, .day = 31 };
        } else if (self.month >= 7) {
            // Q3: target is Sep 30
            if (self.month == 9 and self.day == 30) {
                return Date{ .year = self.year, .month = 12, .day = 31 };
            }
            return Date{ .year = self.year, .month = 9, .day = 30 };
        } else if (self.month >= 4) {
            // Q2: target is Jun 30
            if (self.month == 6 and self.day == 30) {
                return Date{ .year = self.year, .month = 9, .day = 30 };
            }
            return Date{ .year = self.year, .month = 6, .day = 30 };
        } else {
            // Q1: target is Mar 31
            if (self.month == 3 and self.day == 31) {
                return Date{ .year = self.year, .month = 6, .day = 30 };
            }
            return Date{ .year = self.year, .month = 3, .day = 31 };
        }
    }

    pub fn nextMonth(self: Date) Date {
        const days_in_month = std.time.epoch.getDaysInMonth(@intCast(self.year), @enumFromInt(self.month));
        if (self.day == days_in_month) {
            // Already on last day of month, go to next month
            if (self.month == 12) {
                const next_days = std.time.epoch.getDaysInMonth(@intCast(self.year + 1), @enumFromInt(1));
                return Date{ .year = self.year + 1, .month = 1, .day = next_days };
            } else {
                const next_days = std.time.epoch.getDaysInMonth(@intCast(self.year), @enumFromInt(self.month + 1));
                return Date{ .year = self.year, .month = self.month + 1, .day = next_days };
            }
        }
        return Date{ .year = self.year, .month = self.month, .day = days_in_month };
    }

    /// Returns the ISO week number (1-53) for this date
    /// ISO 8601: A week belongs to the year that contains the week's Thursday
    pub fn getISOWeek(self: Date) u6 {
        // Find the Thursday of this week
        // ISO 8601: Monday=1, Sunday=7 (our enum: Monday=1, Sunday=0)
        const this_weekday = self.weekday();
        const iso_weekday: u8 = if (this_weekday == .sunday) 7 else @intFromEnum(this_weekday);
        const days_to_thursday: i8 = 4 - @as(i8, @intCast(iso_weekday));
        const thursday = self.addDays(@as(i32, days_to_thursday));

        // The week belongs to the year containing the Thursday
        const year_to_use = thursday.year;

        // Calculate week number within that year
        const jan_1 = Date{ .year = year_to_use, .month = 1, .day = 1 };
        const jan_1_weekday = jan_1.weekday();

        // Days from Jan 1 to Thursday
        const epoch_jan_1 = jan_1.toEpochDay();
        const epoch_thursday = thursday.toEpochDay();
        const days_from_jan_1: u32 = @intCast(epoch_thursday.day - epoch_jan_1.day);

        // Adjust for ISO week: if Jan 1 is Fri, Sat, or Sun, those days belong to last year's week
        const iso_offset: i8 = switch (jan_1_weekday) {
            .monday => 0,
            .tuesday => 1,
            .wednesday => 2,
            .thursday => 3,
            .friday => -3,
            .saturday => -2,
            .sunday => -1,
        };

        const iso_day: i32 = @as(i32, @intCast(days_from_jan_1)) + iso_offset;
        const week_num: u6 = @intCast(@divFloor(iso_day, 7) + 1);

        return week_num;
    }

    /// Returns the quarter number (1-4) for this date
    pub fn getQuarter(self: Date) u3 {
        return @intCast((self.month - 1) / 3 + 1);
    }

    /// Returns the 3-letter month abbreviation
    pub fn getMonthName(self: Date) []const u8 {
        return switch (self.month) {
            1 => "Jan",
            2 => "Feb",
            3 => "Mar",
            4 => "Apr",
            5 => "May",
            6 => "Jun",
            7 => "Jul",
            8 => "Aug",
            9 => "Sep",
            10 => "Oct",
            11 => "Nov",
            12 => "Dec",
            else => unreachable,
        };
    }
};

const Comparison = enum { after, before, equal };

pub const Weekday = enum(u3) {
    sunday = 0,
    monday = 1,
    tuesday = 2,
    wednesday = 3,
    thursday = 4,
    friday = 5,
    saturday = 6,
};

test "fromSlice" {
    const date = try Date.fromSlice("2021-01-01");
    try std.testing.expectEqual(Date{ .year = 2021, .month = 1, .day = 1 }, date);
}

test "fromSlice slash" {
    const date = try Date.fromSlice("2021/01/01");
    try std.testing.expectEqual(Date{ .year = 2021, .month = 1, .day = 1 }, date);
}

test "fromSlice error" {
    try std.testing.expectError(error.InvalidDate, Date.fromSlice("2021-01-"));
    try std.testing.expectError(error.InvalidDate, Date.fromSlice("2021-01-01-01"));
    try std.testing.expectError(error.InvalidDate, Date.fromSlice("2021-01"));
    try std.testing.expectError(error.InvalidCharacter, Date.fromSlice("2021-01-0x"));
    try std.testing.expectError(error.InvalidDate, Date.fromSlice("2021-00-01"));
    try std.testing.expectError(error.Overflow, Date.fromSlice("2021-01-32"));
    try std.testing.expectError(error.InvalidDate, Date.fromSlice("2021-01/01"));
}

test "epochDay" {
    const date = Date{ .year = 2025, .month = 10, .day = 27 };
    try std.testing.expectEqual(Date.fromEpochDay(date.toEpochDay()), date);
}

test "nextWeek" {
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 10, .day = 27 }).nextWeek(),
        Date{ .year = 2025, .month = 11, .day = 2 },
    );
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 10, .day = 26 }).nextWeek(),
        Date{ .year = 2025, .month = 11, .day = 2 },
    );
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 10, .day = 25 }).nextWeek(),
        Date{ .year = 2025, .month = 10, .day = 26 },
    );
}

test "weekday" {
    const date1 = Date{ .year = 2025, .month = 10, .day = 27 };
    try std.testing.expectEqual(.monday, date1.weekday());
    const date2 = Date{ .year = 2014, .month = 1, .day = 1 };
    try std.testing.expectEqual(.wednesday, date2.weekday());
}

test "nextYear" {
    // Regular day should return Dec 31 of current year
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 10, .day = 27 }).nextYear(),
        Date{ .year = 2025, .month = 12, .day = 31 },
    );
    // Already on Dec 31, should return Dec 31 of next year
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 12, .day = 31 }).nextYear(),
        Date{ .year = 2026, .month = 12, .day = 31 },
    );
    // Dec 30 should return Dec 31 of current year
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 12, .day = 30 }).nextYear(),
        Date{ .year = 2025, .month = 12, .day = 31 },
    );
}

test "nextQuarter" {
    // Q1 (Jan-Mar) -> Mar 31
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 1, .day = 15 }).nextQuarter(),
        Date{ .year = 2025, .month = 3, .day = 31 },
    );
    // Q1 already on Mar 31 -> Jun 30
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 3, .day = 31 }).nextQuarter(),
        Date{ .year = 2025, .month = 6, .day = 30 },
    );

    // Q2 (Apr-Jun) -> Jun 30
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 5, .day = 15 }).nextQuarter(),
        Date{ .year = 2025, .month = 6, .day = 30 },
    );
    // Q2 already on Jun 30 -> Sep 30
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 6, .day = 30 }).nextQuarter(),
        Date{ .year = 2025, .month = 9, .day = 30 },
    );

    // Q3 (Jul-Sep) -> Sep 30
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 8, .day = 15 }).nextQuarter(),
        Date{ .year = 2025, .month = 9, .day = 30 },
    );
    // Q3 already on Sep 30 -> Dec 31
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 9, .day = 30 }).nextQuarter(),
        Date{ .year = 2025, .month = 12, .day = 31 },
    );

    // Q4 (Oct-Dec) -> Dec 31
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 11, .day = 15 }).nextQuarter(),
        Date{ .year = 2025, .month = 12, .day = 31 },
    );
    // Q4 already on Dec 31 -> Mar 31 next year
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 12, .day = 31 }).nextQuarter(),
        Date{ .year = 2026, .month = 3, .day = 31 },
    );
}

test "nextMonth" {
    // Regular day in October -> Oct 31
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 10, .day = 27 }).nextMonth(),
        Date{ .year = 2025, .month = 10, .day = 31 },
    );
    // Already on Oct 31 -> Nov 30
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 10, .day = 31 }).nextMonth(),
        Date{ .year = 2025, .month = 11, .day = 30 },
    );
    // Feb 28 (non-leap) -> Feb 28
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 2, .day = 15 }).nextMonth(),
        Date{ .year = 2025, .month = 2, .day = 28 },
    );
    // Feb 28 (non-leap year, already on last day) -> Mar 31
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 2, .day = 28 }).nextMonth(),
        Date{ .year = 2025, .month = 3, .day = 31 },
    );
    // Feb 29 (leap year, already on last day) -> Mar 31
    try std.testing.expectEqual(
        (Date{ .year = 2024, .month = 2, .day = 29 }).nextMonth(),
        Date{ .year = 2024, .month = 3, .day = 31 },
    );
    // Dec 31 -> Jan 31 next year
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 12, .day = 31 }).nextMonth(),
        Date{ .year = 2026, .month = 1, .day = 31 },
    );
}
