const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Uri = @import("Uri.zig");
const ErrorDetails = @import("ErrorDetails.zig");
const Lexer = @import("lexer.zig").Lexer;
const Data = @import("data.zig");

const Self = @This();

uri: Uri,
source: std.ArrayList(u8),
ast: Ast,
/// Parallel to `ast.tokens`; interpretation depends on the token's tag.
token_interned: std.ArrayList(u32),
/// Errors found during parsing or per-file Sema (e.g. warnings).
/// Cross-file errors live on `Project.errors`.
errors: std.ArrayList(ErrorDetails),

pub fn init(uri: Uri) Self {
    return .{
        .uri = uri,
        .source = .empty,
        .ast = .empty,
        .token_interned = .empty,
        .errors = .empty,
    };
}

/// Makes a copy of source
pub fn loadFromSource(self: *Self, alloc: Allocator, source: [:0]const u8) !void {
    self.reset();

    try self.source.appendSlice(alloc, source);
    try self.source.append(alloc, 0);
    // Recover slice at new owned position:
    const source_ = self.source.items[0 .. self.source.items.len - 1 :0];
    try self.ast.parse(alloc, self.uri, source_);
    try self.token_interned.appendNTimes(alloc, std.math.maxInt(u32), self.ast.tokens.items.len);
    try self.errors.appendSlice(alloc, self.ast.errors.items);
}

pub fn reset(self: *Self) void {
    self.source.clearRetainingCapacity();
    self.token_interned.clearRetainingCapacity();
    self.errors.clearRetainingCapacity();
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
        .source = self.source.items,
    });
}
