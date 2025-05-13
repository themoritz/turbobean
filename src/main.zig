const std = @import("std");

const lex = @import("lexer.zig");
const render = @import("render.zig");
const number = @import("number.zig");
const data = @import("data.zig");
const parser = @import("parser.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);
    if (args.len < 2) return error.MissingArgument;
    const filename = args[1];
    const file = try std.fs.cwd().openFile(filename, .{});
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
        if (token.tag == .invalid) std.debug.print("invalid {s}\n", .{source[token.loc.start - 1 .. token.loc.end + 1]});
        token_count += 1;
        if (token.tag == .eof) break;
    }

    std.debug.print("{d}\n", .{token_count});
}

test {
    _ = lex.Lexer;
    _ = render;
    _ = number;
    _ = data;
    _ = parser;
}
