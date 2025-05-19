const std = @import("std");
const Allocator = std.mem.Allocator;
const Date = @import("date.zig").Date;
const Parser = @import("parser.zig");
const Number = @import("number.zig").Number;
const Lexer = @import("lexer.zig").Lexer;

const Self = @This();

alloc: Allocator,
sources: std.StringHashMap([:0]const u8),
entries: Entries,
postings: Postings,
tagslinks: TagsLinks,
meta: Meta,
costcomps: CostComps,
currencies: Currencies,

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
    close: Close,
    commodity: Commodity,
    pad: Pad,
    balance: Balance,
    price: PriceDecl,
    event: Event,
    query: Query,
    note: Note,
    document: Document,
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

pub const Close = struct {
    date: Date,
    account: []const u8,
    meta: ?Range,
};

pub const Commodity = struct {
    date: Date,
    currency: []const u8,
    meta: ?Range,
};

pub const Pad = struct {
    date: Date,
    account: []const u8,
    pad_to: []const u8,
    meta: ?Range,
};

pub const Balance = struct {
    date: Date,
    account: []const u8,
    amount: Amount,
    tolerance: ?Number,
    meta: ?Range,
};

pub const PriceDecl = struct {
    date: Date,
    currency: []const u8,
    amount: Amount,
    meta: ?Range,
};

pub const Event = struct {
    date: Date,
    variable: []const u8,
    value: []const u8,
    meta: ?Range,
};

pub const Query = struct {
    date: Date,
    name: []const u8,
    sql: []const u8,
    meta: ?Range,
};

pub const Note = struct {
    date: Date,
    account: []const u8,
    note: []const u8,
    meta: ?Range,
};

pub const Document = struct {
    date: Date,
    account: []const u8,
    filename: []const u8,
    tagslinks: ?Range,
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

pub fn init(alloc: Allocator) Self {
    const sources = std.StringHashMap([:0]const u8).init(alloc);
    return Self{
        .alloc = alloc,
        .postings = .{},
        .tagslinks = .{},
        .meta = .{},
        .costcomps = CostComps.init(alloc),
        .currencies = Currencies.init(alloc),
        .entries = Entries.init(alloc),
        .sources = sources,
    };
}

pub fn parse(alloc: Allocator, source: [:0]const u8) !Self {
    var self = Self.init(alloc);
    const name = try alloc.dupe(u8, "static");
    const owned_source = try alloc.dupeZ(u8, source);
    const imports = try self.add_file(name, owned_source);
    defer self.alloc.free(imports);
    return self;
}

pub fn load_file(alloc: Allocator, name: []const u8) !Self {
    var self = Self.init(alloc);
    try self.load_file_rec(name);
    return self;
}

fn load_file_rec(self: *Self, name: []const u8) !void {
    if (self.sources.get(name)) |_| return error.ImportCycle;
    const imports = try self.load_single_file(name);
    defer self.alloc.free(imports);
    const dir = std.fs.path.dirname(name) orelse ".";
    for (imports) |import| {
        const joined = try std.fs.path.join(self.alloc, &.{ dir, import });
        defer self.alloc.free(joined);
        try self.load_file_rec(joined);
    }
}

fn load_single_file(self: *Self, name: []const u8) !Imports.Slice {
    const owned_name = try self.alloc.dupe(u8, name);

    const file = try std.fs.cwd().openFile(name, .{});
    defer file.close();

    const filesize = try file.getEndPos();
    const source = try self.alloc.alloc(u8, filesize + 1);

    _ = try file.readAll(source[0..filesize]);
    source[filesize] = 0;

    const null_terminated: [:0]u8 = source[0..filesize :0];
    return try self.add_file(owned_name, null_terminated);
}

/// Takes ownership of name and source.
fn add_file(self: *Self, name: []const u8, source: [:0]const u8) !Imports.Slice {
    try self.sources.put(name, source);

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
        .entries = &self.entries,
        .postings = &self.postings,
        .tagslinks = &self.tagslinks,
        .meta = &self.meta,
        .costcomps = &self.costcomps,
        .currencies = &self.currencies,
        .imports = Imports.init(self.alloc),
        .err = null,
    };

    parser.parse() catch |err| switch (err) {
        error.ParseError => {
            try parser.err.?.print(self.alloc, source);
            return err;
        },
        else => return err,
    };

    return parser.imports.toOwnedSlice();
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    var iter = self.sources.iterator();
    while (iter.next()) |kv| {
        alloc.free(kv.key_ptr.*);
        alloc.free(kv.value_ptr.*);
    }
    self.sources.deinit();

    self.entries.deinit();
    self.costcomps.deinit();
    self.currencies.deinit();
    self.postings.deinit(alloc);
    self.tagslinks.deinit(alloc);
    self.meta.deinit(alloc);
}
