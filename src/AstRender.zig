const std = @import("std");
const Self = @This();
const Ast = @import("Ast.zig");
const Node = Ast.Node;

alloc: std.mem.Allocator,
ast: *Ast,
w: *std.Io.Writer,

pub fn render(alloc: std.mem.Allocator, w: *std.Io.Writer, ast: *Ast) !void {
    std.debug.assert(ast.errors.items.len == 0);

    var self = Self{
        .alloc = alloc,
        .ast = ast,
        .w = w,
    };

    try self.renderRoot();
}

fn renderRoot(self: *Self) !void {
    const decls = self.ast.root();
    for (decls) |decl| {
        try self.renderDeclaration(decl);
    }
}

fn renderDeclaration(self: *Self, node: Node.Index) !void {
    switch (self.ast.node(node)) {
        .entry => |entry| {
            try self.renderEntry(self.ast.getExtra(entry, Node.Entry));
        },
        else => @panic("unexpected node, expected declaration"),
    }
}

fn renderEntry(self: *Self, entry: Node.Entry) !void {
    try self.renderToken(entry.date);
    try self.space();
    switch (self.ast.node(entry.payload)) {
        .transaction => |tx_extra| {
            const tx = self.ast.getExtra(tx_extra, Node.Transaction);
            try self.renderToken(tx.flag);
            if (tx.payee.unwrap()) |p| {
                try self.space();
                try self.renderToken(p);
            }
            if (tx.narration.unwrap()) |n| {
                try self.space();
                try self.renderToken(n);
            }
            // entry.tagslinks
            // entry.meta
            for (self.ast.list(tx.postings)) |p| {
                _ = p;
                //
            }
        },
    }
}

fn space(self: *Self) !void {
    try self.w.writeByte(' ');
}

fn renderToken(self: *Self, token: Ast.TokenIndex) !void {
    try self.w.write(self.ast.tokens.items[@intFromEnum(token)].slice);
}

fn renderOptionalToken(self: *Self, token: Ast.OptionalTokenIndex) !void {
    if (token.unwrap()) |t| try self.renderToken(t);
}
