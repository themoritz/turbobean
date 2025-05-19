const std = @import("std");

const lex = @import("lexer.zig");
const render = @import("render.zig");
const number = @import("number.zig");
const Data = @import("data.zig");
const parser = @import("parser.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);
    if (args.len < 2) return error.MissingArgument;
    const filename = args[1];

    var data = Data.init(allocator);
    defer data.deinit(allocator);

    try data.load_file(filename);

    std.debug.print("{d}\n", .{data.entries.items.len});
    // try render.print(allocator, &data);
}

test {
    _ = lex.Lexer;
    _ = render;
    _ = number;
    _ = Data;
    _ = parser;
}
