//! Recursive descent parser with some lookahead. No backtracking.
//!
//! Conventions:
//!
//! - If a function is called parseX, it typically returns one of three options:
//!   - an error: The sub parser has committed to a grammar and then got stuck.
//!     Not revocerable
//!   - null: The sub parser didn't match. It hasn't consumed any tokens. Use this to
//!     model alternatives.
//!   - a value: The sub parser succeeded. It consumed all tokens it needed
//!
//! - If a function is called expectX, it will return a parse erorr when the expected
//!   grammar isn't found or doesn't parse successfully. The parser should fail.
//!
const std = @import("std");
const Allocator = std.mem.Allocator;
const Data = @import("data.zig");
const Date = @import("date.zig").Date;
const Self = @This();
const Lexer = @import("lexer.zig").Lexer;
const Number = @import("number.zig").Number;

pub const Error = error{ ParseError, InvalidCharacter } || Allocator.Error;

gpa: Allocator,
tokens: Data.Tokens,
tok_i: usize,

entries: Data.Entries,
postings: Data.Postings,
tagslinks: Data.TagsLinks,
meta: Data.Meta,

err: ?ErrorDetails,

pub const ErrorDetails = struct {
    tag: Tag,
    token: Lexer.Token,
    expected: ?Lexer.Token.Tag,

    pub const Tag = enum {
        expected_token,
        expected_amount,
        expected_entry,
        expected_key_value,
        expected_value,
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

fn addKeyValue(p: *Self, keyvalue: Data.KeyValue) !usize {
    const result = p.meta.len;
    try p.meta.append(p.gpa, keyvalue);
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
    const result = p.currentToken();
    p.tok_i += 1;
    return result;
}

fn currentToken(p: *Self) Lexer.Token {
    return p.tokens.items[p.tok_i];
}

fn nextToken(p: *Self) ?Lexer.Token {
    if (p.tok_i + 1 < p.tokens.items.len) {
        return p.tokens.items[p.tok_i + 1];
    } else return null;
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
        _ = try p.parseDecl() orelse break;
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

            const s1 = p.tryTokenSlice(.string);
            const s2 = p.tryTokenSlice(.string);
            var payee = s1;
            var narration = s2;

            if (s2 == null) {
                payee = null;
                narration = s1;
            }

            const tagslinks = try p.parseTagsLinks();
            _ = p.tryToken(.eol);

            const meta_top = p.meta.len;
            while (true) {
                _ = try p.parseKeyValueLine() orelse break;
            }
            const meta = Data.Range.create(meta_top, p.meta.len);

            const postings_top = p.postings.len;
            while (true) {
                _ = try p.parsePosting() orelse break;
            }
            const postings = Data.Range.create(postings_top, p.postings.len);

            const transaction = Data.Transaction{ .date = date, .flag = flag, .payee = payee, .narration = narration, .tagslinks = tagslinks, .postings = postings, .meta = meta };
            const entry = Data.Entry{ .transaction = transaction };

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

fn parsePosting(p: *Self) !?usize {
    // Lookahead
    if (p.currentToken().tag != .indent) return null;
    const next_token = p.nextToken() orelse return null;
    if (next_token.tag != .account) return null;

    _ = try p.expectToken(.indent);
    const account = p.tryTokenSlice(.account) orelse return null;
    const amount = try p.parseAmount() orelse return p.fail(.expected_amount);
    _ = p.tryToken(.eol);

    const meta_top = p.meta.len;
    while (true) {
        _ = try p.parseKeyValueLine() orelse break;
    }
    const meta = Data.Range.create(meta_top, p.meta.len);

    const posting = Data.Posting{
        .account = account,
        .amount = amount,
        .meta = meta,
    };

    return try p.addPosting(posting);
}

fn parseKeyValueLine(p: *Self) !?usize {
    // Lookahead
    if (p.currentToken().tag != .indent) return null;
    const next_token = p.nextToken() orelse return null;
    if (next_token.tag != .key) return null;

    _ = try p.expectToken(.indent);
    const kv = try p.parseKeyValue() orelse return p.fail(.expected_key_value);
    _ = try p.expectToken(.eol);
    return kv;
}

fn parseKeyValue(p: *Self) !?usize {
    const key = p.tryToken(.key) orelse return null;
    _ = try p.expectToken(.colon);
    switch (p.currentToken().tag) {
        .string, .account, .date, .currency, .tag, .true, .false, .none, .number => {
            const value = p.advanceToken();
            return try p.addKeyValue(Data.KeyValue{
                .key = key.loc,
                .value = value.loc,
            });
        },
        // TODO: amount
        else => return p.fail(.expected_value),
    }
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
    return Data.Range.create(tagslinks_top, p.tagslinks.len);
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

test "tx" {
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
}

test "pushtag poptat" {
    try testParse(
        \\pushtag #nz
        \\
        \\poptag #foo
        \\
    );
}

test "meta" {
    try testParse(
        \\2020-01-01 txn
        \\  foo: TRUE
        \\
        \\2020-02-01 txn "a" "b"
        \\  foo: FALSE
        \\  Assets:Foo 10.0000 USD
        \\    bar: NULL
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
