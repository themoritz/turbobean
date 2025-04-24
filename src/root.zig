const lex = @import("lexer.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");

test {
    _ = lex.Lexer;
    _ = ast;
    _ = parser;
}
