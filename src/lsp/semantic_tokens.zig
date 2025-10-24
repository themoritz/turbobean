const std = @import("std");
const lsp = @import("lsp");
const Lexer = @import("../lexer.zig").Lexer;
const Token = Lexer.Token;

pub const TokenType = enum(u32) {
    namespace,
    type,
    // class,
    // @"enum",
    // interface,
    // @"struct",
    // typeParameter,
    parameter,
    variable,
    property,
    enumMember,
    // event,
    function,
    // method,
    // macro,
    keyword,
    modifier,
    comment,
    string,
    escapeSequence,
    number,
    // regexp,
    operator,
    // decorator,
};

fn tagToTokenType(token: Token.Tag) ?TokenType {
    return switch (token) {
        .date => .parameter,
        .number => .number,
        .string => .string,
        .account => .variable,
        .currency => .type,
        .flag => .modifier,
        .key => .enumMember,
        .link => .property,
        .tag => .namespace,

        .eol,
        .indent,
        => null,
        .comment => .comment,

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
        => .operator,
        .hash,
        .asterisk,
        => .modifier,
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
        => .function,

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

pub fn tokensToData(alloc: std.mem.Allocator, tokens: []Token) !std.ArrayList(u32) {
    var result = std.ArrayList(u32){};
    errdefer result.deinit(alloc);

    var last_line: u32 = 0;
    var last_char: u32 = 0;

    for (tokens) |token| {
        if (token.tag == .account) {
            var iter = std.mem.splitScalar(u8, token.slice, ':');
            var i: u32 = 0;
            var char = token.start_col;
            while (iter.next()) |piece| : (i += 1) {
                if (i > 0) {
                    const tok = Token{
                        .slice = ":",
                        .tag = .account,
                        .line = token.line,
                        .start_col = char,
                        .end_col = char + 1,
                    };
                    char += 1;
                    try addToken(alloc, tok, .operator, &last_line, &last_char, &result);
                }

                const width: u16 = @intCast(try std.unicode.calcUtf16LeLen(piece));
                const tok = Token{
                    .slice = piece,
                    .tag = .account,
                    .line = token.line,
                    .start_col = char,
                    .end_col = char + width,
                };
                char += width;
                try addToken(alloc, tok, if (i == 0) .escapeSequence else null, &last_line, &last_char, &result);
            }
        } else {
            try addToken(alloc, token, null, &last_line, &last_char, &result);
        }
    }
    return result;
}

fn addToken(
    alloc: std.mem.Allocator,
    token: Token,
    overwrite_type: ?TokenType,
    last_line: *u32,
    last_char: *u32,
    result: *std.ArrayList(u32),
) !void {
    var buf: [5]u32 = undefined;
    if (tagToTokenType(token.tag)) |tag| {
        buf[0] = token.line - last_line.*;
        last_line.* = token.line;
        if (buf[0] > 0) last_char.* = 0;
        buf[1] = token.start_col - last_char.*;
        last_char.* = token.start_col;
        buf[2] = token.end_col - token.start_col;
        buf[3] = @intFromEnum(overwrite_type orelse tag);
        buf[4] = 0;
        try result.appendSlice(alloc, &buf);
    }
}

test tokensToData {
    try testGoTokens(
        \\2022-01-01 open
        \\  include
    , &.{ 0, 0, 10, 2, 0, 0, 11, 4, 6, 0, 1, 2, 7, 7, 0 });
}

fn testGoTokens(source: [:0]const u8, expected: []const u32) !void {
    const alloc = std.testing.allocator;
    var lexer = Lexer.init(source);

    var tokens = std.ArrayList(Token){};
    defer tokens.deinit(alloc);

    while (true) {
        const token = lexer.next();
        try tokens.append(alloc, token);
        if (token.tag == .eof) break;
    }

    var actual = try tokensToData(alloc, tokens.items);
    defer actual.deinit(alloc);

    try std.testing.expectEqualSlices(u32, expected, actual.items);
}
