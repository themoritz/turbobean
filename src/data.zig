//! Data for one file.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Date = @import("date.zig").Date;
const Parser = @import("parser.zig");
const Number = @import("number.zig").Number;
const Lexer = @import("lexer.zig").Lexer;
const Solver = @import("solver.zig").Solver;
const ErrorDetails = @import("ErrorDetails.zig");

const Self = @This();

alloc: Allocator,
source: [:0]const u8,
entries: Entries,
config: Config,
postings: Postings,
tagslinks: TagsLinks,
meta: Meta,
costcomps: CostComps,
currencies: Currencies,

errors: std.ArrayList(ErrorDetails),

pub const Entries = std.ArrayList(Entry);
pub const Postings = std.MultiArrayList(Posting);
pub const TagsLinks = std.MultiArrayList(TagLink);
pub const Meta = std.MultiArrayList(KeyValue);
pub const CostComps = std.ArrayList(CostComp);
pub const Currencies = std.ArrayList([]const u8);
pub const Imports = std.ArrayList([]const u8);

pub const Tokens = std.ArrayList(Lexer.Token);

pub const Posting = struct {
    flag: ?Lexer.Token,
    account: []const u8,
    amount: Amount,
    cost: ?Cost,
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

pub const Cost = struct {
    comps: ?Range,
    total: bool,
};

pub const CostComp = union(enum) {
    amount: Amount,
    date: Date,
    label: []const u8,
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
    account: []const u8,
    currencies: ?Range,
    booking: ?[]const u8,
};

pub const Close = struct {
    account: []const u8,
};

pub const Commodity = struct {
    currency: []const u8,
};

pub const Pad = struct {
    account: []const u8,
    pad_to: []const u8,
};

pub const Balance = struct {
    account: []const u8,
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
    account: []const u8,
    note: []const u8,
};

pub const Document = struct {
    account: []const u8,
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
    const self, const imports = try loadSource(alloc, owned_source, true);
    defer self.alloc.free(imports);
    return self;
}

/// Takes ownership of source.
pub fn loadSource(alloc: Allocator, source: [:0]const u8, is_root: bool) !struct { Self, Imports.Slice } {
    var self = Self{
        .alloc = alloc,
        .postings = .{},
        .tagslinks = .{},
        .meta = .{},
        .costcomps = CostComps.init(alloc),
        .currencies = Currencies.init(alloc),
        .entries = Entries.init(alloc),
        .source = source,
        .config = Config.init(alloc),
        .errors = std.ArrayList(ErrorDetails).init(alloc),
    };
    errdefer self.deinit();

    var lexer = Lexer.init(source);
    var tokens = Tokens.init(self.alloc);
    defer tokens.deinit();

    while (true) {
        const token = lexer.next();
        try tokens.append(token);
        if (token.tag == .eof) break;
    }

    var parser: Parser = .{
        .alloc = self.alloc,
        .tokens = tokens,
        .tok_i = 0,
        .is_root = is_root,
        .source_file = source,
        .entries = &self.entries,
        .postings = &self.postings,
        .tagslinks = &self.tagslinks,
        .meta = &self.meta,
        .costcomps = &self.costcomps,
        .currencies = &self.currencies,
        .config = &self.config,
        .imports = Imports.init(self.alloc),
        .active_tags = std.StringHashMap(void).init(self.alloc),
        .active_meta = std.StringHashMap([]const u8).init(self.alloc),
        .err = null,
    };
    defer parser.imports.deinit();
    defer parser.active_tags.deinit();
    defer parser.active_meta.deinit();

    parser.parse() catch |err| switch (err) {
        error.ParseError => {
            try parser.err.?.print(self.alloc, source);
            return err;
        },
        else => return err,
    };

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
                        try self.addError(entry.main_token, "", tag);
                    };
                }
            },
            else => continue,
        }
    }
}

fn addError(self: *Self, token: Lexer.Token, source_file: []const u8, tag: ErrorDetails.Tag) !void {
    try self.errors.append(ErrorDetails{
        .tag = tag,
        .token = token,
        .source_file = source_file,
        .expected = null,
    });
}

/// Returns true if errors were printed.
pub fn printErrors(self: *Self) !bool {
    var errors_printed = false;
    for (self.errors.items, 0..) |err, i| {
        if (i == 10) {
            std.debug.print("... and {d} more errors\n", .{self.errors.items.len - 10});
            break;
        }
        try err.print(self.alloc, self.source);
        errors_printed = true;
    }
    return errors_printed;
}

pub fn deinit(self: *Self) void {
    self.alloc.free(self.source);

    self.entries.deinit();
    self.costcomps.deinit();
    self.currencies.deinit();
    self.postings.deinit(self.alloc);
    self.tagslinks.deinit(self.alloc);
    self.meta.deinit(self.alloc);
    self.config.deinit();

    self.errors.deinit();
}
