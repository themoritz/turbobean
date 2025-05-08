const std = @import("std");

const lex = @import("lexer.zig");
const render = @import("render.zig");
const decimal = @import("decimal.zig");
const data = @import("data.zig");
const parser = @import("parser.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const file = try std.fs.cwd().openFile("example.bean", .{});
    defer file.close();

    // Read entire file into a dynamically allocated buffer
    const source = try file.readToEndAlloc(allocator, 1024 * 1024); // Max size: 1MB
    defer allocator.free(source); // Free the allocated memory

    std.debug.print("File content: {s}\n", .{source});
}

test {
    _ = lex.Lexer;
    _ = render;
    _ = decimal;
    _ = data;
    _ = parser;
}
