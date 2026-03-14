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
    var parser = Parser.init(alloc, uri, &self);
    defer parser.deinit();
    try parser.parse();
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

pub const Node = union(enum) {
    /// Node index for every declaration
    root: Range,
    /// Filename string
    include: TokenIndex,
    entry: ExtraIndex,
    transaction: ExtraIndex,
    // posting: Posting,
    amount: struct {
        number: OptionalTokenIndex,
        currency: OptionalTokenIndex,
    },

    pub const Index = enum(u32) {
        _,
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
        flag: ?TokenIndex,
        account: TokenIndex,
        amount: Index,
        lot_spec: Index,
        price: ?TokenIndex,
        meta: Range,
    };

    comptime {
        std.debug.assert(@sizeOf(Node) <= 12);
    }

    pub const Range = struct {
        start: ExtraIndex,
        end: ExtraIndex,
    };
};

pub fn node(self: *Self, index: Node.Index) Node {
    return self.nodes.items[index];
}

pub fn getExtra(self: *Self, index: ExtraIndex, comptime T: type) T {
    const fields = std.meta.fields(T);
    var result: T = undefined;
    inline for (fields, 0..) |field, i| {
        @field(result, field.name) = switch (field.type) {
            Node.Index,
            Node.OptionalIndex,
            TokenIndex,
            OptionalTokenIndex,
            ExtraIndex,
            => @enumFromInt(self.extra_data[@intFromEnum(index) + i]),
            else => @compileError("unexpected field type: " ++ @typeName(field.type)),
        };
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
    return @ptrCast(self.ast.extra_data[range.start..range.end]);
}
