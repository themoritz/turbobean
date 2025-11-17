const std = @import("std");
const zts = @import("zts");
const State = @import("State.zig");
const Project = @import("../project.zig");
const Tree = @import("../tree.zig");
const Date = @import("../date.zig").Date;
const Number = @import("../number.zig").Number;
const Data = @import("../data.zig");
const DisplaySettings = @import("DisplaySettings.zig");
const PlainInventory = @import("../inventory.zig").PlainInventory;
const Prices = @import("../Prices.zig");
const StringStore = @import("../StringStore.zig");
const t = @import("templates.zig");
const tpl = t.income_statement;
const common = @import("common.zig");

pub fn handler(
    alloc: std.mem.Allocator,
    req: *std.http.Server.Request,
    state: *State,
) !void {
    try common.SseHandler([]DataPoint, void).run(
        alloc,
        req,
        state,
        {},
        render,
        "plot_changes",
    );
}

const DataPoint = struct {
    period: StringStore.String,
    currency: []const u8,
    account: []const u8,
    balance: f64,
    balance_rendered: StringStore.String,
};

const DataTracker = struct {
    alloc: std.mem.Allocator,
    prices: *Prices,
    operating_currencies: []const []const u8,
    display: DisplaySettings,
    inv: Inventories,
    next_emit_date: ?Date,
    string_store: *StringStore,
    data: std.ArrayList(DataPoint),

    pub fn init(
        alloc: std.mem.Allocator,
        prices: *Prices,
        operating_currencies: []const []const u8,
        display: DisplaySettings,
        string_store: *StringStore,
    ) DataTracker {
        return .{
            .alloc = alloc,
            .prices = prices,
            .operating_currencies = operating_currencies,
            .display = display,
            .inv = Inventories.init(alloc),
            .next_emit_date = null,
            .string_store = string_store,
            .data = .{},
        };
    }

    pub fn deinit(self: *DataTracker) void {
        self.inv.deinit();
        self.data.deinit(self.alloc);
    }

    pub fn newEntry(self: *DataTracker, date: Date) !void {
        if (self.next_emit_date == null) {
            self.next_emit_date = self.display.interval.advanceDate(date);
            return;
        }
        if (self.next_emit_date.?.compare(date) == .after) {
            try self.flushData();
            self.next_emit_date = self.display.interval.advanceDate(self.next_emit_date.?);
        }
    }

    pub fn flushData(self: *DataTracker) !void {
        try self.inv.convert(self.display.conversion, self.prices);

        var iter = self.inv.map.iterator();
        while (iter.next()) |kv| {
            const pair = kv.key_ptr.*;
            const balance = kv.value_ptr.*;
            try self.data.append(self.alloc, .{
                .period = try self.string_store.print("{f}", .{self.next_emit_date.?}),
                .currency = pair.currency,
                .account = pair.account,
                .balance = balance.toFloat(),
                .balance_rendered = try self.string_store.print("{f}", .{balance.withPrecision(2)}),
            });
        }
        self.inv.clear();
    }

    pub fn updateWithPosting(self: *DataTracker, posting: Data.Posting) !void {
        if (std.mem.startsWith(u8, posting.account.slice, "Income") or
            std.mem.startsWith(u8, posting.account.slice, "Expenses"))
        {
            try self.inv.postInventory(&posting);
        }
    }
};

fn render(
    alloc: std.mem.Allocator,
    project: *const Project,
    display: DisplaySettings,
    out: *std.Io.Writer,
    string_store: *StringStore,
    ctx: void,
) ![]DataPoint {
    _ = ctx;
    var tree = try Tree.init(alloc);
    defer tree.deinit();

    const operating_currencies = try project.getConfig().getOperatingCurrencies(alloc);
    defer alloc.free(operating_currencies);

    var prices = Prices.init(alloc);
    defer prices.deinit();

    var data_tracker = DataTracker.init(alloc, &prices, operating_currencies, display, string_store);
    defer data_tracker.deinit();

    for (project.sorted_entries.items) |sorted_entry| {
        const data = project.files.items[sorted_entry.file];
        const entry = data.entries.items[sorted_entry.entry];

        switch (entry.payload) {
            .open => |open| {
                _ = try tree.open(open.account.slice, null, open.booking_method);
            },
            .transaction => |tx| {
                if (tx.dirty) continue;
                if (!display.isWithinDateRange(entry.date)) continue;

                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        const p = data.postings.get(i);
                        try tree.postInventory(entry.date, p);
                        try data_tracker.updateWithPosting(p);
                    }
                }
            },
            .pad => |pad| {
                if (pad.synthetic_index == null) continue;
                if (!display.isWithinDateRange(entry.date)) continue;

                const index = pad.synthetic_index.?;
                const synthetic_entry = project.synthetic_entries.items[index];
                const tx = synthetic_entry.payload.transaction;
                const postings = tx.postings.?;
                for (postings.start..postings.end) |i| {
                    const p = project.synthetic_postings.get(i);
                    try tree.postInventory(entry.date, p);
                    try data_tracker.updateWithPosting(p);
                }
            },
            .price => |price| {
                try prices.setPrice(price);
            },
            else => {},
        }

        if (display.isWithinDateRange(entry.date)) {
            try data_tracker.newEntry(entry.date);
        }
    }

    try common.renderPlotArea(operating_currencies, out);

    // Render Tree
    const treeRenderer = common.TreeRenderer{
        .alloc = alloc,
        .out = out,
        .tree = &tree,
        .operating_currencies = operating_currencies,
        .conversion = display.conversion,
        .prices = &prices,
    };

    try zts.write(tpl, "income_statement", out);
    try treeRenderer.renderTable("Income");
    try zts.write(tpl, "left_end", out);
    try treeRenderer.renderTable("Expenses");
    try zts.write(tpl, "right_end", out);

    return data_tracker.data.toOwnedSlice(alloc);
}

const Inventories = struct {
    map: Map,

    // TODO: Share with Prices.zig
    const Map = std.HashMap(Pair, Number, Context, std.hash_map.default_max_load_percentage);

    const Pair = struct {
        account: []const u8,
        currency: []const u8,
    };

    const Context = struct {
        pub fn hash(_: Context, key: Pair) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(key.account);
            hasher.update(key.currency);
            return hasher.final();
        }

        pub fn eql(_: Context, a: Pair, b: Pair) bool {
            return std.mem.eql(u8, a.account, b.account) and
                std.mem.eql(u8, a.currency, b.currency);
        }
    };

    pub fn init(alloc: std.mem.Allocator) Inventories {
        return .{
            .map = Map.init(alloc),
        };
    }

    pub fn deinit(self: *Inventories) void {
        self.map.deinit();
    }

    pub fn clear(self: *Inventories) void {
        self.map.clearRetainingCapacity();
    }

    pub fn add(self: *Inventories, account: []const u8, currency: []const u8, amount: Number) !void {
        const pair = Pair{
            .account = account,
            .currency = currency,
        };
        const old = self.balance(pair.account, pair.currency);
        try self.map.put(pair, old.add(amount));
    }

    pub fn postInventory(self: *Inventories, posting: *const Data.Posting) !void {
        try self.add(posting.account.slice, posting.amount.currency.?, posting.amount.number.?);
    }

    pub fn balance(self: *const Inventories, account: []const u8, currency: []const u8) Number {
        const pair = Pair{
            .account = account,
            .currency = currency,
        };
        return self.map.get(pair) orelse Number.zero();
    }

    pub fn convert(
        self: *Inventories,
        conversion: DisplaySettings.Conversion,
        prices: *const Prices,
    ) !void {
        switch (conversion) {
            .units => {},
            .currency => |to| {
                var iter = self.map.iterator();
                while (iter.next()) |kv| {
                    const from = kv.key_ptr.*;
                    if (std.mem.eql(u8, from.currency, to)) continue;
                    if (prices.convert(kv.value_ptr.*, from.currency, to)) |converted| {
                        _ = self.map.remove(from);
                        try self.add(from.account, to, converted);
                    }
                }
            },
        }
    }
};
