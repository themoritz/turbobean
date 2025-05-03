const std = @import("std");

pub const Lexer = struct {
    buffer: [:0]const u8,
    index: usize,

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

        pub const Tag = enum {
            date,
            number,
            star,
            bang,
            string,
            account,
            currency,
            invalid,
            eof,
        };
    };

    pub fn init(buffer: [:0]const u8) Lexer {
        return .{
            .buffer = buffer,
            .index = 0,
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
        currency,
    };

    pub fn next(self: *Lexer) Token {
        var result: Token = .{
            .tag = undefined,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };

        state: switch (State.start) {
            .start => switch (self.buffer[self.index]) {
                0 => {
                    if (self.index == self.buffer.len) {
                        return .{
                            .tag = .eof,
                            .loc = .{
                                .start = self.index,
                                .end = self.index,
                            },
                        };
                    } else {
                        continue :state .invalid;
                    }
                },
                ' ', '\n', '\r' => {
                    self.index += 1;
                    result.loc.start = self.index;
                    continue :state .start;
                },
                '"' => {
                    self.index += 1;
                    result.tag = .string;
                    continue :state .string;
                },
                '-', '0'...'9' => {
                    result.tag = .number;
                    self.index += 1;
                    continue :state .int;
                },
                '*' => {
                    self.index += 1;
                    result.tag = .star;
                },
                '!' => {
                    self.index += 1;
                    result.tag = .bang;
                },
                'A'...'Z' => {
                    result.tag = .currency;
                    self.index += 1;
                    continue :state .currency;
                },
                else => continue :state .invalid,
            },

            .invalid => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else {
                        continue :state .invalid;
                    },
                    // Recovers to parse a new token after newline.
                    '\n' => result.tag = .invalid,
                    else => continue :state .invalid,
                }
            },

            .string => {
                switch (self.buffer[self.index]) {
                    0 => continue :state .invalid,
                    '"' => self.index += 1,
                    else => {
                        self.index += 1;
                        continue :state .string;
                    },
                }
            },

            .int => switch (self.buffer[self.index]) {
                '0'...'9' => {
                    self.index += 1;
                    continue :state .int;
                },
                '-' => {
                    self.index += 1;
                    // Make sure we're at 5th digit
                    if (self.index - result.loc.start == 5) {
                        result.tag = .date;
                        continue :state .date;
                    } else {
                        continue :state .invalid;
                    }
                },
                '.' => {
                    self.index += 1;
                    continue :state .number;
                },
                else => {},
            },

            .number => switch (self.buffer[self.index]) {
                '0'...'9' => {
                    self.index += 1;
                    continue :state .number;
                },
                0, '\n', ' ', '\r' => {},
                else => {
                    continue :state .invalid;
                },
            },

            .date => switch (self.buffer[self.index]) {
                '0'...'9' => {
                    self.index += 1;
                    // Check valid positions of digits
                    switch (self.index - result.loc.start) {
                        6, 7, 9, 10 => continue :state .date,
                        else => continue :state .invalid,
                    }
                },
                '-' => {
                    self.index += 1;
                    // Check valid positions of hyphens
                    switch (self.index - result.loc.start) {
                        5, 8 => continue :state .date,
                        else => continue :state .invalid,
                    }
                },
                0, ' ', '\n', '\r' => {
                    // Check valid length
                    switch (self.index + 1 - result.loc.start) {
                        11 => {},
                        else => continue :state .invalid,
                    }
                },
                else => continue :state .invalid,
            },

            .currency => switch (self.buffer[self.index]) {
                'A'...'Z' => {
                    self.index += 1;
                    continue :state .currency;
                },
                'a'...'z', ':' => {
                    result.tag = .account;
                    self.index += 1;
                    continue :state .account;
                },
                0, ' ', '\n', '\r' => {},
                else => continue :state .invalid,
            },

            .account => switch (self.buffer[self.index]) {
                'a'...'z', 'A'...'Z', '_', ':' => {
                    self.index += 1;
                    continue :state .account;
                },
                0, ' ', '\n', '\r' => {},
                else => continue :state .invalid,
            },
        }

        result.loc.end = self.index;
        return result;
    }
};

test "lexer" {
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

    try testLex("#", &.{.invalid});

    try testLex(
        \\ 2025-04-22 * "Buy coffee"
        \\     Assets:Checking  -100.10 USD
        \\     Expenses:Food
    , &.{ .date, .star, .string, .account, .number, .currency, .account });
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
