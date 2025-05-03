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

    pub fn fromSlice(bytes: []const u8) std.fmt.ParseIntError!Date {
        const year = try std.fmt.parseInt(u32, bytes[0..4], 10);
        const month = try std.fmt.parseInt(u4, bytes[5..7], 10);
        const day = try std.fmt.parseInt(u5, bytes[8..10], 10);
        return Date{
            .year = year,
            .month = month,
            .day = day,
        };
    }
    pub fn format(self: Date, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try std.fmt.format(writer, "{d:0>4}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day });
    }
};

const Comparison = enum { after, before, equal };
