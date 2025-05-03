const lex = @import("lexer.zig");
const render = @import("render.zig");
const decimal = @import("decimal.zig");
const data = @import("data.zig");
const parser = @import("parser.zig");

test {
    _ = lex.Lexer;
    _ = render;
    _ = decimal;
    _ = data;
    _ = parser;
}
