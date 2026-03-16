const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Self = @This();
const ErrorDetails = @import("ErrorDetails.zig");
const Parser = @import("AstParser.zig");
const Uri = @import("Uri.zig");

alloc: std.mem.Allocator,
source: [:0]const u8,
tokens: std.ArrayList(Lexer.Token),
nodes: std.ArrayList(Node),
extra_data: std.ArrayList(u32),
errors: std.ArrayList(ErrorDetails),

pub fn parse(alloc: std.mem.Allocator, uri: Uri, source: [:0]const u8) !Self {
    var self = Self{
        .alloc = alloc,
        .source = source,
        .tokens = .{},
        .nodes = .{},
        .extra_data = .{},
        .errors = .{},
    };

    // Average 10 bytes per token:
    try self.tokens.ensureTotalCapacity(alloc, source.len / 10);
    var lexer = Lexer.init(source);
    while (true) {
        const token = lexer.next();
        try self.tokens.append(alloc, token);
        if (token.tag == .eof) break;
    }

    var parser = Parser.init(alloc, uri, &self);
    defer parser.deinit();
    try parser.parse();
    return self;
}

pub fn deinit(self: *Self) void {
    self.tokens.deinit(self.alloc);
    self.nodes.deinit(self.alloc);
    self.extra_data.deinit(self.alloc);
    self.errors.deinit(self.alloc);
}

pub const ExtraIndex = enum(u32) {
    _,
};

pub const TokenIndex = enum(u32) {
    _,

    pub fn toOptional(i: TokenIndex) OptionalTokenIndex {
        const result: OptionalTokenIndex = @enumFromInt(@intFromEnum(i));
        std.debug.assert(result != .none);
        return result;
    }
};

pub const OptionalTokenIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oi: OptionalTokenIndex) ?TokenIndex {
        return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
    }

    pub fn fromOptional(oi: ?TokenIndex) OptionalTokenIndex {
        return if (oi) |i| i.toOptional() else .none;
    }
};

pub const KeyValue = struct { key: TokenIndex, value: TokenIndex };

pub const Node = union(enum) {
    /// Node index for every declaration
    root: Range,
    /// Directives
    include: TokenIndex,
    option: KeyValue,
    plugin: TokenIndex,
    pushtag: TokenIndex,
    poptag: TokenIndex,
    pushmeta: KeyValue,
    popmeta: KeyValue,
    /// Entries
    entry: ExtraIndex,
    transaction: ExtraIndex,
    posting: ExtraIndex,
    open: ExtraIndex,
    close: TokenIndex,
    commodity: TokenIndex,
    pad: struct { account: TokenIndex, pad_to: TokenIndex },
    pnl: struct { account: TokenIndex, income_account: TokenIndex },
    balance: ExtraIndex,
    price_decl: struct { currency: TokenIndex, amount: Index },
    event: KeyValue,
    query: KeyValue,
    note: KeyValue,
    document: KeyValue,
    /// Sub-nodes
    amount: struct {
        number: OptionalTokenIndex,
        currency: OptionalTokenIndex,
    },
    lot_spec: ExtraIndex,
    price_annotation: struct { total: TokenIndex, amount: Index },
    key_value: KeyValue,

    pub const Index = enum(u32) {
        _,
        pub fn toOptional(i: Index) OptionalIndex {
            const result: OptionalIndex = @enumFromInt(@intFromEnum(i));
            std.debug.assert(result != .none);
            return result;
        }
    };

    pub const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(oi: OptionalIndex) ?Index {
            return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
        }

        pub fn fromOptional(oi: ?Index) OptionalIndex {
            return if (oi) |i| i.toOptional() else .none;
        }
    };

    pub const Entry = struct {
        date: TokenIndex,
        tagslinks: Range,
        meta: Range,
        payload: Index,
    };

    pub const Transaction = struct {
        flag: TokenIndex,
        payee: OptionalTokenIndex,
        narration: OptionalTokenIndex,
        postings: Range,
    };

    pub const Posting = struct {
        flag: OptionalTokenIndex,
        account: TokenIndex,
        amount: Index,
        lot_spec: OptionalIndex,
        price: OptionalIndex,
        meta: Range,
    };

    pub const Open = struct {
        account: TokenIndex,
        booking_method: OptionalTokenIndex,
        currencies: Range,
    };

    pub const Balance = struct {
        account: TokenIndex,
        amount: Index,
        tolerance: OptionalTokenIndex,
    };

    pub const LotSpec = struct {
        lcurl: TokenIndex,
        rcurl: TokenIndex,
        price: OptionalIndex,
        date: OptionalTokenIndex,
        label: OptionalTokenIndex,
    };

    pub const Range = struct {
        start: ExtraIndex,
        end: ExtraIndex,
    };

    comptime {
        std.debug.assert(@sizeOf(Node) <= 12);
    }
};

pub fn node(self: *Self, index: Node.Index) Node {
    return self.nodes.items[@intFromEnum(index)];
}

pub fn getExtra(self: *Self, index: ExtraIndex, comptime T: type) T {
    const fields = std.meta.fields(T);
    var result: T = undefined;
    var i: usize = 0;
    inline for (fields) |field| {
        @field(result, field.name) = switch (field.type) {
            Node.Index,
            Node.OptionalIndex,
            TokenIndex,
            OptionalTokenIndex,
            ExtraIndex,
            => @enumFromInt(self.extra_data.items[@intFromEnum(index) + i]),
            Node.Range => blk: {
                var range: Node.Range = undefined;
                range.start = @enumFromInt(self.extra_data.items[@intFromEnum(index) + i]);
                i += 1;
                range.end = @enumFromInt(self.extra_data.items[@intFromEnum(index) + i]);
                break :blk range;
            },
            else => @compileError("unexpected field type: " ++ @typeName(field.type)),
        };
        i += 1;
    }
    return result;
}

pub fn root(self: *Self) []const Node.Index {
    switch (self.nodes.items[0]) {
        .root => |range| {
            return self.list(range);
        },
        else => @panic("unexpected node type"),
    }
}

pub fn list(self: *Self, range: Node.Range) []const Node.Index {
    return @ptrCast(self.extra_data.items[@intFromEnum(range.start)..@intFromEnum(range.end)]);
}

pub fn tokenList(self: *Self, range: Node.Range) []const TokenIndex {
    return @ptrCast(self.extra_data.items[@intFromEnum(range.start)..@intFromEnum(range.end)]);
}

/// Returns the first token index for a declaration node (entry or directive).
/// For entries, this is the date token. For directives, it's the keyword token
/// (one before the stored token).
pub fn firstToken(self: *Self, index: Node.Index) usize {
    const n = self.node(index);
    return switch (n) {
        .entry => |extra| @intFromEnum(self.getExtra(extra, Node.Entry).date),
        // Directives store the token after the keyword
        .include => |tok| @intFromEnum(tok) - 1,
        .option => |kv| @intFromEnum(kv.key) - 1,
        .plugin => |tok| @intFromEnum(tok) - 1,
        .pushtag => |tok| @intFromEnum(tok) - 1,
        .poptag => |tok| @intFromEnum(tok) - 1,
        .pushmeta => |kv| @intFromEnum(kv.key) - 1,
        .popmeta => |kv| @intFromEnum(kv.key) - 1,
        .posting => |extra| {
            const p = self.getExtra(extra, Node.Posting);
            // indent is before flag (if present) or account
            if (p.flag.unwrap()) |f| return @intFromEnum(f) - 1;
            return @intFromEnum(p.account) - 1;
        },
        .key_value => |kv| @intFromEnum(kv.key) - 1, // indent before key
        else => unreachable,
    };
}
