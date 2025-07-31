const std = @import("std");
const Allocator = std.mem.Allocator;
const Number = @import("number.zig").Number;
const Date = @import("date.zig").Date;
const LotSpec = @import("data.zig").LotSpec;

pub const BookingMethod = enum {
    fifo,
    lifo,
    strict,
};

pub const Booking = struct {
    method: BookingMethod,
    cost_currency: []const u8,
};

pub const Lot = struct {
    units: Number,
    cost: Cost,
};

pub const Cost = struct {
    price: Number,
    date: Date,
    label: ?[]const u8,

    fn with_lot_spec(self: *const Cost, spec: ?LotSpec) Cost {
        if (spec) |s| {
            return Cost{
                .price = if (s.price) |p| p.number.? else self.price,
                .date = s.date orelse self.date,
                .label = s.label orelse self.label,
            };
        } else {
            return self.*;
        }
    }
};

pub const Lots = struct {
    booking_method: BookingMethod,
    lots: std.ArrayListUnmanaged(Lot),

    pub fn init(booking_method: BookingMethod) Lots {
        return .{
            .booking_method = booking_method,
            .lots = std.ArrayListUnmanaged(Lot){},
        };
    }

    pub fn deinit(self: *Lots, alloc: Allocator) void {
        self.lots.deinit(alloc);
    }

    /// lot: the lot that should be booked
    /// lot_spec:
    /// - If reducing lots: filter the lots to reduce.
    /// - If introducing new lots: Overwrite the properties of the new lot.
    /// Returns: cost-weight
    pub fn book(self: *Lots, alloc: Allocator, lot: Lot, lot_spec: ?LotSpec) !Number {
        // For a long lot, these are shorts which match lot_spec
        // For a short lot, longs that match lot_spec
        var filtered = std.ArrayList(usize).init(alloc);
        defer filtered.deinit();

        for (self.lots.items, 0..) |l, i| {
            if (lot.units.is_positive() and l.units.is_positive()) continue;
            if (lot.units.is_negative() and l.units.is_negative()) continue;

            if (lot_spec) |spec| {
                if (spec.price) |price| {
                    if (!l.cost.price.sub(price.number.?).is_zero()) continue;
                }
                if (spec.date) |date| {
                    if (!std.meta.eql(l.cost.date, date)) continue;
                }
                if (spec.label) |l1| {
                    if (l.cost.label) |l2| {
                        if (!std.mem.eql(u8, l1, l2)) continue;
                    }
                }
            }
            try filtered.append(i);
        }

        if (filtered.items.len > 1) {
            var total_filtered = Number.zero();
            for (filtered.items) |i|
                total_filtered = total_filtered.add(self.lots.items[i].units);
            if (!total_filtered.sub(lot.units).is_zero()) {
                switch (self.booking_method) {
                    .strict => {
                        return error.CantDisambiguateLots;
                    },
                    .fifo => {
                        std.sort.block(usize, filtered.items, self.lots.items, struct {
                            fn lessThan(lots: []Lot, a: usize, b: usize) bool {
                                return lots[a].cost.date.compare(lots[b].cost.date) == .after;
                            }
                        }.lessThan);
                    },
                    .lifo => {
                        std.sort.block(usize, filtered.items, self.lots.items, struct {
                            fn lessThan(lots: []Lot, a: usize, b: usize) bool {
                                return lots[a].cost.date.compare(lots[b].cost.date) == .before;
                            }
                        }.lessThan);
                    },
                }
            }
        }

        var cost_weight = Number.zero();

        if (lot.units.is_positive()) {
            var remaining = lot.units;
            for (filtered.items) |i| {
                const l = &self.lots.items[i];
                if (remaining.is_positive()) {
                    std.debug.assert(l.units.is_negative());
                    const to_book = l.units.negate().min(remaining);
                    cost_weight = cost_weight.add(l.cost.price.mul(to_book));
                    l.units = l.units.add(to_book);
                    remaining = remaining.sub(to_book);
                    if (remaining.is_zero()) break;
                }
            }
            if (remaining.is_positive()) {
                cost_weight = cost_weight.add(remaining.mul(lot.cost.price));
                try self.lots.append(alloc, Lot{
                    .units = remaining,
                    .cost = lot.cost.with_lot_spec(lot_spec),
                });
            }
        }

        if (lot.units.is_negative()) {
            var remaining = lot.units;
            for (filtered.items) |i| {
                const l = &self.lots.items[i];
                if (remaining.is_negative()) {
                    std.debug.assert(l.units.is_positive());
                    const to_book = l.units.min(remaining.negate());
                    cost_weight = cost_weight.sub(l.cost.price.mul(to_book));
                    l.units = l.units.sub(to_book);
                    remaining = remaining.add(to_book);
                    if (remaining.is_zero()) break;
                }
            }
            if (remaining.is_negative()) {
                cost_weight = cost_weight.add(remaining.mul(lot.cost.price));
                try self.lots.append(alloc, Lot{
                    .units = remaining,
                    .cost = lot.cost.with_lot_spec(lot_spec),
                });
            }
        }

        // Filter out empty lots
        var write_index: usize = 0;
        for (self.lots.items) |l| {
            if (!l.units.is_zero()) {
                self.lots.items[write_index] = l;
                write_index += 1;
            }
        }
        self.lots.shrinkRetainingCapacity(write_index);

        // Check lots are either all long or all short.
        std.debug.assert(b: {
            var long: ?bool = null;
            for (self.lots.items) |l| {
                if (long) |lng| {
                    if (lng and l.units.is_negative()) break :b false;
                    if (!lng and l.units.is_positive()) break :b false;
                } else {
                    if (l.units.is_positive()) long = true;
                    if (l.units.is_negative()) long = false;
                }
            }
            break :b true;
        });

        return cost_weight;
    }

    pub fn balance(self: *Lots) Number {
        var result = Number.zero();
        for (self.lots.items) |lot| result = result.add(lot.units);
        return result;
    }

    pub fn clone(self: *const Lots, alloc: Allocator) !Lots {
        return .{
            .booking_method = self.booking_method,
            .longs = try self.longs.clone(alloc),
            .shorts = try self.shorts.clone(alloc),
        };
    }
};

pub const LotsInventory = struct {
    alloc: Allocator,
    restricted: bool,
    booking: Booking,
    by_currency: std.StringHashMap(Lots),

    pub fn init(
        alloc: Allocator,
        booking: Booking,
        currencies: ?[][]const u8,
    ) !LotsInventory {
        if (currencies) |cs| {
            var by_currency = std.StringHashMap(Lots).init(alloc);
            for (cs) |c| try by_currency.put(c, Lots.init(booking.method));

            return .{
                .alloc = alloc,
                .restricted = true,
                .booking = booking,
                .by_currency = by_currency,
            };
        } else {
            return .{
                .alloc = alloc,
                .restricted = false,
                .booking = booking,
                .by_currency = std.StringHashMap(Lots).init(alloc),
            };
        }
    }

    pub fn deinit(self: *LotsInventory) void {
        var iter = self.by_currency.valueIterator();
        while (iter.next()) |v| v.deinit(self.alloc);
        self.by_currency.deinit();
    }

    pub fn book(
        self: *LotsInventory,
        currency: []const u8,
        lot: Lot,
        cost_currency: []const u8,
        lot_spec: ?LotSpec,
    ) !Number {
        if (!std.mem.eql(u8, cost_currency, self.booking.cost_currency)) {
            return error.CostCurrencyDoesNotMatch;
        }
        if (lot_spec) |spec| {
            if (spec.price) |price| {
                if (!std.mem.eql(u8, price.currency.?, self.booking.cost_currency)) {
                    return error.CostCurrencyDoesNotMatch;
                }
            }
        }
        if (self.by_currency.getPtr(currency)) |lots| {
            return try lots.book(self.alloc, lot, lot_spec);
        } else {
            if (self.restricted) {
                return error.DoesNotHoldCurrency;
            } else {
                var lots = Lots.init(self.booking.method);
                const cost_weight = lots.book(self.alloc, lot, lot_spec);
                try self.by_currency.put(currency, lots);
                return cost_weight;
            }
        }
    }

    pub fn isEmpty(self: *const LotsInventory) bool {
        var iter = self.by_currency.valueIterator();
        while (iter.next()) |v| {
            if (v.lots.items.len > 0) return false;
        }
        return true;
    }

    pub fn summary(self: *const LotsInventory, alloc: Allocator) !Summary {
        var by_currency = std.StringHashMap(Summary.CurrencySummary).init(alloc);
        var iter = self.by_currency.iterator();
        while (iter.next()) |kv| {
            try by_currency.put(kv.key_ptr.*, .{
                .plain = Number.zero(),
                .cost_currency = self.booking.cost_currency,
                .lots = try kv.value_ptr.lots.clone(alloc),
            });
        }
        return Summary{
            .by_currency = by_currency,
            .alloc = alloc,
        };
    }

    pub fn clone(self: *const LotsInventory, alloc: Allocator) !LotsInventory {
        var result = LotsInventory{
            .alloc = alloc,
            .restricted = self.restricted,
            .booking = self.booking,
            .by_currency = std.StringHashMap(Lots).init(alloc),
        };
        errdefer result.deinit();
        var iter = self.by_currency.iterator();
        while (iter.next()) |kv| {
            var lots = try kv.value_ptr.clone(alloc);
            errdefer lots.deinit(alloc);
            try result.by_currency.put(kv.key_ptr.*, lots);
        }
        return result;
    }
};

/// Just records units by currency.
pub const PlainInventory = struct {
    alloc: Allocator,
    restricted: bool,
    by_currency: std.StringHashMap(Number),

    pub fn init(alloc: Allocator, currencies: ?[][]const u8) !PlainInventory {
        if (currencies) |cs| {
            var by_currency = std.StringHashMap(Number).init(alloc);
            for (cs) |c| try by_currency.put(c, Number.zero());

            return .{
                .alloc = alloc,
                .restricted = true,
                .by_currency = by_currency,
            };
        } else {
            return .{
                .alloc = alloc,
                .restricted = false,
                .by_currency = std.StringHashMap(Number).init(alloc),
            };
        }
    }

    pub fn deinit(self: *PlainInventory) void {
        self.by_currency.deinit();
    }

    pub fn add(self: *PlainInventory, currency: []const u8, number: Number) !void {
        const old = try self.balance(currency);
        const new = old.add(number);
        try self.by_currency.put(currency, new);
    }

    pub fn balance(self: *const PlainInventory, currency: []const u8) !Number {
        return self.by_currency.get(currency) orelse
            if (self.restricted) error.DoesNotHoldCurrency else Number.zero();
    }

    pub fn isEmpty(self: *const PlainInventory) bool {
        var iter = self.by_currency.valueIterator();
        while (iter.next()) |v| {
            if (!v.is_zero()) return false;
        }
        return true;
    }

    pub fn summary(self: *const PlainInventory, alloc: Allocator) !Summary {
        var by_currency = std.StringHashMap(Summary.CurrencySummary).init(alloc);
        var iter = self.by_currency.iterator();
        while (iter.next()) |kv| {
            try by_currency.put(kv.key_ptr.*, .{
                .plain = kv.value_ptr.*,
                .cost_currency = null,
                .lots = .{},
            });
        }
        return .{ .by_currency = by_currency, .alloc = alloc };
    }

    pub fn clone(self: *const PlainInventory, alloc: Allocator) !PlainInventory {
        return .{
            .alloc = alloc,
            .restricted = self.restricted,
            .by_currency = try self.by_currency.cloneWithAllocator(alloc),
        };
    }
};

pub const Inventory = union(enum) {
    plain: PlainInventory,
    lots: LotsInventory,

    pub fn init(alloc: Allocator, booking: ?Booking, currencies: ?[][]const u8) !Inventory {
        if (booking) |b| {
            return .{
                .lots = try LotsInventory.init(alloc, b, currencies),
            };
        } else {
            return .{
                .plain = try PlainInventory.init(alloc, currencies),
            };
        }
    }

    pub fn deinit(self: *Inventory) void {
        switch (self.*) {
            .plain => |*inv| inv.deinit(),
            .lots => |*inv| inv.deinit(),
        }
    }

    pub fn add(self: *Inventory, currency: []const u8, number: Number) !void {
        switch (self.*) {
            .plain => |*inv| try inv.add(currency, number),
            .lots => return error.CannotAddToLotsInventory,
        }
    }

    pub fn book(
        self: *Inventory,
        currency: []const u8,
        lot: Lot,
        cost_currency: []const u8,
    ) !Number {
        switch (self.*) {
            .plain => return error.CannotBookToPlainInventory,
            .lots => |*inv| return try inv.book(currency, lot, cost_currency),
        }
    }

    pub fn isEmpty(self: *const Inventory) bool {
        return switch (self.*) {
            .plain => |inv| inv.isEmpty(),
            .lots => |inv| inv.isEmpty(),
        };
    }

    pub fn summary(self: *const Inventory, alloc: Allocator) !Summary {
        return switch (self.*) {
            .plain => |inv| inv.summary(alloc),
            .lots => |inv| inv.summary(alloc),
        };
    }

    pub fn clone(self: *const Inventory, alloc: Allocator) !Inventory {
        return switch (self.*) {
            .plain => |inv| .{ .plain = try inv.clone(alloc) },
            .lots => |inv| .{ .lots = try inv.clone(alloc) },
        };
    }
};

pub const Summary = struct {
    by_currency: std.StringHashMap(CurrencySummary),
    alloc: Allocator,

    pub const CurrencySummary = struct {
        plain: Number,
        cost_currency: ?[]const u8,
        lots: std.ArrayListUnmanaged(Lot),
    };

    pub fn init(alloc: Allocator) Summary {
        return .{
            .by_currency = std.StringHashMap(CurrencySummary).init(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Summary) void {
        var iter = self.by_currency.valueIterator();
        while (iter.next()) |v| v.lots.deinit(self.alloc);
        self.by_currency.deinit();
    }

    pub fn isEmpty(self: *const Summary) bool {
        var iter = self.by_currency.valueIterator();
        while (iter.next()) |v| {
            if (!v.plain.is_zero() or v.lots.items.len > 0) return false;
        }
        return true;
    }

    pub fn combine(self: *Summary, other: Summary) !void {
        var iter = other.by_currency.iterator();
        while (iter.next()) |entry| {
            if (self.by_currency.getPtr(entry.key_ptr.*)) |v| {
                v.plain = v.plain.add(entry.value_ptr.plain);
                for (entry.value_ptr.lots.items) |l| try v.lots.append(self.alloc, l);
            } else {
                try self.by_currency.put(entry.key_ptr.*, .{
                    .plain = entry.value_ptr.plain,
                    .cost_currency = entry.value_ptr.cost_currency,
                    .lots = try entry.value_ptr.lots.clone(self.alloc),
                });
            }
        }
    }

    pub fn balance(self: *const Summary, currency: []const u8) Number {
        if (self.by_currency.get(currency)) |v| {
            var result = v.plain;
            for (v.lots.items) |l| result = result.add(l.units);
            return result;
        } else {
            return Number.zero();
        }
    }

    pub fn treeDisplay(self: *const Summary, indent: u32, writer: std.io.AnyWriter) !void {
        var iter = self.by_currency.iterator();
        var first = true;
        while (iter.next()) |kv| {
            if (!kv.value_ptr.plain.is_zero()) {
                if (!first) {
                    try writer.writeByte('\n');
                    try writer.writeByteNTimes(' ', indent);
                }
                try writer.print("{any} {s}", .{ kv.value_ptr.plain, kv.key_ptr.* });
                first = false;
            }
            if (kv.value_ptr.lots.items.len > 0) {
                for (kv.value_ptr.lots.items) |lot| {
                    if (!first) {
                        try writer.writeByte('\n');
                        try writer.writeByteNTimes(' ', indent);
                    }
                    try writer.print("{} {s} @ {} {s} {{{}", .{
                        lot.units,
                        kv.key_ptr.*,
                        lot.cost.price,
                        kv.value_ptr.cost_currency.?,
                        lot.cost.date,
                    });
                    if (lot.cost.label) |label| {
                        try writer.print(", {s}", .{label});
                    }
                    try writer.print("}}", .{});
                    first = false;
                }
            }
        }
    }

    pub fn hoverDisplay(self: *const Summary, writer: std.io.AnyWriter) !void {
        var iter = self.by_currency.iterator();
        while (iter.next()) |kv| {
            if (!kv.value_ptr.plain.is_zero()) {
                try writer.print("• {any} {s}\n", .{ kv.value_ptr.plain, kv.key_ptr.* });
            }
            if (kv.value_ptr.lots.items.len > 0) {
                for (kv.value_ptr.lots.items) |lot| {
                    try writer.print("• {} {s} @ {} {s} {{{}", .{
                        lot.units,
                        kv.key_ptr.*,
                        lot.cost.price,
                        kv.value_ptr.cost_currency.?,
                        lot.cost.date,
                    });
                    if (lot.cost.label) |label| {
                        try writer.print(", {s}", .{label});
                    }
                    try writer.print("}}\n", .{});
                }
            }
        }
    }
};

test "cost weight" {
    const alloc = std.testing.allocator;

    var inv = Lots.init(.fifo);
    defer inv.deinit(alloc);

    _ = try inv.book(alloc, Lot{
        .units = Number.fromInt(10),
        .cost = Cost{
            .price = Number.fromInt(10),
            .date = try Date.fromSlice("2025-01-01"),
            .label = null,
        },
    }, null);
    _ = try inv.book(alloc, Lot{
        .units = Number.fromInt(10),
        .cost = Cost{
            .price = Number.fromInt(15),
            .date = try Date.fromSlice("2025-01-02"),
            .label = null,
        },
    }, null);
    const cost_weight = try inv.book(alloc, Lot{
        .units = Number.fromInt(-15),
        .cost = Cost{
            .price = Number.fromInt(30),
            .date = try Date.fromSlice("2025-01-03"),
            .label = null,
        },
    }, null);

    try std.testing.expectEqual(Number.fromInt(-175), cost_weight);
    try std.testing.expectEqual(1, inv.lots.items.len);
    try std.testing.expectEqual(Number.fromInt(5), inv.balance());
}

test "cross line" {
    const alloc = std.testing.allocator;

    var inv = Lots.init(.fifo);
    defer inv.deinit(alloc);

    _ = try inv.book(alloc, Lot{
        .units = Number.fromInt(-1),
        .cost = Cost{
            .price = Number.fromInt(10),
            .date = try Date.fromSlice("2025-01-01"),
            .label = null,
        },
    }, null);
    const cost_weight = try inv.book(alloc, Lot{
        .units = Number.fromInt(2),
        .cost = Cost{
            .price = Number.fromInt(20),
            .date = try Date.fromSlice("2025-01-03"),
            .label = null,
        },
    }, null);

    try std.testing.expectEqual(Number.fromInt(30), cost_weight);
    try std.testing.expectEqual(1, inv.lots.items.len);
    try std.testing.expectEqual(Number.fromInt(1), inv.balance());
}

test "combine" {
    var plain = try PlainInventory.init(std.testing.allocator, null);
    defer plain.deinit();
    var lots = try LotsInventory.init(
        std.testing.allocator,
        .{ .method = .fifo, .cost_currency = "NZD" },
        null,
    );
    defer lots.deinit();
    try plain.add("USD", Number.fromInt(1));
    _ = try lots.book("USD", Lot{
        .units = Number.fromInt(1),
        .cost = Cost{
            .price = Number.fromInt(10),
            .date = try Date.fromSlice("2025-01-01"),
            .label = null,
        },
    }, "NZD", null);
    _ = try lots.book("EUR", Lot{
        .units = Number.fromInt(2),
        .cost = Cost{
            .price = Number.fromInt(10),
            .date = try Date.fromSlice("2025-01-01"),
            .label = null,
        },
    }, "NZD", null);
    var plain_sum = try plain.summary(std.testing.allocator);
    var lots_sum = try lots.summary(std.testing.allocator);
    defer plain_sum.deinit();
    defer lots_sum.deinit();
    try plain_sum.combine(lots_sum);
    try std.testing.expectEqual(Number.fromInt(1), plain_sum.by_currency.get("USD").?.plain);
    try std.testing.expectEqual(1, plain_sum.by_currency.get("USD").?.lots.items.len);
    try std.testing.expectEqual(1, plain_sum.by_currency.get("EUR").?.lots.items.len);
}

test "plain empty" {
    var inv = try PlainInventory.init(std.testing.allocator, null);
    defer inv.deinit();

    try std.testing.expect(inv.isEmpty());
    try inv.add("USD", Number.fromInt(1));
    try std.testing.expect(!inv.isEmpty());
    try inv.add("USD", Number.fromInt(-1));
    try std.testing.expect(inv.isEmpty());
}

test "lots empty" {
    var inv = try LotsInventory.init(
        std.testing.allocator,
        .{ .method = .fifo, .cost_currency = "NZD" },
        null,
    );
    defer inv.deinit();

    try std.testing.expect(inv.isEmpty());
    _ = try inv.book("USD", Lot{
        .units = Number.fromInt(1),
        .cost = Cost{
            .price = Number.fromInt(10),
            .date = try Date.fromSlice("2025-01-01"),
            .label = null,
        },
    }, "NZD", null);
    try std.testing.expect(!inv.isEmpty());
    _ = try inv.book("USD", Lot{
        .units = Number.fromInt(-1),
        .cost = Cost{
            .price = Number.fromInt(10),
            .date = try Date.fromSlice("2025-01-02"),
            .label = null,
        },
    }, "NZD", null);
    try std.testing.expect(inv.isEmpty());
}

// test "format" {
//     var inv = Inventory.init(std.testing.allocator);
//     defer inv.deinit();
//
//     try inv.add(Number.fromInt(1), "USD");
//     try inv.add(Number.fromInt(2), "EUR");
//
//     const result = try std.fmt.allocPrint(std.testing.allocator, "{any}", .{inv});
//     defer std.testing.allocator.free(result);
//
//     try std.testing.expectEqualStrings("2 EUR, 1 USD", result);
// }
