const std = @import("std");
const Self = @This();
const Date = @import("../date.zig").Date;

interval: Interval = .week,
conversion: Conversion = .{ .units = {} },

start_date: ?[]const u8 = null,
end_date: ?[]const u8 = null,

const Interval = enum {
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
