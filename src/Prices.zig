const std = @import("std");
const Allocator = std.mem.Allocator;
const Number = @import("number.zig").Number;
const Data = @import("data.zig");
const PriceDeclView = Data.PriceDeclView;
const CurrencyIndex = Data.CurrencyIndex;
const PlainInventory = @import("inventory.zig").PlainInventory;
const Summary = @import("inventory.zig").Summary;
const CurrencyPool = @import("string_pool.zig").CurrencyPool;

const Self = @This();

latest_prices: PriceMap,
allocator: Allocator,

const CurrencyPair = struct {
    from: CurrencyIndex,
    to: CurrencyIndex,
};

const PriceMap = std.AutoHashMap(CurrencyPair, Number);

pub fn init(alloc: Allocator) Self {
    return .{
        .latest_prices = PriceMap.init(alloc),
        .allocator = alloc,
    };
}

pub fn deinit(self: *Self) void {
    self.latest_prices.deinit();
}

/// Set the latest price for a currency pair. Also stores the inverse pair
/// automatically. `rate` is the number to multiply with when going from `from`
/// to `to`.
///
/// Example: setPrice("USD", "EUR", 1.5) will store:
///   - USD -> EUR: 1.5
///   - EUR -> USD: 0.666...
pub fn setPricePlain(self: *Self, from: CurrencyIndex, to: CurrencyIndex, rate: Number) !void {
    try self.latest_prices.put(.{ .from = from, .to = to }, rate);
    if (!rate.is_zero()) {
        const inverse_rate = try Number.fromInt(1).div(rate);
        try self.latest_prices.put(.{ .from = to, .to = from }, inverse_rate);
    }
}

/// Assumes a `PriceDeclView` has already been validated and contains a valid amount.
pub fn setPrice(self: *Self, decl: PriceDeclView) !void {
    try self.setPricePlain(decl.currency, decl.amount_currency, decl.amount);
}

/// Get the conversion rate from one currency to another. Returns `null` if no
/// price is available.
pub fn getPrice(self: *const Self, from: CurrencyIndex, to: CurrencyIndex) ?Number {
    return self.latest_prices.get(.{ .from = from, .to = to });
}

/// Convert an amount from one currency to another. Returns null if no price is
/// available.
pub fn convert(self: *const Self, amount: Number, from: CurrencyIndex, to: CurrencyIndex) ?Number {
    if (from == to) return amount;
    const rate = self.getPrice(from, to) orelse return null;
    return amount.mul(rate).normalize();
}

/// Convert everything to the `to` currency if possible according to this price
/// table.
///
/// Caller owns returned inventory.
pub fn convertInventory(
    self: *const Self,
    inventory: *const PlainInventory,
    to: CurrencyIndex,
    result: *PlainInventory,
) !void {
    result.clear();
    var iter = inventory.by_currency.iterator();
    while (iter.next()) |kv| {
        const from = kv.key;
        const balance = kv.value_ptr.*;
        if (self.convert(balance, from, to)) |converted| {
            try result.add(to, converted);
        } else {
            try result.add(from, balance);
        }
    }
}

test "setPrice stores both forward and inverse rates" {
    const alloc = std.testing.allocator;
    var pool = try CurrencyPool.init(alloc);
    defer pool.deinit(alloc);

    const usd = try pool.intern(alloc, "USD");
    const eur = try pool.intern(alloc, "EUR");

    var prices = init(alloc);
    defer prices.deinit();

    try prices.setPricePlain(usd, eur, Number.fromFloat(2.0));
    try std.testing.expectEqual(Number.fromFloat(2.0), prices.getPrice(usd, eur).?);
    try std.testing.expectEqual(Number.fromFloat(0.5), prices.getPrice(eur, usd).?);
}

test "getPrice returns null for unknown pair" {
    const alloc = std.testing.allocator;
    var pool = try CurrencyPool.init(alloc);
    defer pool.deinit(alloc);

    const usd = try pool.intern(alloc, "USD");
    const eur = try pool.intern(alloc, "EUR");

    var prices = init(alloc);
    defer prices.deinit();

    try std.testing.expect(prices.getPrice(usd, eur) == null);
}

test "setPrice updates existing rates" {
    const alloc = std.testing.allocator;
    var pool = try CurrencyPool.init(alloc);
    defer pool.deinit(alloc);

    const usd = try pool.intern(alloc, "USD");
    const eur = try pool.intern(alloc, "EUR");

    var prices = init(alloc);
    defer prices.deinit();

    try prices.setPricePlain(usd, eur, Number.fromFloat(1.5));
    try prices.setPricePlain(usd, eur, Number.fromFloat(2.0));

    const rate = prices.getPrice(usd, eur).?;
    try std.testing.expectEqual(Number.fromFloat(2.0), rate);

    // Inverse should also be updated
    const inverse = prices.getPrice(eur, usd).?;
    try std.testing.expectEqual(Number.fromFloat(0.5), inverse);
}

test "convert amount between currencies" {
    const alloc = std.testing.allocator;
    var pool = try CurrencyPool.init(alloc);
    defer pool.deinit(alloc);

    const usd = try pool.intern(alloc, "USD");
    const eur = try pool.intern(alloc, "EUR");

    var prices = init(alloc);
    defer prices.deinit();

    try prices.setPricePlain(usd, eur, Number.fromFloat(2.0));

    // Convert 100 USD to EUR
    const result = prices.convert(Number.fromFloat(100), usd, eur).?;
    try std.testing.expectEqual(Number.fromFloat(200), result);
}

test "convert returns null for unknown currency pair" {
    const alloc = std.testing.allocator;
    var pool = try CurrencyPool.init(alloc);
    defer pool.deinit(alloc);

    const usd = try pool.intern(alloc, "USD");
    const eur = try pool.intern(alloc, "EUR");

    var prices = init(alloc);
    defer prices.deinit();

    const result = prices.convert(Number.fromFloat(100), usd, eur);
    try std.testing.expect(result == null);
}

test "convert returns same amount for same currency" {
    const alloc = std.testing.allocator;
    var pool = try CurrencyPool.init(alloc);
    defer pool.deinit(alloc);

    const usd = try pool.intern(alloc, "USD");

    var prices = init(alloc);
    defer prices.deinit();

    const amount = Number.fromFloat(100);
    const result = prices.convert(amount, usd, usd).?;
    try std.testing.expectEqual(amount, result);
}

test "no inverse of zero rate" {
    const alloc = std.testing.allocator;
    var pool = try CurrencyPool.init(alloc);
    defer pool.deinit(alloc);

    const usd = try pool.intern(alloc, "USD");
    const eur = try pool.intern(alloc, "EUR");

    var prices = init(alloc);
    defer prices.deinit();

    try prices.setPricePlain(usd, eur, Number.fromFloat(0));
    try std.testing.expect(prices.convert(Number.fromFloat(100), eur, usd) == null);
}
