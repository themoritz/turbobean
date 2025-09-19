const std = @import("std");
const Self = @This();
const Date = @import("../date.zig").Date;

start_date: ?[]const u8 = null,
end_date: ?[]const u8 = null,

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
