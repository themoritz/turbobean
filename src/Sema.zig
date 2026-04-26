//! Converts an AST into Data (semantic analysis).
//!
//! Sema owns the construction side: it touches Data's private storage directly
//! (intern pools, token_interned side-table, SoA lists). Consumers should go
//! through views/iterators instead.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Data = @import("data.zig");
const Date = @import("date.zig").Date;
const Lexer = @import("lexer.zig").Lexer;
const Number = @import("number.zig").Number;
const Inventory = @import("inventory.zig");
const ErrorDetails = @import("ErrorDetails.zig");
const Uri = @import("Uri.zig");
const Node = Ast.Node;
const Self = @This();

alloc: Allocator,
data: *Data,
is_root: bool,

// Owned
imports: std.ArrayList(Data.Import),
/// Active pushtag stack. Value is the original `pushtag` token, used to
/// attribute synthesized (implicit) tags to a source location.
active_tags: std.StringHashMap(Ast.TokenIndex),
/// Active pushmeta stack. Value holds original key/value token indices so
/// synthesized meta entries inherit real source locations.
active_meta: std.StringHashMap(StackedKV),

const StackedKV = struct {
    key_tok: Ast.TokenIndex,
    value_tok: Ast.TokenIndex,
};

pub fn init(alloc: Allocator, data: *Data, is_root: bool) Self {
    return .{
        .alloc = alloc,
        .data = data,
        .is_root = is_root,
        .imports = .{},
        .active_tags = .init(alloc),
        .active_meta = .init(alloc),
    };
}

pub fn deinit(self: *Self) void {
    self.imports.deinit(self.alloc);
    self.active_tags.deinit();
    self.active_meta.deinit();
}

// --- token helpers ----------------------------------------------------------

fn tok(self: *Self, index: Ast.TokenIndex) Lexer.Token {
    return self.data.ast.tokens.items[@intFromEnum(index)];
}

fn tokSlice(self: *Self, index: Ast.TokenIndex) []const u8 {
    return self.tok(index).slice;
}

fn optTokSlice(self: *Self, index: Ast.OptionalTokenIndex) ?[]const u8 {
    const i = index.unwrap() orelse return null;
    return self.tokSlice(i);
}

// --- intern helpers ---------------------------------------------------------

fn internAccount(self: *Self, t: Ast.TokenIndex) !Data.AccountIndex {
    const idx = try self.data.accounts.intern(self.alloc, self.tokSlice(t));
    self.data.token_interned.items[@intFromEnum(t)] = @intFromEnum(idx);
    return idx;
}

fn internCurrency(self: *Self, t: Ast.TokenIndex) !Data.CurrencyIndex {
    const idx = try self.data.currencies.intern(self.alloc, self.tokSlice(t));
    self.data.token_interned.items[@intFromEnum(t)] = @intFromEnum(idx);
    return idx;
}

fn internCurrencyOpt(self: *Self, t: Ast.OptionalTokenIndex) !Data.OptionalCurrencyIndex {
    const i = t.unwrap() orelse return .none;
    return (try self.internCurrency(i)).toOptional();
}

// --- error reporting --------------------------------------------------------

fn warnAt(self: *Self, token: Ast.TokenIndex, msg: ErrorDetails.Tag) !void {
    try self.data.addWarning(token, self.data.uri, msg);
}

// --- top level --------------------------------------------------------------

pub fn run(self: *Self) !Data.Imports {
    for (self.data.ast.root()) |decl_index| {
        const n = self.data.ast.node(decl_index);
        switch (n) {
            .entry => |extra| try self.convertEntry(extra),
            .pushtag => |tag_tok| try self.handlePushtag(tag_tok),
            .poptag => |tag_tok| self.handlePoptag(tag_tok),
            .pushmeta => |kv| try self.handlePushmeta(kv),
            .popmeta => |kv| self.handlePopmeta(kv),
            .option => |kv| try self.handleOption(kv),
            .include => |file_tok| try self.handleInclude(file_tok),
            .plugin => |plugin_tok| try self.handlePlugin(plugin_tok),
            else => {},
        }
    }
    return self.imports.toOwnedSlice(self.alloc);
}

fn handlePushtag(self: *Self, tag_tok: Ast.TokenIndex) !void {
    try self.active_tags.put(self.tokSlice(tag_tok), tag_tok);
}

fn handlePoptag(self: *Self, tag_tok: Ast.TokenIndex) void {
    _ = self.active_tags.remove(self.tokSlice(tag_tok));
}

fn handlePushmeta(self: *Self, kv: Ast.KeyValue) !void {
    try self.active_meta.put(self.tokSlice(kv.key), .{
        .key_tok = kv.key,
        .value_tok = kv.value,
    });
}

fn handlePopmeta(self: *Self, kv: Ast.KeyValue) void {
    _ = self.active_meta.remove(self.tokSlice(kv.key));
}

fn handleOption(self: *Self, kv: Ast.KeyValue) !void {
    if (self.is_root) {
        try self.data.config.addOption(self.tokSlice(kv.key), self.tokSlice(kv.value));
    }
}

fn handleInclude(self: *Self, file_tok: Ast.TokenIndex) !void {
    const file_token = self.tok(file_tok);
    const slice = file_token.slice;
    try self.imports.append(self.alloc, .{
        .path = slice[1 .. slice.len - 1],
        .token = file_token,
    });
}

fn handlePlugin(self: *Self, plugin_tok: Ast.TokenIndex) !void {
    if (self.is_root) {
        try self.data.config.addPlugin(self.tokSlice(plugin_tok));
    }
}

// --- entries ----------------------------------------------------------------

fn convertEntry(self: *Self, extra: Ast.ExtraIndex) !void {
    const entry_data = self.data.ast.getExtra(extra, Node.Entry);
    const date = Date.fromSlice(self.tokSlice(entry_data.date)) catch return; // skip invalid dates

    const tagslinks = try self.convertTagsLinks(entry_data.tagslinks);
    const meta = try self.convertMeta(entry_data.meta, true);

    const payload_node = self.data.ast.node(entry_data.payload);
    const payload: Data.Entry.Payload = switch (payload_node) {
        .transaction => |tx_extra| try self.convertTransaction(tx_extra),
        .open => |open_extra| try self.convertOpen(open_extra),
        .close => |account_tok| blk: {
            _ = try self.internAccount(account_tok);
            break :blk .{ .close = .{ .account = account_tok } };
        },
        .commodity => |currency_tok| blk: {
            const cur = try self.internCurrency(currency_tok);
            break :blk .{ .commodity = .{ .currency = cur } };
        },
        .pad => |pad| blk: {
            _ = try self.internAccount(pad.account);
            _ = try self.internAccount(pad.pad_to);
            break :blk .{ .pad = .{
                .account = pad.account,
                .pad_to = pad.pad_to,
            } };
        },
        .pnl => |pnl| blk: {
            _ = try self.internAccount(pnl.account);
            _ = try self.internAccount(pnl.income_account);
            break :blk .{ .pnl = .{
                .account = pnl.account,
                .income_account = pnl.income_account,
            } };
        },
        .balance => |bal_extra| try self.convertBalance(bal_extra),
        .price_decl => |pd| try self.convertPriceDecl(pd),
        .event => |kv| .{ .event = .{ .variable = kv.key, .value = kv.value } },
        .query => |kv| .{ .query = .{ .name = kv.key, .sql = kv.value } },
        .note => |kv| blk: {
            _ = try self.internAccount(kv.key);
            break :blk .{ .note = .{ .account = kv.key, .note = kv.value } };
        },
        .document => |kv| blk: {
            _ = try self.internAccount(kv.key);
            break :blk .{ .document = .{ .account = kv.key, .filename = kv.value } };
        },
        else => return,
    };

    try self.data.entries.append(self.alloc, Data.Entry{
        .date = date,
        .main_token = entry_data.date,
        .tagslinks = tagslinks,
        .meta = meta,
        .payload = payload,
    });
}

fn convertTransaction(self: *Self, tx_extra: Ast.ExtraIndex) !Data.Entry.Payload {
    const tx = self.data.ast.getExtra(tx_extra, Node.Transaction);

    if (std.mem.eql(u8, self.tokSlice(tx.flag), "!")) try self.warnAt(tx.flag, .flagged);

    const postings_top = self.data.postings.len;
    for (self.data.ast.list(tx.postings)) |posting_index| {
        try self.convertPosting(posting_index);
    }
    const postings = Data.Range.from(postings_top, self.data.postings.len);

    return .{ .transaction = .{
        .flag = tx.flag,
        .payee = tx.payee,
        .narration = tx.narration,
        .postings = postings,
    } };
}

fn convertPosting(self: *Self, posting_index: Node.Index) !void {
    const n = self.data.ast.node(posting_index);
    const p = self.data.ast.getExtra(n.posting, Node.Posting);

    _ = try self.internAccount(p.account);
    if (p.flag.unwrap()) |flag_tok| {
        if (std.mem.eql(u8, self.tokSlice(flag_tok), "!")) try self.warnAt(flag_tok, .flagged);
    }

    const amount = try self.convertAmount(p.amount);

    var lot_spec: ?Data.LotSpec = if (p.lot_spec.unwrap()) |ls_idx| try self.convertLotSpec(ls_idx) else null;
    var price: ?Data.Price = if (p.price.unwrap()) |pr_idx| try self.convertPriceAnnotation(pr_idx) else null;

    const meta = try self.convertMeta(p.meta, false);

    // Beancount backwards-compat: when a lot spec carries a complete price
    // and no price annotation exists, promote it to the price annotation.
    if (lot_spec) |*ls| {
        if (ls.price != null and ls.price_currency.unwrap() != null and price == null) {
            price = .{
                .amount = ls.price,
                .amount_currency = ls.price_currency,
                .total = false,
            };
            ls.price = null;
            ls.price_currency = .none;
            try self.warnAt(p.account, .inferred_price);

            if (ls.date == null and ls.label == .none) lot_spec = null;
        }
    }

    const price_idx: Data.OptionalPriceIndex = if (price) |pr| blk: {
        const idx: Data.PriceIndex = @enumFromInt(self.data.prices.items.len);
        try self.data.prices.append(self.alloc, pr);
        break :blk idx.toOptional();
    } else .none;

    const lot_spec_idx: Data.OptionalLotSpecIndex = if (lot_spec) |ls| blk: {
        const idx: Data.LotSpecIndex = @enumFromInt(self.data.lot_specs.items.len);
        try self.data.lot_specs.append(self.alloc, ls);
        break :blk idx.toOptional();
    } else .none;

    try self.data.postings.append(self.alloc, Data.Posting{
        .account = p.account,
        .flag = p.flag,
        .amount_number = Data.PackedNumber.pack(amount.number),
        .amount_currency = amount.currency,
        .price = price_idx,
        .lot_spec = lot_spec_idx,
        .meta = meta,
        .ast_node = posting_index.toOptional(),
    });
}

const AmountResolved = struct {
    number: ?Number,
    currency: Data.OptionalCurrencyIndex,
};

fn convertAmount(self: *Self, amount_index: Node.Index) !AmountResolved {
    const n = self.data.ast.node(amount_index);
    const amt = n.amount;
    const number: ?Number = if (amt.number.unwrap()) |num_tok| self.parseNumber(num_tok) else null;
    const currency = try self.internCurrencyOpt(amt.currency);
    return .{ .number = number, .currency = currency };
}

fn parseNumber(self: *Self, num_tok: Ast.TokenIndex) ?Number {
    const num_i = @intFromEnum(num_tok);
    const slice = self.data.ast.tokens.items[num_i].slice;
    const is_negative = num_i > 0 and self.data.ast.tokens.items[num_i - 1].tag == .minus;
    const number = Number.fromSlice(slice) catch return null;
    return if (is_negative) number.negate() else number;
}

fn convertLotSpec(self: *Self, ls_index: Node.Index) !Data.LotSpec {
    const n = self.data.ast.node(ls_index);
    const ls = self.data.ast.getExtra(n.lot_spec, Node.LotSpec);

    var lot_number: ?Number = null;
    var lot_currency: Data.OptionalCurrencyIndex = .none;
    if (ls.price.unwrap()) |price_index| {
        const amt = try self.convertAmount(price_index);
        // Keep only non-empty amount (match old behaviour).
        if (amt.number != null or amt.currency.unwrap() != null) {
            lot_number = amt.number;
            lot_currency = amt.currency;
        }
    }

    const lot_date: ?Date = if (ls.date.unwrap()) |date_tok|
        Date.fromSlice(self.tokSlice(date_tok)) catch null
    else
        null;

    return .{
        .price = lot_number,
        .price_currency = lot_currency,
        .date = lot_date,
        .label = ls.label,
    };
}

fn convertPriceAnnotation(self: *Self, price_index: Node.Index) !Data.Price {
    const n = self.data.ast.node(price_index);
    const pa = n.price_annotation;
    const total = self.tok(pa.total).tag == .atat;
    const amount = try self.convertAmount(pa.amount);
    return .{
        .amount = amount.number,
        .amount_currency = amount.currency,
        .total = total,
    };
}

fn convertOpen(self: *Self, open_extra: Ast.ExtraIndex) !Data.Entry.Payload {
    const open = self.data.ast.getExtra(open_extra, Node.Open);
    _ = try self.internAccount(open.account);

    const cur_top = self.data.open_currencies.items.len;
    for (self.data.ast.tokenList(open.currencies)) |cur_tok| {
        const idx = try self.internCurrency(cur_tok);
        try self.data.open_currencies.append(self.alloc, idx);
    }
    const currencies = Data.Range.from(cur_top, self.data.open_currencies.items.len);

    const booking_method: ?Inventory.BookingMethod = if (self.optTokSlice(open.booking_method)) |b|
        if (std.mem.eql(u8, b, "\"FIFO\""))
            .fifo
        else if (std.mem.eql(u8, b, "\"LIFO\""))
            .lifo
        else if (std.mem.eql(u8, b, "\"STRICT\""))
            .strict
        else
            null
    else
        null;

    return .{ .open = .{
        .account = open.account,
        .currencies = currencies,
        .booking_method = booking_method,
    } };
}

fn convertBalance(self: *Self, bal_extra: Ast.ExtraIndex) !Data.Entry.Payload {
    const bal = self.data.ast.getExtra(bal_extra, Node.Balance);
    _ = try self.internAccount(bal.account);
    const amount = try self.convertAmount(bal.amount);
    const tolerance: ?Number = if (bal.tolerance.unwrap()) |tol_tok| self.parseNumber(tol_tok) else null;
    return .{ .balance = .{
        .account = bal.account,
        .amount = Data.PackedNumber.pack(amount.number),
        .amount_currency = amount.currency.unwrap().?,
        .tolerance = Data.PackedNumber.pack(tolerance),
    } };
}

fn convertPriceDecl(self: *Self, pd: anytype) !Data.Entry.Payload {
    const cur_idx = try self.internCurrency(pd.currency);
    const amount = try self.convertAmount(pd.amount);
    return .{ .price = .{
        .currency = cur_idx,
        .amount_number = Data.PackedNumber.pack(amount.number),
        .amount_currency = amount.currency.unwrap() orelse unreachable,
    } };
}

fn convertTagsLinks(self: *Self, range: Node.Range) !Data.Range {
    const tagslinks_top = self.data.tagslinks.len;

    // Explicit tags/links from the AST
    for (self.data.ast.tokenList(range)) |tag_tok| {
        const token = self.tok(tag_tok);
        const kind: Data.TagLink.Kind = switch (token.tag) {
            .tag => .tag,
            .link => .link,
            else => continue,
        };
        try self.data.tagslinks.append(self.alloc, Data.TagLink{
            .kind = kind,
            .token = tag_tok,
            .explicit = true,
        });
    }

    // Implicit tags from active pushtag stack.
    var tags_iter = self.active_tags.iterator();
    while (tags_iter.next()) |kv| {
        try self.data.tagslinks.append(self.alloc, Data.TagLink{
            .kind = .tag,
            .token = kv.value_ptr.*,
            .explicit = false,
        });
    }

    return Data.Range.from(tagslinks_top, self.data.tagslinks.len);
}

fn convertMeta(self: *Self, range: Node.Range, add_from_stack: bool) !Data.Range {
    const meta_top = self.data.meta.len;

    for (self.data.ast.list(range)) |kv_index| {
        const n = self.data.ast.node(kv_index);
        const kv = n.key_value;
        try self.data.meta.append(self.alloc, Data.KeyValue{
            .key = kv.key,
            .value = kv.value,
        });
    }

    if (add_from_stack) {
        var meta_iter = self.active_meta.iterator();
        while (meta_iter.next()) |kv| {
            try self.data.meta.append(self.alloc, Data.KeyValue{
                .key = kv.value_ptr.key_tok,
                .value = kv.value_ptr.value_tok,
            });
        }
    }

    return Data.Range.from(meta_top, self.data.meta.len);
}
