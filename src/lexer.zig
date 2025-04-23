const std = @import("std");

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
        string,
        colon,
        identifier,
        invalid,
        eof,
    };
};

pub const Lexer = struct {
    buffer: [:0]const u8,
    index: usize,

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
                '"' => {
                    result.tag = .string;
                    continue :state .string;
                },
                else => continue :state .invalid,
            },
            .invalid => result.tag = .invalid,
            .string => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '"' => self.index += 1,
                    else => continue :state .string,
                }
            },
        }

        result.loc.end = self.index;
        return result;
    }
};

test "lexer" {
    try testLex("\"foo\"", &.{.string});
}

fn testLex(source: [:0]const u8, expected_tags: []const Token.Tag) !void {
    var lexer = Lexer.init(source);
    for (expected_tags) |tag| {
        const token = lexer.next();
        try std.testing.expectEqual(tag, token.tag);
    }
}
