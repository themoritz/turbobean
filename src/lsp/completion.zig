const std = @import("std");
const lsp = @import("lsp");

/// For a given source file and line number, returns the slice of the source
/// that represents the text in the requested line number (excluding newlines).
pub fn getLine(source: [:0]const u8, line: u32) ?[]const u8 {
    var current_line: u32 = 0;
    var line_start: usize = 0;

    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        if (i == source.len or source[i] == '\n') {
            if (current_line == line) {
                return source[line_start..i];
            }
            current_line += 1;
            line_start = i + 1;
        }
    }
    return null;
}

test getLine {
    try std.testing.expectEqualStrings("Hello", getLine("Hello\nYo\nWorld", 0).?);
    try std.testing.expectEqualStrings("Yo", getLine("Hello\nYo\nWorld", 1).?);
    try std.testing.expectEqualStrings("World", getLine("Hello\nYo\nWorld", 2).?);
    try std.testing.expectEqual(null, getLine("Hello\nYo\nWorld", 3));
}

/// TODO: Make it count utf-16 code points.
pub fn getTextBefore(line: []const u8, col: u32) []const u8 {
    return line[0..col];
}

pub fn getWordAround(line: []const u8, col: u32) ?struct { u32, u32 } {
    var iter = std.mem.splitAny(u8, line, " \t");
    while (iter.next()) |word| {
        const start = word.ptr - line.ptr;
        const end = start + word.len;
        if (start <= col and col <= end) {
            return .{ @intCast(start), @intCast(end) };
        }
    }
    return null;
}

test getWordAround {
    try std.testing.expectEqual(.{ 0, 5 }, getWordAround("Hello world", 1).?);
    try std.testing.expectEqual(.{ 6, 11 }, getWordAround("Hello\tworld", 7).?);
}

pub fn countOccurrences(line: []const u8, needle: []const u8) u32 {
    var iter = std.mem.splitSequence(u8, line, needle);
    var count: u32 = 0;
    while (iter.next()) |_| count += 1;
    return count - 1;
}

test countOccurrences {
    try std.testing.expectEqual(@as(u32, 2), countOccurrences("Hello world", "o"));
    try std.testing.expectEqual(@as(u32, 0), countOccurrences("Hello world", "x"));
    try std.testing.expectEqual(@as(u32, 1), countOccurrences("Hello world", "ll"));
    try std.testing.expectEqual(@as(u32, 1), countOccurrences("Hello world", "H"));
    try std.testing.expectEqual(@as(u32, 1), countOccurrences("Hello world", "d"));
}
