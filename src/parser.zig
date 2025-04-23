const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("ast.zig");
const Parser = @This();

gpa: Allocator,
tokens: Ast.TokenList.Slice,
nodes: Ast.NodeList,
extra_data: Ast.ExtraData,

pub fn parseRoot(p: *Parser) !void {
    _ = p;
}
