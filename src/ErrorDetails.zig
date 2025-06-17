const std = @import("std");
const Allocator = std.mem.Allocator;
const Lexer = @import("lexer.zig").Lexer;
const Uri = @import("Uri.zig");
const Self = @This();

tag: Tag,
token: Lexer.Token,
uri: Uri,
source: [:0]const u8,
expected: ?Lexer.Token.Tag,

pub const Tag = enum {
    expected_declaration,
    invalid_number,
    invalid_date,
    expected_token,
    expected_entry,
    expected_key_value,
    expected_value,
    expected_amount,
    tag_already_pushed,
    meta_already_pushed,
    tag_not_pushed,
    meta_not_pushed,

    tx_does_not_balance,
    tx_no_solution,
    tx_too_many_variables,
    tx_division_by_zero,
    tx_multiple_solutions,
};

pub fn message(e: Self, alloc: Allocator) ![]const u8 {
    var buffer = std.ArrayList(u8).init(alloc);
    switch (e.tag) {
        .expected_token => {
            try std.fmt.format(buffer.writer(), "Expected {s}, found {s}\n", .{ @tagName(e.expected.?), @tagName(e.token.tag) });
        },
        else => {
            try std.fmt.format(buffer.writer(), "{s}\n", .{@tagName(e.tag)});
        },
    }
    return buffer.toOwnedSlice();
}

pub fn print(e: Self, alloc: Allocator) !void {
    const rendered = try dump(e, alloc);
    defer alloc.free(rendered);
    std.debug.print("{s}\n", .{rendered});
}

pub fn dump(e: Self, alloc: Allocator) ![]const u8 {
    var buffer = std.ArrayList(u8).init(alloc);
    defer buffer.deinit();

    // Calculate line and col from token.loc
    const loc = e.token.slice;
    var line_start: u32 = 0;
    var col_start: u32 = 0;
    const start = @intFromPtr(loc.ptr) - @intFromPtr(e.source.ptr);
    const end = start + loc.len;
    var line_pos: usize = 0;
    for (0..start) |i| {
        if (e.source[i] == '\n') {
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
        if (e.source[i] == '\n') {
            line_end += 1;
            col_end = 0;
        } else {
            col_end += 1;
        }
    }

    std.debug.assert(line_start == line_end);
    std.debug.assert(col_start <= col_end);

    var line_pos_end = e.source.len;
    for (end..e.source.len) |i| {
        if (e.source[i] == '\n') {
            line_pos_end = i;
            break;
        }
    }

    const relative = try e.uri.relative(alloc);
    defer alloc.free(relative);
    try std.fmt.format(buffer.writer(), "{s}:\n", .{relative});

    try std.fmt.format(buffer.writer(), "{d:>5} | {s}\n", .{ line_start + 1, e.source[line_pos..line_pos_end] });
    for (0..col_start + 8) |_| try buffer.append(' ');
    if (col_start == col_end) {
        try buffer.append('\\');
    } else {
        for (col_start..col_end) |_| try buffer.append('^');
    }

    try buffer.append('\n');

    for (0..col_start + 8) |_| try buffer.append(' ');
    const msg = try e.message(alloc);
    defer alloc.free(msg);
    try buffer.appendSlice(msg);

    return buffer.toOwnedSlice();
}

test "render" {
    try testLoc(2, 0,
        \\Hello Foo
    ,
        \\test.bean:
        \\    1 | Hello Foo
        \\          \
        \\          Expected string, found number
        \\
    );

    try testLoc(0, 1,
        \\Hello Foo
    ,
        \\test.bean:
        \\    1 | Hello Foo
        \\        ^
        \\        Expected string, found number
        \\
    );

    try testLoc(6, 3,
        \\Hello Foo
    ,
        \\test.bean:
        \\    1 | Hello Foo
        \\              ^^^
        \\              Expected string, found number
        \\
    );
}

fn testLoc(start: u32, len: u32, source: [:0]const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    var uri = try Uri.from_relative_to_cwd(alloc, "test.bean");
    defer uri.deinit(alloc);
    const e = Self{
        .tag = .expected_token,
        .token = Lexer.Token{ .tag = .number, .slice = source[start .. start + len], .line = 0, .start_col = @intCast(start), .end_col = @intCast(start + len) },
        .uri = uri,
        .source = source,
        .expected = .string,
    };
    const rendered = try e.dump(alloc);
    defer alloc.free(rendered);

    try std.testing.expectEqualSlices(u8, expected, rendered);
}
