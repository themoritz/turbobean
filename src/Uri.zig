//! Crude URI container. Only supports file:// for now.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();

const prefix = "file://";

value: []const u8,

pub fn from_raw(alloc: Allocator, value: []const u8) !Self {
    return Self{ .value = try alloc.dupe(u8, value) };
}

/// Use to get a URI from a relative path that the user typed.
pub fn from_relative_to_cwd(alloc: Allocator, name: []const u8) !Self {
    const real = try std.fs.cwd().realpathAlloc(alloc, name);
    defer alloc.free(real);
    const value = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, real });
    return Self{ .value = value };
}

pub fn from_absolute(alloc: Allocator, path: []const u8) !Self {
    const value = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, path });
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

pub fn load_nullterminated(self: *const Self, alloc: Allocator) ![:0]const u8 {
    const file = try std.fs.openFileAbsolute(self.absolute(), .{});
    defer file.close();

    const filesize = try file.getEndPos();
    const source = try alloc.alloc(u8, filesize + 1);
    errdefer alloc.free(source);

    _ = try file.readAll(source[0..filesize]);
    source[filesize] = 0;

    const null_terminated: [:0]u8 = source[0..filesize :0];

    return null_terminated;
}

pub fn clone(self: *const Self, alloc: Allocator) !Self {
    const value = try alloc.dupe(u8, self.value);
    return Self{ .value = value };
}

pub fn move_relative(self: *const Self, alloc: Allocator, path: []const u8) !Self {
    const dir = std.fs.path.dirname(self.absolute()) orelse ".";
    const joined = try std.fs.path.join(alloc, &.{ dir, path });
    defer alloc.free(joined);
    return Self{ .value = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, joined }) };
}

test relative {
    const alloc = std.testing.allocator;
    var uri = try Self.from_relative_to_cwd(alloc, "dummy.bean");
    defer uri.deinit(alloc);
    const result = try uri.relative(alloc);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("dummy.bean", result);
}
