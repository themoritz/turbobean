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
        .keyword_pnl,
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
        switch (token.tag) {
            .account => {
                // Highlight individual account pieces.
                var iter = std.mem.splitScalar(u8, token.slice, ':');
                var i: u32 = 0;
                var char = token.start_col;
                while (iter.next()) |piece| : (i += 1) {
                    if (i > 0) {
                        const tok = Token{
                            .slice = undefined,
                            .tag = .account,
                            .start_line = token.start_line,
                            .end_line = token.end_line,
                            .start_col = char,
                            .end_col = char + 1,
                        };
                        char += 1;
                        try addToken(alloc, tok, .operator, &last_line, &last_char, &result);
                    }

                    const width: u16 = @intCast(try std.unicode.calcUtf16LeLen(piece));
                    const tok = Token{
                        .slice = undefined,
                        .tag = .account,
                        .start_line = token.start_line,
                        .end_line = token.end_line,
                        .start_col = char,
                        .end_col = char + width,
                    };
                    char += width;
                    try addToken(alloc, tok, if (i == 0) .escapeSequence else null, &last_line, &last_char, &result);
                }
            },
            .string => {
                // Deal with multi-line strings which are not supported by all editors.
                var iter = std.mem.splitScalar(u8, token.slice, '\n');
                var i = token.start_line;
                while (iter.next()) |line| : (i += 1) {
                    const width: u16 = @intCast(try std.unicode.calcUtf16LeLen(line));
                    const start_col: u16 = if (i == token.start_line) token.start_col else 0;
                    const end_col: u16 = if (i == token.end_line) token.end_col else start_col + width;
                    const tok = Token{
                        .slice = undefined,
                        .tag = .string,
                        .start_line = i,
                        .end_line = i,
                        .start_col = start_col,
                        .end_col = end_col,
                    };
                    try addToken(alloc, tok, null, &last_line, &last_char, &result);
                }
            },
            else => {
                try addToken(alloc, token, null, &last_line, &last_char, &result);
            },
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
        // Offset to last token line
        buf[0] = token.start_line - last_line.*;
        last_line.* = token.start_line;
        if (buf[0] > 0) last_char.* = 0;
        // Offset to last token start
        buf[1] = token.start_col - last_char.*;
        last_char.* = token.start_col;
        // Token length
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

test "multiline string" {
    try testGoTokens(
        \\"Multi
        \\Line
        \\String"
    , &.{ 0, 0, 6, 10, 0, 1, 0, 4, 10, 0, 1, 0, 7, 10, 0 });

    try testGoTokens(
        \\"String
        \\"
    , &.{ 0, 0, 7, 10, 0, 1, 0, 1, 10, 0 });
}

test "unicode string" {
    try testGoTokens(
        \\"Ope𝄞ning"
    , &.{ 0, 0, 11, 10, 0 });
}

test "unicode account" {
    try testGoTokens(
        "Equity:Ope𝄞ning 200",
        &.{ 0, 0, 6, 11, 0, 0, 6, 1, 13, 0, 0, 1, 9, 3, 0, 0, 10, 3, 12, 0 },
    );
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
