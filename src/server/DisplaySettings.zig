const std = @import("std");
const Self = @This();
const Date = @import("../date.zig").Date;

interval: Interval = .week,
conversion: Conversion = .{ .units = {} },

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

pub fn deinit(self: *Self) void {
    _ = self;
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
