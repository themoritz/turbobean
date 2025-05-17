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
const ErrorDetails = @import("ErrorDetails.zig");

pub const Error = error{ ParseError, InvalidCharacter } || Allocator.Error;

gpa: Allocator,
tokens: Data.Tokens,
tok_i: usize,

entries: Data.Entries,
postings: Data.Postings,
tagslinks: Data.TagsLinks,
meta: Data.Meta,
costcomps: Data.CostComps,
currencies: Data.Currencies,

err: ?ErrorDetails,
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

fn addCostComp(p: *Self, costcomp: Data.CostComp) !usize {
    const result = p.costcomps.items.len;
    try p.costcomps.append(costcomp);
    return result;
}

fn addCurrency(p: *Self, currency: []const u8) !usize {
    const result = p.currencies.items.len;
    try p.currencies.append(currency);
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
    p.eatWhitespace();
    while (true) {
        _ = try p.parseDeclaration() orelse break;
        p.eatWhitespace();
    }
}

/// Only returns null at EOF.
fn parseDeclaration(p: *Self) !?usize {
    if (try p.parseEntry() orelse try p.parseDirective()) |directive| {
        return directive;
    } else {
        if (p.currentToken().tag == .eof) {
            return null;
        } else {
            return p.fail(.expected_declaration);
        }
    }
}

/// Returns index of newly parsed entry in entries array.
fn parseEntry(p: *Self) !?usize {
    const date = try p.parseDate() orelse return null;
    var entry: Data.Entry = undefined;
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
            try p.expectEolOrEof();

            const meta = try p.parseMeta();

            const postings_top = p.postings.len;
            while (true) {
                _ = try p.parsePosting() orelse break;
            }
            const postings = Data.Range.create(postings_top, p.postings.len);

            const transaction = Data.Transaction{ .date = date, .flag = flag, .payee = payee, .narration = narration, .tagslinks = tagslinks, .postings = postings, .meta = meta };
            entry = Data.Entry{ .transaction = transaction };
        },
        .keyword_open => {
            _ = p.advanceToken();
            const account = try p.expectTokenSlice(.account);

            const currency_top = p.currencies.items.len;
            if (p.tryToken(.currency)) |cur| {
                _ = try p.addCurrency(cur.loc);
                while (true) {
                    _ = p.tryToken(.comma) orelse break;
                    const c = try p.expectToken(.currency);
                    _ = try p.addCurrency(c.loc);
                }
            }
            const currencies = Data.Range.create(currency_top, p.currencies.items.len);
            const booking = if (p.tryToken(.string)) |b| b.loc else null;
            try p.expectEolOrEof();
            const meta = try p.parseMeta();

            const open = Data.Open{ .date = date, .account = account, .currencies = currencies, .booking = booking, .meta = meta };
            entry = Data.Entry{ .open = open };
        },
        .keyword_close => {
            _ = p.advanceToken();
            const account = try p.expectTokenSlice(.account);
            try p.expectEolOrEof();
            const meta = try p.parseMeta();
            const close = Data.Close{ .date = date, .account = account, .meta = meta };
            entry = Data.Entry{ .close = close };
        },
        .keyword_commodity => {
            _ = p.advanceToken();
            const currency = try p.expectTokenSlice(.currency);
            try p.expectEolOrEof();
            const meta = try p.parseMeta();
            const commodity = Data.Commodity{ .date = date, .currency = currency, .meta = meta };
            entry = Data.Entry{ .commodity = commodity };
        },
        .keyword_pad => {
            _ = p.advanceToken();
            const account = try p.expectTokenSlice(.account);
            const pad_to = try p.expectTokenSlice(.account);
            try p.expectEolOrEof();
            const meta = try p.parseMeta();
            const pad = Data.Pad{ .date = date, .account = account, .pad_to = pad_to, .meta = meta };
            entry = Data.Entry{ .pad = pad };
        },
        .keyword_balance => {
            _ = p.advanceToken();
            const account = try p.expectTokenSlice(.account);
            const number = try p.expectNumberExpr();
            var tolerance: ?Number = null;
            switch (p.currentToken().tag) {
                .tilde => {
                    _ = p.advanceToken();
                    tolerance = try p.expectNumberExpr();
                },
                else => {},
            }
            const currency = try p.expectTokenSlice(.currency);
            try p.expectEolOrEof();
            const meta = try p.parseMeta();
            const amount = Data.Amount{ .number = number, .currency = currency };
            const balance = Data.Balance{ .date = date, .account = account, .amount = amount, .tolerance = tolerance, .meta = meta };
            entry = Data.Entry{ .balance = balance };
        },
        .keyword_price => {
            _ = p.advanceToken();
            const currency = try p.expectTokenSlice(.currency);
            const amount = try p.parseAmount() orelse return p.fail(.expected_amount);
            try p.expectEolOrEof();
            const meta = try p.parseMeta();
            const price = Data.PriceDecl{ .date = date, .currency = currency, .amount = amount, .meta = meta };
            entry = Data.Entry{ .price = price };
        },
        .keyword_event => {
            _ = p.advanceToken();
            const variable = try p.expectTokenSlice(.string);
            const value = try p.expectTokenSlice(.string);
            try p.expectEolOrEof();
            const meta = try p.parseMeta();
            const event = Data.Event{ .date = date, .variable = variable, .value = value, .meta = meta };
            entry = Data.Entry{ .event = event };
        },
        .keyword_query => {
            _ = p.advanceToken();
            const name = try p.expectTokenSlice(.string);
            const sql = try p.expectTokenSlice(.string);
            try p.expectEolOrEof();
            const meta = try p.parseMeta();
            const query = Data.Query{ .date = date, .name = name, .sql = sql, .meta = meta };
            entry = Data.Entry{ .query = query };
        },
        .keyword_note => {
            _ = p.advanceToken();
            const account = try p.expectTokenSlice(.account);
            const note = try p.expectTokenSlice(.string);
            try p.expectEolOrEof();
            const meta = try p.parseMeta();
            const note_entry = Data.Note{ .date = date, .account = account, .note = note, .meta = meta };
            entry = Data.Entry{ .note = note_entry };
        },
        .keyword_document => {
            _ = p.advanceToken();
            const account = try p.expectTokenSlice(.account);
            const filename = try p.expectTokenSlice(.string);
            const tagslinks = try p.parseTagsLinks();
            try p.expectEolOrEof();
            const meta = try p.parseMeta();
            const document = Data.Document{ .date = date, .account = account, .filename = filename, .tagslinks = tagslinks, .meta = meta };
            entry = Data.Entry{ .document = document };
        },
        else => return p.fail(.expected_entry),
    }
    return try p.addEntry(entry);
}

fn parseDirective(p: *Self) !?usize {
    var entry: Data.Entry = undefined;
    switch (p.currentToken().tag) {
        .keyword_pushtag => {
            _ = p.advanceToken();
            const tag = try p.expectTokenSlice(.tag);
            entry = Data.Entry{ .pushtag = tag };
        },
        .keyword_poptag => {
            _ = p.advanceToken();
            const tag = try p.expectTokenSlice(.tag);
            entry = Data.Entry{ .poptag = tag };
        },
        .keyword_pushmeta => {
            _ = p.advanceToken();
            const meta = try p.parseKeyValue() orelse return p.fail(.expected_key_value);
            entry = Data.Entry{ .pushmeta = meta };
        },
        .keyword_popmeta => {
            _ = p.advanceToken();
            const meta = try p.parseKeyValue() orelse return p.fail(.expected_key_value);
            entry = Data.Entry{ .popmeta = meta };
        },
        .keyword_option => {
            _ = p.advanceToken();
            const key = try p.expectToken(.string);
            const value = try p.expectToken(.string);
            const option = Data.Option{
                .key = key.loc,
                .value = value.loc,
            };
            entry = Data.Entry{ .option = option };
        },
        .keyword_include => {
            _ = p.advanceToken();
            const file = try p.expectToken(.string);
            entry = Data.Entry{ .include = file.loc };
        },
        .keyword_plugin => {
            _ = p.advanceToken();
            const plugin = try p.expectToken(.string);
            entry = Data.Entry{ .plugin = plugin.loc };
        },
        else => return null,
    }
    _ = try p.expectEolOrEof();
    return try p.addEntry(entry);
}

fn parseMeta(p: *Self) !?Data.Range {
    const meta_top = p.meta.len;
    while (true) {
        _ = try p.parseKeyValueLine() orelse break;
    }
    return Data.Range.create(meta_top, p.meta.len);
}

fn parsePosting(p: *Self) !?usize {
    // Lookahead
    if (p.currentToken().tag != .indent) return null;
    const next_token = p.nextToken() orelse return null;
    switch (next_token.tag) {
        .account, .flag, .asterisk, .hash => {},
        else => return null,
    }

    _ = try p.expectToken(.indent);
    const flag = p.parseFlag();
    const account = p.tryTokenSlice(.account) orelse return null;
    const amount = try p.parseIncomleteAmount();
    const cost = try p.parseCost();
    const price = try p.parsePriceAnnotation();
    _ = p.tryToken(.eol);

    const meta = try p.parseMeta();

    const posting = Data.Posting{
        .flag = flag,
        .account = account,
        .amount = amount,
        .cost = cost,
        .price = price,
        .meta = meta,
    };

    return try p.addPosting(posting);
}

fn parsePriceAnnotation(p: *Self) !?Data.Price {
    switch (p.currentToken().tag) {
        .at, .atat => {
            const total = switch (p.advanceToken().tag) {
                .at => false,
                .atat => true,
                else => unreachable,
            };
            const amount = try p.parseIncomleteAmount();
            return Data.Price{
                .amount = amount,
                .total = total,
            };
        },
        else => return null,
    }
}

fn parseCost(p: *Self) !?Data.Cost {
    const open = p.tryToken(.lcurl) orelse p.tryToken(.lcurllcurl) orelse return null;

    const costcomp_top = p.costcomps.items.len;

    while (true) {
        switch (p.currentToken().tag) {
            .date => {
                const date = try p.parseDate() orelse return p.failExpected(.date);
                _ = try p.addCostComp(.{ .date = date });
            },
            .string => {
                const label = p.advanceToken().loc;
                _ = try p.addCostComp(.{ .label = label });
            },
            else => {
                const amount = try p.parseIncomleteAmount();
                if (amount.exists()) {
                    _ = try p.addCostComp(.{ .amount = amount });
                } else break;
            },
        }
        if (p.tryToken(.comma) == null) break;
    }

    const range = Data.Range.create(costcomp_top, p.costcomps.items.len);

    switch (open.tag) {
        .lcurl => {
            _ = try p.expectToken(.rcurl);
            return .{ .comps = range, .total = false };
        },
        .lcurllcurl => {
            _ = try p.expectToken(.rcurlrcurl);
            return .{ .comps = range, .total = true };
        },
        else => unreachable,
    }
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
        else => {
            // TODO: amount. need to change value to enum
            return p.fail(.expected_value);
        },
    }
}

fn parseIncomleteAmount(p: *Self) !Data.Amount {
    const number = try p.parseNumberExpr();
    const currency = p.tryTokenSlice(.currency);
    return .{
        .number = number,
        .currency = currency,
    };
}

fn parseAmount(p: *Self) !?Data.Amount {
    const number = try p.parseNumberExpr() orelse return null;
    const currency = try p.expectTokenSlice(.currency);
    return .{
        .number = number,
        .currency = currency,
    };
}

fn parseFlag(p: *Self) ?Lexer.Token {
    switch (p.currentToken().tag) {
        .flag, .asterisk, .hash => return p.advanceToken(),
        else => return null,
    }
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

fn expectEolOrEof(p: *Self) !void {
    switch (p.currentToken().tag) {
        .eol => _ = p.advanceToken(),
        .eof => {},
        else => return p.failExpected(.eol),
    }
}

fn eatWhitespace(p: *Self) void {
    while (true) {
        if (p.currentToken().tag == .indent and p.nextToken() != null and p.nextToken().?.tag == .eol) {
            _ = p.advanceToken();
            _ = p.advanceToken();
        } else if (p.currentToken().tag == .eol) {
            _ = p.advanceToken();
        } else {
            break;
        }
    }
}

fn parseDate(p: *Self) !?Date {
    const token = p.tryToken(.date) orelse return null;
    return try Date.fromSlice(token.loc);
}

fn parseNumberExpr(p: *Self) !?Number {
    switch (p.currentToken().tag) {
        .number => {
            const token = p.advanceToken();
            return try Number.fromSlice(token.loc);
        },
        .minus => {
            _ = p.advanceToken();
            const token = try p.expectToken(.number);
            const number = try Number.fromSlice(token.loc);
            return number.negate();
        },
        else => return null,
    }
}

fn expectNumberExpr(p: *Self) !Number {
    return try p.parseNumberExpr() orelse return p.failExpected(.number);
}

test "negative" {
    try testRoundtrip(
        \\2015-11-01 * "Test"
        \\  Assets:Foo -1.0000 USD
        \\
    );
}

test "tx" {
    try testRoundtrip(
        \\2015-11-01 * "Test"
        \\  Foo 100.0000 USD
        \\  Bar 2.0000 EUR
        \\
    );

    try testRoundtrip(
        \\2024-12-01 * "Foo"
        \\
    );

    try testRoundtrip(
        \\2015-01-01 * ""
        \\  ! Aa 10.0000 USD
        \\  Ba 30.0000 USD
        \\
        \\2016-01-01 * ""
        \\  Ca 10.0000 USD
        \\  Da 20.0000 USD
        \\
    );
}

test "tagslinks" {
    try testRoundtrip(
        \\2019-05-15 # #tag ^link
        \\
    );
}

test "directives" {
    try testRoundtrip(
        \\pushtag #nz
        \\
        \\poptag #foo
        \\
        \\pushmeta k: "Val"
        \\
        \\popmeta k: Assets:Val
        \\
        \\option "some" "option"
        \\
        \\include "file.bean"
        \\
        \\plugin "some_plugin"
        \\
    );
}

test "meta" {
    try testRoundtrip(
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

test "price annotation" {
    try testRoundtrip(
        \\2020-02-01 txn "a" "b"
        \\  Assets:Foo 10.0000 USD @ 2.0000 EUR
        \\  Assets:Foo @@ 4.0000 EUR
        \\
    );
}

test "cost spec" {
    try testRoundtrip(
        \\2020-02-01 txn "a" "b"
        \\  Assets:Foo 10.0000 USD {}
        \\  Assets:Foo {0.0000 USD, "label"}
        \\  Assets:Foo {2014-01-01}
        \\
    );
}

test "open" {
    try testRoundtrip(
        \\1985-08-17 open Assets:Foo USD,EUR "strict"
        \\  a: "Yes"
        \\
        \\1985-09-24 open Assets:Bar NZD
        \\
        \\1985-09-24 open Assets:Bar "lax"
        \\
    );
}

test "close" {
    try testRoundtrip(
        \\1985-08-17 close Assets:Foo
        \\  a: "Yes"
        \\
        \\1985-09-24 close Assets:Bar
        \\
    );
}

test "commodity" {
    try testRoundtrip(
        \\1985-08-17 commodity USD
        \\  a: "Yes"
        \\
        \\1985-09-24 commodity EUR
        \\
    );
}

test "pad" {
    try testRoundtrip(
        \\1985-08-17 pad Assets:Foo Equity:Opening-Balances
        \\  a: "Yes"
        \\
        \\1985-09-24 pad Assets:Bar Equity:Opening-Balances
        \\
    );
}

test "balance" {
    try testRoundtrip(
        \\1985-08-17 balance Assets:Foo 0.0000 USD
        \\  a: "Yes"
        \\
        \\1985-09-24 balance Assets:Bar 0.1000 ~ 0.0001 EUR
        \\
    );
}

test "price" {
    try testRoundtrip(
        \\1985-08-17 price TGT 0.0000 USD
        \\  a: "Yes"
        \\
        \\1985-09-24 price TGT 200.0000 USD
        \\
    );
}

test "event" {
    try testRoundtrip(
        \\1985-08-17 event "location" "Paris"
        \\  a: "Yes"
        \\
        \\1985-09-24 event "location" "London"
        \\
    );
}

test "query" {
    try testRoundtrip(
        \\1985-08-17 query "france-balances" "SELECT ..."
        \\  a: "Yes"
        \\
        \\1985-09-24 query "london-balances" "SELECT ..."
        \\
    );
}

test "note" {
    try testRoundtrip(
        \\1985-08-17 note Assets:Foo "Called them"
        \\  a: "Yes"
        \\
        \\1985-09-24 note Assets:Bar "Called them"
        \\
    );
}

test "document" {
    try testRoundtrip(
        \\1985-08-17 document Assets:Foo "/usr/bin/foo"
        \\  a: "Yes"
        \\
        \\1985-09-24 document Assets:Bar "/usr/bin/bar" #tag ^link
        \\
    );
}

test "org mode" {
    try testEntries(
        \\2024-09-01 open Assets:Foo
        \\
        \\
        \\* This sentence is an org-mode title.
        \\
        \\2013-03-01 open Assets:Foo
    , &.{ .open, .open });

    try testEntries(
        \\* 2024
        \\
        \\** June
        \\
        \\2024-06-01 balance Assets:Currency:ING:Giro 0.00 EUR
    , &.{.balance});
}

test "comments" {
    try testEntries(
        \\option "title" "Title"
        \\
        \\; TODO:
        \\; - More historical prices
        \\
        \\option "operating_currency" "EUR"
        \\option "operating_currency" "USD"
        \\option "render_commas" "True"
        \\  ; indented comment
        \\
        \\include "prices.bean"
        \\
        \\2021-01-01 open Assets:Cash
        \\
        \\2021-01-01 open Expenses:Books
        \\2021-01-01 open Expenses:Food
    , &.{ .option, .option, .option, .option, .include, .open, .open, .open });
}

const EntryTag = @typeInfo(Data.Entry).@"union".tag_type.?;

fn testEntries(source: [:0]const u8, expected: []const EntryTag) !void {
    var data = try Data.parse(std.testing.allocator, source);
    defer data.deinit(std.testing.allocator);

    for (expected, 0..) |tag, i| {
        const entry = data.entries[i];
        try std.testing.expectEqual(@tagName(tag), @tagName(entry));
    }
}

fn testRoundtrip(source: [:0]const u8) !void {
    const alloc = std.testing.allocator;

    var data = try Data.parse(alloc, source);
    defer data.deinit(alloc);

    // const pretty = @import("pretty.zig");
    // try pretty.print(alloc, data.entries, .{});
    // try pretty.print(alloc, data.postings.items(.amount), .{});
    // try pretty.print(alloc, data.meta.items(.key), .{});

    const Render = @import("render.zig");
    const rendered = try Render.dump(alloc, &data);
    defer alloc.free(rendered);

    try std.testing.expectEqualSlices(u8, source, rendered);
}
