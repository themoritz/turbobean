const std = @import("std");
const Allocator = std.mem.Allocator;
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig");

const Ast = @This();

source: [:0]const u8,
nodes: NodeList.Slice,
tokens: TokenList.Slice,
extra_data: ExtraData.Slice,

pub const TokenIndex = u32;
pub const NodeIndex = u32;
pub const ExtraIndex = u32;
pub const ByteOffset = u32;

pub const ExtraData = std.ArrayListUnmanaged(u32);
pub const NodeList = std.MultiArrayList(Node);
pub const TokenList = std.MultiArrayList(struct { tag: Lexer.Token.Tag, start: ByteOffset });

pub fn parse(gpa: Allocator, source: [:0]const u8) !Ast {
    var tokens = TokenList{};
    defer tokens.deinit(gpa);

    try tokens.ensureTotalCapacity(gpa, source.len / 8);

    var lexer = Lexer.init(source);
    while (true) {
        const token = lexer.next();
        try tokens.append(gpa, .{
            .tag = token.tag,
            .start = @intCast(token.loc.start),
        });
        if (token.tag == .eof) break;
    }

    var parser: Parser = .{
        .gpa = gpa,
        .tokens = tokens.slice(),
        .nodes = .{},
        .extra_data = .{},
        .scratch = .{},
        .token_index = 0,
        .err = null,
    };
    defer parser.nodes.deinit(gpa);
    defer parser.extra_data.deinit(gpa);
    defer parser.scratch.deinit(gpa);

    try parser.nodes.ensureTotalCapacity(gpa, (tokens.len + 2) / 2);

    try parser.parseRoot();

    return Ast{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = try parser.extra_data.toOwnedSlice(gpa),
    };
}

pub fn deinit(ast: *Ast, gpa: Allocator) void {
    ast.tokens.deinit(gpa);
    ast.nodes.deinit(gpa);
    gpa.free(ast.extra_data);
}

pub const Node = struct {
    token: TokenIndex,
    data: Data,

    pub const Data = union(enum) {
        root: ExtraRange,
        transaction: struct {
            date: TokenIndex,
            flag: TokenIndex,
            message: TokenIndex,
            legs: ExtraRange,
        },
        leg: struct {
            account: TokenIndex,
            amount: ?TokenIndex,
            currency: ?TokenIndex,
        },
    };

    pub const ExtraRange = struct {
        start: ExtraIndex,
        /// Exclusive
        end: ExtraIndex,
    };
};

pub const Error = struct {
    tag: Tag,
    token: TokenIndex,
    expected: ?Lexer.Token.Tag,

    pub const Tag = enum {
        expected_token,
    };
};
