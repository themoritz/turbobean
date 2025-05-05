const std = @import("std");

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

        pub const Tag = enum {
            date,
            number,
            string,
            account,
            currency,
            flag,
            key,
            link,

            eol,
            indent,

            asterisk,

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
        account,
        link,
        currency,
        /// For special characters in the middle. Can't end on this.
        currency_special,
        keyword,
        comment,
        indent,
        flag,
        flag_special,
    };

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
                '-', '0'...'9' => {
                    self.consume();
                    result.tag = .number;
                    continue :state .int;
                },
                '*' => {
                    self.consume();
                    result.tag = .asterisk;
                },
                '!', '&', '#', '?', '%' => {
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
                else => continue :state .invalid,
            },

            .invalid => {
                switch (self.current()) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else {
                        self.consume();
                        continue :state .invalid;
                    },
                    // Recovers to parse a new token after newline.
                    '\n' => {
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
                '-' => {
                    self.consume();
                    // Make sure we're at 5th digit
                    if (self.index - result.loc.start == 5) {
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
                '0'...'9' => {
                    self.consume();
                    // Check valid positions of digits
                    switch (self.index - result.loc.start) {
                        6, 7, 9, 10 => continue :state .date,
                        else => continue :state .invalid,
                    }
                },
                '-' => {
                    self.consume();
                    // Check valid positions of hyphens
                    switch (self.index - result.loc.start) {
                        5, 8 => continue :state .date,
                        else => continue :state .invalid,
                    }
                },
                0, ' ', '\n' => {
                    // Check valid length
                    switch (self.index + 1 - result.loc.start) {
                        11 => {},
                        else => continue :state .invalid,
                    }
                },
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
                    self.consume();
                    continue :state .account;
                },
                0, ' ', '\t', '\n' => {},
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

            .account => switch (self.current()) {
                'a'...'z', 'A'...'Z', '_', ':' => {
                    self.consume();
                    continue :state .account;
                },
                0, ' ', '\n' => {},
                else => continue :state .invalid,
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
                    self.consume();
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

test "lexer" {
    try testLex("\"café 😊\"", &.{.string});
    try testLex("\"\"", &.{.string});
    try testLex("\"\" Au", &.{ .string, .account });
    try testLex("\"foo\"", &.{.string});
    try testLex("15", &.{.number});
    try testLex("15.5", &.{.number});
    try testLex("2014-15-20", &.{.date});
    try testLex("5 1949-41-09", &.{ .number, .date });
    try testLex("\"bar\" 12.1 4 2025-01-01", &.{ .string, .number, .number, .date });

    try testLex("USD", &.{.currency});
    try testLex("Usd", &.{.account});
    try testLex("Assets:Checking", &.{.account});
    try testLex("Assets:Foo 100 USD", &.{ .account, .number, .currency });

    try testLex(
        \\2025-04-22 * "Buy coffee"
        \\    Assets:Checking  -100.10 USD
        \\    Expenses:Food
    , &.{ .date, .asterisk, .string, .eol, .indent, .account, .number, .currency, .eol, .indent, .account });
}

test "currency" {
    try testLex("EUR", &.{.currency});
    try testLex("E.R", &.{.currency});
    try testLex("EUR.1", &.{.currency});
    try testLex("EUR.", &.{.invalid});
    try testLex("_EUR.", &.{.invalid});
    try testLex("E*R", &.{.invalid});
}

test "keywords" {
    try testLex("open", &.{.keyword_open});
    try testLex("close", &.{.keyword_close});
    try testLex("pad 15", &.{ .keyword_pad, .number });
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
    try testLex("my1: open 15", &.{ .key, .keyword_open, .number });
}

test "link" {
    try testLex("# ^/App.", &.{ .flag, .link });
}

fn testLex(source: [:0]const u8, expected_tags: []const Lexer.Token.Tag) !void {
    var lexer = Lexer.init(source);
    for (expected_tags) |tag| {
        const token = lexer.next();
        try std.testing.expectEqual(tag, token.tag);
    }
    const last_token = lexer.next();
    try std.testing.expectEqual(last_token.tag, .eof);
    try std.testing.expectEqual(source.len, last_token.loc.start);
    try std.testing.expectEqual(source.len, last_token.loc.end);
}
