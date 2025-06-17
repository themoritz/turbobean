//! Crude URI container. Only supports file:// for now.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();

const prefix = "file://";

value: []const u8,

/// Use to get a URI from a relative path that the user typed.
pub fn from_relative_to_cwd(alloc: Allocator, name: []const u8) !Self {
    const real = try std.fs.cwd().realpathAlloc(alloc, name);
    defer alloc.free(real);
    const value = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, real });
    return Self{ .value = value };
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    alloc.free(self.value);
}

pub fn absolute(self: *const Self) []const u8 {
    return self.value[7..];
}

/// Caller owns returned memory.
pub fn relative(self: *const Self, alloc: Allocator) ![]const u8 {
    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);
    return try std.fs.path.relative(alloc, cwd, self.absolute());
}

test relative {
    const alloc = std.testing.allocator;
    var uri = try Self.from_relative_to_cwd(alloc, "test.bean");
    defer uri.deinit(alloc);
    const result = try uri.relative(alloc);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("test.bean", result);
}
