const std = @import("std");
const zts = @import("zts");
const State = @import("State.zig");
const Uri = @import("../Uri.zig");
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
const tpl = t.balance_sheet;
const common = @import("common.zig");

pub fn handler(
    alloc: std.mem.Allocator,
    req: *std.http.Server.Request,
    state: *State,
) !void {
    try common.SseHandler(common.PlotData, void).run(
        alloc,
        req,
        state,
        {},
        render,
        "plot_points",
    );
}

const NetWorth = struct {
    alloc: std.mem.Allocator,
    prices: *Prices,
    operating_currencies: []const []const u8,
    display: DisplaySettings,
    inv: PlainInventory,
    converted_inv: PlainInventory,
    string_store: *StringStore,
    plot_data: *common.PlotData,

    pub fn init(
        alloc: std.mem.Allocator,
        prices: *Prices,
        operating_currencies: []const []const u8,
        display: DisplaySettings,
        string_store: *StringStore,
        plot_data: *common.PlotData,
    ) !NetWorth {
        return .{
            .alloc = alloc,
            .prices = prices,
            .operating_currencies = operating_currencies,
            .display = display,
            .inv = try PlainInventory.init(alloc, null),
            .converted_inv = try PlainInventory.init(alloc, null),
            .string_store = string_store,
            .plot_data = plot_data,
        };
    }

    pub fn deinit(self: *NetWorth) void {
        self.inv.deinit();
        self.converted_inv.deinit();
    }

    pub fn flush(self: *NetWorth, date: Date) !void {
        switch (self.display.conversion) {
            .units => try self.emitPlotPoints(&self.inv, date),
            .currency => |cur| {
                try self.prices.convertInventory(&self.inv, cur, &self.converted_inv);
                try self.emitPlotPoints(&self.converted_inv, date);
            },
        }
    }

    pub fn emitPlotPoints(self: *NetWorth, inv: *PlainInventory, date: Date) !void {
        var iter = inv.by_currency.iterator();
        while (iter.next()) |kv| {
            const balance = kv.value_ptr.*;
            try self.plot_data.points.append(self.alloc, .{
                .date = try self.string_store.print("{f}", .{date}),
                .currency = kv.key_ptr.*,
                .balance = balance.toFloat(),
                .balance_rendered = try self.string_store.print("{f}", .{balance.withPrecision(2)}),
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
    project: *const Project,
    display: DisplaySettings,
    out: *std.Io.Writer,
    string_store: *StringStore,
    ctx: void,
) !common.PlotData {
    _ = ctx;
    var tree = try Tree.init(alloc);
    defer tree.deinit();

    const operating_currencies = try project.getConfig().getOperatingCurrencies(alloc);
    defer alloc.free(operating_currencies);

    var prices = Prices.init(alloc);
    defer prices.deinit();

    var plot_data = common.PlotData{ .alloc = alloc };
    errdefer plot_data.deinit();

    var net_worth = try NetWorth.init(
        alloc,
        &prices,
        operating_currencies,
        display,
        string_store,
        &plot_data,
    );
    defer net_worth.deinit();

    var date_state = DateState.before;

    var iter = common.IntervalIterator.init(project, display.interval);
    while (iter.next()) |it| switch (it) {
        .cutoff => |date| {
            if (date_state == .within) {
                try net_worth.flush(date);
            }
        },
        .entry => |e| {
            const data, const entry = e;
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
        },
    };

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

    return plot_data;
}
