const std = @import("std");
const Allocator = std.mem.Allocator;
const Number = @import("number.zig").Number;
const Date = @import("date.zig").Date;

pub const Inventory = struct {
    alloc: Allocator,
    by_currency: std.StringHashMap(Number),

    pub fn init(alloc: Allocator) Inventory {
        return Inventory{
            .alloc = alloc,
            .by_currency = std.StringHashMap(Number).init(alloc),
        };
    }

    pub fn deinit(self: *Inventory) void {
        self.by_currency.deinit();
    }

    pub fn add(self: *Inventory, number: Number, currency: []const u8) !void {
        const old = self.balance(currency);
        const new = old.add(number);
        if (new.is_zero()) {
            _ = self.by_currency.remove(currency);
        } else {
            try self.by_currency.put(currency, new);
        }
    }

    pub fn combine(self: *Inventory, other: *Inventory) !void {
        var iter = other.by_currency.iterator();
        while (iter.next()) |entry| {
            try self.add(entry.value_ptr.*, entry.key_ptr.*);
        }
    }

    pub fn balance(self: *const Inventory, currency: []const u8) Number {
        return self.by_currency.get(currency) orelse Number.zero();
    }

    pub fn isEmpty(self: *const Inventory) bool {
        return self.by_currency.count() == 0;
    }

    pub fn format(self: *const Inventory, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        var iter = self.by_currency.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) {
                try std.fmt.format(writer, ", ", .{});
            }
            first = false;
            try std.fmt.format(writer, "{any} {s}", .{ entry.value_ptr.*, entry.key_ptr.* });
        }
    }

    pub fn clone(self: *const Inventory, alloc: Allocator) !Inventory {
        var result = Inventory.init(alloc);
        errdefer result.deinit();
        var iter = self.by_currency.iterator();
        while (iter.next()) |entry| {
            try result.add(entry.value_ptr.*, entry.key_ptr.*);
        }
        return result;
    }
};

test "combine" {
    var inv1 = Inventory.init(std.testing.allocator);
    defer inv1.deinit();
    var inv2 = Inventory.init(std.testing.allocator);
    defer inv2.deinit();
    try inv1.add(Number.fromInt(1), "USD");
    try inv2.add(Number.fromInt(2), "USD");
    try inv2.add(Number.fromInt(2), "EUR");
    try inv1.combine(&inv2);
    try std.testing.expectEqual(Number.fromInt(3), inv1.balance("USD"));
    try std.testing.expectEqual(Number.fromInt(2), inv1.balance("EUR"));
}

test "empty" {
    var inv = Inventory.init(std.testing.allocator);
    defer inv.deinit();

    try std.testing.expect(inv.isEmpty());
    try inv.add(Number.fromInt(1), "USD");
    try std.testing.expect(!inv.isEmpty());
    try inv.add(Number.fromInt(-1), "USD");
    try std.testing.expect(inv.isEmpty());
}

test "format" {
    var inv = Inventory.init(std.testing.allocator);
    defer inv.deinit();

    try inv.add(Number.fromInt(1), "USD");
    try inv.add(Number.fromInt(2), "EUR");

    const result = try std.fmt.allocPrint(std.testing.allocator, "{any}", .{inv});
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("2 EUR, 1 USD", result);
}
