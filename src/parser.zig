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
const Inventory = @import("inventory.zig");
const Uri = @import("Uri.zig");

pub const Error = error{ParseError} || Allocator.Error;

alloc: Allocator,
tokens: Data.Tokens,
tok_i: usize,
is_root: bool,
uri: Uri,
source: [:0]const u8,

entries: *Data.Entries,
config: *Data.Config,
imports: Data.Imports,
postings: *Data.Postings,
tagslinks: *Data.TagsLinks,
meta: *Data.Meta,
currencies: *Data.Currencies,

active_tags: std.StringHashMap(void),
active_meta: std.StringHashMap([]const u8),

errors: *std.ArrayList(ErrorDetails),

fn addEntry(p: *Self, entry: Data.Entry) !usize {
    const result = p.entries.items.len;
    try p.entries.append(entry);
    return result;
}

fn addPosting(p: *Self, posting: Data.Posting) !usize {
    const result = p.postings.len;
    try p.postings.append(p.alloc, posting);
    return result;
}

fn addTagLink(p: *Self, taglink: Data.TagLink) !usize {
    const result = p.tagslinks.len;
    try p.tagslinks.append(p.alloc, taglink);
    return result;
}

fn addKeyValue(p: *Self, keyvalue: Data.KeyValue) !usize {
    const result = p.meta.len;
    try p.meta.append(p.alloc, keyvalue);
    return result;
}

fn addCurrency(p: *Self, currency: []const u8) !usize {
    const result = p.currencies.items.len;
    try p.currencies.append(currency);
    return result;
}

fn failExpected(p: *Self, expected_token: Lexer.Token.Tag) Error {
    return p.failMsg(.{
        .tag = .expected_token,
        .token = p.currentToken(),
        .uri = p.uri,
        .source = p.source,
        .expected = expected_token,
    });
}

fn fail(p: *Self, msg: ErrorDetails.Tag) Error {
    return p.failAt(p.currentToken(), msg);
}

fn failAt(p: *Self, token: Lexer.Token, msg: ErrorDetails.Tag) Error {
    return p.failMsg(.{
        .tag = msg,
        .token = token,
        .uri = p.uri,
        .source = p.source,
        .expected = null,
    });
}

fn failMsg(p: *Self, err: ErrorDetails) Error {
    try p.errors.append(err);
    return error.ParseError;
}

fn warnAt(p: *Self, token: Lexer.Token, msg: ErrorDetails.Tag) !void {
    try p.errors.append(.{
        .tag = msg,
        .token = token,
        .uri = p.uri,
        .source = p.source,
        .expected = null,
        .severity = .warn,
    });
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
    return token.slice;
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
    return token.slice;
}

pub fn parse(p: *Self) !void {
    try p.eatWhitespace();
    while (true) {
        _ = try p.parseDeclarationRecoverable() orelse break;
        try p.eatWhitespace();
    }
}

fn parseDeclarationRecoverable(p: *Self) !?void {
    return p.parseDeclaration() catch |err| switch (err) {
        error.ParseError => {
            // Skip ahead until next newline, consume it and then try the next
            // declaration.
            while (true) {
                switch (p.currentToken().tag) {
                    .eol => {
                        _ = p.advanceToken();
                        break;
                    },
                    .eof => return null,
                    else => _ = p.advanceToken(),
                }
            }
        },
        else => return err,
    };
}

/// Only returns null at EOF.
fn parseDeclaration(p: *Self) !?void {
    if (try p.parseEntry() orelse try p.parseDirective()) |_| {
        return;
    } else {
        if (p.currentToken().tag == .eof) {
            return null;
        } else {
            return p.fail(.expected_declaration);
        }
    }
}

/// Returns index of newly parsed entry in entries array.
fn parseEntry(p: *Self) !?void {
    const date_token = p.tryToken(.date) orelse return null;
    const date = Date.fromSlice(date_token.slice) catch return p.failAt(date_token, .invalid_date);
    var payload: Data.Entry.Payload = undefined;
    switch (p.currentToken().tag) {
        .keyword_txn, .flag, .asterisk, .hash => {
            return try p.expectTransactionBody(date, date_token);
        },
        .keyword_open => {
            _ = p.advanceToken();
            const account = try p.expectToken(.account);

            const currency_top = p.currencies.items.len;
            if (p.tryToken(.currency)) |cur| {
                _ = try p.addCurrency(cur.slice);
                while (true) {
                    _ = p.tryToken(.comma) orelse break;
                    const c = try p.expectToken(.currency);
                    _ = try p.addCurrency(c.slice);
                }
            }
            const currencies = Data.Range.create(currency_top, p.currencies.items.len);
            const booking_method: ?Inventory.BookingMethod = if (p.tryToken(.string)) |b|
                if (std.mem.eql(u8, b.slice, "\"FIFO\""))
                    .fifo
                else if (std.mem.eql(u8, b.slice, "\"LIFO\""))
                    .lifo
                else if (std.mem.eql(u8, b.slice, "\"STRICT\""))
                    .strict
                else
                    return p.failAt(b, .invalid_booking_method)
            else
                null;

            payload = .{ .open = .{
                .account = account,
                .currencies = currencies,
                .booking_method = booking_method,
            } };
        },
        .keyword_close => {
            _ = p.advanceToken();
            const account = try p.expectToken(.account);
            payload = .{ .close = .{
                .account = account,
            } };
        },
        .keyword_commodity => {
            _ = p.advanceToken();
            const currency = try p.expectTokenSlice(.currency);
            payload = .{ .commodity = .{
                .currency = currency,
            } };
        },
        .keyword_pad => {
            _ = p.advanceToken();
            const account = try p.expectToken(.account);
            const pad_to = try p.expectToken(.account);
            payload = .{ .pad = .{
                .account = account,
                .pad_to = pad_to,
            } };
        },
        .keyword_balance => {
            _ = p.advanceToken();
            const account = try p.expectToken(.account);
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
            const amount = Data.Amount{ .number = number, .currency = currency };
            payload = .{ .balance = .{
                .account = account,
                .amount = amount,
                .tolerance = tolerance,
            } };
        },
        .keyword_price => {
            _ = p.advanceToken();
            const currency = try p.expectTokenSlice(.currency);
            const amount = try p.parseAmount() orelse return p.fail(.expected_amount);
            payload = .{ .price = .{
                .currency = currency,
                .amount = amount,
            } };
        },
        .keyword_event => {
            _ = p.advanceToken();
            const variable = try p.expectTokenSlice(.string);
            const value = try p.expectTokenSlice(.string);
            payload = .{ .event = .{
                .variable = variable,
                .value = value,
            } };
        },
        .keyword_query => {
            _ = p.advanceToken();
            const name = try p.expectTokenSlice(.string);
            const sql = try p.expectTokenSlice(.string);
            payload = .{ .query = .{
                .name = name,
                .sql = sql,
            } };
        },
        .keyword_note => {
            _ = p.advanceToken();
            const account = try p.expectToken(.account);
            const note = try p.expectTokenSlice(.string);
            payload = .{ .note = .{
                .account = account,
                .note = note,
            } };
        },
        .keyword_document => {
            _ = p.advanceToken();
            const account = try p.expectToken(.account);
            const filename = try p.expectTokenSlice(.string);
            payload = .{ .document = .{
                .account = account,
                .filename = filename,
            } };
        },
        else => return p.fail(.expected_entry),
    }

    const tagslinks = try p.parseTagsLinks();
    try p.expectEolOrEof();
    const meta = try p.parseMeta(true);

    _ = try p.addEntry(Data.Entry{
        .date = date,
        .main_token = date_token,
        .payload = payload,
        .tagslinks = tagslinks,
        .meta = meta,
    });
}

fn expectTransactionBody(p: *Self, date: Date, date_token: Lexer.Token) !void {
    const flag = p.advanceToken();
    if (std.mem.eql(u8, flag.slice, "!")) try p.warnAt(flag, .flagged);

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

    const meta = try p.parseMeta(true);

    const postings_top = p.postings.len;
    while (true) {
        if (try p.parsePosting()) |_| {} else if (try p.parseIndentedLine()) |_| {} else break;
    }
    const postings = Data.Range.create(postings_top, p.postings.len);

    const payload = Data.Entry.Payload{ .transaction = .{
        .flag = flag,
        .payee = payee,
        .narration = narration,
        .postings = postings,
    } };

    _ = try p.addEntry(Data.Entry{
        .date = date,
        .main_token = date_token,
        .payload = payload,
        .tagslinks = tagslinks,
        .meta = meta,
    });
}

fn parseIndentedLine(p: *Self) !?void {
    if (p.currentToken().tag == .indent and p.nextToken() != null and (p.nextToken().?.tag == .eol or p.nextToken().?.tag == .comment)) {
        _ = try p.expectToken(.indent);
        _ = p.tryToken(.comment);
        _ = try p.expectToken(.eol);
    } else return null;
}

fn parseDirective(p: *Self) !?void {
    switch (p.currentToken().tag) {
        .keyword_pushtag => {
            _ = p.advanceToken();
            const tag = try p.expectToken(.tag);
            if (p.active_tags.contains(tag.slice)) {
                return p.failAt(tag, .tag_already_pushed);
            } else {
                try p.active_tags.put(tag.slice, {});
            }
        },
        .keyword_poptag => {
            _ = p.advanceToken();
            const tag = try p.expectToken(.tag);
            if (!p.active_tags.remove(tag.slice)) {
                return p.failAt(tag, .tag_not_pushed);
            }
        },
        .keyword_pushmeta => {
            _ = p.advanceToken();
            const kv = try p.parseKeyValue() orelse return p.fail(.expected_key_value);
            if (p.active_meta.contains(kv.key.slice)) {
                return p.failAt(kv.key, .meta_already_pushed);
            } else {
                try p.active_meta.put(kv.key.slice, kv.value.slice);
            }
        },
        .keyword_popmeta => {
            _ = p.advanceToken();
            const kv = try p.parseKeyValue() orelse return p.fail(.expected_key_value);
            if (!p.active_meta.remove(kv.key.slice)) {
                return p.failAt(kv.key, .meta_not_pushed);
            }
        },
        .keyword_option => {
            _ = p.advanceToken();
            const key = try p.expectToken(.string);
            const value = try p.expectToken(.string);
            if (p.is_root) {
                try p.config.addOption(key.slice, value.slice);
            }
            // TODO: Else warn
        },
        .keyword_include => {
            _ = p.advanceToken();
            const file = try p.expectToken(.string);
            try p.imports.append(file.slice[1 .. file.slice.len - 1]);
        },
        .keyword_plugin => {
            _ = p.advanceToken();
            const plugin = try p.expectToken(.string);
            if (p.is_root) {
                try p.config.addPlugin(plugin.slice);
            }
            // TODO: Else warn
        },
        else => return null,
    }
    _ = try p.expectEolOrEof();
}

fn parseMeta(p: *Self, add_from_stack: bool) !?Data.Range {
    const meta_top = p.meta.len;
    while (true) {
        if (try p.parseKeyValueLine()) |_| {} else if (try p.parseIndentedLine()) |_| {} else break;
    }

    // Add meta that's on the pushmeta stack
    if (add_from_stack) {
        var meta_iter = p.active_meta.iterator();
        while (meta_iter.next()) |kv| {
            _ = try p.addKeyValue(Data.KeyValue{
                .key = Lexer.Token{ .slice = kv.key_ptr.*, .tag = .key, .line = 0, .start_col = 0, .end_col = 0 },
                .value = Lexer.Token{ .slice = kv.value_ptr.*, .tag = .string, .line = 0, .start_col = 0, .end_col = 0 },
            });
        }
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
    const account = p.tryToken(.account) orelse return null;
    const amount = try p.parseIncomleteAmount();
    const lot_spec = try p.parseLotSpec();
    const price = try p.parsePriceAnnotation();
    _ = p.tryToken(.comment);
    _ = p.tryToken(.eol);

    if (flag) |f| {
        if (std.mem.eql(u8, f.slice, "!")) try p.warnAt(f, .flagged);
    }

    const meta = try p.parseMeta(false);

    const posting = Data.Posting{
        .flag = flag,
        .account = account,
        .amount = amount,
        .lot_spec = lot_spec,
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

fn parseLotSpec(p: *Self) !?Data.LotSpec {
    _ = p.tryToken(.lcurl) orelse return null;

    var price: ?Data.Amount = null;
    var date: ?Date = null;
    var label: ?[]const u8 = null;

    while (true) {
        switch (p.currentToken().tag) {
            .date => {
                if (date != null) return p.fail(.duplicate_lot_spec);
                date = try p.parseDate() orelse return p.failExpected(.date);
            },
            .string => {
                if (label != null) return p.fail(.duplicate_lot_spec);
                label = p.advanceToken().slice;
            },
            else => {
                const amount = try p.parseAmount();
                if (amount) |_| {
                    if (price != null) return p.fail(.duplicate_lot_spec);
                    price = amount;
                }
            },
        }
        if (p.tryToken(.comma) == null) break;
    }

    _ = try p.expectToken(.rcurl);
    return .{ .price = price, .date = date, .label = label };
}

fn parseKeyValueLine(p: *Self) !?usize {
    // Lookahead
    if (p.currentToken().tag != .indent) return null;
    const next_token = p.nextToken() orelse return null;
    if (next_token.tag != .key) return null;

    _ = try p.expectToken(.indent);
    const kv = try p.parseKeyValue() orelse return p.fail(.expected_key_value);
    _ = try p.expectToken(.eol);
    return try p.addKeyValue(kv);
}

fn parseKeyValue(p: *Self) !?Data.KeyValue {
    const key = p.tryToken(.key) orelse return null;
    _ = try p.expectToken(.colon);
    switch (p.currentToken().tag) {
        .string, .account, .date, .currency, .tag, .true, .false, .none, .number => {
            const value = p.advanceToken();
            return Data.KeyValue{
                .key = key,
                .value = value,
            };
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
            _ = try p.addTagLink(Data.TagLink{ .kind = .tag, .slice = tag.slice });
        } else if (p.tryToken(.link)) |link| {
            _ = try p.addTagLink(Data.TagLink{ .kind = .link, .slice = link.slice });
        } else break;
    }

    // Add tags that are on the pushtags stack
    var tags_iter = p.active_tags.keyIterator();
    while (tags_iter.next()) |tag| {
        _ = try p.addTagLink(Data.TagLink{ .kind = .tag, .slice = tag.* });
    }

    return Data.Range.create(tagslinks_top, p.tagslinks.len);
}

fn expectEolOrEof(p: *Self) !void {
    _ = p.tryToken(.comment);
    switch (p.currentToken().tag) {
        .eol => _ = p.advanceToken(),
        .eof => {},
        else => return p.failExpected(.eol),
    }
}

fn eatWhitespace(p: *Self) !void {
    while (true) {
        if (try p.parseIndentedLine()) |_| {
            //
        } else if (p.currentToken().tag == .eol) {
            _ = p.advanceToken();
        } else if (p.currentToken().tag == .comment) {
            _ = try p.expectToken(.comment);
            _ = try p.expectEolOrEof();
        } else {
            break;
        }
    }
}

fn parseDate(p: *Self) !?Date {
    const token = p.tryToken(.date) orelse return null;
    return Date.fromSlice(token.slice) catch return p.failAt(token, .invalid_date);
}

fn parseNumberExpr(p: *Self) !?Number {
    switch (p.currentToken().tag) {
        .number => return try p.parseNumber(),
        .minus => {
            _ = p.advanceToken();
            const number = try p.expectNumber();
            return number.negate();
        },
        else => return null,
    }
}

fn expectNumberExpr(p: *Self) !Number {
    return try p.parseNumberExpr() orelse return p.failExpected(.number);
}

fn parseNumber(p: *Self) !?Number {
    const token = p.currentToken();
    if (token.tag == .number) {
        const number = Number.fromSlice(token.slice) catch return p.fail(.invalid_number);
        _ = p.advanceToken();
        return number;
    } else return null;
}

fn expectNumber(p: *Self) !Number {
    return try p.parseNumber() orelse return p.failExpected(.number);
}

test "negative" {
    try testRoundtrip(
        \\2015-11-01 * "Test"
        \\  Assets:Foo -1 USD
        \\
    );
}

test "tx" {
    try testRoundtrip(
        \\2015-11-01 * "Test"
        \\  Foo 100 USD
        \\  Bar 2 EUR
        \\
    );

    try testRoundtrip(
        \\2024-12-01 * "Foo"
        \\
    );

    try testRoundtrip(
        \\2015-01-01 * ""
        \\  ! Aa 10 USD
        \\  Ba 30 USD
        \\
        \\2016-01-01 * ""
        \\  Ca 10 USD
        \\  Da 20 USD
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
    try testParse(
        \\pushtag #nz
        \\
        \\poptag #nz
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

test "pushpop" {
    const expectEqual = std.testing.expectEqual;

    const source =
        \\pushtag #tag
        \\pushmeta k: "Val"
        \\
        \\2015-11-01 * "Test" #tag2
        \\  Assets:Foo 100.00 USD
        \\
        \\2022-11-01 close Assets:Foo
        \\  k2: "Val2"
        \\
        \\poptag #tag
        \\popmeta k: "Val"
        \\
        \\2015-11-01 * "Test"
        \\  k2: "Val2"
        \\  Assets:Foo 100.00 USD
        \\
        \\2022-11-01 close Assets:Foo ^link
    ;

    var data = try Data.parse(std.testing.allocator, source);
    defer data.deinit();

    // Tags
    try expectEqual(@as(usize, 2), data.entries.items[0].tagslinks.?.len());
    try expectEqual(@as(usize, 1), data.entries.items[1].tagslinks.?.len());
    try expectEqual(null, data.entries.items[2].tagslinks);
    try expectEqual(@as(usize, 1), data.entries.items[3].tagslinks.?.len());

    // Meta
    try expectEqual(@as(usize, 1), data.entries.items[0].meta.?.len());
    try expectEqual(@as(usize, 2), data.entries.items[1].meta.?.len());
    try expectEqual(@as(usize, 1), data.entries.items[2].meta.?.len());
    try expectEqual(null, data.entries.items[3].meta);

    // Meta is not pushed to postings
    try expectEqual(null, data.postings.items(.meta)[0]);
}

test "meta" {
    try testRoundtrip(
        \\2020-01-01 txn
        \\  foo: TRUE
        \\
        \\2020-02-01 txn "a" "b"
        \\  foo: FALSE
        \\  Assets:Foo 10.00 USD
        \\    bar: NULL
        \\
    );
}

test "price annotation" {
    try testRoundtrip(
        \\2020-02-01 txn "a" "b"
        \\  Assets:Foo 10 USD @ 2 EUR
        \\  Assets:Foo @@ 4 EUR
        \\
    );
}

test "cost spec" {
    try testRoundtrip(
        \\2020-02-01 txn "a" "b"
        \\  Assets:Foo 10 USD {}
        \\  Assets:Foo {0 USD, "label"}
        \\  Assets:Foo {2014-01-01}
        \\
    );
}

test "open" {
    try testRoundtrip(
        \\1985-08-17 open Assets:Foo USD,EUR "STRICT"
        \\  a: "Yes"
        \\
        \\1985-09-24 open Assets:Bar NZD
        \\
        \\1985-09-24 open Assets:Bar "FIFO"
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
        \\1985-08-17 balance Assets:Foo 0.0 USD
        \\  a: "Yes"
        \\
        \\1985-09-24 balance Assets:Bar 0.10 ~ 0.01 EUR
        \\
    );
}

test "price" {
    try testRoundtrip(
        \\1985-08-17 price TGT 0 USD
        \\  a: "Yes"
        \\
        \\1985-09-24 price TGT 200 USD
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

test "indent continue" {
    try testEntries(
        \\2021-06-23 * "SATURN" ^HO22036653030652/175962
        \\  ; Washing machine?
        \\  Assets:Currency -442.89 EUR
        \\  Expenses:Home
        \\
    , &.{.transaction});

    try testEntries(
        \\2021-06-23 * "SATURN ONLINE INGOLSTADT 000" ^HO22036653030652/175962
        \\  Assets:Currency -442.89 EUR
        \\    key: "value"
        \\    ; Todo
        \\    key2: "value2"
        \\  Expenses:Home
        \\
    , &.{.transaction});
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
        \\2021-01-01 open Assets:Cash
        \\
        \\; TODO:
        \\; - More historical prices
        \\
        \\2021-01-01 open Assets:Cash
        \\  ; indented comment
        \\
        \\2021-01-01 open Assets:Cash
    , &.{ .open, .open, .open });
}

test "recover without final newline" {
    try testEntries("2015-01-01", &.{});
}

test "eol comments" {
    try testEntries(
        \\2021-01-01 open Assets:Cash ; Cash
        \\
        \\; Tx
        \\2021-06-23 * "SATURN" ; Saturn
        \\  Assets:Currency -442.89 EUR ; EUR
        \\  Expenses:Foo
    , &.{ .open, .transaction });
}

const EntryTag = @typeInfo(Data.Entry.Payload).@"union".tag_type.?;

fn testEntries(source: [:0]const u8, expected: []const EntryTag) !void {
    var data = try Data.parse(std.testing.allocator, source);
    defer data.deinit();

    for (expected, 0..) |tag, i| {
        const entry = data.entries.items[i];
        try std.testing.expectEqual(@tagName(tag), @tagName(entry.payload));
    }
}

fn testParse(source: [:0]const u8) !void {
    var data = try Data.parse(std.testing.allocator, source);
    defer data.deinit();
    if (data.errors.items.len > 0) return error.ParseError;
}

fn testRoundtrip(source: [:0]const u8) !void {
    const alloc = std.testing.allocator;

    var data = try Data.parse(alloc, source);
    defer data.deinit();

    // const pretty = @import("pretty.zig");
    // try pretty.print(alloc, data.entries, .{});
    // try pretty.print(alloc, data.postings.items(.amount), .{});
    // try pretty.print(alloc, data.meta.items(.key), .{});

    const Render = @import("render.zig");
    const rendered = try Render.dump(alloc, &data);
    defer alloc.free(rendered);

    try std.testing.expectEqualStrings(source, rendered);
}
