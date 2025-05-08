const std = @import("std");

const lex = @import("lexer.zig");
const render = @import("render.zig");
const decimal = @import("decimal.zig");
const data = @import("data.zig");
const parser = @import("parser.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const file = try std.fs.cwd().openFile("test.bean", .{});
    defer file.close();

    const filesize = try file.getEndPos();
    const source = try allocator.alloc(u8, filesize + 1);
    defer allocator.free(source);

    _ = try file.readAll(source[0..filesize]);

    source[filesize] = 0;
    const null_terminated: [:0]u8 = source[0..filesize :0];

    var token_count: u32 = 0;
    var lexer = lex.Lexer.init(null_terminated);
    while (true) {
        const token = lexer.next();
        token_count += 1;
        if (token.tag == .eof) break;
    }

    std.debug.print("{d}\n", .{token_count});
}

test {
    _ = lex.Lexer;
    _ = render;
    _ = decimal;
    _ = data;
    _ = parser;
}
