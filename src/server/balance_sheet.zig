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
const tpl = t.balance_sheet;
const common = @import("common.zig");
const ztracy = @import("ztracy");

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
            const tracy_zone = ztracy.ZoneNC(@src(), "Balance sheet SSE loop", 0x00_ff_00_00);
            defer tracy_zone.End();

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
        try sse.send(.{ .payload = json.writer.buffered(), .event = "plot_points" });

        const elapsed_ns2 = timer.read();
        const elapsed_ms2 = @divFloor(elapsed_ns2, std.time.ns_per_ms);
        std.log.info("Sent in {d} ms", .{elapsed_ms2});

        html.clearRetainingCapacity();
        json.clearRetainingCapacity();

        if (!listener.waitForNewVersion()) break;
    }
    try sse.end();
}

const PlotPoint = struct {
    date: []const u8,
    currency: []const u8,
    balance: f64,
    balance_rendered: []const u8,

    pub fn deinit(self: *PlotPoint, alloc: std.mem.Allocator) void {
        alloc.free(self.date);
        alloc.free(self.currency);
        alloc.free(self.balance_rendered);
    }
};

const NetWorth = struct {
    alloc: std.mem.Allocator,
    prices: *Prices,
    operating_currencies: []const []const u8,
    display: DisplaySettings,
    inv: PlainInventory,
    next_emit_date: ?Date,
    plot_points: std.ArrayList(PlotPoint),

    pub fn init(
        alloc: std.mem.Allocator,
        prices: *Prices,
        operating_currencies: []const []const u8,
        display: DisplaySettings,
    ) !NetWorth {
        return .{
            .alloc = alloc,
            .prices = prices,
            .operating_currencies = operating_currencies,
            .display = display,
            .inv = try PlainInventory.init(alloc, null),
            .next_emit_date = null,
            .plot_points = .{},
        };
    }

    pub fn deinit(self: *NetWorth) void {
        self.inv.deinit();
        for (self.plot_points.items) |*plot_point| plot_point.deinit(self.alloc);
        self.plot_points.deinit(self.alloc);
    }

    pub fn newEntry(self: *NetWorth, date: Date) !void {
        if (self.next_emit_date == null) {
            self.next_emit_date = self.display.interval.advanceDate(date);
            return;
        }
        if (self.next_emit_date.?.compare(date) == .after) {
            switch (self.display.conversion) {
                .units => try self.emitPlotPoints(&self.inv),
                .currency => |cur| {
                    var inv = try self.prices.convertInventory(self.alloc, &self.inv, cur);
                    defer inv.deinit();
                    try self.emitPlotPoints(&inv);
                },
            }
            self.next_emit_date = self.display.interval.advanceDate(self.next_emit_date.?);
        }
    }

    pub fn emitPlotPoints(self: *NetWorth, inv: *PlainInventory) !void {
        var iter = inv.by_currency.iterator();
        while (iter.next()) |kv| {
            const balance = kv.value_ptr.*;
            try self.plot_points.append(self.alloc, .{
                .date = try std.fmt.allocPrint(self.alloc, "{f}", .{self.next_emit_date.?}),
                .currency = try self.alloc.dupe(u8, kv.key_ptr.*),
                .balance = balance.toFloat(),
                .balance_rendered = try std.fmt.allocPrint(self.alloc, "{f}", .{balance.withPrecision(2)}),
            });
        }
    }

    pub fn updateWithPosting(self: *NetWorth, posting: Data.Posting) !void {
        if (std.mem.startsWith(u8, posting.account.slice, "Assets") or
            std.mem.startsWith(u8, posting.account.slice, "Liabilities"))
        {
            const currency = posting.amount.currency.?;
            const amount = posting.amount.number.?;
            try self.inv.add(currency, amount);
        }
    }
};

const DateState = enum { before, within };

fn render(
    alloc: std.mem.Allocator,
    project: *Project,
    display: DisplaySettings,
    out: *std.Io.Writer,
) ![]PlotPoint {
    var tree = try Tree.init(alloc);
    defer tree.deinit();

    const operating_currencies = try project.getConfig().getOperatingCurrencies(alloc);
    defer alloc.free(operating_currencies);

    var prices = Prices.init(alloc);
    defer prices.deinit();

    var net_worth = try NetWorth.init(alloc, &prices, operating_currencies, display);
    defer net_worth.deinit();

    var date_state = DateState.before;

    for (project.sorted_entries.items) |sorted_entry| {
        const data = project.files.items[sorted_entry.file];
        const entry = data.entries.items[sorted_entry.entry];

        state: switch (date_state) {
            .before => {
                if (display.hasStartDate()) {
                    if (display.isAfterStart(entry.date)) {
                        try tree.clearEarnings("Equity:Earnings:Previous");
                        continue :state .within;
                    }
                } else {
                    continue :state .within;
                }
            },
            .within => {
                date_state = .within;
                if (display.isAfterEnd(entry.date)) {
                    break;
                }
            },
        }

        switch (entry.payload) {
            .open => |open| {
                _ = try tree.open(open.account.slice, null, open.booking_method);
            },
            .transaction => |tx| {
                if (tx.dirty) continue;

                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        const p = data.postings.get(i);
                        try tree.postInventory(entry.date, p);
                        try net_worth.updateWithPosting(p);
                    }
                }
            },
            .pad => |pad| {
                if (pad.synthetic_index == null) continue;

                const index = pad.synthetic_index.?;
                const synthetic_entry = project.synthetic_entries.items[index];
                const tx = synthetic_entry.payload.transaction;
                const postings = tx.postings.?;
                for (postings.start..postings.end) |i| {
                    const p = project.synthetic_postings.get(i);
                    try tree.postInventory(entry.date, p);
                    try net_worth.updateWithPosting(p);
                }
            },
            .price => |price| {
                try prices.setPrice(price);
            },
            else => {},
        }

        if (date_state == .within) {
            try net_worth.newEntry(entry.date);
        }
    }

    try tree.clearEarnings("Equity:Earnings:Current");

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

    try zts.write(tpl, "balance_sheet", out);
    try treeRenderer.renderTable("Assets");
    try zts.write(tpl, "left_end", out);
    try treeRenderer.renderTable("Liabilities");
    try treeRenderer.renderTable("Equity");
    try zts.write(tpl, "right_end", out);

    return net_worth.plot_points.toOwnedSlice(alloc);
}
