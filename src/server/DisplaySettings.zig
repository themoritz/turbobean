const std = @import("std");
const Self = @This();
const Date = @import("../date.zig").Date;
const StringStore = @import("../StringStore.zig");

interval: Interval = .week,
conversion: Conversion = .{ .units = {} },

start_date: ?[]const u8 = null,
end_date: ?[]const u8 = null,

pub const Interval = enum {
    day,
    week,
    month,
    quarter,
    year,

    pub fn advanceDate(self: Interval, date: Date) Date {
        switch (self) {
            .day => return date.nextDay(),
            .week => return date.nextWeek(),
            .month => return date.nextMonth(),
            .quarter => return date.nextQuarter(),
            .year => return date.nextYear(),
        }
    }

    pub fn formatPeriod(self: Interval, date: Date, string_store: *StringStore) !StringStore.String {
        switch (self) {
            .day => return try string_store.print("{f}", .{date}),
            .week => {
                const week = date.getISOWeek();
                return try string_store.print("W{d} {d}", .{ week, date.year });
            },
            .month => return try string_store.print("{s} {d}", .{ date.getMonthName(), date.year }),
            .quarter => {
                const quarter = date.getQuarter();
                return try string_store.print("Q{d} {d}", .{ quarter, date.year });
            },
            .year => return try string_store.print("{d}", .{date.year}),
        }
    }
};

pub const Conversion = union(enum) {
    units,
    currency: []const u8,

    pub fn from_url_param(param: []const u8) !Conversion {
        if (std.mem.eql(u8, param, "units")) {
            return .{ .units = {} };
        } else {
            return .{ .currency = param };
        }
    }
};

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    if (self.start_date) |start| alloc.free(start);
    if (self.end_date) |end| alloc.free(end);
}

pub fn isWithinDateRange(self: Self, date: Date) bool {
    if (self.start_date) |start| {
        const start_parsed = Date.fromSlice(start) catch return false;
        if (date.compare(start_parsed) == .after) {
            return false;
        }
    }

    if (self.end_date) |end| {
        const end_parsed = Date.fromSlice(end) catch return false;
        if (date.compare(end_parsed) == .before) {
            return false;
        }
    }

    return true;
}

pub fn isAfterStart(self: Self, date: Date) bool {
    if (self.start_date) |start| {
        const start_parsed = Date.fromSlice(start) catch return false;
        if (date.compare(start_parsed) == .after) {
            return false;
        }
    }
    return true;
}

pub fn isAfterEnd(self: Self, date: Date) bool {
    if (self.end_date) |end| {
        const end_parsed = Date.fromSlice(end) catch return false;
        if (date.compare(end_parsed) == .before) {
            return true;
        }
    }
    return false;
}

pub fn hasStartDate(self: Self) bool {
    return self.start_date != null;
}

pub fn hasEndDate(self: Self) bool {
    return self.end_date != null;
}

test "parse" {
    const http = @import("http.zig");
    const alloc = std.testing.allocator;

    const input = "/?interval=month&conversion=USD";

    var request = try http.ParsedRequest.parse(alloc, input);
    defer request.deinit(alloc);
    const actual = try http.Query(Self).parse(alloc, &request.params);

    try std.testing.expectEqual(.month, actual.interval);
    try std.testing.expectEqualStrings("USD", actual.conversion.currency);
}

test "parse default" {
    const http = @import("http.zig");
    const alloc = std.testing.allocator;

    const input = "/?foo=bar";

    var request = try http.ParsedRequest.parse(alloc, input);
    defer request.deinit(alloc);
    const actual = try http.Query(Self).parse(alloc, &request.params);

    try std.testing.expectEqual(.week, actual.interval);
    try std.testing.expectEqual({}, actual.conversion.units);
}

fn testFormatPeriod(year: u32, month: u4, day: u5, interval: Interval, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    var string_store = StringStore.init(alloc);
    defer string_store.deinit();

    const date = Date{ .year = year, .month = month, .day = day };
    const result = try interval.formatPeriod(date, &string_store);
    try std.testing.expectEqualStrings(expected, result.slice());
}

test "formatPeriod - day" {
    try testFormatPeriod(2025, 1, 15, .day, "2025-01-15");
}

test "formatPeriod - week" {
    try testFormatPeriod(2025, 1, 5, .week, "W1 2025");
    try testFormatPeriod(2024, 12, 29, .week, "W52 2024");
}

test "formatPeriod - month" {
    try testFormatPeriod(2025, 1, 15, .month, "Jan 2025");
    try testFormatPeriod(2025, 2, 28, .month, "Feb 2025");
    try testFormatPeriod(2024, 12, 31, .month, "Dec 2024");
}

test "formatPeriod - quarter" {
    try testFormatPeriod(2025, 1, 15, .quarter, "Q1 2025");
    try testFormatPeriod(2025, 6, 30, .quarter, "Q2 2025");
    try testFormatPeriod(2025, 9, 15, .quarter, "Q3 2025");
    try testFormatPeriod(2024, 12, 31, .quarter, "Q4 2024");
}

test "formatPeriod - year" {
    try testFormatPeriod(2025, 6, 15, .year, "2025");
    try testFormatPeriod(2024, 12, 31, .year, "2024");
}
