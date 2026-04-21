const std = @import("std");
const Allocator = std.mem.Allocator;
const Number = @import("number.zig").Number;
const Data = @import("data.zig");
const PriceDeclView = Data.PriceDeclView;
const CurrencyIndex = Data.CurrencyIndex;
const PlainInventory = @import("inventory.zig").PlainInventory;
const Summary = @import("inventory.zig").Summary;
const StringPool = @import("StringPool.zig");

const Self = @This();

/// (from, to) `CurrencyIndex` → rate. Storage is a flat `AutoHashMap` keyed
/// by a pair of u32 enum values, so there's no string hashing on the hot
/// conversion path.
latest_prices: PriceMap,
allocator: Allocator,

pub const Pair = struct {
    from: CurrencyIndex,
    to: CurrencyIndex,
};

const PriceMap = std.AutoHashMap(Pair, Number);

pub fn init(alloc: Allocator) Self {
    return .{
        .latest_prices = PriceMap.init(alloc),
        .allocator = alloc,
    };
}

pub fn deinit(self: *Self) void {
    self.latest_prices.deinit();
}

/// Record `rate` for converting `from → to`. Also stores the inverse rate
/// (unless `rate` is zero).
pub fn setPrice(self: *Self, from: CurrencyIndex, to: CurrencyIndex, rate: Number) !void {
    try self.latest_prices.put(.{ .from = from, .to = to }, rate);
    if (!rate.is_zero()) {
        const inverse_rate = try Number.fromInt(1).div(rate);
        try self.latest_prices.put(.{ .from = to, .to = from }, inverse_rate);
    }
}

/// Convenience wrapper for a `PriceDeclView`, which already carries indices.
pub fn setPriceFromDecl(self: *Self, decl: PriceDeclView) !void {
    try self.setPrice(decl.currency, decl.amount_currency, decl.amount);
}

pub fn getPrice(self: *const Self, from: CurrencyIndex, to: CurrencyIndex) ?Number {
    return self.latest_prices.get(.{ .from = from, .to = to });
}

pub fn convert(self: *const Self, amount: Number, from: CurrencyIndex, to: CurrencyIndex) ?Number {
    if (from == to) return amount;
    const rate = self.getPrice(from, to) orelse return null;
    return amount.mul(rate).normalize();
}

/// Convert everything in `inventory` to `to` if possible. Writes into
/// `result` (cleared first).
pub fn convertInventory(
    self: *const Self,
    inventory: *const PlainInventory,
    to: CurrencyIndex,
    result: *PlainInventory,
) !void {
    result.clear();
    var iter = inventory.by_currency.iterator();
    while (iter.next()) |kv| {
        const from = kv.key_ptr.*;
        const balance = kv.value_ptr.*;
        if (self.convert(balance, from, to)) |converted| {
            try result.add(to, converted);
        } else {
            try result.add(from, balance);
        }
    }
}

// --- tests ------------------------------------------------------------------

fn testCurrency(pool: *StringPool, alloc: Allocator, name: []const u8) !CurrencyIndex {
    const raw = try pool.intern(alloc, name);
    return @enumFromInt(@intFromEnum(raw));
}

test "setPrice stores both forward and inverse rates" {
    const alloc = std.testing.allocator;
    var pool = try StringPool.init(alloc);
    defer pool.deinit(alloc);

    const usd = try testCurrency(&pool, alloc, "USD");
    const eur = try testCurrency(&pool, alloc, "EUR");

    var prices = init(alloc);
    defer prices.deinit();

    try prices.setPrice(usd, eur, Number.fromFloat(2.0));
    try std.testing.expectEqual(Number.fromFloat(2.0), prices.getPrice(usd, eur).?);
    try std.testing.expectEqual(Number.fromFloat(0.5), prices.getPrice(eur, usd).?);
}

test "getPrice returns null for unknown pair" {
    const alloc = std.testing.allocator;
    var pool = try StringPool.init(alloc);
    defer pool.deinit(alloc);

    const usd = try testCurrency(&pool, alloc, "USD");
    const eur = try testCurrency(&pool, alloc, "EUR");

    var prices = init(alloc);
    defer prices.deinit();

    try std.testing.expect(prices.getPrice(usd, eur) == null);
}

test "convert same currency" {
    const alloc = std.testing.allocator;
    var pool = try StringPool.init(alloc);
    defer pool.deinit(alloc);
    const usd = try testCurrency(&pool, alloc, "USD");

    var prices = init(alloc);
    defer prices.deinit();

    const amount = Number.fromFloat(100);
    try std.testing.expectEqual(amount, prices.convert(amount, usd, usd).?);
}

test "convert across currencies" {
    const alloc = std.testing.allocator;
    var pool = try StringPool.init(alloc);
    defer pool.deinit(alloc);
    const usd = try testCurrency(&pool, alloc, "USD");
    const eur = try testCurrency(&pool, alloc, "EUR");

    var prices = init(alloc);
    defer prices.deinit();

    try prices.setPrice(usd, eur, Number.fromFloat(2.0));
    try std.testing.expectEqual(Number.fromFloat(200), prices.convert(Number.fromFloat(100), usd, eur).?);
}

test "no inverse of zero rate" {
    const alloc = std.testing.allocator;
    var pool = try StringPool.init(alloc);
    defer pool.deinit(alloc);
    const usd = try testCurrency(&pool, alloc, "USD");
    const eur = try testCurrency(&pool, alloc, "EUR");

    var prices = init(alloc);
    defer prices.deinit();

    try prices.setPrice(usd, eur, Number.fromFloat(0));
    try std.testing.expect(prices.convert(Number.fromFloat(100), eur, usd) == null);
}
