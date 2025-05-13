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
tagslinks: Data.TagsLinks,
err: ?ErrorDetails,
current_token: Lexer.Token,

pub const ErrorDetails = struct {
    tag: Tag,
    token: Lexer.Token,
    expected: ?Lexer.Token.Tag,

    pub const Tag = enum {
        expected_token,
        expected_amount,
        expected_entry,
    };
};

fn addEntry(p: *Self, entry: Data.Entry) !usize {
    const result = p.entries.items.len;
    try p.entries.append(entry);
    return result;
}

fn addPosting(p: *Self, posting: Data.Posting) !usize {
    const result = p.postings.len;
    try p.postings.append(p.gpa, posting);
    return result;
}

fn addTagLink(p: *Self, taglink: Data.TagLink) !usize {
    const result = p.tagslinks.len;
    try p.tagslinks.append(p.gpa, taglink);
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
    return token.loc;
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

fn tryTokenSlice(p: *Self, tag: Lexer.Token.Tag) ?[]const u8 {
    const token = p.tryToken(tag) orelse return null;
    return token.loc;
}

pub fn parse(p: *Self) !void {
    while (true) {
        const entry = try p.parseDecl();
        if (entry == null) break;
    }
}

fn parseDecl(p: *Self) !?usize {
    return try p.parseEntry() orelse try p.parseDirective();
}

/// Returns index of newly parsed entry in entries array.
fn parseEntry(p: *Self) !?usize {
    const date = try p.parseDate() orelse return null;
    switch (p.currentToken().tag) {
        .keyword_txn, .flag, .asterisk, .hash => {
            const flag = p.advanceToken();
            const payee = p.tryTokenSlice(.string);
            const narration = p.tryTokenSlice(.string);
            const tagslinks = try p.parseTagsLinks();
            _ = p.tryToken(.eol);

            const postings_top = p.postings.len;
            while (true) {
                const posting = try p.parsePostingOrKeyValue();
                if (posting == null) break;
            }
            const entry = Data.Entry{ .transaction = .{ .date = date, .flag = flag, .payee = payee, .narration = narration, .tagslinks = tagslinks, .postings = .{
                .start = postings_top,
                .end = p.postings.len,
            } } };

            _ = p.tryToken(.eol);

            return try p.addEntry(entry);
        },
        else => return p.fail(.expected_entry),
    }
}

fn parseDirective(p: *Self) !?usize {
    switch (p.currentToken().tag) {
        .keyword_pushtag => {
            _ = p.advanceToken();
            const tag = try p.expectTokenSlice(.tag);
            _ = try p.expectEolPlus();
            return try p.addEntry(Data.Entry{ .pushtag = tag });
        },
        .keyword_poptag => {
            _ = p.advanceToken();
            const tag = try p.expectTokenSlice(.tag);
            _ = try p.expectEolPlus();
            return try p.addEntry(Data.Entry{ .poptag = tag });
        },
        else => return null,
    }
}

fn parsePostingOrKeyValue(p: *Self) !?usize {
    _ = p.tryToken(.indent) orelse return null;
    const account = try p.expectTokenSlice(.account);
    const amount = try p.parseAmount() orelse return p.fail(.expected_amount);
    _ = p.tryToken(.eol);

    const posting = Data.Posting{
        .account = account,
        .amount = amount,
    };

    return try p.addPosting(posting);
}

fn parseAmount(p: *Self) !?Data.Amount {
    const number = try p.parseNumber() orelse return null;
    const currency = try p.expectTokenSlice(.currency);
    return .{
        .number = number,
        .currency = currency,
    };
}

fn parseTagsLinks(p: *Self) !?Data.Range {
    const tagslinks_top = p.tagslinks.len;
    while (true) {
        if (p.tryToken(.tag)) |tag| {
            _ = try p.addTagLink(Data.TagLink{ .kind = .tag, .slice = tag.loc });
        } else if (p.tryToken(.link)) |link| {
            _ = try p.addTagLink(Data.TagLink{ .kind = .link, .slice = link.loc });
        } else break;
    }
    const tagslinks_bot = p.tagslinks.len;
    if (tagslinks_bot == tagslinks_top) return null;
    return Data.Range{
        .start = tagslinks_top,
        .end = tagslinks_bot,
    };
}

/// Expects at least one .eol, and consumes all it finds. Returns last consumed
/// .eol.
fn expectEolPlus(p: *Self) !Lexer.Token {
    var result = try p.expectToken(.eol);
    while (true) {
        if (p.tryToken(.eol)) |i| {
            result = i;
        } else break;
    }
    return result;
}

fn parseDate(p: *Self) !?Date {
    const token = p.tryToken(.date) orelse return null;
    return try Date.fromSlice(token.loc);
}

fn parseNumber(p: *Self) !?Number {
    const token = p.tryToken(.number) orelse return null;
    return try Number.fromSlice(token.loc);
}

test "parser" {
    try testParse(
        \\2015-11-01 * "Test"
        \\  Foo 100.0000 USD
        \\  Bar 2.0000 EUR
        \\
    );

    try testParse(
        \\2024-12-01 * "Foo"
        \\
    );

    try testParse(
        \\2015-01-01 * ""
        \\  Aa 10.0000 USD
        \\  Ba 30.0000 USD
        \\
        \\2016-01-01 * ""
        \\  Ca 10.0000 USD
        \\  Da 20.0000 USD
        \\
    );

    try testParse(
        \\pushtag #nz
        \\
        \\poptag #foo
        \\
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
