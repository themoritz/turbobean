const std = @import("std");
const Ast = @import("Ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const Self = @This();
const Node = Ast.Node;
const ErrorDetails = @import("ErrorDetails.zig");
const Uri = @import("Uri.zig");

alloc: std.mem.Allocator,
uri: Uri,
source: [:0]const u8,
tokens: []const Lexer.Token,
tok_i: usize,

scratch: std.ArrayList(Node.Index),
token_scratch: std.ArrayList(Ast.TokenIndex),

nodes: *std.ArrayList(Node),
extra_data: *std.ArrayList(u32),
errors: *std.ArrayList(ErrorDetails),

pub fn init(alloc: std.mem.Allocator, uri: Uri, ast: *Ast) Self {
    return .{
        .alloc = alloc,
        .uri = uri,
        .source = ast.source,
        .tokens = ast.tokens.items,
        .tok_i = 0,
        .scratch = .{},
        .token_scratch = .{},
        .nodes = &ast.nodes,
        .extra_data = &ast.extra_data,
        .errors = &ast.errors,
    };
}

pub fn deinit(self: *Self) void {
    self.scratch.deinit(self.alloc);
    self.token_scratch.deinit(self.alloc);
}

fn addNode(self: *Self, node: Node) !Node.Index {
    const result: Node.Index = @enumFromInt(self.nodes.items.len);
    try self.nodes.append(self.alloc, node);
    return result;
}

fn addExtra(self: *Self, extra: anytype) !Ast.ExtraIndex {
    const result: Ast.ExtraIndex = @enumFromInt(self.extra_data.items.len);
    const fields = std.meta.fields(@TypeOf(extra));
    inline for (fields) |field| {
        switch (field.type) {
            Node.Index,
            Node.OptionalIndex,
            Ast.TokenIndex,
            Ast.OptionalTokenIndex,
            Ast.ExtraIndex,
            => {
                try self.extra_data.append(self.alloc, @intFromEnum(@field(extra, field.name)));
            },
            Node.Range => {
                const range: Node.Range = @field(extra, field.name);
                try self.extra_data.append(self.alloc, @intFromEnum(range.start));
                try self.extra_data.append(self.alloc, @intFromEnum(range.end));
            },
            else => @compileError("unsupported field type"),
        }
    }
    return result;
}

fn makeRange(self: *Self, slice: []const Node.Index) !Node.Range {
    try self.extra_data.appendSlice(self.alloc, @ptrCast(slice));
    return .{
        .start = @enumFromInt(self.extra_data.items.len - slice.len),
        .end = @enumFromInt(self.extra_data.items.len),
    };
}

fn makeTokenRange(self: *Self, slice: []const Ast.TokenIndex) !Node.Range {
    try self.extra_data.appendSlice(self.alloc, @ptrCast(slice));
    return .{
        .start = @enumFromInt(self.extra_data.items.len - slice.len),
        .end = @enumFromInt(self.extra_data.items.len),
    };
}

pub const Error = error{ParseError} || std.mem.Allocator.Error;

fn fail(p: *Self, msg: ErrorDetails.Tag) Error {
    return p.failAt(p.currentToken(), msg);
}

fn failExpected(p: *Self, expected_token: Lexer.Token.Tag) Error {
    return p.failMsg(.{
        .tag = .{ .expected_token = expected_token },
        .token = p.currentToken(),
        .uri = p.uri,
        .source = p.source,
    });
}

fn failAt(self: *Self, token: Lexer.Token, msg: ErrorDetails.Tag) Error {
    return self.failMsg(.{
        .tag = msg,
        .token = token,
        .uri = self.uri,
        .source = self.source,
    });
}

fn failMsg(self: *Self, err: ErrorDetails) Error {
    try self.errors.append(self.alloc, err);
    return error.ParseError;
}

fn currentToken(self: *Self) Lexer.Token {
    return self.tokens[self.tok_i];
}

fn advanceToken(self: *Self) Ast.TokenIndex {
    const result: Ast.TokenIndex = @enumFromInt(self.tok_i);
    self.tok_i += 1;
    return result;
}

fn nextToken(self: *Self) ?Lexer.Token {
    return if (self.tok_i + 1 < self.tokens.len)
        self.tokens[self.tok_i + 1]
    else
        null;
}

fn expectToken(self: *Self, tag: Lexer.Token.Tag) !Ast.TokenIndex {
    if (self.currentToken().tag == tag) {
        return self.advanceToken();
    } else {
        return self.failExpected(tag);
    }
}

fn tryToken(self: *Self, tag: Lexer.Token.Tag) ?Ast.TokenIndex {
    if (self.currentToken().tag == tag) {
        return self.advanceToken();
    } else {
        return null;
    }
}

pub fn parse(self: *Self) !void {
    // Add root node at index 0 for entrypoint into the AST.
    _ = try self.addNode(undefined);

    try self.eatWhiteSpace();

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    decls: while (true) {
        const node = self.parseDeclaration() catch |err| switch (err) {
            // Skip ahead until next newline
            error.ParseError => blk: {
                while (true) {
                    switch (self.currentToken().tag) {
                        .eol => {
                            _ = self.advanceToken();
                            break;
                        },
                        .eof => break,
                        else => _ = self.advanceToken(),
                    }
                }
                break :blk null;
            },
            else => return err,
        };
        if (node) |n| {
            try self.scratch.append(self.alloc, n);
            try self.eatWhiteSpace();
        } else {
            break :decls;
        }
    }

    const declarations = self.scratch.items[scratch_top..];
    self.nodes.items[0] = .{
        .root = try self.makeRange(declarations),
    };
}

fn eatWhiteSpace(self: *Self) !void {
    while (true) {
        if (try self.parseIndentedLine()) |_| {
            //
        } else if (self.currentToken().tag == .eol) {
            _ = self.advanceToken();
        } else if (self.currentToken().tag == .comment) {
            _ = try self.expectToken(.comment);
            _ = try self.expectEolOrEof();
        } else {
            break;
        }
    }
}

// Only returns null at EOF.
fn parseDeclaration(self: *Self) !?Node.Index {
    if (try self.parseEntry() orelse try self.parseDirective()) |node| {
        return node;
    } else {
        if (self.currentToken().tag == .eof) {
            return null;
        } else {
            return self.fail(.expected_declaration);
        }
    }
}

fn parseEntry(self: *Self) !?Node.Index {
    const date = self.tryToken(.date) orelse return null;

    switch (self.currentToken().tag) {
        .keyword_txn,
        .flag,
        .asterisk,
        .hash,
        => return try self.parseTransactionEntry(date),
        else => {},
    }

    const payload_node: Node.Index = switch (self.currentToken().tag) {
        .keyword_open => blk: {
            _ = self.advanceToken();
            const account = try self.expectToken(.account);

            const tscratch_top = self.token_scratch.items.len;
            defer self.token_scratch.shrinkRetainingCapacity(tscratch_top);

            if (self.tryToken(.currency)) |cur| {
                try self.token_scratch.append(self.alloc, cur);
                while (self.tryToken(.comma) != null) {
                    const c = try self.expectToken(.currency);
                    try self.token_scratch.append(self.alloc, c);
                }
            }

            const currencies = try self.makeTokenRange(self.token_scratch.items[tscratch_top..]);
            const booking_method = self.tryToken(.string);

            const extra = try self.addExtra(Node.Open{
                .account = account,
                .booking_method = Ast.OptionalTokenIndex.fromOptional(booking_method),
                .currencies = currencies,
            });
            break :blk try self.addNode(.{ .open = extra });
        },
        .keyword_close => blk: {
            _ = self.advanceToken();
            const account = try self.expectToken(.account);
            break :blk try self.addNode(.{ .close = account });
        },
        .keyword_commodity => blk: {
            _ = self.advanceToken();
            const currency = try self.expectToken(.currency);
            break :blk try self.addNode(.{ .commodity = currency });
        },
        .keyword_pad => blk: {
            _ = self.advanceToken();
            const account = try self.expectToken(.account);
            const pad_to = try self.expectToken(.account);
            break :blk try self.addNode(.{ .pad = .{ .account = account, .pad_to = pad_to } });
        },
        .keyword_pnl => blk: {
            _ = self.advanceToken();
            const account = try self.expectToken(.account);
            const income_account = try self.expectToken(.account);
            break :blk try self.addNode(.{ .pnl = .{ .account = account, .income_account = income_account } });
        },
        .keyword_balance => blk: {
            _ = self.advanceToken();
            const account = try self.expectToken(.account);

            _ = self.tryToken(.minus);
            const number = try self.expectToken(.number);
            var tolerance: ?Ast.TokenIndex = null;
            if (self.tryToken(.tilde) != null) {
                _ = self.tryToken(.minus);
                tolerance = try self.expectToken(.number);
            }
            const currency = try self.expectToken(.currency);

            const amount_node = try self.addNode(.{ .amount = .{
                .number = number.toOptional(),
                .currency = currency.toOptional(),
            } });

            const extra = try self.addExtra(Node.Balance{
                .account = account,
                .amount = amount_node,
                .tolerance = Ast.OptionalTokenIndex.fromOptional(tolerance),
            });
            break :blk try self.addNode(.{ .balance = extra });
        },
        .keyword_price => blk: {
            _ = self.advanceToken();
            const currency = try self.expectToken(.currency);
            const amount = try self.parseAmount() orelse return self.fail(.expected_amount);
            break :blk try self.addNode(.{ .price_decl = .{ .currency = currency, .amount = amount } });
        },
        .keyword_event => blk: {
            _ = self.advanceToken();
            const variable = try self.expectToken(.string);
            const value = try self.expectToken(.string);
            break :blk try self.addNode(.{ .event = .{ .key = variable, .value = value } });
        },
        .keyword_query => blk: {
            _ = self.advanceToken();
            const name = try self.expectToken(.string);
            const sql = try self.expectToken(.string);
            break :blk try self.addNode(.{ .query = .{ .key = name, .value = sql } });
        },
        .keyword_note => blk: {
            _ = self.advanceToken();
            const account = try self.expectToken(.account);
            const note = try self.expectToken(.string);
            break :blk try self.addNode(.{ .note = .{ .key = account, .value = note } });
        },
        .keyword_document => blk: {
            _ = self.advanceToken();
            const account = try self.expectToken(.account);
            const filename = try self.expectToken(.string);
            break :blk try self.addNode(.{ .document = .{ .key = account, .value = filename } });
        },
        else => return self.fail(.expected_entry),
    };

    const tagslinks = try self.parseTagsLinks();
    try self.expectEolOrEof();
    const meta = try self.parseMeta();

    const entry_extra = try self.addExtra(Node.Entry{
        .date = date,
        .tagslinks = tagslinks,
        .meta = meta,
        .payload = payload_node,
    });

    return try self.addNode(.{ .entry = entry_extra });
}

fn parseTransactionEntry(self: *Self, date: Ast.TokenIndex) !Node.Index {
    const flag = self.advanceToken();

    var payee = self.tryToken(.string);
    var narration = self.tryToken(.string);

    if (narration == null) {
        narration = payee;
        payee = null;
    }

    const tagslinks = try self.parseTagsLinks();
    try self.expectEolOrEof();
    const meta = try self.parseMeta();

    // Parse postings
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        if (try self.parsePosting()) |posting_node| {
            try self.scratch.append(self.alloc, posting_node);
        } else if (try self.parseIndentedLine()) |_| {
            //
        } else break;
    }

    const postings = try self.makeRange(self.scratch.items[scratch_top..]);

    const tx_extra = try self.addExtra(Node.Transaction{
        .flag = flag,
        .payee = Ast.OptionalTokenIndex.fromOptional(payee),
        .narration = Ast.OptionalTokenIndex.fromOptional(narration),
        .postings = postings,
    });
    const tx_node = try self.addNode(.{ .transaction = tx_extra });

    const entry_extra = try self.addExtra(Node.Entry{
        .date = date,
        .tagslinks = tagslinks,
        .meta = meta,
        .payload = tx_node,
    });

    return try self.addNode(.{ .entry = entry_extra });
}

fn parseDirective(self: *Self) !?Node.Index {
    switch (self.currentToken().tag) {
        .keyword_pushtag => {
            _ = self.advanceToken();
            const tag = try self.expectToken(.tag);
            try self.expectEolOrEof();
            return try self.addNode(.{ .pushtag = tag });
        },
        .keyword_poptag => {
            _ = self.advanceToken();
            const tag = try self.expectToken(.tag);
            try self.expectEolOrEof();
            return try self.addNode(.{ .poptag = tag });
        },
        .keyword_pushmeta => {
            _ = self.advanceToken();
            const key = self.tryToken(.key) orelse return self.fail(.expected_key_value);
            _ = try self.expectToken(.colon);
            const value = switch (self.currentToken().tag) {
                .string, .account, .date, .currency, .tag, .true, .false, .none, .number => self.advanceToken(),
                else => return self.fail(.expected_value),
            };
            try self.expectEolOrEof();
            return try self.addNode(.{ .pushmeta = .{ .key = key, .value = value } });
        },
        .keyword_popmeta => {
            _ = self.advanceToken();
            const key = self.tryToken(.key) orelse return self.fail(.expected_key_value);
            _ = try self.expectToken(.colon);
            const value = switch (self.currentToken().tag) {
                .string, .account, .date, .currency, .tag, .true, .false, .none, .number => self.advanceToken(),
                else => return self.fail(.expected_value),
            };
            try self.expectEolOrEof();
            return try self.addNode(.{ .popmeta = .{ .key = key, .value = value } });
        },
        .keyword_option => {
            _ = self.advanceToken();
            const opt_key = try self.expectToken(.string);
            const opt_value = try self.expectToken(.string);
            try self.expectEolOrEof();
            return try self.addNode(.{ .option = .{ .key = opt_key, .value = opt_value } });
        },
        .keyword_include => {
            _ = self.advanceToken();
            const file = try self.expectToken(.string);
            try self.expectEolOrEof();
            return try self.addNode(.{ .include = file });
        },
        .keyword_plugin => {
            _ = self.advanceToken();
            const plugin = try self.expectToken(.string);
            try self.expectEolOrEof();
            return try self.addNode(.{ .plugin = plugin });
        },
        else => return null,
    }
}

fn parseTagsLinks(self: *Self) !Node.Range {
    const tscratch_top = self.token_scratch.items.len;
    defer self.token_scratch.shrinkRetainingCapacity(tscratch_top);

    while (true) {
        if (self.tryToken(.tag)) |tag| {
            try self.token_scratch.append(self.alloc, tag);
        } else if (self.tryToken(.link)) |link| {
            try self.token_scratch.append(self.alloc, link);
        } else break;
    }

    return try self.makeTokenRange(self.token_scratch.items[tscratch_top..]);
}

fn parseMeta(self: *Self) !Node.Range {
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        if (try self.parseKeyValueLine()) |kv_node| {
            try self.scratch.append(self.alloc, kv_node);
        } else if (try self.parseIndentedLine()) |_| {
            //
        } else break;
    }

    return try self.makeRange(self.scratch.items[scratch_top..]);
}

fn parseKeyValueLine(self: *Self) !?Node.Index {
    // Lookahead
    if (self.currentToken().tag != .indent) return null;
    const next = self.nextToken() orelse return null;
    if (next.tag != .key) return null;

    _ = try self.expectToken(.indent);
    const kv_node = try self.parseKeyValue() orelse return self.fail(.expected_key_value);
    try self.expectEolOrEof();
    return kv_node;
}

fn parseKeyValue(self: *Self) !?Node.Index {
    const key = self.tryToken(.key) orelse return null;
    _ = try self.expectToken(.colon);
    switch (self.currentToken().tag) {
        .string, .account, .date, .currency, .tag, .true, .false, .none, .number => {
            const value = self.advanceToken();
            return try self.addNode(.{ .key_value = .{ .key = key, .value = value } });
        },
        else => return self.fail(.expected_value),
    }
}

fn parsePosting(self: *Self) !?Node.Index {
    // Lookahead
    if (self.currentToken().tag != .indent) return null;
    const next = self.nextToken() orelse return null;
    switch (next.tag) {
        .account, .flag, .asterisk, .hash => {},
        else => return null,
    }

    _ = try self.expectToken(.indent);
    const flag = self.parseFlag();
    const account = self.tryToken(.account) orelse return null;
    const amount = try self.parseIncompleteAmount();
    const lot_spec = try self.parseLotSpec();
    const price = try self.parsePriceAnnotation();
    _ = self.tryToken(.comment);
    _ = self.tryToken(.eol);

    const meta = try self.parseMeta();

    const extra = try self.addExtra(Node.Posting{
        .flag = Ast.OptionalTokenIndex.fromOptional(flag),
        .account = account,
        .amount = amount,
        .lot_spec = Node.OptionalIndex.fromOptional(lot_spec),
        .price = Node.OptionalIndex.fromOptional(price),
        .meta = meta,
    });

    return try self.addNode(.{ .posting = extra });
}

fn parseIncompleteAmount(self: *Self) !Node.Index {
    // If we see a minus, consume it. The number token follows immediately.
    // We store the number token index; the renderer checks token[number-1]
    // for a minus sign to reproduce negative numbers.
    const has_minus = self.tryToken(.minus) != null;
    var number: ?Ast.TokenIndex = null;
    if (has_minus) {
        number = try self.expectToken(.number);
    } else {
        number = self.tryToken(.number);
    }
    const currency = self.tryToken(.currency);
    return try self.addNode(.{ .amount = .{
        .number = Ast.OptionalTokenIndex.fromOptional(number),
        .currency = Ast.OptionalTokenIndex.fromOptional(currency),
    } });
}

fn parseAmount(self: *Self) !?Node.Index {
    _ = self.tryToken(.minus);
    const number = self.tryToken(.number) orelse return null;
    const currency = try self.expectToken(.currency);
    return try self.addNode(.{ .amount = .{
        .number = number.toOptional(),
        .currency = currency.toOptional(),
    } });
}

fn parseLotSpec(self: *Self) !?Node.Index {
    const lcurl = self.tryToken(.lcurl) orelse return null;

    var price_node: ?Node.Index = null;
    var lot_date: ?Ast.TokenIndex = null;
    var label: ?Ast.TokenIndex = null;

    while (self.currentToken().tag != .rcurl) {
        switch (self.currentToken().tag) {
            .date => {
                if (lot_date != null) return self.fail(.duplicate_lot_spec);
                lot_date = self.advanceToken();
            },
            .string => {
                if (label != null) return self.fail(.duplicate_lot_spec);
                label = self.advanceToken();
            },
            .number, .minus => {
                if (price_node != null) return self.fail(.duplicate_lot_spec);
                price_node = try self.parseAmount();
            },
            else => break,
        }
        if (self.tryToken(.comma) == null) break;
    }

    const rcurl = try self.expectToken(.rcurl);

    const extra = try self.addExtra(Node.LotSpec{
        .lcurl = lcurl,
        .rcurl = rcurl,
        .price = Node.OptionalIndex.fromOptional(price_node),
        .date = Ast.OptionalTokenIndex.fromOptional(lot_date),
        .label = Ast.OptionalTokenIndex.fromOptional(label),
    });

    return try self.addNode(.{ .lot_spec = extra });
}

fn parsePriceAnnotation(self: *Self) !?Node.Index {
    switch (self.currentToken().tag) {
        .at, .atat => {
            const at_token = self.advanceToken();
            const amount = try self.parseIncompleteAmount();
            return try self.addNode(.{ .price_annotation = .{
                .total = at_token,
                .amount = amount,
            } });
        },
        else => return null,
    }
}

fn parseFlag(self: *Self) ?Ast.TokenIndex {
    switch (self.currentToken().tag) {
        .flag, .asterisk, .hash => return self.advanceToken(),
        else => return null,
    }
}

fn expectEolOrEof(self: *Self) !void {
    _ = self.tryToken(.comment);
    switch (self.currentToken().tag) {
        .eol => _ = self.advanceToken(),
        .eof => {},
        else => return self.failExpected(.eol),
    }
}

fn parseIndentedLine(self: *Self) !?void {
    if (self.currentToken().tag == .indent and self.nextToken() != null and (self.nextToken().?.tag == .eol or self.nextToken().?.tag == .comment)) {
        _ = try self.expectToken(.indent);
        _ = self.tryToken(.comment);
        _ = try self.expectToken(.eol);
    } else return null;
}

test "negative" {
    try testRoundtrip(
        \\2015-11-01 * "Test"
        \\  Assets:Foo                            -1 USD
        \\
    );
}

test "tx" {
    try testRoundtrip(
        \\2015-11-01 * "Test"
        \\  Foo                                  100 USD
        \\  Bar                                    2 EUR
        \\
    );

    try testRoundtrip(
        \\2024-12-01 * "Foo"
        \\
    );

    try testRoundtrip(
        \\2015-01-01 * ""
        \\  ! Aa                                  10 USD
        \\  Ba                                    30 USD
        \\
        \\2016-01-01 * ""
        \\  Ca                                    10 USD
        \\  Da                                    20 USD
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

test "meta" {
    try testRoundtrip(
        \\2020-01-01 txn
        \\  foo: TRUE
        \\
        \\2020-02-01 txn "a" "b"
        \\  foo: FALSE
        \\  Assets:Foo                         10.00 USD
        \\    bar: NULL
        \\
    );
}

test "price annotation" {
    try testRoundtrip(
        \\2020-02-01 txn "a" "b"
        \\  Assets:Foo                            10 USD @  2 EUR
        \\  Assets:Foo                                   @@ 4 EUR
        \\
    );
}

test "cost spec" {
    try testRoundtrip(
        \\2020-02-01 txn "a" "b"
        \\  Assets:Foo                            10 USD {}
        \\  Assets:Foo                                   {"label"}    @ 0 USD
        \\  Assets:Foo                                   {2014-01-01}
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
    try testRoundtrip(
        \\2021-06-23 * "SATURN" ^HO22036653030652/175962
        \\  ; Washing machine?
        \\  Assets:Currency                  -442.89 EUR
        \\  Expenses:Home
        \\
    );

    try testParse(
        \\2021-06-23 * "SATURN ONLINE INGOLSTADT 000" ^HO22036653030652/175962
        \\  Assets:Currency  -442.89 EUR
        \\    key: "value"
        \\    ; Todo
        \\    key2: "value2"
        \\  Expenses:Home
        \\
    );
}

test "org mode" {
    try testRoundtrip(
        \\2024-09-01 open Assets:Foo
        \\
        \\* This sentence is an org-mode title.
        \\
        \\2013-03-01 open Assets:Foo
        \\
    );

    try testRoundtrip(
        \\* 2024
        \\
        \\** June
        \\
        \\2024-06-01 balance Assets:Currency:ING:Giro 0.00 EUR
        \\
    );
}

test "comments" {
    try testRoundtrip(
        \\2021-01-01 open Assets:Cash
        \\
        \\; TODO:
        \\; - More historical prices
        \\
        \\2021-01-01 open Assets:Cash
        \\
        \\2021-01-01 open Assets:Cash
        \\
    );
}

test "recover without final newline" {
    // Just verifies the parser doesn't crash - errors are expected
    const alloc = std.testing.allocator;
    var uri = try Uri.from_relative_to_cwd(alloc, "dummy.bean");
    defer uri.deinit(alloc);
    var ast = try Ast.parse(alloc, uri, "2015-01-01");
    defer ast.deinit();
}

// Formatter -------------

test "eol comments" {
    try testRoundtrip(
        \\2021-01-01 open Assets:Cash ; Cash
        \\
        \\; Tx
        \\2021-06-23 * "SATURN" ; Saturn
        \\  Assets:Currency                  -442.89 EUR ; EUR
        \\  Expenses:Foo
        \\
    );
}

test "comments before first declaration" {
    try testRoundtrip(
        \\; File header comment
        \\; Another line
        \\2021-01-01 open Assets:Cash
        \\
    );
}

test "blank line normalization" {
    // Multiple blank lines between decls should be collapsed to one
    try testNormalize(
        \\2021-01-01 open Assets:Cash
        \\
        \\
        \\
        \\2021-01-01 open Assets:Bank
        \\
    ,
        \\2021-01-01 open Assets:Cash
        \\
        \\2021-01-01 open Assets:Bank
        \\
    );
}

test "org mode blank lines" {
    // Org headings get one blank line around them
    try testRoundtrip(
        \\; comment
        \\
        \\* Heading
        \\
        \\2021-01-01 open Assets:Cash
        \\
    );
}

test "eol comment on directive" {
    try testRoundtrip(
        \\option "title" "Test" ; My ledger
        \\
    );
}

test "indented comment between postings" {
    try testRoundtrip(
        \\2021-01-01 * "Test"
        \\  Assets:Cash                          100 USD
        \\  ; between postings
        \\  Expenses:Food                       -100 USD
        \\
    );
}

test "eol comment on posting" {
    try testRoundtrip(
        \\2021-01-01 * "Test"
        \\  Assets:Cash                          100 USD ; cash account
        \\  Expenses:Food
        \\
    );
}

test "comment after last posting" {
    try testRoundtrip(
        \\2021-01-01 * "Test"
        \\  Assets:Cash                          100 USD
        \\  Expenses:Food
        \\  ; trailing comment
        \\
        \\2021-02-01 open Assets:Bank
        \\
    );
}

test "indented comment between meta lines" {
    try testRoundtrip(
        \\2021-01-01 * "Test"
        \\  foo: "bar"
        \\  ; comment between meta
        \\  baz: "qux"
        \\  Assets:Cash                          100 USD
        \\  Expenses:Food
        \\
    );
}

test "indented comment before meta" {
    try testRoundtrip(
        \\2021-01-01 open Assets:Cash
        \\  ; comment before meta
        \\  foo: "bar"
        \\
    );
}

test "indented comment after meta" {
    try testRoundtrip(
        \\2021-01-01 * "Test"
        \\  Assets:Cash                          100 USD
        \\    pkey: "pval"
        \\    ; comment after posting meta
        \\    pkey2: "pval2"
        \\  Expenses:Food
        \\
    );
}

test "indent normalization" {
    // Posting with wrong indentation (4 spaces) normalized to 2
    try testNormalize(
        \\2021-01-01 * "Test"
        \\    Assets:Cash    100 USD
        \\    Expenses:Food
        \\
    ,
        \\2021-01-01 * "Test"
        \\  Assets:Cash                          100 USD
        \\  Expenses:Food
        \\
    );

    // Entry meta with wrong indentation (4 spaces) normalized to 2
    try testNormalize(
        \\2021-01-01 open Assets:Cash
        \\    foo: "bar"
        \\
    ,
        \\2021-01-01 open Assets:Cash
        \\  foo: "bar"
        \\
    );

    // Posting meta with wrong indentation (2 spaces) normalized to 4
    try testNormalize(
        \\2021-01-01 * "Test"
        \\  Assets:Cash 100 USD
        \\  pkey: "pval"
        \\  Expenses:Food
        \\
    ,
        \\2021-01-01 * "Test"
        \\  Assets:Cash                          100 USD
        \\    pkey: "pval"
        \\  Expenses:Food
        \\
    );

    // Indented comment with wrong indentation normalized
    try testNormalize(
        \\2021-01-01 * "Test"
        \\      ; over-indented comment
        \\  Assets:Cash 100 USD
        \\  Expenses:Food
        \\
    ,
        \\2021-01-01 * "Test"
        \\  ; over-indented comment
        \\  Assets:Cash                          100 USD
        \\  Expenses:Food
        \\
    );

    // Posting meta comment with wrong indentation normalized to 4 spaces
    try testNormalize(
        \\2021-01-01 * "Test"
        \\  Assets:Cash 100 USD
        \\  ; wrong indent for posting meta comment
        \\    pkey: "pval"
        \\  Expenses:Food
        \\
    ,
        \\2021-01-01 * "Test"
        \\  Assets:Cash                          100 USD
        \\    ; wrong indent for posting meta comment
        \\    pkey: "pval"
        \\  Expenses:Food
        \\
    );
}

test "eol comment on close" {
    try testRoundtrip(
        \\2021-01-01 open Assets:Cash
        \\2021-12-31 close Assets:Cash ; closed
        \\
    );
}

test "eol comment on commodity" {
    try testRoundtrip(
        \\2021-01-01 commodity USD ; US Dollar
        \\
    );
}

test "eol comment on balance" {
    try testRoundtrip(
        \\2021-01-01 open Assets:Cash
        \\2021-01-01 balance Assets:Cash 100 USD ; check
        \\
    );
}

test "eol comment on pad" {
    try testRoundtrip(
        \\2021-01-01 open Assets:Cash
        \\2021-01-01 open Equity:Opening
        \\2021-01-01 pad Assets:Cash Equity:Opening ; padding
        \\
    );
}

test "eol comment on event" {
    try testRoundtrip(
        \\2021-01-01 event "location" "Berlin" ; moved
        \\
    );
}

test "eol comment on query" {
    try testRoundtrip(
        \\2021-01-01 query "cash" "SELECT *" ; all cash
        \\
    );
}

test "eol comment on note" {
    try testRoundtrip(
        \\2021-01-01 open Assets:Cash
        \\2021-01-01 note Assets:Cash "hello" ; noted
        \\
    );
}

test "eol comment on price" {
    try testRoundtrip(
        \\2021-01-01 price USD 0.85 EUR ; exchange rate
        \\
    );
}

test "eol comment on include" {
    try testRoundtrip(
        \\include "other.bean" ; included
        \\
    );
}

test "eol comment on plugin" {
    try testRoundtrip(
        \\plugin "mymodule" ; loaded
        \\
    );
}

test "eol comment on pushtag" {
    try testRoundtrip(
        \\pushtag #trip ; start of trip
        \\poptag #trip ; end of trip
        \\
    );
}

test "eol comment on pushmeta" {
    try testRoundtrip(
        \\pushmeta foo: "bar" ; meta start
        \\popmeta foo: "bar" ; meta end
        \\
    );
}

test "eol comment on posting without amount" {
    try testRoundtrip(
        \\2021-01-01 open Assets:Cash
        \\2021-01-01 open Expenses:Food
        \\
        \\2021-06-01 * "Lunch"
        \\  Assets:Cash                          -10 USD
        \\  Expenses:Food ; auto-balanced
        \\
    );
}

test "eol comment on entry meta" {
    try testRoundtrip(
        \\2021-01-01 open Assets:Cash
        \\  foo: "bar" ; meta comment
        \\
    );
}

test "eol comment on posting meta" {
    try testRoundtrip(
        \\2021-01-01 * "Test"
        \\  Assets:Cash                          100 USD
        \\    pkey: "pval" ; posting meta comment
        \\  Expenses:Food
        \\
    );
}

test "eol comment on transaction narration only" {
    try testRoundtrip(
        \\2021-01-01 open Assets:Cash
        \\2021-01-01 open Expenses:Food
        \\
        \\2021-06-01 * "Lunch" ; simple tx
        \\  Assets:Cash                          -10 USD
        \\  Expenses:Food
        \\
    );
}

test "eol comment on transaction with payee" {
    try testRoundtrip(
        \\2021-01-01 open Assets:Cash
        \\2021-01-01 open Expenses:Food
        \\
        \\2021-06-01 * "Restaurant" "Lunch" ; with payee
        \\  Assets:Cash                          -10 USD
        \\  Expenses:Food
        \\
    );
}

test "eol comment space normalization" {
    try testNormalize(
        \\2021-01-01 open Assets:Cash     ; too many spaces
        \\
    ,
        \\2021-01-01 open Assets:Cash ; too many spaces
        \\
    );
}

test "comment after cost spec" {
    try testRoundtrip(
        \\2025-01-01 * "Buy AAPL for EUR"
        \\  Assets:Stocks                         10 AAPL {10.00 EUR} ; fkjsel
        \\
    );
}

// Formatter alignment -----

test "posting alignment" {
    // Basic: align to longest account + 2 spaces
    try testRoundtrip(
        \\2021-01-01 * "Test"
        \\  Assets:Cash                       100    USD
        \\  Expenses:Food                       2.50 EUR
        \\
    );

    try testRoundtrip(
        \\2021-01-01 * "Test"
        \\  Assets:Bank:Checking:Main        1000.00 USD
        \\  Expenses:Food:Restaurant           50.0  USD
        \\  Equity:Opening-Balances         -1050.00 USD
        \\
    );

    // Flag
    try testRoundtrip(
        \\2021-01-01 * "Test"
        \\  ! Assets:Cash                        100 USD
        \\  Expenses:Food                       -100 USD
        \\
    );

    // Price annotation
    try testRoundtrip(
        \\2021-01-01 * "Test"
        \\  Assets:Stocks                         10 AAPL @ 150 USD
        \\  Assets:Cash                        -1500 USD
        \\
    );

    // Cost spec and price annotation
    try testRoundtrip(
        \\2021-01-01 * "Test"
        \\  Assets:Stocks                         10 AAPL {2022-01-01} @   15 USD
        \\  Assets:Cash                        -1500 USD  {4 USD}      @@ 200 APPL
        \\
    );
}

fn testParse(source: [:0]const u8) !void {
    const alloc = std.testing.allocator;

    var uri = try Uri.from_relative_to_cwd(alloc, "dummy.bean");
    defer uri.deinit(alloc);

    var ast = try Ast.parse(alloc, uri, source);
    defer ast.deinit();

    if (ast.errors.items.len > 0) {
        try ast.errors.items[0].print(alloc);
        return error.ParseError;
    }
}

fn testNormalize(source: [:0]const u8, expected: [:0]const u8) !void {
    const alloc = std.testing.allocator;

    var uri = try Uri.from_relative_to_cwd(alloc, "dummy.bean");
    defer uri.deinit(alloc);

    var ast = try Ast.parse(alloc, uri, source);
    defer ast.deinit();
    if (ast.errors.items.len > 0) {
        try ast.errors.items[0].print(alloc);
        return error.ParseError;
    }

    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();

    const Render = @import("Renderer.zig");
    try Render.render(alloc, &allocating.writer, &ast);

    try std.testing.expectEqualStrings(expected, allocating.written());
}

fn testRoundtrip(source: [:0]const u8) !void {
    const alloc = std.testing.allocator;

    var uri = try Uri.from_relative_to_cwd(alloc, "dummy.bean");
    defer uri.deinit(alloc);

    var ast = try Ast.parse(alloc, uri, source);
    defer ast.deinit();
    if (ast.errors.items.len > 0) {
        try ast.errors.items[0].print(alloc);
        return error.ParseError;
    }

    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();

    const Render = @import("Renderer.zig");
    try Render.render(alloc, &allocating.writer, &ast);

    try std.testing.expectEqualStrings(source, allocating.written());
}
