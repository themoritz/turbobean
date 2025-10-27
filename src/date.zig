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
        var epoch_day = self.toEpochDay();
        epoch_day.day += @intCast(days);
        return Date.fromEpochDay(epoch_day);
    }

    pub fn nextSunday(self: Date) Date {
        const days_until_sunday = (7 - @intFromEnum(self.weekday())) % 7;
        if (days_until_sunday == 0) {
            return self.addDays(7);
        }
        return self.addDays(days_until_sunday);
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

test "nextSunday" {
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 10, .day = 27 }).nextSunday(),
        Date{ .year = 2025, .month = 11, .day = 2 },
    );
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 10, .day = 26 }).nextSunday(),
        Date{ .year = 2025, .month = 11, .day = 2 },
    );
    try std.testing.expectEqual(
        (Date{ .year = 2025, .month = 10, .day = 25 }).nextSunday(),
        Date{ .year = 2025, .month = 10, .day = 26 },
    );
}

test "weekday" {
    const date1 = Date{ .year = 2025, .month = 10, .day = 27 };
    try std.testing.expectEqual(.monday, date1.weekday());
    const date2 = Date{ .year = 2014, .month = 1, .day = 1 };
    try std.testing.expectEqual(.wednesday, date2.weekday());
}
