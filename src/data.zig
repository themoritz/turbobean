//! Data for one file.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Date = @import("date.zig").Date;
const Parser = @import("parser.zig");
const Number = @import("number.zig").Number;
const Lexer = @import("lexer.zig").Lexer;
const Solver = @import("solver.zig").Solver;
const Inventory = @import("inventory.zig");
const ErrorDetails = @import("ErrorDetails.zig");
const Uri = @import("Uri.zig");

const Self = @This();

alloc: Allocator,
source: [:0]const u8,
uri: Uri,
tokens: Tokens,
entries: Entries,
config: Config,
postings: Postings,
tagslinks: TagsLinks,
meta: Meta,
currencies: Currencies,

errors: std.ArrayList(ErrorDetails),

pub const Entries = std.ArrayList(Entry);
pub const Postings = std.MultiArrayList(Posting);
pub const TagsLinks = std.MultiArrayList(TagLink);
pub const Meta = std.MultiArrayList(KeyValue);
pub const Currencies = std.ArrayList([]const u8);
pub const Imports = std.ArrayList([]const u8);

pub const Tokens = std.ArrayList(Lexer.Token);

pub const Posting = struct {
    flag: ?Lexer.Token,
    account: Lexer.Token,
    amount: Amount,
    lot_spec: ?LotSpec,
    price: ?Price,
    meta: ?Range,
};

pub const Amount = struct {
    number: ?Number,
    currency: ?[]const u8,

    pub fn exists(amount: *const Amount) bool {
        return amount.number != null or amount.currency != null;
    }

    pub fn isComplete(a: *const Amount) bool {
        return a.number != null and a.currency != null;
    }
};

pub const LotSpec = struct {
    price: ?Amount,
    date: ?Date,
    label: ?[]const u8,
};

pub const Price = struct {
    amount: Amount,
    total: bool,
};

pub const Entry = struct {
    date: Date,
    main_token: Lexer.Token,
    tagslinks: ?Range,
    meta: ?Range,
    payload: Payload,

    pub const Payload = union(enum) {
        transaction: Transaction,
        open: Open,
        close: Close,
        commodity: Commodity,
        pad: Pad,
        balance: Balance,
        price: PriceDecl,
        event: Event,
        query: Query,
        note: Note,
        document: Document,
    };

    pub fn compare(ctx: void, self: Entry, other: Entry) bool {
        _ = ctx;
        switch (self.date.compare(other.date)) {
            .after => return true,
            else => return false,
        }
    }
};

pub const Config = struct {
    options: std.StringHashMap([]const u8),
    plugins: std.ArrayList([]const u8),

    pub fn init(alloc: Allocator) Config {
        return .{
            .options = std.StringHashMap([]const u8).init(alloc),
            .plugins = std.ArrayList([]const u8).init(alloc),
        };
    }

    pub fn deinit(self: *Config) void {
        self.options.deinit();
        self.plugins.deinit();
    }

    pub fn addOption(self: *Config, key: []const u8, value: []const u8) !void {
        if (!self.options.contains(key)) {
            try self.options.put(key, value);
        }
    }

    pub fn addPlugin(self: *Config, plugin: []const u8) !void {
        try self.plugins.append(plugin);
    }
};

pub const Open = struct {
    account: Lexer.Token,
    currencies: ?Range,
    booking: ?Inventory.Booking,
};

pub const Close = struct {
    account: Lexer.Token,
};

pub const Commodity = struct {
    currency: []const u8,
};

pub const Pad = struct {
    account: Lexer.Token,
    pad_to: Lexer.Token,
    /// Index into synthetic transactions that Project generates when
    /// processing pads.
    synthetic_index: ?usize = null,
};

pub const Balance = struct {
    account: Lexer.Token,
    amount: Amount,
    tolerance: ?Number,
};

pub const PriceDecl = struct {
    currency: []const u8,
    amount: Amount,
};

pub const Event = struct {
    variable: []const u8,
    value: []const u8,
};

pub const Query = struct {
    name: []const u8,
    sql: []const u8,
};

pub const Note = struct {
    account: Lexer.Token,
    note: []const u8,
};

pub const Document = struct {
    account: Lexer.Token,
    filename: []const u8,
};

pub const Transaction = struct {
    flag: Lexer.Token,
    payee: ?[]const u8,
    narration: ?[]const u8,
    postings: ?Range,
};

pub const Range = struct {
    start: usize,
    end: usize, // exclusive

    pub fn create(start: usize, end: usize) ?Range {
        if (start == end) return null;
        return .{
            .start = start,
            .end = end,
        };
    }

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }
};

pub const TagLink = struct {
    kind: Kind,
    slice: []const u8,

    pub const Kind = enum {
        tag,
        link,
    };
};

pub const KeyValue = struct {
    key: Lexer.Token,
    value: Lexer.Token,
};

pub fn parse(alloc: Allocator, source: [:0]const u8) !Self {
    const owned_source = try alloc.dupeZ(u8, source);
    var uri = try Uri.from_relative_to_cwd(alloc, "dummy.bean");
    defer uri.deinit(alloc);
    const self, const imports = try loadSource(alloc, uri, owned_source, true);
    defer self.alloc.free(imports);
    return self;
}

/// Takes ownership of source.
pub fn loadSource(alloc: Allocator, uri: Uri, source: [:0]const u8, is_root: bool) !struct { Self, Imports.Slice } {
    var self = Self{
        .alloc = alloc,
        .postings = .{},
        .tagslinks = .{},
        .meta = .{},
        .currencies = Currencies.init(alloc),
        .tokens = Tokens.init(alloc),
        .entries = Entries.init(alloc),
        .source = source,
        .uri = uri,
        .config = Config.init(alloc),
        .errors = std.ArrayList(ErrorDetails).init(alloc),
    };
    errdefer self.deinit();

    var lexer = Lexer.init(source);

    while (true) {
        const token = lexer.next();
        try self.tokens.append(token);
        if (token.tag == .eof) break;
    }

    var parser: Parser = .{
        .alloc = self.alloc,
        .tokens = self.tokens,
        .tok_i = 0,
        .is_root = is_root,
        .uri = uri,
        .source = source,
        .entries = &self.entries,
        .postings = &self.postings,
        .tagslinks = &self.tagslinks,
        .meta = &self.meta,
        .currencies = &self.currencies,
        .config = &self.config,
        .imports = Imports.init(self.alloc),
        .active_tags = std.StringHashMap(void).init(self.alloc),
        .active_meta = std.StringHashMap([]const u8).init(self.alloc),
        .errors = &self.errors,
    };
    defer parser.imports.deinit();
    defer parser.active_tags.deinit();
    defer parser.active_meta.deinit();

    try parser.parse();

    return .{ self, try parser.imports.toOwnedSlice() };
}

pub fn balanceTransactions(self: *Self) !void {
    var one: ?Number = Number.fromFloat(1);
    var solver = Solver.init(self.alloc);
    defer solver.deinit();

    for (self.entries.items) |entry| {
        switch (entry.payload) {
            .transaction => |tx| {
                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        const number: *?Number = &self.postings.items(.amount)[i].number;
                        var price: *?Number = undefined;
                        var currency: *?[]const u8 = undefined;

                        if (self.postings.items(.price)[i]) |_| {
                            // TODO: Turn this into proper error
                            std.debug.assert(self.postings.items(.amount)[i].currency != null);
                            currency = &self.postings.items(.price)[i].?.amount.currency;
                            price = &self.postings.items(.price)[i].?.amount.number;
                        } else {
                            currency = &self.postings.items(.amount)[i].currency;
                            price = &one;
                        }

                        try solver.addTriple(price, number, currency);
                    }
                    solver.solve() catch |err| {
                        const tag: ErrorDetails.Tag = switch (err) {
                            error.DoesNotBalance => .tx_does_not_balance,
                            error.NoSolution => .tx_no_solution,
                            error.TooManyVariables => .tx_too_many_variables,
                            error.DivisionByZero => .tx_division_by_zero,
                            error.MultipleSolutions => .tx_multiple_solutions,
                            else => return err,
                        };
                        try self.addError(entry.main_token, self.uri, tag);
                    };
                }
            },
            else => continue,
        }
    }
}

fn addError(self: *Self, token: Lexer.Token, uri: Uri, tag: ErrorDetails.Tag) !void {
    try self.errors.append(ErrorDetails{
        .tag = tag,
        .token = token,
        .uri = uri,
        .source = self.source,
        .expected = null,
    });
}

pub fn deinit(self: *Self) void {
    self.alloc.free(self.source);

    self.tokens.deinit();
    self.entries.deinit();
    self.currencies.deinit();
    self.postings.deinit(self.alloc);
    self.tagslinks.deinit(self.alloc);
    self.meta.deinit(self.alloc);
    self.config.deinit();

    self.errors.deinit();
}
