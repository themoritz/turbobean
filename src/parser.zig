const std = @import("std");
const Allocator = std.mem.Allocator;
const Data = @import("data.zig");
const Date = @import("date.zig").Date;
const Self = @This();
const Lexer = @import("lexer.zig").Lexer;
const Number = @import("number.zig").Number;

pub const Error = error{ ParseError, InvalidCharacter } || Allocator.Error;

gpa: Allocator,
lexer: *Lexer,
entries: Data.Entries,
postings: Data.Postings,
err: ?ErrorDetails,
current_token: Lexer.Token,

pub const ErrorDetails = struct {
    tag: Tag,
    token: Lexer.Token,
    expected: ?Lexer.Token.Tag,

    pub const Tag = enum {
        expected_token,
        expected_amount,
    };
};

fn addPosting(p: *Self, posting: Data.Posting) !usize {
    const result = p.postings.len;
    try p.postings.append(p.gpa, posting);
    return result;
}

fn addEntry(p: *Self, entry: Data.Entry) !usize {
    const result = p.entries.items.len;
    try p.entries.append(entry);
    return result;
}

fn failExpected(p: *Self, expected_token: Lexer.Token.Tag) error{ParseError} {
    return p.failMsg(.{
        .tag = .expected_token,
        .token = p.currentToken(),
        .expected = expected_token,
    });
}

fn fail(p: *Self, msg: ErrorDetails.Tag) error{ParseError} {
    return p.failMsg(.{
        .tag = msg,
        .token = p.currentToken(),
        .expected = null,
    });
}

fn failMsg(p: *Self, err: ErrorDetails) error{ParseError} {
    p.err = err;
    return error.ParseError;
}

/// Advances the lexer and stores the next token in `current_token`.
/// Returns the previous token.
fn advanceToken(p: *Self) Lexer.Token {
    const result = p.current_token;
    p.current_token = p.lexer.next();
    return result;
}

fn currentToken(p: *Self) Lexer.Token {
    return p.current_token;
}

/// If successful, returns the token looked for and advances
/// the lexer.
fn expectToken(p: *Self, tag: Lexer.Token.Tag) Error!Lexer.Token {
    const current = p.currentToken();
    if (current.tag != tag) {
        return p.failExpected(tag);
    } else {
        return p.advanceToken();
    }
}

fn expectTokenSlice(p: *Self, tag: Lexer.Token.Tag) Error![]const u8 {
    const token = try p.expectToken(tag);
    return p.lexer.token_slice(&token);
}

/// If successful, returns the token looked for and advances the
/// lexer.
fn tryToken(p: *Self, tag: Lexer.Token.Tag) ?Lexer.Token {
    if (p.currentToken().tag == tag) {
        return p.advanceToken();
    } else {
        return null;
    }
}

pub fn parse(p: *Self) !void {
    while (true) {
        _ = p.parseEntry() catch |err| switch (err) {
            error.ParseError => {
                // std.debug.print("{any}\n", .{p.err});
                break;
            },
            else => return err,
        };
    }
}

/// Returns index of newly parsed entry in entries array.
fn parseEntry(p: *Self) !usize {
    const date_slice = try p.expectTokenSlice(.date);
    const date = try Date.fromSlice(date_slice);
    const flag = try p.parseFlag();
    const msg = try p.expectTokenSlice(.string);
    _ = p.tryToken(.eol);

    const postings_top = p.postings.len;
    while (true) {
        _ = p.parsePosting() catch |err| switch (err) {
            error.ParseError => break,
            else => return err,
        };
    }
    const entry = Data.Entry{ .transaction = .{ .date = date, .flag = flag, .message = msg, .postings = .{
        .start = postings_top,
        .end = p.postings.len,
    } } };

    _ = p.tryToken(.eol);

    return p.addEntry(entry);
}

fn parseFlag(p: *Self) !Data.Flag {
    if (p.tryToken(.asterisk)) |_| {
        return .star;
    } else {
        _ = try p.expectToken(.flag);
        return .bang;
    }
}

fn parsePosting(p: *Self) Error!usize {
    _ = try p.expectToken(.indent);
    const account = try p.expectTokenSlice(.account);
    const amount = try p.parseAmount() orelse return p.fail(.expected_amount);
    _ = p.tryToken(.eol);

    const posting = Data.Posting{
        .account = account,
        .amount = amount,
    };

    return p.addPosting(posting);
}

fn parseAmount(p: *Self) !?Data.Amount {
    const number = try p.parseNumber() orelse return null;
    const currency = try p.expectTokenSlice(.currency);
    return .{
        .number = number,
        .currency = currency,
    };
}

fn parseNumber(p: *Self) !?Number {
    if (p.tryToken(.number)) |token| {
        const slice = p.lexer.token_slice(&token);
        return try Number.fromSlice(slice);
    } else return null;
}

test "parser" {
    try testParse(
        \\2015-11-01 * "Test"
        \\  Foo 100.0000 USD
        \\  Bar 2.0000 EUR
    );

    try testParse(
        \\2024-12-01 * "Foo"
    );

    try testParse(
        \\2015-01-01 * ""
        \\  Aa 10.0000 USD
        \\  Ba 30.0000 USD
        \\
        \\2016-01-01 * ""
        \\  Ca 10.0000 USD
        \\  Da 20.0000 USD
    );
}

fn testParse(source: [:0]const u8) !void {
    const alloc = std.testing.allocator;

    var data = try Data.parse(alloc, source);
    defer data.deinit(alloc);

    // const pretty = @import("pretty.zig");
    // try pretty.print(alloc, data.entries, .{});
    // try pretty.print(alloc, data.postings.items(.amount), .{});

    const Render = @import("render.zig");
    const rendered = try Render.dump(alloc, &data);
    defer alloc.free(rendered);

    try std.testing.expectEqualSlices(u8, source, rendered);
}
