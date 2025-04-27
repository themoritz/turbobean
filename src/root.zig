const lex = @import("lexer.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const render = @import("render.zig");

test {
    _ = lex.Lexer;
    _ = ast;
    _ = parser;
    _ = render;
}
