const std = @import("std");
const Allocator = std.mem.Allocator;
const Number = @import("number.zig").Number;
const PriceDecl = @import("data.zig").PriceDecl;
const PlainInventory = @import("inventory.zig").PlainInventory;
const Summary = @import("inventory.zig").Summary;

const Self = @This();

latest_prices: PriceMap,
allocator: Allocator,

const PriceMap = std.HashMap(
    CurrencyPair,
    Number,
    CurrencyPairContext,
    std.hash_map.default_max_load_percentage,
);

const CurrencyPair = struct {
    from: []const u8,
    to: []const u8,
};

const CurrencyPairContext = struct {
    pub fn hash(_: CurrencyPairContext, key: CurrencyPair) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.from);
        hasher.update(key.to);
        return hasher.final();
    }

    pub fn eql(_: CurrencyPairContext, a: CurrencyPair, b: CurrencyPair) bool {
        return std.mem.eql(u8, a.from, b.from) and
            std.mem.eql(u8, a.to, b.to);
    }
};

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
pub fn setPricePlain(self: *Self, from: []const u8, to: []const u8, rate: Number) !void {
    const pair = CurrencyPair{ .from = from, .to = to };
    try self.latest_prices.put(pair, rate);

    // Store the inverse rate
    if (!rate.is_zero()) {
        const inverse_rate = try Number.fromInt(1).div(rate);
        const inverse_pair = CurrencyPair{ .from = to, .to = from };
        try self.latest_prices.put(inverse_pair, inverse_rate);
    }
}

/// Assumes a `PriceDecl` has already been validated and contains a valid amount.
pub fn setPrice(self: *Self, decl: PriceDecl) !void {
    try self.setPricePlain(decl.currency, decl.amount.currency.?, decl.amount.number.?);
}

/// Get the conversion rate from one currency to another. Returns `null` if no
/// price is available.
pub fn getPrice(self: *const Self, from: []const u8, to: []const u8) ?Number {
    const pair = CurrencyPair{ .from = from, .to = to };
    return self.latest_prices.get(pair);
}

/// Convert an amount from one currency to another. Returns null if no price is
/// available.
pub fn convert(self: *const Self, amount: Number, from: []const u8, to: []const u8) ?Number {
    if (std.mem.eql(u8, from, to)) {
        return amount;
    }

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
    to: []const u8,
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

test "setPrice stores both forward and inverse rates" {
    var prices = init(std.testing.allocator);
    defer prices.deinit();

    try prices.setPricePlain("USD", "EUR", Number.fromFloat(2.0));

    const usd_to_eur = prices.getPrice("USD", "EUR").?;
    const eur_to_usd = prices.getPrice("EUR", "USD").?;

    try std.testing.expectEqual(Number.fromFloat(2.0), usd_to_eur);
    try std.testing.expectEqual(Number.fromFloat(0.5), eur_to_usd);
}

test "getPrice returns null for unknown pair" {
    var prices = init(std.testing.allocator);
    defer prices.deinit();

    const result = prices.getPrice("USD", "EUR");
    try std.testing.expect(result == null);
}

test "setPrice updates existing rates" {
    var prices = init(std.testing.allocator);
    defer prices.deinit();

    try prices.setPricePlain("USD", "EUR", Number.fromFloat(1.5));
    try prices.setPricePlain("USD", "EUR", Number.fromFloat(2.0));

    const rate = prices.getPrice("USD", "EUR").?;
    try std.testing.expectEqual(Number.fromFloat(2.0), rate);

    // Inverse should also be updated
    const inverse = prices.getPrice("EUR", "USD").?;
    try std.testing.expectEqual(Number.fromFloat(0.5), inverse);
}

test "convert amount between currencies" {
    var prices = init(std.testing.allocator);
    defer prices.deinit();

    try prices.setPricePlain("USD", "EUR", Number.fromFloat(2.0));

    // Convert 100 USD to EUR
    const result = prices.convert(Number.fromFloat(100), "USD", "EUR").?;
    try std.testing.expectEqual(Number.fromFloat(200), result);
}

test "convert returns null for unknown currency pair" {
    var prices = init(std.testing.allocator);
    defer prices.deinit();

    const result = prices.convert(Number.fromFloat(100), "USD", "EUR");
    try std.testing.expect(result == null);
}

test "convert returns same amount for same currency" {
    var prices = init(std.testing.allocator);
    defer prices.deinit();

    const amount = Number.fromFloat(100);
    const result = prices.convert(amount, "USD", "USD").?;
    try std.testing.expectEqual(amount, result);
}

test "no inverse of zero rate" {
    var prices = init(std.testing.allocator);
    defer prices.deinit();

    try prices.setPricePlain("USD", "EUR", Number.fromFloat(0));

    const result = prices.convert(Number.fromFloat(100), "EUR", "USD");
    try std.testing.expect(result == null);
}
