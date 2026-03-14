const std = @import("std");
const Ast = @import("Ast.zig");
const Lexer = @import("lexer.zig").Lexer;
const Self = @This();
const Node = Ast.Node;
const ErrorDetails = @import("ErrorDetails.zig");
const Uri = @import("Uri.zig");

alloc: std.mem.Allocator,
uri: Uri,
source: [:0]const u8,
tokens: []const Lexer.Token,
tok_i: usize,

scratch: std.ArrayList(Node.Index),

nodes: *std.ArrayList(Node),
extra_data: *std.ArrayList(u32),
errors: *std.ArrayList(ErrorDetails),

pub fn init(alloc: std.mem.Allocator, uri: Uri, ast: *Ast) Self {
    return .{
        .alloc = alloc,
        .uri = uri,
        .source = ast.source,
        .tokens = ast.tokens.items,
        .tok_i = 0,
        .scratch = .{},
        .nodes = &ast.nodes,
        .extra_data = &ast.extra_data,
        .errors = &ast.errors,
    };
}

pub fn deinit(self: *Self) void {
    self.scratch.deinit(self.alloc);
}

fn addNode(self: *Self, node: Node) !Node.Index {
    const result: Node.Index = @enumFromInt(self.nodes.items.len);
    try self.nodes.append(self.alloc, node);
    return result;
}

fn addExtra(self: *Self, extra: anytype) !Ast.ExtraIndex {
    const result: Ast.ExtraIndex = @enumFromInt(self.extra_data.items.len);
    const fields = std.meta.fields(@TypeOf(extra));
    inline for (fields) |field| {
        switch (field.type) {
            Node.Index, Ast.TokenIndex, Ast.OptionalTokenIndex, Ast.ExtraIndex => {
                try self.extra_data.append(self.alloc, @intFromEnum(@field(extra, field.name)));
            },
            Node.Range => {
                const range: Node.Range = @field(extra, field.name);
                try self.extra_data.append(self.alloc, @intFromEnum(range.start));
                try self.extra_data.append(self.alloc, @intFromEnum(range.end));
            },
            else => @compileError("unsupported field type"),
        }
    }
    return result;
}

fn makeRange(self: *Self, slice: []const Node.Index) !Node.Range {
    try self.extra_data.appendSlice(self.alloc, @ptrCast(slice));
    return .{
        .start = @enumFromInt(self.extra_data.items.len - slice.len),
        .end = @enumFromInt(self.extra_data.items.len),
    };
}

pub const Error = error{ParseError} || std.mem.Allocator.Error;

fn fail(p: *Self, msg: ErrorDetails.Tag) Error {
    return p.failAt(p.currentToken(), msg);
}

fn failExpected(p: *Self, expected_token: Lexer.Token.Tag) Error {
    return p.failMsg(.{
        .tag = .{ .expected_token = expected_token },
        .token = p.currentToken(),
        .uri = p.uri,
        .source = p.source,
    });
}

fn failAt(self: *Self, token: Lexer.Token, msg: ErrorDetails.Tag) Error {
    return self.failMsg(.{
        .tag = msg,
        .token = token,
        .uri = self.uri,
        .source = self.source,
    });
}

fn failMsg(self: *Self, err: ErrorDetails) Error {
    try self.errors.append(self.alloc, err);
    return error.ParseError;
}

fn currentToken(self: *Self) Lexer.Token {
    return self.tokens[self.tok_i];
}

fn advanceToken(self: *Self) Ast.TokenIndex {
    const result: Ast.TokenIndex = @enumFromInt(self.tok_i);
    self.tok_i += 1;
    return result;
}

fn nextToken(self: *Self) ?Lexer.Token {
    return if (self.tok_i + 1 < self.tokens.len)
        self.tokens[self.tok_i + 1]
    else
        null;
}

fn expectToken(self: *Self, tag: Lexer.Token.Tag) !Ast.TokenIndex {
    if (self.currentToken().tag == tag) {
        return self.advanceToken();
    } else {
        return self.failExpected(tag);
    }
}

fn tryToken(self: *Self, tag: Lexer.Token.Tag) ?Ast.TokenIndex {
    if (self.currentToken().tag == tag) {
        return self.advanceToken();
    } else {
        return null;
    }
}

pub fn parse(self: *Self) !void {
    // Add root node at index 0 for entrypoint into the AST.
    _ = try self.addNode(undefined);

    try self.eatWhiteSpace();

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        const node = try self.parseDeclarationRecoverable() orelse break;
        try self.scratch.append(self.alloc, node);
        try self.eatWhiteSpace();
    }

    const declarations = self.scratch.items[scratch_top..];
    self.nodes.items[0] = .{
        .root = try self.makeRange(declarations),
    };
}

fn eatWhiteSpace(self: *Self) !void {
    while (true) {
        if (try self.parseIndentedLine()) |_| {
            //
        } else if (self.currentToken().tag == .eol) {
            _ = self.advanceToken();
        } else if (self.currentToken().tag == .comment) {
            _ = try self.expectToken(.comment);
            _ = try self.expectEolOrEof();
        } else {
            break;
        }
    }
}

fn parseDeclarationRecoverable(self: *Self) !?Node.Index {
    return self.parseDeclaration() catch |err| switch (err) {
        error.ParseError => {
            // Skip ahead until next newline, consume it and then try the next
            // declaration.
            while (true) {
                switch (self.currentToken().tag) {
                    .eol => {
                        _ = self.advanceToken();
                        break;
                    },
                    .eof => return null,
                    else => _ = self.advanceToken(),
                }
            }
        },
        else => return err,
    };
}

/// Only returns null at EOF.
fn parseDeclaration(self: *Self) !?Node.Index {
    if (try self.parseEntry() orelse try self.parseDirective()) |node| {
        return node;
    } else {
        if (self.currentToken().tag == .eof) {
            return null;
        } else {
            return self.fail(.expected_declaration);
        }
    }
}

fn parseEntry(self: *Self) !?Node.Index {
    const date = self.tryToken(.date) orelse return null;

    const entry_extra: Ast.ExtraIndex = blk: switch (self.currentToken().tag) {
        .keyword_txn, .flag, .asterisk, .hash => {
            const flag = self.advanceToken();

            var payee = self.tryToken(.string);
            var narration = self.tryToken(.string);

            if (narration == null) {
                narration = payee;
                payee = null;
            }

            // tagslinks
            try self.expectEolOrEof();

            // meta

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // while (true) {
            //     if (try p.parsePosting())
            // }

            const postings = self.scratch.items[scratch_top..];

            const tx_extra = try self.addExtra(Node.Transaction{
                .flag = flag,
                .narration = Ast.OptionalTokenIndex.fromOptional(narration),
                .payee = Ast.OptionalTokenIndex.fromOptional(payee),
                .postings = try self.makeRange(postings),
            });
            const tx_node = try self.addNode(Node{
                .transaction = tx_extra,
            });

            const entry_extra = try self.addExtra(Node.Entry{
                .date = date,
                .tagslinks = undefined,
                .meta = undefined,
                .payload = tx_node,
            });

            break :blk entry_extra;
        },
        else => @panic("TODO"),
    };

    return try self.addNode(.{ .entry = entry_extra });
}

fn parseDirective(self: *Self) !?Node.Index {
    _ = self;
    return null;
}

fn parseFlag(self: *Self) ?Ast.TokenIndex {
    switch (self.currentToken().tag) {
        .flag, .asterisk, .hash => return self.advanceToken(),
        else => return null,
    }
}

fn expectEolOrEof(self: *Self) !void {
    _ = self.tryToken(.comment);
    switch (self.currentToken().tag) {
        .eol => _ = self.advanceToken(),
        .eof => {},
        else => return self.failExpected(.eol),
    }
}

// TODO: rename to parseIndentedComment
fn parseIndentedLine(self: *Self) !?void {
    if (self.currentToken().tag == .indent and self.nextToken() != null and (self.nextToken().?.tag == .eol or self.nextToken().?.tag == .comment)) {
        _ = try self.expectToken(.indent);
        _ = self.tryToken(.comment);
        _ = try self.expectToken(.eol);
    } else return null;
}

test "negative" {
    try testRoundtrip(
        \\2015-11-01 * "Test"
        \\  Assets:Foo -1 USD
        \\
    );
}

fn testParse(source: [:0]const u8) !void {
    const alloc = std.testing.allocator;

    var uri = try Uri.from_relative_to_cwd(alloc, "dummy.bean");
    defer uri.deinit(alloc);

    var ast = try Ast.parse(alloc, uri, source);
    defer ast.deinit();

    if (ast.errors.items.len > 0) return error.ParseError;
}

fn testRoundtrip(source: [:0]const u8) !void {
    const alloc = std.testing.allocator;

    var uri = try Uri.from_relative_to_cwd(alloc, "dummy.bean");
    defer uri.deinit(alloc);

    var ast = try Ast.parse(alloc, uri, source);
    defer ast.deinit();

    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();

    const Render = @import("AstRender.zig");
    try Render.render(alloc, &allocating.writer, &ast);

    try std.testing.expectEqualStrings(source, allocating.written());
}
