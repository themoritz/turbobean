const std = @import("std");

pub const Date = struct {
    year: u32,
    month: u4,
    day: u5,

    /// Compares two dates with another. If `date2` happens after `date1`,
    /// then the `TimeComparison.after` is returned. If `date2` happens before `date1`,
    /// then `TimeComparison.before` is returned. If both represent the same date,
    /// `TimeComparison.equal` is returned;
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

    pub fn format(self: Date, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try std.fmt.format(writer, "{d:0>4}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day });
    }
};

const Comparison = enum { after, before, equal };

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
