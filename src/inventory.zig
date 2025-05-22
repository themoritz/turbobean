const std = @import("std");
const Allocator = std.mem.Allocator;
const Number = @import("number.zig").Number;
const Date = @import("date.zig").Date;

const Inventory = struct {
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
            try self.by_currency.remove(currency);
        } else {
            try self.by_currency.put(currency, new);
        }
    }

    pub fn balance(self: *const Inventory, currency: []const u8) Number {
        return self.by_currency.get(currency) orelse Number.zero();
    }
};
