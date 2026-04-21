const std = @import("std");
const Allocator = std.mem.Allocator;
const Number = @import("number.zig").Number;
const Date = @import("date.zig").Date;
const Data = @import("data.zig");
const LotSpec = Data.LotSpecView;
const CurrencyIndex = Data.CurrencyIndex;
const StringPool = @import("StringPool.zig");

pub const BookingMethod = enum {
    fifo,
    lifo,
    strict,
};

pub const Lot = struct {
    units: Number,
    cost: Cost,
};

pub const Cost = struct {
    price: Number,
    currency: CurrencyIndex,
    date: Date,
    label: ?[]const u8,

    fn with_lot_spec(self: *const Cost, spec: ?LotSpec) Cost {
        if (spec) |s| {
            return Cost{
                .price = s.price orelse self.price,
                .currency = s.price_currency.unwrap() orelse self.currency,
                .date = s.date orelse self.date,
                .label = s.labelText() orelse self.label,
            };
        } else {
            return self.*;
        }
    }
};

pub const Lots = struct {
    booking_method: BookingMethod,
    shorts: std.ArrayListUnmanaged(Lot),
    longs: std.ArrayListUnmanaged(Lot),

    pub fn init(booking_method: BookingMethod) Lots {
        return .{
            .booking_method = booking_method,
            .longs = std.ArrayListUnmanaged(Lot){},
            .shorts = std.ArrayListUnmanaged(Lot){},
        };
    }

    pub fn deinit(self: *Lots, alloc: Allocator) void {
        self.longs.deinit(alloc);
        self.shorts.deinit(alloc);
    }

    pub fn book(self: *Lots, alloc: Allocator, lot: Lot, lot_spec: ?LotSpec) !Number {
        if (lot.units.is_zero()) return Number.zero();

        var same = if (lot.units.is_positive()) &self.longs else &self.shorts;
        var other = if (lot.units.is_negative()) &self.longs else &self.shorts;

        if (other.items.len == 0) {
            const cost_weight = lot.units.mul(lot.cost.price);
            try same.append(alloc, Lot{
                .units = lot.units,
                .cost = lot.cost.with_lot_spec(lot_spec),
            });
            return cost_weight;
        }

        if (lot_spec) |spec| {
            var match: ?usize = null;
            for (other.items, 0..) |l, i| {
                if (spec.price) |price| {
                    if (!l.cost.price.sub(price).is_zero()) continue;
                    if (spec.price_currency.unwrap()) |pc| {
                        if (l.cost.currency != pc) continue;
                    }
                }
                if (spec.date) |date| {
                    if (!std.meta.eql(l.cost.date, date)) continue;
                }
                if (spec.labelText()) |l1| {
                    if (l.cost.label) |l2| {
                        if (!std.mem.eql(u8, l1, l2)) continue;
                    } else continue;
                }
                if (match) |_| {
                    return error.LotSpecAmbiguousMatch;
                } else {
                    match = i;
                }
            }
            if (match) |i| {
                var l = &other.items[i];
                if (lot.units.abs().sub(l.units.abs()).is_positive())
                    return error.LotSpecMatchTooSmall;
                if (l.cost.currency != lot.cost.currency)
                    return error.CostCurrencyMismatch;
                const cost_weight = lot.units.mul(l.cost.price);
                l.units = l.units.add(lot.units);
                if (l.units.is_zero()) _ = other.swapRemove(i);
                return cost_weight;
            } else {
                return error.LotSpecNoMatch;
            }
        }

        if (self.booking_method == .strict) {
            var sum = Number.zero();
            var cost_weight = Number.zero();
            for (other.items) |l| {
                if (l.cost.currency != lot.cost.currency)
                    return error.CostCurrencyMismatch;
                sum = sum.add(l.units);
                cost_weight = cost_weight.add(l.units.mul(l.cost.price));
            }
            if (sum.add(lot.units).is_zero()) {
                other.clearAndFree(alloc);
                return cost_weight;
            } else {
                return error.AmbiguousStrictBooking;
            }
        }

        switch (self.booking_method) {
            .strict => unreachable,
            .fifo => std.sort.block(Lot, other.items, {}, struct {
                fn lessThan(_: void, a: Lot, b: Lot) bool {
                    return a.cost.date.compare(b.cost.date) == .before;
                }
            }.lessThan),
            .lifo => std.sort.block(Lot, other.items, {}, struct {
                fn lessThan(_: void, a: Lot, b: Lot) bool {
                    return a.cost.date.compare(b.cost.date) == .after;
                }
            }.lessThan),
        }

        var remaining = lot.units;
        var cost_weight = Number.zero();
        var i = other.items.len;
        while (i > 0) {
            i -= 1;
            var l = &other.items[i];
            if (remaining.is_zero()) break;

            if (l.cost.currency != lot.cost.currency)
                return error.CostCurrencyMismatch;

            const to_book = if (lot.units.is_positive())
                l.units.negate().min(remaining)
            else
                l.units.min(remaining.negate()).negate();

            cost_weight = cost_weight.add(l.cost.price.mul(to_book));
            l.units = l.units.add(to_book);
            remaining = remaining.sub(to_book);
            if (l.units.is_zero()) _ = other.pop();
        }
        if (!remaining.is_zero()) {
            cost_weight = cost_weight.add(remaining.mul(lot.cost.price));
            try same.append(alloc, Lot{
                .units = remaining,
                .cost = lot.cost.with_lot_spec(lot_spec),
            });
        }

        std.debug.assert(@intFromBool(self.shorts.items.len > 0) + @intFromBool(self.longs.items.len > 0) <= 1);

        return cost_weight;
    }

    pub fn balance(self: *const Lots) Number {
        var result = Number.zero();
        for (self.longs.items) |lot| result = result.add(lot.units);
        for (self.shorts.items) |lot| result = result.add(lot.units);
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

/// `AutoHashMap` keyed by the dense `CurrencyIndex` u32. Trivial hash = u64
/// identity; no string compare on lookup.
pub const CurrencyMap = std.AutoHashMap;

pub const LotsInventory = struct {
    alloc: Allocator,
    restricted: bool,
    booking_method: BookingMethod,
    by_currency: CurrencyMap(CurrencyIndex, Lots),

    pub fn init(
        alloc: Allocator,
        booking_method: BookingMethod,
        currencies: ?[]const CurrencyIndex,
    ) !LotsInventory {
        var by_currency = CurrencyMap(CurrencyIndex, Lots).init(alloc);
        errdefer by_currency.deinit();
        if (currencies) |cs| {
            for (cs) |c| try by_currency.put(c, Lots.init(booking_method));
        }
        return .{
            .alloc = alloc,
            .restricted = currencies != null,
            .booking_method = booking_method,
            .by_currency = by_currency,
        };
    }

    pub fn deinit(self: *LotsInventory) void {
        var iter = self.by_currency.valueIterator();
        while (iter.next()) |v| v.deinit(self.alloc);
        self.by_currency.deinit();
    }

    pub fn book(
        self: *LotsInventory,
        currency: CurrencyIndex,
        lot: Lot,
        lot_spec: ?LotSpec,
    ) !Number {
        if (self.by_currency.getPtr(currency)) |lots| {
            return try lots.book(self.alloc, lot, lot_spec);
        } else {
            if (self.restricted) {
                return error.DoesNotHoldCurrency;
            } else {
                var lots = Lots.init(self.booking_method);
                const cost_weight = lots.book(self.alloc, lot, lot_spec);
                try self.by_currency.put(currency, lots);
                return cost_weight;
            }
        }
    }

    pub fn isEmpty(self: *const LotsInventory) bool {
        var iter = self.by_currency.valueIterator();
        while (iter.next()) |v| {
            if (v.longs.items.len > 0 or v.shorts.items.len > 0) return false;
        }
        return true;
    }

    pub fn summary(self: *const LotsInventory, alloc: Allocator) !Summary {
        var result = Summary.init(alloc);
        errdefer result.deinit();
        var iter = self.by_currency.iterator();
        while (iter.next()) |kv| {
            var lots = try kv.value_ptr.longs.clone(alloc);
            errdefer lots.deinit(alloc);
            try lots.appendSlice(alloc, kv.value_ptr.shorts.items);
            try result.by_currency.put(kv.key_ptr.*, .{
                .plain = Number.zero(),
                .lots = lots,
            });
        }
        return result;
    }

    pub fn toPlain(self: *const LotsInventory, alloc: Allocator) !PlainInventory {
        var inv = try PlainInventory.init(alloc, null);
        errdefer inv.deinit();

        var iter = self.by_currency.iterator();
        while (iter.next()) |kv| {
            try inv.add(kv.key_ptr.*, kv.value_ptr.balance());
        }

        return inv;
    }

    pub fn balance(self: *const LotsInventory, currency: CurrencyIndex) !Number {
        if (self.by_currency.get(currency)) |lots| {
            return lots.balance();
        } else {
            return if (self.restricted) error.DoesNotHoldCurrency else Number.zero();
        }
    }

    pub fn clone(self: *const LotsInventory, alloc: Allocator) !LotsInventory {
        var result = LotsInventory{
            .alloc = alloc,
            .restricted = self.restricted,
            .booking_method = self.booking_method,
            .by_currency = CurrencyMap(CurrencyIndex, Lots).init(alloc),
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

    pub fn clear(self: *LotsInventory) void {
        var iter = self.by_currency.valueIterator();
        while (iter.next()) |v| v.deinit(self.alloc);
        self.by_currency.clearRetainingCapacity();
    }
};

/// Just records units by currency.
pub const PlainInventory = struct {
    alloc: Allocator,
    restricted: bool,
    by_currency: CurrencyMap(CurrencyIndex, Number),

    pub fn init(alloc: Allocator, currencies: ?[]const CurrencyIndex) !PlainInventory {
        var by_currency = CurrencyMap(CurrencyIndex, Number).init(alloc);
        errdefer by_currency.deinit();
        if (currencies) |cs| {
            for (cs) |c| try by_currency.put(c, Number.zero());
        }
        return .{
            .alloc = alloc,
            .restricted = currencies != null,
            .by_currency = by_currency,
        };
    }

    pub fn deinit(self: *PlainInventory) void {
        self.by_currency.deinit();
    }

    pub fn add(self: *PlainInventory, currency: CurrencyIndex, number: Number) !void {
        const old = try self.balance(currency);
        const new = old.add(number);
        try self.by_currency.put(currency, new);
    }

    pub fn balance(self: *const PlainInventory, currency: CurrencyIndex) !Number {
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
        var result = Summary.init(alloc);
        errdefer result.deinit();
        var iter = self.by_currency.iterator();
        while (iter.next()) |kv| {
            try result.by_currency.put(kv.key_ptr.*, .{
                .plain = kv.value_ptr.*,
                .lots = .{},
            });
        }
        return result;
    }

    pub fn clone(self: *const PlainInventory, alloc: Allocator) !PlainInventory {
        return .{
            .alloc = alloc,
            .restricted = self.restricted,
            .by_currency = try self.by_currency.cloneWithAllocator(alloc),
        };
    }

    pub fn clear(self: *PlainInventory) void {
        self.by_currency.clearRetainingCapacity();
    }
};

pub const Inventory = union(enum) {
    plain: PlainInventory,
    lots: LotsInventory,

    pub fn init(alloc: Allocator, booking_method: ?BookingMethod, currencies: ?[]const CurrencyIndex) !Inventory {
        if (booking_method) |b| {
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

    pub fn add(self: *Inventory, currency: CurrencyIndex, number: Number) !void {
        switch (self.*) {
            .plain => |*inv| try inv.add(currency, number),
            .lots => return error.CannotAddToLotsInventory,
        }
    }

    pub fn book(
        self: *Inventory,
        currency: CurrencyIndex,
        lot: Lot,
        lot_spec: ?LotSpec,
    ) !?Number {
        switch (self.*) {
            .plain => |*inv| if (lot_spec) |_| {
                return error.PlainInventoryDoesNotSupportLotSpec;
            } else {
                try inv.add(currency, lot.units);
                return null;
            },
            .lots => |*inv| return try inv.book(currency, lot, lot_spec),
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

    pub fn balance(self: *const Inventory, currency: CurrencyIndex) !Number {
        return switch (self.*) {
            .plain => |inv| inv.balance(currency),
            .lots => |inv| inv.balance(currency),
        };
    }

    pub fn toPlain(self: *const Inventory, alloc: Allocator) !PlainInventory {
        return switch (self.*) {
            .plain => |inv| inv.clone(alloc),
            .lots => |inv| inv.toPlain(alloc),
        };
    }

    pub fn clone(self: *const Inventory, alloc: Allocator) !Inventory {
        return switch (self.*) {
            .plain => |inv| .{ .plain = try inv.clone(alloc) },
            .lots => |inv| .{ .lots = try inv.clone(alloc) },
        };
    }

    pub fn clear(self: *Inventory) void {
        switch (self.*) {
            .plain => |*inv| inv.clear(),
            .lots => |*inv| inv.clear(),
        }
    }
};

pub const Summary = struct {
    by_currency: CurrencyMap(CurrencyIndex, CurrencySummary),
    alloc: Allocator,

    pub const CurrencySummary = struct {
        plain: Number,
        lots: std.ArrayListUnmanaged(Lot),

        pub fn total_units(self: *const CurrencySummary) Number {
            var result = self.plain;
            for (self.lots.items) |l| result = result.add(l.units);
            return result;
        }
    };

    pub fn init(alloc: Allocator) Summary {
        return .{
            .by_currency = CurrencyMap(CurrencyIndex, CurrencySummary).init(alloc),
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
                    .lots = try entry.value_ptr.lots.clone(self.alloc),
                });
            }
        }
    }

    pub fn balance(self: *const Summary, currency: CurrencyIndex) Number {
        if (self.by_currency.get(currency)) |v| {
            return v.total_units();
        } else {
            return Number.zero();
        }
    }

    /// Resolve currency texts through a `StringPool` borrowed from the caller.
    /// Output is sorted by currency text for deterministic rendering.
    pub fn treeDisplay(self: *const Summary, pool: *const StringPool, indent: u32, writer: std.io.AnyWriter) !void {
        var alloc_buf: [64]CurrencyIndex = undefined;
        const sorted = try sortedKeys(self, pool, &alloc_buf);

        var first = true;
        for (sorted) |cur_idx| {
            const v = self.by_currency.get(cur_idx).?;
            const cur_text = pool.get(@enumFromInt(@intFromEnum(cur_idx)));
            if (!v.plain.is_zero()) {
                if (!first) {
                    try writer.writeByte('\n');
                    try writer.writeByteNTimes(' ', indent);
                }
                try writer.print("{f} {s}", .{ v.plain, cur_text });
                first = false;
            }
            for (v.lots.items) |lot| {
                if (!first) {
                    try writer.writeByte('\n');
                    try writer.writeByteNTimes(' ', indent);
                }
                const cost_cur = pool.get(@enumFromInt(@intFromEnum(lot.cost.currency)));
                try writer.print("{f} {s} @ {f} {s} {{{f}", .{
                    lot.units, cur_text, lot.cost.price, cost_cur, lot.cost.date,
                });
                if (lot.cost.label) |label| try writer.print(", {s}", .{label});
                try writer.print("}}", .{});
                first = false;
            }
        }
    }

    pub fn hoverDisplay(self: *const Summary, pool: *const StringPool, writer: *std.Io.Writer) !void {
        var alloc_buf: [64]CurrencyIndex = undefined;
        const sorted = try sortedKeys(self, pool, &alloc_buf);

        for (sorted) |cur_idx| {
            const v = self.by_currency.get(cur_idx).?;
            const cur_text = pool.get(@enumFromInt(@intFromEnum(cur_idx)));
            if (!v.plain.is_zero()) {
                try writer.print("• {f} {s}\n", .{ v.plain, cur_text });
            }
            for (v.lots.items) |lot| {
                const cost_cur = pool.get(@enumFromInt(@intFromEnum(lot.cost.currency)));
                try writer.print("• {f} {s} @ {f} {s} {{{f}", .{
                    lot.units, cur_text, lot.cost.price, cost_cur, lot.cost.date,
                });
                if (lot.cost.label) |label| try writer.print(", {s}", .{label});
                try writer.print("}}\n", .{});
            }
        }
    }

    /// Fill `buf` with the summary's currencies, sorted by their text. Returns
    /// the populated slice (caller's stack buffer is large enough in practice
    /// — inventories rarely span more than a handful of currencies).
    fn sortedKeys(
        self: *const Summary,
        pool: *const StringPool,
        buf: *[64]CurrencyIndex,
    ) ![]CurrencyIndex {
        const n = self.by_currency.count();
        std.debug.assert(n <= buf.len);
        var i: usize = 0;
        var it = self.by_currency.keyIterator();
        while (it.next()) |k| : (i += 1) buf[i] = k.*;
        const slice = buf[0..n];
        const SortCtx = struct {
            pool: *const StringPool,
            pub fn lessThan(ctx: @This(), a: CurrencyIndex, b: CurrencyIndex) bool {
                const a_text = ctx.pool.get(@enumFromInt(@intFromEnum(a)));
                const b_text = ctx.pool.get(@enumFromInt(@intFromEnum(b)));
                return std.mem.order(u8, a_text, b_text) == .lt;
            }
        };
        std.sort.block(CurrencyIndex, slice, SortCtx{ .pool = pool }, SortCtx.lessThan);
        return slice;
    }

    pub fn toPlain(self: *const Summary, alloc: Allocator) !PlainInventory {
        var result = try PlainInventory.init(alloc, null);
        errdefer result.deinit();

        var iter = self.by_currency.iterator();
        while (iter.next()) |entry| {
            try result.add(entry.key_ptr.*, entry.value_ptr.total_units());
        }

        return result;
    }
};

// --- tests ------------------------------------------------------------------

fn testCurrency(pool: *StringPool, alloc: Allocator, name: []const u8) !CurrencyIndex {
    const raw = try pool.intern(alloc, name);
    return @enumFromInt(@intFromEnum(raw));
}

test "cost weight" {
    const alloc = std.testing.allocator;
    var pool = try StringPool.init(alloc);
    defer pool.deinit(alloc);
    const usd = try testCurrency(&pool, alloc, "USD");

    var inv = Lots.init(.fifo);
    defer inv.deinit(alloc);

    _ = try inv.book(alloc, Lot{
        .units = Number.fromInt(10),
        .cost = Cost{
            .price = Number.fromInt(10),
            .currency = usd,
            .date = try Date.fromSlice("2025-01-01"),
            .label = null,
        },
    }, null);
    _ = try inv.book(alloc, Lot{
        .units = Number.fromInt(10),
        .cost = Cost{
            .price = Number.fromInt(15),
            .currency = usd,
            .date = try Date.fromSlice("2025-01-02"),
            .label = null,
        },
    }, null);
    const cost_weight = try inv.book(alloc, Lot{
        .units = Number.fromInt(-15),
        .cost = Cost{
            .price = Number.fromInt(30),
            .currency = usd,
            .date = try Date.fromSlice("2025-01-03"),
            .label = null,
        },
    }, null);

    try std.testing.expectEqual(Number.fromInt(-175), cost_weight);
    try std.testing.expectEqual(1, inv.longs.items.len);
    try std.testing.expectEqual(0, inv.shorts.items.len);
    try std.testing.expectEqual(Number.fromInt(5), inv.balance());
}

test "cross line" {
    const alloc = std.testing.allocator;
    var pool = try StringPool.init(alloc);
    defer pool.deinit(alloc);
    const usd = try testCurrency(&pool, alloc, "USD");

    var inv = Lots.init(.fifo);
    defer inv.deinit(alloc);

    _ = try inv.book(alloc, Lot{
        .units = Number.fromInt(-1),
        .cost = Cost{
            .price = Number.fromInt(10),
            .currency = usd,
            .date = try Date.fromSlice("2025-01-01"),
            .label = null,
        },
    }, null);
    const cost_weight = try inv.book(alloc, Lot{
        .units = Number.fromInt(2),
        .cost = Cost{
            .price = Number.fromInt(20),
            .currency = usd,
            .date = try Date.fromSlice("2025-01-03"),
            .label = null,
        },
    }, null);

    try std.testing.expectEqual(Number.fromInt(30), cost_weight);
    try std.testing.expectEqual(1, inv.longs.items.len);
    try std.testing.expectEqual(0, inv.shorts.items.len);
    try std.testing.expectEqual(Number.fromInt(1), inv.balance());
}

test "combine" {
    const alloc = std.testing.allocator;
    var pool = try StringPool.init(alloc);
    defer pool.deinit(alloc);
    const usd = try testCurrency(&pool, alloc, "USD");
    const eur = try testCurrency(&pool, alloc, "EUR");
    const nzd = try testCurrency(&pool, alloc, "NZD");

    var plain = try PlainInventory.init(alloc, null);
    defer plain.deinit();
    var lots = try LotsInventory.init(alloc, .fifo, null);
    defer lots.deinit();
    try plain.add(usd, Number.fromInt(1));
    _ = try lots.book(usd, Lot{
        .units = Number.fromInt(1),
        .cost = Cost{
            .price = Number.fromInt(10),
            .currency = usd,
            .date = try Date.fromSlice("2025-01-01"),
            .label = null,
        },
    }, null);
    _ = try lots.book(eur, Lot{
        .units = Number.fromInt(2),
        .cost = Cost{
            .price = Number.fromInt(10),
            .currency = nzd,
            .date = try Date.fromSlice("2025-01-01"),
            .label = null,
        },
    }, null);
    var plain_sum = try plain.summary(alloc);
    var lots_sum = try lots.summary(alloc);
    defer plain_sum.deinit();
    defer lots_sum.deinit();
    try plain_sum.combine(lots_sum);
    try std.testing.expectEqual(Number.fromInt(1), plain_sum.by_currency.get(usd).?.plain);
    try std.testing.expectEqual(1, plain_sum.by_currency.get(usd).?.lots.items.len);
    try std.testing.expectEqual(1, plain_sum.by_currency.get(eur).?.lots.items.len);
}

test "plain empty" {
    const alloc = std.testing.allocator;
    var pool = try StringPool.init(alloc);
    defer pool.deinit(alloc);
    const usd = try testCurrency(&pool, alloc, "USD");

    var inv = try PlainInventory.init(alloc, null);
    defer inv.deinit();

    try std.testing.expect(inv.isEmpty());
    try inv.add(usd, Number.fromInt(1));
    try std.testing.expect(!inv.isEmpty());
    try inv.add(usd, Number.fromInt(-1));
    try std.testing.expect(inv.isEmpty());
}

test "lots empty" {
    const alloc = std.testing.allocator;
    var pool = try StringPool.init(alloc);
    defer pool.deinit(alloc);
    const usd = try testCurrency(&pool, alloc, "USD");
    const nzd = try testCurrency(&pool, alloc, "NZD");

    var inv = try LotsInventory.init(alloc, .fifo, null);
    defer inv.deinit();

    try std.testing.expect(inv.isEmpty());
    _ = try inv.book(usd, Lot{
        .units = Number.fromInt(1),
        .cost = Cost{
            .price = Number.fromInt(10),
            .currency = nzd,
            .date = try Date.fromSlice("2025-01-01"),
            .label = null,
        },
    }, null);
    try std.testing.expect(!inv.isEmpty());
    _ = try inv.book(usd, Lot{
        .units = Number.fromInt(-1),
        .cost = Cost{
            .price = Number.fromInt(10),
            .currency = nzd,
            .date = try Date.fromSlice("2025-01-02"),
            .label = null,
        },
    }, null);
    try std.testing.expect(inv.isEmpty());
}
