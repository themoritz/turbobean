const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Uri = @import("Uri.zig");
const ErrorDetails = @import("ErrorDetails.zig");
const Lexer = @import("lexer.zig").Lexer;
const Data = @import("data.zig");

const Self = @This();

uri: Uri,
source: [:0]const u8,
ast: Ast,
/// Parallel to `ast.tokens`; interpretation depends on the token's tag.
token_interned: std.ArrayList(u32),
/// Errors found during parsing or per-file Sema (e.g. warnings).
/// Cross-file errors live on `Project.errors`.
errors: std.ArrayList(ErrorDetails),

/// Takes ownership of `uri` and `source`.
pub fn loadFromSource(alloc: Allocator, uri: Uri, source: [:0]const u8) !Self {
    var ast = try Ast.parse(alloc, uri, source);
    errdefer ast.deinit();

    var token_interned: std.ArrayList(u32) = .{};
    errdefer token_interned.deinit(alloc);
    try token_interned.appendNTimes(alloc, std.math.maxInt(u32), ast.tokens.items.len);

    const errors = try ast.errors.clone(alloc);

    return .{
        .uri = uri,
        .source = source,
        .ast = ast,
        .token_interned = token_interned,
        .errors = errors,
    };
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    alloc.free(self.source);
    self.uri.deinit(alloc);
    self.ast.deinit();
    self.token_interned.deinit(alloc);
    self.errors.deinit(alloc);
}

pub fn token(self: *const Self, index: Ast.TokenIndex) Lexer.Token {
    return self.ast.tokens.items[@intFromEnum(index)];
}

pub fn tokenSlice(self: *const Self, index: Ast.TokenIndex) []const u8 {
    return self.token(index).slice;
}

pub fn optTokenSlice(self: *const Self, index: Ast.OptionalTokenIndex) ?[]const u8 {
    const i = index.unwrap() orelse return null;
    return self.tokenSlice(i);
}

/// Resolve an account token to its interned `AccountIndex` via the side-table.
pub fn accountOf(self: *const Self, tok: Ast.TokenIndex) Data.AccountIndex {
    return @enumFromInt(self.token_interned.items[@intFromEnum(tok)]);
}

/// Resolve a currency token to its interned `CurrencyIndex` via the side-table.
pub fn currencyOf(self: *const Self, tok: Ast.TokenIndex) Data.CurrencyIndex {
    return @enumFromInt(self.token_interned.items[@intFromEnum(tok)]);
}

pub fn addError(self: *Self, alloc: Allocator, tok: Ast.TokenIndex, tag: ErrorDetails.Tag) !void {
    try self.errors.append(alloc, .{
        .tag = tag,
        .token = self.token(tok),
        .uri = self.uri,
        .source = self.source,
    });
}

pub fn addWarning(self: *Self, alloc: Allocator, tok: Ast.TokenIndex, tag: ErrorDetails.Tag) !void {
    try self.errors.append(alloc, .{
        .tag = tag,
        .severity = .warn,
        .token = self.token(tok),
        .uri = self.uri,
        .source = self.source,
    });
}
