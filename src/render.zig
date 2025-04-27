const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("ast.zig");
const Render = @This();

buffer: std.ArrayList(u8),
ast: *Ast,

pub fn init(alloc: Allocator, ast: *Ast) !Render {
    return .{
        .buffer = std.ArrayList(u8).init(alloc),
        .ast = ast,
    };
}

pub fn deinit(r: *Render) void {
    r.buffer.deinit();
}

pub fn dump(alloc: Allocator, ast: *Ast) ![]const u8 {
    var render = try init(alloc, ast);
    defer render.deinit();
    try render.traverse(0);
    return render.buffer.toOwnedSlice();
}

pub fn print(alloc: Allocator, ast: *Ast) !void {
    var render = try init(alloc, ast);
    defer render.deinit();
    try render.traverse(0);
    std.debug.print("{s}", .{render.buffer.items});
}

fn appendToken(r: *Render, token_index: u32) !void {
    const start = r.ast.tokens.items(.start)[token_index];
    const end = r.ast.tokens.items(.end)[token_index];
    const items = r.ast.source[start..end];
    try r.buffer.appendSlice(items);
}

inline fn space(r: *Render) !void {
    try r.buffer.append(' ');
}

inline fn newline(r: *Render) !void {
    try r.buffer.append('\n');
}

inline fn indent(r: *Render) !void {
    try r.buffer.appendSlice("  ");
}

fn nodeRange(r: *Render, range: Ast.Node.ExtraRange) []Ast.NodeIndex {
    return r.ast.extra_data[range.start..range.end];
}

fn traverse(r: *Render, node: u32) !void {
    switch (r.ast.nodes.items(.data)[node]) {
        .root => |decls| {
            const decls_range = r.nodeRange(decls);
            for (decls_range, 1..) |decl, i| {
                try r.traverse(decl);
                if (i < decls_range.len) {
                    try r.newline();
                    try r.newline();
                }
            }
        },
        .transaction => |tx| {
            try r.appendToken(tx.date);
            try r.space();
            try r.appendToken(tx.flag);
            try r.space();
            try r.appendToken(tx.message);
            const legs = r.nodeRange(tx.legs);
            if (legs.len > 0) {
                try r.newline();
            }
            for (legs, 1..) |leg, i| {
                try r.traverse(leg);
                if (i < legs.len) try r.newline();
            }
        },
        .leg => |leg| {
            try r.indent();
            try r.appendToken(leg.account);
            try r.space();
            if (leg.amount) |amount| {
                try r.appendToken(amount);
                try r.space();
            }
            if (leg.currency) |currency| {
                try r.appendToken(currency);
            }
        },
    }
}
