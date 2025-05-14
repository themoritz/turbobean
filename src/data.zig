const std = @import("std");
const Allocator = std.mem.Allocator;
const Date = @import("date.zig").Date;
const Parser = @import("parser.zig");
const Number = @import("number.zig").Number;
const Lexer = @import("lexer.zig").Lexer;

const Self = @This();

source: [:0]const u8,
entries: Entries.Slice,
postings: Postings.Slice,
tagslinks: TagsLinks.Slice,
meta: Meta.Slice,
costcomps: CostComps.Slice,
currencies: Currencies.Slice,

pub const Entries = std.ArrayList(Entry);
pub const Postings = std.MultiArrayList(Posting);
pub const TagsLinks = std.MultiArrayList(TagLink);
pub const Meta = std.MultiArrayList(KeyValue);
pub const CostComps = std.ArrayList(CostComp);
pub const Currencies = std.ArrayList([]const u8);

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

    pub fn is_complete(a: *const Amount) bool {
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

pub const Entry = union(enum) {
    transaction: Transaction,
    open: Open,
    close: struct {
        date: Date,
        account: []const u8,
    },
    // Directives
    pushtag: []const u8,
    poptag: []const u8,
    pushmeta: usize, // meta index
    popmeta: usize, // meta index
    option: Option,
    include: []const u8,
    plugin: []const u8,
};

pub const Option = struct {
    key: []const u8,
    value: []const u8,
};

pub const Open = struct {
    date: Date,
    account: []const u8,
    currencies: ?Range,
    booking: ?[]const u8,
    meta: ?Range,
};

pub const Transaction = struct {
    date: Date,
    flag: Lexer.Token,
    payee: ?[]const u8,
    narration: ?[]const u8,
    tagslinks: ?Range,
    meta: ?Range,
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
    key: []const u8,
    value: []const u8,
};

pub fn parse(alloc: Allocator, source: [:0]const u8) !Self {
    var lexer = Lexer.init(source);
    var tokens = Tokens.init(alloc);
    defer tokens.deinit();

    while (true) {
        const token = lexer.next();
        try tokens.append(token);
        if (token.tag == .eof) break;
    }

    var parser: Parser = .{
        .gpa = alloc,
        .tokens = tokens,
        .tok_i = 0,
        .postings = .{},
        .tagslinks = .{},
        .meta = .{},
        .costcomps = CostComps.init(alloc),
        .currencies = Currencies.init(alloc),
        .entries = Entries.init(alloc),
        .err = null,
    };
    defer parser.postings.deinit(alloc);
    defer parser.tagslinks.deinit(alloc);
    defer parser.meta.deinit(alloc);
    defer parser.costcomps.deinit();
    defer parser.currencies.deinit();
    defer parser.entries.deinit();

    parser.parse() catch |err| switch (err) {
        error.ParseError => {
            std.debug.print("{any}\n", .{parser.err});
            return err;
        },
        else => return err,
    };

    return Self{
        .entries = try parser.entries.toOwnedSlice(),
        .postings = parser.postings.toOwnedSlice(),
        .tagslinks = parser.tagslinks.toOwnedSlice(),
        .meta = parser.meta.toOwnedSlice(),
        .costcomps = try parser.costcomps.toOwnedSlice(),
        .currencies = try parser.currencies.toOwnedSlice(),
        .source = source,
    };
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    alloc.free(self.entries);
    alloc.free(self.costcomps);
    alloc.free(self.currencies);
    self.postings.deinit(alloc);
    self.tagslinks.deinit(alloc);
    self.meta.deinit(alloc);
}
