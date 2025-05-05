const std = @import("std");
const unicode = std.unicode;

pub const Lexer = struct {
    buffer: [:0]const u8,
    index: usize,
    at_line_start: bool,

    pub fn token_slice(lexer: *Lexer, token: *const Token) []const u8 {
        return lexer.buffer[token.loc.start..token.loc.end];
    }

    pub const Token = struct {
        tag: Tag,
        loc: Loc,

        pub const Loc = struct {
            start: usize,
            end: usize,
        };

        pub const keywords = std.StaticStringMap(Tag).initComptime(.{
            .{ "txn", .keyword_txn },
            .{ "balance", .keyword_balance },
            .{ "open", .keyword_open },
            .{ "close", .keyword_close },
            .{ "commodity", .keyword_commodity },
            .{ "pad", .keyword_pad },
            .{ "event", .keyword_event },
            .{ "query", .keyword_query },
            .{ "custom", .keyword_custom },
            .{ "price", .keyword_price },
            .{ "note", .keyword_note },
            .{ "document", .keyword_document },
            .{ "pushtag", .keyword_pushtag },
            .{ "poptag", .keyword_poptag },
            .{ "pushmeta", .keyword_pushmeta },
            .{ "popmeta", .keyword_popmeta },
            .{ "option", .keyword_option },
            .{ "plugin", .keyword_plugin },
            .{ "include", .keyword_include },
        });

        pub fn getKeyword(bytes: []const u8) ?Tag {
            return keywords.get(bytes);
        }

        pub const literals = std.StaticStringMap(Tag).initComptime(.{
            .{ "TRUE", .true },
            .{ "FALSE", .false },
            .{ "NULL", .none },
        });

        pub fn getLiteral(bytes: []const u8) ?Tag {
            return literals.get(bytes);
        }

        pub const Tag = enum {
            date,
            number,
            string,
            account,
            currency,
            flag,
            key,
            link,
            tag,

            eol,
            indent,

            pipe,
            atat,
            at,
            lcurllcurl,
            rcurlrcurl,
            lcurl,
            rcurl,
            comma,
            tilde,
            plus,
            minus,
            slash,
            lparen,
            rparen,
            hash,
            asterisk,
            colon,

            keyword_txn,
            keyword_balance,
            keyword_open,
            keyword_close,
            keyword_commodity,
            keyword_pad,
            keyword_event,
            keyword_query,
            keyword_custom,
            keyword_price,
            keyword_note,
            keyword_document,
            keyword_pushtag,
            keyword_poptag,
            keyword_pushmeta,
            keyword_popmeta,
            keyword_option,
            keyword_plugin,
            keyword_include,

            true,
            false,
            none,

            invalid,
            eof,
        };
    };

    pub fn init(buffer: [:0]const u8) Lexer {
        return .{
            .buffer = buffer,
            .index = 0,
            .at_line_start = true,
        };
    }

    const State = enum {
        start,
        invalid,
        string,
        int,
        date,
        number,
        accounttype_first,
        accountname_first,
        account,
        link,
        tag,
        saw_hash,
        currency,
        /// For special characters in the middle. Can't end on this.
        currency_special,
        keyword,
        comment,
        indent,
        flag,
        flag_special,
        at,
        lcurl,
        rcurl,
    };

    /// Consumes one unicode code point if it is encoded properly. If not
    /// encoded properly returns null, otherwise the number of bytes consumed.
    fn consumeUnicode(self: *Lexer) ?u3 {
        const length = unicode.utf8ByteSequenceLength(self.current()) catch {
            return null;
        };
        // Make sure we have enough bytes in the buffer
        if (self.index + length > self.buffer.len) {
            return null;
        }
        switch (length) {
            1 => {
                if (self.current() < 0x80) {
                    return null;
                }
            },
            2 => {
                // Decode and consume
                const bytes = .{ self.buffer[self.index], self.buffer[self.index + 1] };
                _ = unicode.utf8Decode2(bytes) catch {
                    return null;
                };
            },
            3 => {
                // Decode and consume
                const bytes = .{ self.buffer[self.index], self.buffer[self.index + 1], self.buffer[self.index + 2] };
                _ = unicode.utf8Decode3(bytes) catch {
                    return null;
                };
            },
            4 => {
                // Decode and consume
                const bytes = .{ self.buffer[self.index], self.buffer[self.index + 1], self.buffer[self.index + 2], self.buffer[self.index + 3] };
                _ = unicode.utf8Decode4(bytes) catch {
                    return null;
                };
            },
            else => unreachable,
        }
        self.index += length;
        self.at_line_start = false;
        return length;
    }

    /// Consume the current character. If it's a newline, we're at the start of
    /// the line for the next character. Otherwise, we're not.
    inline fn consume(self: *Lexer) void {
        switch (self.buffer[self.index]) {
            '\n' => self.at_line_start = true,
            else => self.at_line_start = false,
        }

        self.index += 1;
    }

    /// Return character we're currently looking at.
    inline fn current(self: *Lexer) u8 {
        return self.buffer[self.index];
    }

    pub fn next(self: *Lexer) Token {
        var result: Token = .{
            .tag = undefined,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };

        state: switch (State.start) {
            .start => switch (self.current()) {
                0 => {
                    if (self.index == self.buffer.len) {
                        result.tag = .eof;
                    } else {
                        continue :state .invalid;
                    }
                },
                '\n' => {
                    self.consume();
                    result.tag = .eol;
                },
                ' ', '\t' => {
                    if (self.at_line_start) {
                        self.consume();
                        continue :state .indent;
                    } else {
                        self.consume();
                        result.loc.start = self.index;
                        continue :state .start;
                    }
                },
                '"' => {
                    self.consume();
                    result.tag = .string;
                    continue :state .string;
                },
                '0'...'9' => {
                    self.consume();
                    result.tag = .number;
                    continue :state .int;
                },
                '|' => {
                    self.consume();
                    result.tag = .pipe;
                },
                '@' => {
                    self.consume();
                    continue :state .at;
                },
                '{' => {
                    self.consume();
                    continue :state .lcurl;
                },
                '}' => {
                    self.consume();
                    continue :state .rcurl;
                },
                ',' => {
                    self.consume();
                    result.tag = .comma;
                },
                '~' => {
                    self.consume();
                    result.tag = .tilde;
                },
                '+' => {
                    self.consume();
                    result.tag = .plus;
                },
                '-' => {
                    self.consume();
                    result.tag = .minus;
                },
                '/' => {
                    self.consume();
                    result.tag = .slash;
                },
                '(' => {
                    self.consume();
                    result.tag = .lparen;
                },
                ')' => {
                    self.consume();
                    result.tag = .rparen;
                },
                // TODO: Hash?
                '*' => {
                    self.consume();
                    result.tag = .asterisk;
                },
                ':' => {
                    self.consume();
                    result.tag = .colon;
                },
                '#' => {
                    self.consume();
                    continue :state .saw_hash; // Could be flag or tag
                },
                '!', '&', '?', '%' => { // Rest of the flag chars
                    self.consume();
                    result.tag = .flag;
                    continue :state .flag_special;
                },
                'A'...'Z' => {
                    switch (self.current()) {
                        // Flags
                        'P', 'S', 'T', 'C', 'U', 'R', 'M' => {
                            self.consume();
                            result.tag = .flag;
                            continue :state .flag;
                        },
                        else => {
                            self.consume();
                            result.tag = .currency;
                            continue :state .currency;
                        },
                    }
                },
                'a'...'z' => {
                    self.consume();
                    continue :state .keyword;
                },
                ';' => {
                    self.consume();
                    continue :state .comment;
                },
                '^' => {
                    self.consume();
                    result.tag = .link;
                    continue :state .link;
                },
                else => {
                    if (self.consumeUnicode()) |_| {
                        result.tag = .account;
                        continue :state .account;
                    } else {
                        continue :state .invalid;
                    }
                },
            },

            .invalid => {
                switch (self.current()) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else {
                        self.consume();
                        continue :state .invalid;
                    },
                    // Recovers to parse a new token after whitespace.
                    ' ', '\t', '\n' => {
                        self.consume();
                        result.tag = .invalid;
                    },
                    else => {
                        self.consume();
                        continue :state .invalid;
                    },
                }
            },

            .indent => switch (self.current()) {
                ' ', '\t' => {
                    self.consume();
                    continue :state .indent;
                },
                '\n' => {
                    result.loc.start = self.index;
                    self.consume();
                    result.tag = .eol;
                },
                0 => {
                    if (self.index == self.buffer.len) {
                        result.tag = .eof;
                    } else {
                        continue :state .invalid;
                    }
                },
                else => result.tag = .indent,
            },

            .string => {
                switch (self.current()) {
                    0 => continue :state .invalid,
                    '"' => self.consume(),
                    else => {
                        self.consume();
                        continue :state .string;
                    },
                }
            },

            .int => switch (self.current()) {
                '0'...'9' => {
                    self.consume();
                    continue :state .int;
                },
                '-', '/' => {
                    self.consume();
                    // Make sure we're at least 5th digit
                    if (self.index - result.loc.start >= 5) {
                        result.tag = .date;
                        continue :state .date;
                    } else {
                        continue :state .invalid;
                    }
                },
                '.' => {
                    self.consume();
                    continue :state .number;
                },
                else => {},
            },

            .number => switch (self.current()) {
                '0'...'9' => {
                    self.consume();
                    continue :state .number;
                },
                0, '\n', ' ' => {},
                else => {
                    continue :state .invalid;
                },
            },

            .date => switch (self.current()) {
                '0'...'9', '-', '/' => {
                    self.consume();
                    continue :state .date;
                },
                0, ' ', '\n' => {},
                else => continue :state .invalid,
            },

            .flag => switch (self.current()) {
                0, ' ', '\t', '\n' => {},
                else => {
                    result.tag = .currency;
                    continue :state .currency;
                },
            },

            .flag_special => switch (self.current()) {
                0, ' ', '\t', '\n' => {},
                else => continue :state .invalid,
            },

            .at => switch (self.current()) {
                '@' => {
                    self.consume();
                    result.tag = .atat;
                },
                else => result.tag = .at,
            },

            .lcurl => switch (self.current()) {
                '{' => {
                    self.consume();
                    result.tag = .lcurllcurl;
                },
                else => result.tag = .lcurl,
            },

            .rcurl => switch (self.current()) {
                '}' => {
                    self.consume();
                    result.tag = .rcurlrcurl;
                },
                else => result.tag = .rcurl,
            },

            .saw_hash => switch (self.current()) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '/', '.' => {
                    self.consume();
                    result.tag = .tag;
                    continue :state .tag;
                },
                0, ' ', '\t', '\n' => {
                    result.tag = .flag;
                },
                else => continue :state .invalid,
            },

            .tag => switch (self.current()) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '/', '.' => {
                    self.consume();
                    continue :state .tag;
                },
                0, ' ', '\t', '\n' => {},
                else => continue :state .invalid,
            },

            .link => switch (self.current()) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '/', '.' => {
                    self.consume();
                    continue :state .link;
                },
                0, ' ', '\t', '\n' => {},
                else => continue :state .invalid,
            },

            .currency => switch (self.current()) {
                'A'...'Z', '0'...'9' => {
                    self.consume();
                    continue :state .currency;
                },
                '\'', '.', '_', '-' => {
                    self.consume();
                    continue :state .currency_special;
                },
                'a'...'z', ':' => {
                    result.tag = .account;
                    continue :state .account;
                },
                0, ',', ' ', '\t', '\n' => {
                    // Check for TRUE, FALSE, NULL here since they look like currency symbols.
                    const literal = self.buffer[result.loc.start..self.index];
                    if (Token.getLiteral(literal)) |tag| {
                        result.tag = tag;
                    }
                    // Check at most 24 (22 middle + start + end) chars
                    if (self.index - result.loc.start > 24) {
                        continue :state .invalid;
                    }
                },
                else => continue :state .invalid,
            },

            // TODO: Only max 22 of these according to beancount spec.
            .currency_special => switch (self.current()) {
                'A'...'Z', '0'...'9' => {
                    self.consume();
                    continue :state .currency;
                },
                '\'', '.', '_', '-' => {
                    self.consume();
                    continue :state .currency_special;
                },
                else => continue :state .invalid,
            },

            .accounttype_first => switch (self.current()) {
                'A'...'Z' => {
                    self.consume();
                    continue :state .account;
                },
                else => {
                    if (self.consumeUnicode()) |_| {
                        continue :state .account;
                    } else {
                        continue :state .invalid;
                    }
                },
            },

            .accountname_first => switch (self.current()) {
                'A'...'Z', '0'...'9' => {
                    self.consume();
                    continue :state .account;
                },
                else => {
                    if (self.consumeUnicode()) |_| {
                        continue :state .account;
                    } else {
                        continue :state .invalid;
                    }
                },
            },

            .account => switch (self.current()) {
                'A'...'Z', 'a'...'z', '0'...'9', '-' => {
                    self.consume();
                    continue :state .account;
                },
                ':' => {
                    self.consume();
                    continue :state .accountname_first;
                },
                0, ' ', '\t', '\n' => {},
                else => {
                    if (self.consumeUnicode()) |_| {
                        continue :state .account;
                    } else {
                        continue :state .invalid;
                    }
                },
            },

            .keyword => switch (self.current()) {
                'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {
                    self.consume();
                    continue :state .keyword;
                },
                0, ' ', '\n' => {
                    const keyword = self.buffer[result.loc.start..self.index];
                    if (Token.getKeyword(keyword)) |tag| {
                        result.tag = tag;
                    } else {
                        continue :state .invalid;
                    }
                },
                ':' => {
                    // Don't consume so that we can match the : as a `.colon`.
                    result.tag = .key;
                },
                else => continue :state .invalid,
            },

            .comment => switch (self.current()) {
                0 => continue :state .start,
                '\n' => {
                    self.consume();
                    result.loc.start = self.index;
                    continue :state .start;
                },
                else => {
                    self.consume();
                    result.loc.start = self.index;
                    continue :state .comment;
                },
            },
        }

        result.loc.end = self.index;
        return result;
    }
};

test "combined" {
    try testLex("\"café 😊\"", &.{.string});
    try testLex("\"\"", &.{.string});
    try testLex("\"\" Au", &.{ .string, .account });
    try testLex("\"foo\"", &.{.string});
    try testLex("15", &.{.number});
    try testLex("15.5", &.{.number});
    try testLex("\"bar\" 12.1 4 2025-01-01", &.{ .string, .number, .number, .date });

    try testLex("USD", &.{.currency});
    try testLex("Usd", &.{.account});
    try testLex("Assets:Checking", &.{.account});
    try testLex("Assets:Foo 100 USD", &.{ .account, .number, .currency });

    try testLex(
        \\2025-04-22 * "Buy coffee"
        \\    Assets:Checking  -100.10 USD
        \\    Expenses:Food
    , &.{ .date, .asterisk, .string, .eol, .indent, .account, .minus, .number, .currency, .eol, .indent, .account });
}

test "account" {
    try testLex("Foo:Bar", &.{.account});
    try testLex("ΑβγⅠ:ΑβγⅠ", &.{.account});
    try testLex("ابجا:ابجا", &.{.account});
    try testLex("F:B", &.{.account});
    try testLex("F:B CU", &.{ .account, .currency });
    try testLex("Fo:9-", &.{.account});
    try testLex("😊:😊", &.{.account});
    try testLex("😊:`", &.{.invalid});
    try testLex("😊:Fð", &.{.account});
    try testLex("𠁑𠁑:𠁑𠁑", &.{.account});
}

test "date" {
    try testLex("2014-15-20", &.{.date});
    try testLex("2014/12/20", &.{.date});
    try testLex("5 1949-41-09", &.{ .number, .date });
}

test "currency" {
    try testLex("EUR", &.{.currency});
    try testLex("E.R", &.{.currency});
    try testLex("EUR.1", &.{.currency});
    try testLex("EUR.", &.{.invalid});
    try testLex("_EUR.", &.{.invalid});
    try testLex("E*R", &.{.invalid});
    try testLex("ABCDEFGHIJKLMNOPQRSTUVWX", &.{.currency});
    try testLex("ABCDEFGHIJKLMNOPQRSTUVWXY", &.{.invalid});
}

test "keywords" {
    try testLex("open", &.{.keyword_open});
    try testLex("close", &.{.keyword_close});
    try testLex("pad 15", &.{ .keyword_pad, .number });

    try testLex("TRUE FALSE NULL", &.{ .true, .false, .none });
}

test "comments" {
    try testLex("10 ; number", &.{.number});
    try testLex(
        \\; Blah
        \\2015-01-01
    , &.{.date});
}

test "indent" {
    try testLex(
        \\open 
        \\  close
    , &.{ .keyword_open, .eol, .indent, .keyword_close });
}

test "flag" {
    try testLex("# ? CURM", &.{ .flag, .flag, .currency });
}

test "key" {
    try testLex("my1: open 15", &.{ .key, .colon, .keyword_open, .number });
}

test "link" {
    try testLex("# ^/App.", &.{ .flag, .link });
}

test "tag" {
    try testLex("# #abcA7 #", &.{ .flag, .tag, .flag });
}

test "beancount iter" {
    try testLex(
        \\2013-05-18 2014-01-02 2014/01/02
        \\Assets:US:Bank:Checking
        \\Liabilities:US:Bank:Credit
        \\Other:Bank
        \\USD HOOL TEST_D TEST_3 TEST-D TEST-3 NT
        \\"Nice dinner at Mermaid Inn"
        \\""
        \\123 123.45 123.456789 -123 -123.456789
        \\#sometag123
        \\^sometag123
        \\somekey:
    , &.{
        .date,
        .date,
        .date,
        .eol,
        .account,
        .eol,
        .account,
        .eol,
        .account,
        .eol,
        .currency,
        .currency,
        .currency,
        .currency,
        .currency,
        .currency,
        .currency,
        .eol,
        .string,
        .eol,
        .string,
        .eol,
        .number,
        .number,
        .number,
        .minus,
        .number,
        .minus,
        .number,
        .eol,
        .tag,
        .eol,
        .link,
        .eol,
        .key,
        .colon,
    });
}

test "beancount unicode account" {
    try testLex(
        \\Other:Bank Óthяr:Bあnk
        \\abc1:abc1 ΑβγⅠ:ΑβγⅠ ابجا:ابجا
    , &.{ .account, .account, .eol, .key, .colon, .invalid, .account, .account });
}

test "beancount indent" {
    try testLex(
        \\2014-07-05 *
        \\  Equity:Something
    , &.{ .date, .asterisk, .eol, .indent, .account });
}

test "beancount comma currencies" {
    try testLex("USD,CAD,AUD", &.{ .currency, .comma, .currency, .comma, .currency });
}

fn testLex(source: [:0]const u8, expected_tags: []const Lexer.Token.Tag) !void {
    var lexer = Lexer.init(source);
    for (expected_tags) |tag| {
        // std.debug.print("{}\n", .{ tag });
        const token = lexer.next();
        try std.testing.expectEqual(tag, token.tag);
    }
    const last_token = lexer.next();
    try std.testing.expectEqual(last_token.tag, .eof);
    try std.testing.expectEqual(source.len, last_token.loc.start);
    try std.testing.expectEqual(source.len, last_token.loc.end);
}
