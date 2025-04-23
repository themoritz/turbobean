const std = @import("std");
const testing = std.testing;
const lex = @import("lexer.zig");

pub export fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub export fn foo() void {
    var lexer = lex.Lexer.init(&.{});
    const token = lexer.next();
    std.debug.print("{}", .{token});
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}
