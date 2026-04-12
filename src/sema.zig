//! Converts an AST into Data (semantic analysis)
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

pub fn convert(
    alloc: Allocator,
    ast: *Ast,
    uri: Uri,
    is_root: bool,
) !struct { Data, Data.Imports.Slice } {
    var data = Data{
        .alloc = alloc,
        .postings = .{},
        .tagslinks = .{},
        .meta = .{},
        .currencies = .{},
        .tokens = .{},
        .entries = .{},
        .source = ast.source,
        .uri = uri,
        .config = Data.Config.init(alloc),
        .errors = .{},
    };
    errdefer data.deinit();

    // Copy tokens from AST
    data.tokens = ast.tokens.clone(alloc) catch return error.OutOfMemory;

    // Copy parse errors from AST
    for (ast.errors.items) |err| {
        try data.errors.append(alloc, err);
    }

    var converter = Converter{
        .alloc = alloc,
        .ast = ast,
        .uri = uri,
        .is_root = is_root,
        .entries = &data.entries,
        .postings = &data.postings,
        .tagslinks = &data.tagslinks,
        .meta = &data.meta,
        .currencies = &data.currencies,
        .config = &data.config,
        .imports = .{},
        .active_tags = std.StringHashMap(void).init(alloc),
        .active_meta = std.StringHashMap([]const u8).init(alloc),
        .errors = &data.errors,
    };
    defer converter.imports.deinit(alloc);
    defer converter.active_tags.deinit();
    defer converter.active_meta.deinit();

    try converter.walkRoot();

    return .{ data, try converter.imports.toOwnedSlice(alloc) };
}

const Converter = struct {
    alloc: Allocator,
    ast: *Ast,
    uri: Uri,
    is_root: bool,

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

    fn tok(self: *Converter, index: Ast.TokenIndex) Lexer.Token {
        return self.ast.tokens.items[@intFromEnum(index)];
    }

    fn tokSlice(self: *Converter, index: Ast.TokenIndex) []const u8 {
        return self.tok(index).slice;
    }

    fn optTok(self: *Converter, index: Ast.OptionalTokenIndex) ?Lexer.Token {
        const i = index.unwrap() orelse return null;
        return self.tok(i);
    }

    fn optTokSlice(self: *Converter, index: Ast.OptionalTokenIndex) ?[]const u8 {
        const t = self.optTok(index) orelse return null;
        return t.slice;
    }

    fn warnAt(self: *Converter, token: Lexer.Token, msg: ErrorDetails.Tag) !void {
        try self.errors.append(self.alloc, .{
            .tag = msg,
            .token = token,
            .uri = self.uri,
            .source = self.ast.source,
            .severity = .warn,
        });
    }

    fn walkRoot(self: *Converter) !void {
        for (self.ast.root()) |decl_index| {
            const n = self.ast.node(decl_index);
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
    }

    fn handlePushtag(self: *Converter, tag_tok: Ast.TokenIndex) !void {
        const slice = self.tokSlice(tag_tok);
        try self.active_tags.put(slice, {});
    }

    fn handlePoptag(self: *Converter, tag_tok: Ast.TokenIndex) void {
        const slice = self.tokSlice(tag_tok);
        _ = self.active_tags.remove(slice);
    }

    fn handlePushmeta(self: *Converter, kv: Ast.KeyValue) !void {
        try self.active_meta.put(self.tokSlice(kv.key), self.tokSlice(kv.value));
    }

    fn handlePopmeta(self: *Converter, kv: Ast.KeyValue) void {
        _ = self.active_meta.remove(self.tokSlice(kv.key));
    }

    fn handleOption(self: *Converter, kv: Ast.KeyValue) !void {
        if (self.is_root) {
            try self.config.addOption(self.tokSlice(kv.key), self.tokSlice(kv.value));
        }
    }

    fn handleInclude(self: *Converter, file_tok: Ast.TokenIndex) !void {
        const file_token = self.tok(file_tok);
        const slice = file_token.slice;
        try self.imports.append(self.alloc, .{
            .path = slice[1 .. slice.len - 1],
            .token = file_token,
        });
    }

    fn handlePlugin(self: *Converter, plugin_tok: Ast.TokenIndex) !void {
        if (self.is_root) {
            try self.config.addPlugin(self.tokSlice(plugin_tok));
        }
    }

    fn convertEntry(self: *Converter, extra: Ast.ExtraIndex) !void {
        const entry_data = self.ast.getExtra(extra, Node.Entry);
        const date_token = self.tok(entry_data.date);
        const date = Date.fromSlice(date_token.slice) catch return; // skip invalid dates

        const tagslinks = try self.convertTagsLinks(entry_data.tagslinks);
        const meta = try self.convertMeta(entry_data.meta, true);

        const payload_node = self.ast.node(entry_data.payload);
        const payload: Data.Entry.Payload = switch (payload_node) {
            .transaction => |tx_extra| try self.convertTransaction(tx_extra),
            .open => |open_extra| self.convertOpen(open_extra),
            .close => |account_tok| .{ .close = .{ .account = self.tok(account_tok) } },
            .commodity => |currency_tok| .{ .commodity = .{ .currency = self.tokSlice(currency_tok) } },
            .pad => |pad| .{ .pad = .{
                .account = self.tok(pad.account),
                .pad_to = self.tok(pad.pad_to),
            } },
            .pnl => |pnl| .{ .pnl = .{
                .account = self.tok(pnl.account),
                .income_account = self.tok(pnl.income_account),
            } },
            .balance => |bal_extra| self.convertBalance(bal_extra),
            .price_decl => |pd| self.convertPriceDecl(pd),
            .event => |kv| .{ .event = .{
                .variable = self.tokSlice(kv.key),
                .value = self.tokSlice(kv.value),
            } },
            .query => |kv| .{ .query = .{
                .name = self.tokSlice(kv.key),
                .sql = self.tokSlice(kv.value),
            } },
            .note => |kv| .{ .note = .{
                .account = self.tok(kv.key),
                .note = self.tokSlice(kv.value),
            } },
            .document => |kv| .{ .document = .{
                .account = self.tok(kv.key),
                .filename = self.tokSlice(kv.value),
            } },
            else => return, // skip unknown nodes
        };

        try self.entries.append(self.alloc, Data.Entry{
            .date = date,
            .main_token = date_token,
            .payload = payload,
            .tagslinks = tagslinks,
            .meta = meta,
        });
    }

    fn convertTransaction(self: *Converter, tx_extra: Ast.ExtraIndex) !Data.Entry.Payload {
        const tx = self.ast.getExtra(tx_extra, Node.Transaction);
        const flag_token = self.tok(tx.flag);

        if (std.mem.eql(u8, flag_token.slice, "!")) try self.warnAt(flag_token, .flagged);

        var payee = self.optTokSlice(tx.payee);
        var narration = self.optTokSlice(tx.narration);

        // AstParser already swaps payee/narration when there's only one string,
        // so payee=null and narration=the single string. No swap needed here.
        _ = &payee;
        _ = &narration;

        const postings_top = self.postings.len;
        for (self.ast.list(tx.postings)) |posting_index| {
            try self.convertPosting(posting_index);
        }
        const postings = Data.Range.create(postings_top, self.postings.len);

        return .{ .transaction = .{
            .flag = flag_token,
            .payee = payee,
            .narration = narration,
            .postings = postings,
        } };
    }

    fn convertPosting(self: *Converter, posting_index: Node.Index) !void {
        const n = self.ast.node(posting_index);
        const p = self.ast.getExtra(n.posting, Node.Posting);

        const flag_tok = self.optTok(p.flag);
        const account_tok = self.tok(p.account);
        const amount = self.convertAmount(p.amount);

        if (flag_tok) |f| {
            if (std.mem.eql(u8, f.slice, "!")) try self.warnAt(f, .flagged);
        }

        var lot_spec = if (p.lot_spec.unwrap()) |ls_index| self.convertLotSpec(ls_index) else null;
        var price = if (p.price.unwrap()) |price_index| self.convertPriceAnnotation(price_index) else null;

        const meta = try self.convertMeta(p.meta, false);

        // Infer price from cost spec for backwards-compatibility
        if (lot_spec) |*ls| {
            if (ls.price) |lot_price| {
                if (lot_price.isComplete()) {
                    if (price == null) {
                        price = .{
                            .amount = lot_price,
                            .total = false,
                        };
                        ls.price = null;
                        try self.warnAt(account_tok, .inferred_price);

                        // Remove the lot spec if it's empty after this operation
                        if (ls.date == null and ls.label == null)
                            lot_spec = null;
                    }
                }
            }
        }

        try self.postings.append(self.alloc, Data.Posting{
            .flag = flag_tok,
            .account = account_tok,
            .amount = amount,
            .lot_spec = lot_spec,
            .price = price,
            .meta = meta,
        });
    }

    fn convertAmount(self: *Converter, amount_index: Node.Index) Data.Amount {
        const n = self.ast.node(amount_index);
        const amt = n.amount;
        return .{
            .number = if (amt.number.unwrap()) |num_tok| self.parseNumber(num_tok) else null,
            .currency = self.optTokSlice(amt.currency),
        };
    }

    fn parseNumber(self: *Converter, num_tok: Ast.TokenIndex) ?Number {
        const num_i = @intFromEnum(num_tok);
        const slice = self.ast.tokens.items[num_i].slice;
        const is_negative = num_i > 0 and self.ast.tokens.items[num_i - 1].tag == .minus;
        const number = Number.fromSlice(slice) catch return null;
        return if (is_negative) number.negate() else number;
    }

    fn convertLotSpec(self: *Converter, ls_index: Node.Index) Data.LotSpec {
        const n = self.ast.node(ls_index);
        const ls = self.ast.getExtra(n.lot_spec, Node.LotSpec);

        var lot_price: ?Data.Amount = null;
        if (ls.price.unwrap()) |price_index| {
            const price_amount = self.convertAmount(price_index);
            if (price_amount.number != null or price_amount.currency != null) {
                lot_price = price_amount;
            }
        }

        const lot_date: ?Date = if (ls.date.unwrap()) |date_tok|
            Date.fromSlice(self.tokSlice(date_tok)) catch null
        else
            null;

        const label = self.optTokSlice(ls.label);

        return .{
            .price = lot_price,
            .date = lot_date,
            .label = label,
        };
    }

    fn convertPriceAnnotation(self: *Converter, price_index: Node.Index) Data.Price {
        const n = self.ast.node(price_index);
        const pa = n.price_annotation;
        const total = self.tok(pa.total).tag == .atat;
        const amount = self.convertAmount(pa.amount);
        return .{
            .amount = amount,
            .total = total,
        };
    }

    fn convertOpen(self: *Converter, open_extra: Ast.ExtraIndex) Data.Entry.Payload {
        const open = self.ast.getExtra(open_extra, Node.Open);
        const account_tok = self.tok(open.account);

        const currency_top = self.currencies.items.len;
        for (self.ast.tokenList(open.currencies)) |cur_tok| {
            self.currencies.append(self.alloc, self.tokSlice(cur_tok)) catch {};
        }
        const currencies = Data.Range.create(currency_top, self.currencies.items.len);

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
            .account = account_tok,
            .currencies = currencies,
            .booking_method = booking_method,
        } };
    }

    fn convertBalance(self: *Converter, bal_extra: Ast.ExtraIndex) Data.Entry.Payload {
        const bal = self.ast.getExtra(bal_extra, Node.Balance);
        const account_tok = self.tok(bal.account);
        const amount = self.convertAmount(bal.amount);
        const tolerance: ?Number = if (bal.tolerance.unwrap()) |tol_tok| self.parseNumber(tol_tok) else null;

        return .{ .balance = .{
            .account = account_tok,
            .amount = amount,
            .tolerance = tolerance,
        } };
    }

    fn convertPriceDecl(self: *Converter, pd: anytype) Data.Entry.Payload {
        const amount = self.convertAmount(pd.amount);
        return .{ .price = .{
            .currency = self.tokSlice(pd.currency),
            .amount = amount,
        } };
    }

    fn convertTagsLinks(self: *Converter, range: Node.Range) !?Data.Range {
        const tagslinks_top = self.tagslinks.len;

        // Explicit tags/links from the AST
        for (self.ast.tokenList(range)) |tag_tok| {
            const token = self.tok(tag_tok);
            const kind: Data.TagLink.Kind = switch (token.tag) {
                .tag => .tag,
                .link => .link,
                else => continue,
            };
            try self.tagslinks.append(self.alloc, Data.TagLink{
                .kind = kind,
                .token = token,
                .explicit = true,
            });
        }

        // Add tags from pushtag stack
        var tags_iter = self.active_tags.keyIterator();
        while (tags_iter.next()) |tag| {
            const synthetic_token = Lexer.Token{
                .tag = .tag,
                .slice = tag.*,
                .start_line = 0,
                .end_line = 0,
                .start_col = 0,
                .end_col = 0,
            };
            try self.tagslinks.append(self.alloc, Data.TagLink{
                .kind = .tag,
                .token = synthetic_token,
                .explicit = false,
            });
        }

        return Data.Range.create(tagslinks_top, self.tagslinks.len);
    }

    fn convertMeta(self: *Converter, range: Node.Range, add_from_stack: bool) !?Data.Range {
        const meta_top = self.meta.len;

        for (self.ast.list(range)) |kv_index| {
            const n = self.ast.node(kv_index);
            const kv = n.key_value;
            try self.meta.append(self.alloc, Data.KeyValue{
                .key = self.tok(kv.key),
                .value = self.tok(kv.value),
            });
        }

        // Add meta from pushmeta stack
        if (add_from_stack) {
            var meta_iter = self.active_meta.iterator();
            while (meta_iter.next()) |kv| {
                try self.meta.append(self.alloc, Data.KeyValue{
                    .key = Lexer.Token{ .slice = kv.key_ptr.*, .tag = .key, .start_line = 0, .end_line = 0, .start_col = 0, .end_col = 0 },
                    .value = Lexer.Token{ .slice = kv.value_ptr.*, .tag = .string, .start_line = 0, .end_line = 0, .start_col = 0, .end_col = 0 },
                });
            }
        }

        return Data.Range.create(meta_top, self.meta.len);
    }
};
