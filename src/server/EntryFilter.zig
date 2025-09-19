const std = @import("std");
const Self = @This();
const Date = @import("../date.zig").Date;

startDate: ?[]const u8 = null,
endDate: ?[]const u8 = null,

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    if (self.startDate) |start| alloc.free(start);
    if (self.endDate) |end| alloc.free(end);
}

pub fn isWithinDateRange(self: Self, date: Date) bool {
    if (self.startDate) |start| {
        const start_parsed = Date.fromSlice(start) catch return false;
        if (date.compare(start_parsed) == .after) {
            return false;
        }
    }

    if (self.endDate) |end| {
        const end_parsed = Date.fromSlice(end) catch return false;
        if (date.compare(end_parsed) == .before) {
            return false;
        }
    }

    return true;
}
