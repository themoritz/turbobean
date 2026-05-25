const std = @import("std");
const Self = @This();
const log = std.log.scoped(.watcher);

pub fn init(comptime T: type, ctx: *T, alloc: std.mem.Allocator, io: std.Io) !Self {
    _ = ctx;
    _ = alloc;
    _ = io;
    log.warn("File watcher not supported on this platform.", .{});
    return .{};
}

pub fn start(self: *Self) !void {
    _ = self;
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn addFile(self: *Self, path: []const u8) !void {
    _ = self;
    _ = path;
}
