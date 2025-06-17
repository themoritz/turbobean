const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();

root: []const u8,

/// Load the config from a directory. dir has to be an absolute path.
pub fn load_from_dir(alloc: Allocator, dir: []const u8) !Self {
    const config_path = try std.fs.path.join(alloc, &.{ dir, "zigcount.config" });
    defer alloc.free(config_path);

    const file = try std.fs.openFileAbsolute(config_path, .{});
    defer file.close();

    const config_file = try file.readToEndAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(config_file);

    return Self{ .root = try parseConfig(alloc, config_file) };
}

fn parseConfig(alloc: Allocator, config_file: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, config_file[0..7], "root = ")) return error.InvalidConfig;
    var i: usize = 7;
    while (i < config_file.len and config_file[i] != '\n') : (i += 1) {}
    return try alloc.dupe(u8, config_file[7..i]);
}

pub fn deinit(self: Self, alloc: Allocator) void {
    alloc.free(self.root);
}

pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    _ = fmt;
    _ = options;
    try std.fmt.format(writer, "Config{{ .root = \"{s}\" }}", .{self.root});
}

test parseConfig {
    const alloc = std.testing.allocator;

    const c1 = try parseConfig(alloc, "root = test.bean");
    defer alloc.free(c1);
    try std.testing.expectEqualStrings("test.bean", c1);

    const c2 = try parseConfig(alloc, "root = test.bean\nfoo = bar");
    defer alloc.free(c2);
    try std.testing.expectEqualStrings("test.bean", c2);

    const err = parseConfig(alloc, "roo = test.bean");
    try std.testing.expectError(error.InvalidConfig, err);
}
