const std = @import("std");
const Allocator = std.mem.Allocator;
const Self = @This();

allocating: std.Io.Writer.Allocating,

pub const String = struct {
    parent: *Self,
    start: usize,
    end: usize,

    pub fn jsonStringify(self: *const String, jw: anytype) !void {
        try jw.write(self.slice());
    }

    pub fn slice(self: *const String) []const u8 {
        return self.parent.allocating.writer.buffer[self.start..self.end];
    }
};

pub fn init(alloc: Allocator) Self {
    return .{
        .allocating = std.Io.Writer.Allocating.init(alloc),
    };
}

pub fn deinit(self: *Self) void {
    self.allocating.deinit();
}

pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !String {
    const start = self.allocating.writer.end;
    try self.allocating.writer.print(fmt, args);
    const end = self.allocating.writer.end;
    return String{ .parent = self, .start = start, .end = end };
}

pub fn clearRetainingCapacity(self: *Self) void {
    self.allocating.clearRetainingCapacity();
}

test "StringStore" {
    const alloc = std.testing.allocator;
    var store = Self.init(alloc);
    defer store.deinit();

    const s = try store.print("Hello {s}", .{"world"});
    try std.testing.expectEqualStrings("Hello world", s.slice());

    store.clearRetainingCapacity();

    const Struct = struct {
        field: String,
    };

    const s2 = Struct{
        .field = try store.print("{d}", .{3}),
    };

    var json = std.Io.Writer.Allocating.init(alloc);
    defer json.deinit();
    var stringify = std.json.Stringify{ .writer = &json.writer };

    try stringify.write(s2);

    try std.testing.expectEqualStrings("{\"field\":\"3\"}", json.written());
}
