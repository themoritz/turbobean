const std = @import("std");
const zts = @import("zts");
const http = @import("http.zig");
const State = @import("State.zig");
const Uri = @import("../Uri.zig");
const Project = @import("../project.zig");
const Tree = @import("../tree.zig");
const Date = @import("../date.zig").Date;
const Number = @import("../number.zig").Number;
const Data = @import("../data.zig");
const SSE = @import("SSE.zig");
const DisplaySettings = @import("DisplaySettings.zig");
const PlainInventory = @import("../inventory.zig").PlainInventory;
const Prices = @import("../Prices.zig");
const t = @import("templates.zig");
const tpl = t.income_statement;
const common = @import("common.zig");

pub fn handler(
    alloc: std.mem.Allocator,
    req: *std.http.Server.Request,
    state: *State,
) !void {
    var sse = try SSE.init(alloc, req);
    defer sse.deinit();

    var parsed_request = try http.ParsedRequest.parse(alloc, req.head.target);
    defer parsed_request.deinit(alloc);
    var display = try http.Query(DisplaySettings).parse(alloc, &parsed_request.params);
    defer display.deinit(alloc);

    var html = std.Io.Writer.Allocating.init(alloc);
    defer html.deinit();

    var json = std.Io.Writer.Allocating.init(alloc);
    defer json.deinit();
    var stringify = std.json.Stringify{ .writer = &json.writer };

    var listener = state.broadcast.newListener();

    var timer = try std.time.Timer.start();
    while (true) {
        timer.reset();
        {
            state.acquireProject();
            defer state.releaseProject();

            const plot_points = try render(alloc, state.project, display, &html.writer);
            defer {
                for (plot_points) |*plot_point| plot_point.deinit(alloc);
                alloc.free(plot_points);
            }

            const elapsed_ns = timer.read();
            const elapsed_ms = @divFloor(elapsed_ns, std.time.ns_per_ms);
            std.log.info("Except JSON in {d} ms", .{elapsed_ms});

            try stringify.write(plot_points);
        }

        const elapsed_ns = timer.read();
        const elapsed_ms = @divFloor(elapsed_ns, std.time.ns_per_ms);
        std.log.info("Computed in {d} ms", .{elapsed_ms});
        timer.reset();

        try sse.send(.{ .payload = html.writer.buffered() });
        try sse.send(.{ .payload = json.writer.buffered(), .event = "income_data" });

        const elapsed_ns2 = timer.read();
        const elapsed_ms2 = @divFloor(elapsed_ns2, std.time.ns_per_ms);
        std.log.info("Sent in {d} ms", .{elapsed_ms2});

        html.clearRetainingCapacity();
        json.clearRetainingCapacity();

        if (!listener.waitForNewVersion()) break;
    }
    try sse.end();
}

const DataPoint = struct {
    period: []const u8,
    currency: []const u8,
    account: []const u8,
    balance: f64,
    balance_rendered: []const u8,

    pub fn deinit(self: *DataPoint, alloc: std.mem.Allocator) void {
        alloc.free(self.period);
        alloc.free(self.currency);
        alloc.free(self.account);
        alloc.free(self.balance_rendered);
    }
};

const DataTracker = struct {
    alloc: std.mem.Allocator,
    prices: *Prices,
    operating_currencies: []const []const u8,
    display: DisplaySettings,
    inv: Inventories,
    next_emit_date: ?Date,
    data: std.ArrayList(DataPoint),

    pub fn init(
        alloc: std.mem.Allocator,
        prices: *Prices,
        operating_currencies: []const []const u8,
        display: DisplaySettings,
    ) DataTracker {
        return .{
            .alloc = alloc,
            .prices = prices,
            .operating_currencies = operating_currencies,
            .display = display,
            .inv = Inventories.init(alloc),
            .next_emit_date = null,
            .data = .{},
        };
    }

    pub fn deinit(self: *DataTracker) void {
        self.inv.deinit();
        for (self.data.items) |*plot_point| plot_point.deinit(self.alloc);
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
        var iter = self.inv.map.iterator();
        while (iter.next()) |kv| {
            const pair = kv.key_ptr.*;
            const balance = kv.value_ptr.*;
            try self.data.append(self.alloc, .{
                .period = try std.fmt.allocPrint(self.alloc, "{f}", .{self.next_emit_date.?}),
                .currency = try self.alloc.dupe(u8, pair.currency),
                .account = try self.alloc.dupe(u8, pair.account),
                .balance = balance.toFloat(),
                .balance_rendered = try std.fmt.allocPrint(self.alloc, "{f}", .{balance.withPrecision(2)}),
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
    project: *Project,
    display: DisplaySettings,
    out: *std.Io.Writer,
) ![]DataPoint {
    var tree = try Tree.init(alloc);
    defer tree.deinit();

    const operating_currencies = try project.getConfig().getOperatingCurrencies(alloc);
    defer alloc.free(operating_currencies);

    var prices = Prices.init(alloc);
    defer prices.deinit();

    var data_tracker = DataTracker.init(alloc, &prices, operating_currencies, display);
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
        self: *const Inventories,
        alloc: std.mem.Allocator,
        conversion: DisplaySettings.Conversion,
        prices: *const Prices,
    ) !Inventories {
        var result = Inventories.init(alloc);
        errdefer result.deinit();

        var iter = self.map.iterator();
        while (iter.next()) |kv| {
            const from = kv.key_ptr.*;
            const unconverted = kv.value_ptr.*;
            switch (conversion) {
                .units => try result.add(from.account, from.currency, unconverted),
                .currency => |to| {
                    if (try prices.convert(unconverted, to)) |converted| {
                        try result.add(from.account, to, converted);
                    } else {
                        try result.add(from.account, from.currency, unconverted);
                    }
                },
            }
        }

        return result;
    }
};
