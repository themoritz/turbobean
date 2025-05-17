const std = @import("std");
const Allocator = std.mem.Allocator;
const Lexer = @import("lexer.zig").Lexer;
const Self = @This();

tag: Tag,
token: Lexer.Token,
expected: ?Lexer.Token.Tag,

pub const Tag = enum {
    expected_declaration,
    expected_token,
    expected_entry,
    expected_key_value,
    expected_value,
    expected_amount,
};

pub fn print(e: Self, alloc: Allocator, source: [:0]const u8) !void {
    const rendered = try dump(e, alloc, source);
    defer alloc.free(rendered);
    std.debug.print("{s}\n", .{rendered});
}

pub fn dump(e: Self, alloc: Allocator, source: [:0]const u8) ![]const u8 {
    var buffer = std.ArrayList(u8).init(alloc);
    defer buffer.deinit();

    // Calculate line and col from token.loc
    const loc = e.token.loc;
    var line_start: u32 = 0;
    var col_start: u32 = 0;
    const start = @intFromPtr(loc.ptr) - @intFromPtr(source.ptr);
    const end = start + loc.len;
    var line_pos: usize = 0;
    for (0..start) |i| {
        if (source[i] == '\n') {
            line_start += 1;
            col_start = 0;
            line_pos = i + 1;
        } else {
            col_start += 1;
        }
    }
    var line_end = line_start;
    var col_end = col_start;
    for (start..end) |i| {
        if (source[i] == '\n') {
            line_end += 1;
            col_end = 0;
        } else {
            col_end += 1;
        }
    }

    var line_pos_end = source.len;
    for (end..source.len) |i| {
        if (source[i] == '\n') {
            line_pos_end = i;
            break;
        }
    }

    try std.fmt.format(buffer.writer(), "{d:>5} | {s}\n", .{ line_start + 1, source[line_pos..line_pos_end] });
    for (0..col_start + 8) |_| try buffer.append(' ');
    for (col_start..col_end) |_| try buffer.append('^');
    try buffer.append('\n');

    for (0..col_start + 8) |_| try buffer.append(' ');
    switch (e.tag) {
        .expected_token => {
            try std.fmt.format(buffer.writer(), "Expected {s}, found {s}\n", .{ @tagName(e.expected.?), @tagName(e.token.tag) });
        },
        else => {
            try std.fmt.format(buffer.writer(), "Expected {s}\n", .{@tagName(e.tag)});
        },
    }

    return buffer.toOwnedSlice();
}

test "render" {
    try testLoc(0, 1,
        \\Hello Foo
    ,
        \\    1 | Hello Foo
        \\        ^
        \\        Expected string, found number
        \\
    );

    try testLoc(6, 3,
        \\Hello Foo
    ,
        \\    1 | Hello Foo
        \\              ^^^
        \\              Expected string, found number
        \\
    );
}

fn testLoc(start: u32, len: u32, source: [:0]const u8, expected: []const u8) !void {
    const e = Self{ .tag = .expected_token, .token = Lexer.Token{ .tag = .number, .loc = source[start .. start + len] }, .expected = .string };
    const alloc = std.testing.allocator;
    const rendered = try e.dump(alloc, source);
    defer alloc.free(rendered);

    try std.testing.expectEqualSlices(u8, expected, rendered);
}
