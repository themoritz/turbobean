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
        var date: Date = undefined;
        var chunks = std.mem.splitAny(u8, bytes, "-/");
        var i: usize = 0;
        while (chunks.next()) |chunk| : (i += 1) {
            if (i == 0) {
                date.year = try std.fmt.parseInt(u32, chunk, 10);
            } else if (i == 1) {
                date.month = try std.fmt.parseInt(u4, chunk, 10);
            } else if (i == 2) {
                date.day = try std.fmt.parseInt(u5, chunk, 10);
            }
        }
        if (i != 3) {
            return error.InvalidDateFormat;
        }
        if (chunks.next()) |_| {
            return error.InvalidDateFormat;
        }
        if (date.month < 1 or date.month > 12) {
            return error.InvalidDateFormat;
        }
        if (date.day < 1 or date.day > 31) {
            return error.InvalidDateFormat;
        }
        return date;
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
    try std.testing.expectError(error.InvalidCharacter, Date.fromSlice("2021-01-"));
    try std.testing.expectError(error.InvalidDateFormat, Date.fromSlice("2021-01-01-01"));
    try std.testing.expectError(error.InvalidDateFormat, Date.fromSlice("2021-01"));
    try std.testing.expectError(error.InvalidCharacter, Date.fromSlice("2021-01-0x"));
    try std.testing.expectError(error.InvalidDateFormat, Date.fromSlice("2021-0-1"));
    try std.testing.expectError(error.Overflow, Date.fromSlice("2021-1-32"));
}
