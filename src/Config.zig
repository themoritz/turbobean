const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Uri = @import("Uri.zig");

const Self = @This();

root: []const u8,

/// Load the config from a directory. dir has to be an absolute path.
pub fn load_from_dir(alloc: Allocator, io: Io, uri: Uri) !Self {
    const config_path = try std.fs.path.join(alloc, &.{ uri.absolute(), "turbobean.config" });
    const config_file = try std.Io.Dir.cwd().readFileAlloc(io, config_path, alloc, .unlimited);
    return Self{ .root = try parseConfig(alloc, config_file) };
}

fn parseConfig(alloc: Allocator, config_file: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, config_file[0..7], "root = ")) return error.InvalidConfig;
    var i: usize = 7;
    while (i < config_file.len and config_file[i] != '\n') : (i += 1) {}
    return try alloc.dupe(u8, config_file[7..i]);
}

pub fn format(self: Self, writer: *std.Io.Writer) !void {
    try writer.print("Config{{ .root = \"{s}\" }}", .{self.root});
}

test parseConfig {
    const alloc = std.heap.smp_allocator;

    const c1 = try parseConfig(alloc, "root = test.bean");
    try std.testing.expectEqualStrings("test.bean", c1);

    const c2 = try parseConfig(alloc, "root = test.bean\nfoo = bar");
    try std.testing.expectEqualStrings("test.bean", c2);

    const err = parseConfig(alloc, "roo = test.bean");
    try std.testing.expectError(error.InvalidConfig, err);
}
