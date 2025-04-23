const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;

pub const Parser = struct {
    const Self = @This();
    lexer: *Lexer,
};
