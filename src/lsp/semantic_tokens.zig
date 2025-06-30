const std = @import("std");
const lsp = @import("lsp");
const Lexer = @import("../lexer.zig").Lexer;
const Token = Lexer.Token;

pub const TokenType = enum(u32) {
    namespace,
    type,
    class,
    @"enum",
    interface,
    @"struct",
    typeParameter,
    parameter,
    variable,
    property,
    enumMember,
    event,
    function,
    method,
    macro,
    keyword,
    modifier,
    comment,
    string,
    escapeSequence,
    number,
    regexp,
    operator,
    decorator,
};

fn goTag(token: Token.Tag) ?TokenType {
    return switch (token) {
        .date => .number,
        .number => .number,
        .string => .string,
        .account => .variable,
        .currency => .number,
        .flag => .modifier,
        .key => .enumMember,
        .link => .comment,
        .tag => .comment,

        .eol,
        .indent,
        => null,

        .pipe,
        .atat,
        .at,
        .lcurllcurl,
        .rcurlrcurl,
        .lcurl,
        .rcurl,
        .comma,
        .tilde,
        .plus,
        .minus,
        .slash,
        .lparen,
        .rparen,
        .hash,
        .asterisk,
        .colon,
        => .operator,

        .keyword_txn,
        .keyword_balance,
        .keyword_open,
        .keyword_close,
        .keyword_commodity,
        .keyword_pad,
        .keyword_event,
        .keyword_query,
        .keyword_custom,
        .keyword_price,
        .keyword_note,
        .keyword_document,
        .keyword_pushtag,
        .keyword_poptag,
        .keyword_pushmeta,
        .keyword_popmeta,
        .keyword_option,
        .keyword_plugin,
        .keyword_include,
        => .keyword,

        .true,
        .false,
        .none,
        => .number,

        .invalid,
        .eof,
        => null,
    };
}

fn goToken(alloc: std.mem.Allocator, tokens: []Token) !std.ArrayList(u32) {
    var result = std.ArrayList(u32).init(alloc);
    errdefer result.deinit();

    var last_line: u32 = 0;
    var last_char: u32 = 0;

    var buf: [5]u32 = undefined;

    for (tokens) |token| {
        if (goTag(token.tag)) |tag| {
            buf[0] = token.line - last_line;
            last_line = token.line;
            if (buf[0] > 0) last_char = 0;
            buf[1] = token.start_col - last_char;
            last_char = token.start_col;
            buf[2] = token.end_col - token.start_col;
            buf[3] = @intFromEnum(tag);
            buf[4] = 0;
            try result.appendSlice(&buf);
        }
    }
    return result;
}

test goToken {
    try testGoTokens(
        \\2022-01-01 open
        \\  Assets:Foo
    , &.{ 0, 0, 10, 20, 0, 0, 11, 4, 15, 0, 1, 2, 10, 8, 0 });
}

fn testGoTokens(source: [:0]const u8, expected: []const u32) !void {
    const alloc = std.testing.allocator;
    var lexer = Lexer.init(source);

    var tokens = std.ArrayList(Token).init(alloc);
    defer tokens.deinit();

    while (true) {
        const token = lexer.next();
        try tokens.append(token);
        if (token.tag == .eof) break;
    }

    var actual = try goToken(alloc, tokens.items);
    defer actual.deinit();

    try std.testing.expectEqualSlices(u32, expected, actual.items);
}
