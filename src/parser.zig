const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("ast.zig");
const Parser = @This();
const Lexer = @import("lexer.zig").Lexer;
const Render = @import("render.zig");

pub const Error = error{ParseError} || Allocator.Error;

gpa: Allocator,
tokens: Ast.TokenList.Slice,
nodes: Ast.NodeList,
extra_data: Ast.ExtraData,
scratch: std.ArrayListUnmanaged(Ast.NodeIndex),
token_index: u32,
err: ?Ast.Error,

/// Returns index of previous token.
fn nextToken(p: *Parser) Ast.TokenIndex {
    const result = p.token_index;
    p.token_index += 1;
    return result;
}

fn currentToken(p: *Parser) Lexer.Token.Tag {
    return p.tokens.items(.tag)[p.token_index];
}

fn addNode(p: *Parser, node: Ast.Node) !Ast.NodeIndex {
    const result = p.nodes.len;
    try p.nodes.append(p.gpa, node);
    return @intCast(result);
}

fn setNode(p: *Parser, i: Ast.NodeIndex, node: Ast.Node) Ast.NodeIndex {
    p.nodes.set(@intCast(i), node);
    return i;
}

fn reserveNode(p: *Parser) !Ast.NodeIndex {
    try p.nodes.resize(p.gpa, p.nodes.len + 1);
    return @intCast(p.nodes.len - 1);
}

fn setError(p: *Parser, err: Ast.Error) void {
    p.err = err;
}

fn storeNewItems(p: *Parser, new_items: []const Ast.NodeIndex) !Ast.Node.ExtraRange {
    try p.extra_data.appendSlice(p.gpa, @ptrCast(new_items));
    return .{
        .start = @intCast(p.extra_data.items.len - new_items.len),
        .end = @intCast(p.extra_data.items.len),
    };
}

/// If successful, returns the current token index.
fn expectToken(p: *Parser, tag: Lexer.Token.Tag) Error!Ast.TokenIndex {
    const current = p.currentToken();
    if (current != tag) {
        p.setError(.{
            .tag = .expected_token,
            .token = p.token_index,
            .expected = tag,
        });
        return error.ParseError;
    } else {
        return p.nextToken();
    }
}

fn tryToken(p: *Parser, tag: Lexer.Token.Tag) ?Ast.TokenIndex {
    if (p.currentToken() != tag) {
        return null;
    } else {
        return p.nextToken();
    }
}

pub fn parseRoot(p: *Parser) !void {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    p.nodes.appendAssumeCapacity(.{
        .token = 0,
        .data = undefined,
    });

    while (true) {
        const tx = p.expectTransaction() catch |err| switch (err) {
            error.ParseError => break,
            else => return err,
        };
        try p.scratch.append(p.gpa, tx);
    }
    const items = p.scratch.items[scratch_top..];
    p.nodes.items(.data)[0] = .{ .root = try p.storeNewItems(items) };
}

/// tx <- date status message (leg)*
fn expectTransaction(p: *Parser) !Ast.NodeIndex {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    const date = try p.expectToken(.date);
    const flag = try p.parseFlag();
    const msg = try p.expectToken(.string);
    const self = try p.reserveNode(); // Before children

    while (true) {
        const leg = p.parseLeg() catch |err| switch (err) {
            error.ParseError => break,
            else => return err,
        };
        try p.scratch.append(p.gpa, leg);
    }
    const items = p.scratch.items[scratch_top..];

    const node = Ast.Node{ .token = date, .data = .{ .transaction = .{
        .date = date,
        .flag = flag,
        .message = msg,
        .legs = try p.storeNewItems(items),
    } } };

    _ = p.setNode(self, node);
    return self;
}

/// flag <- * | !
fn parseFlag(p: *Parser) !Ast.TokenIndex {
    if (p.tryToken(.bang)) |t| {
        return t;
    } else {
        return p.expectToken(.star);
    }
}

/// leg <- account amount currency
fn parseLeg(p: *Parser) Error!Ast.NodeIndex {
    // TODO: Commit to this after seeing indentation.
    const account = try p.expectToken(.account);
    const amount = try p.expectToken(.number);
    const currency = try p.expectToken(.currency);
    const node = Ast.Node{
        .token = account,
        .data = .{ .leg = .{
            .account = account,
            .amount = amount,
            .currency = currency,
        } },
    };

    return try p.addNode(node);
}

test "parser" {
    try testParse(
        \\2015-11-01 * "Test"
        \\  Foo 100 USD
        \\  Bar -2 EUR
    );

    try testParse(
        \\2024-93-01 * "Foo"
    );

    try testParse(
        \\2015-01-01 * ""
        \\  Aa 10 USD
        \\  Ba 30 USD
        \\
        \\2016-01-01 * ""
        \\  Ca 10 USD
        \\  Da 20 USD
    );
}

fn testParse(source: [:0]const u8) !void {
    const gpa = std.testing.allocator;

    var ast = try Ast.parse(gpa, source);
    defer ast.deinit(gpa);

    // const pretty = @import("pretty.zig");
    // try pretty.print(gpa, ast.tokens.items(.tag), .{});

    const rendered = try Render.dump(gpa, &ast);
    defer gpa.free(rendered);

    try std.testing.expectEqualSlices(u8, source, rendered);
}
