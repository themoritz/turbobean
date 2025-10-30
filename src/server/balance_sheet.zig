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
const EntryFilter = @import("EntryFilter.zig");
const DisplaySettings = @import("DisplaySettings.zig");
const PlainInventory = @import("../inventory.zig").PlainInventory;
const Prices = @import("../Prices.zig");
const t = @import("templates.zig");
const tpl = t.balance_sheet;
const common = @import("common.zig");

const MAX_TREE_DEPTH = 10;

pub fn handler(
    alloc: std.mem.Allocator,
    req: *std.http.Server.Request,
    state: *State,
) !void {
    var sse = try SSE.init(alloc, req);
    defer sse.deinit();

    var parsed_request = try http.ParsedRequest.parse(alloc, req.head.target);
    defer parsed_request.deinit(alloc);
    var filter = try http.Query(EntryFilter).parse(alloc, &parsed_request.params);
    defer filter.deinit(alloc);
    var display = try http.Query(DisplaySettings).parse(alloc, &parsed_request.params);
    defer display.deinit();

    var html = std.Io.Writer.Allocating.init(alloc);
    defer html.deinit();

    var json = std.Io.Writer.Allocating.init(alloc);
    defer json.deinit();
    var stringify = std.json.Stringify{ .writer = &json.writer };

    var listener = state.broadcast.newListener();

    while (true) {
        {
            state.acquireProject();
            defer state.releaseProject();

            const plot_points = try render(alloc, state.project, filter, display, &html.writer);
            defer {
                for (plot_points) |*plot_point| plot_point.deinit(alloc);
                alloc.free(plot_points);
            }
            try stringify.write(plot_points);
        }

        try sse.send(.{ .payload = html.writer.buffered() });
        try sse.send(.{ .payload = json.writer.buffered(), .event = "plot_points" });

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
    filter: EntryFilter,
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
                if (filter.hasStartDate()) {
                    if (filter.isAfterStart(entry.date)) {
                        try tree.clearEarnings("Equity:Earnings:Previous");
                        continue :state .within;
                    }
                } else {
                    continue :state .within;
                }
            },
            .within => {
                date_state = .within;
                if (filter.isAfterEnd(entry.date)) {
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
    try zts.write(tpl, "balance_sheet", out);
    try renderTable(alloc, out, &tree, operating_currencies, display.conversion, &prices, "Assets");
    try zts.write(tpl, "left_end", out);
    try renderTable(alloc, out, &tree, operating_currencies, display.conversion, &prices, "Liabilities");
    try renderTable(alloc, out, &tree, operating_currencies, display.conversion, &prices, "Equity");
    try zts.write(tpl, "right_end", out);

    return net_worth.plot_points.toOwnedSlice(alloc);
}

fn renderTable(
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    tree: *const Tree,
    operating_currencies: []const []const u8,
    conversion: DisplaySettings.Conversion,
    prices: *Prices,
    title: []const u8,
) !void {
    for (tree.nodes.items[0].children.items) |i| {
        if (std.mem.eql(u8, tree.nodes.items[i].name, title)) {
            try zts.print(tpl, "table", .{
                .fixed_columns = MAX_TREE_DEPTH,
                .variable_columns = operating_currencies.len + 1,
                .after_name_line = MAX_TREE_DEPTH + 2,
            }, out);

            for (operating_currencies, 0..) |currency, j| {
                try zts.print(tpl, "header_title", .{
                    .title = currency,
                    .from_line = MAX_TREE_DEPTH + 2 + j,
                    .to_line = MAX_TREE_DEPTH + 2 + j + 1,
                }, out);
            }
            try zts.print(tpl, "header_title", .{
                .title = "Other",
                .from_line = MAX_TREE_DEPTH + 2 + operating_currencies.len,
                .to_line = MAX_TREE_DEPTH + 2 + operating_currencies.len + 1,
            }, out);

            try zts.write(tpl, "header_title_end", out);

            var prefix = std.array_list.Managed(bool).init(alloc);
            defer prefix.deinit();

            var name_prefix = std.array_list.Managed(u8).init(alloc);
            defer name_prefix.deinit();
            try name_prefix.appendSlice(title);

            try renderRec(alloc, out, operating_currencies, conversion, prices, tree, i, 0, &prefix, &name_prefix, true);

            try zts.write(tpl, "table_end", out);
        }
    }
}

fn renderRec(
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    operating_currencies: []const []const u8,
    conversion: DisplaySettings.Conversion,
    prices: *Prices,
    tree: *const Tree,
    node_index: u32,
    depth: u32,
    prefix: *std.array_list.Managed(bool),
    name_prefix: *std.array_list.Managed(u8),
    is_last: bool,
) !void {
    const node = tree.nodes.items[node_index];
    const has_children = node.children.items.len > 0;

    var unconverted_inv = try node.inventory.toPlain(alloc);
    defer unconverted_inv.deinit();

    var inv = switch (conversion) {
        .units => try unconverted_inv.clone(alloc),
        .currency => |cur| try prices.convertInventory(alloc, &unconverted_inv, cur),
    };
    defer inv.deinit();

    try zts.write(tpl, "account", out);

    for (prefix.items) |last| {
        try zts.write(tpl, "tree", out);
        if (!last) {
            try zts.write(t.tree, "tree_prefix", out);
        }
        try zts.write(tpl, "tree_end", out);
    }

    if (depth > 0) {
        try zts.write(tpl, "tree", out);
        if (is_last) {
            try zts.write(t.tree, "tree_node_last", out);
        } else {
            try zts.write(t.tree, "tree_node_middle", out);
        }
        try zts.write(tpl, "tree_end", out);
    }

    try zts.write(tpl, "icon", out);
    if (has_children) {
        try zts.write(t.tree, "icon_open", out);
        try zts.write(t.tree, "icon_line", out);
    } else {
        if (depth > 0) {
            try zts.write(t.tree, "icon_leaf", out);
        } else {
            try zts.write(t.tree, "icon_leaf_root", out);
        }
    }
    try zts.write(tpl, "icon_end", out);

    const name_prefix_len = name_prefix.items.len;
    if (depth > 0) {
        try name_prefix.append(':');
        try name_prefix.appendSlice(node.name);
    }

    try zts.print(tpl, "name", .{
        .name = node.name,
        .full_name = name_prefix.items,
        .from_line = depth + 2,
        .to_line = MAX_TREE_DEPTH + 2,
    }, out);

    for (operating_currencies, 0..) |currency, j| {
        try zts.print(tpl, "balances", .{
            .from_line = MAX_TREE_DEPTH + 2 + j,
            .to_line = MAX_TREE_DEPTH + 2 + j + 1,
        }, out);
        if (inv.by_currency.get(currency)) |balance| {
            if (!balance.is_zero()) {
                try zts.print(tpl, "balance", .{
                    .units = balance.withPrecision(2),
                    .cur = "",
                }, out);
            }
        }
        try zts.write(tpl, "balances_end", out);
    }

    try zts.print(tpl, "balances", .{
        .from_line = MAX_TREE_DEPTH + 2 + operating_currencies.len,
        .to_line = MAX_TREE_DEPTH + 2 + operating_currencies.len + 1,
    }, out);
    var iter = inv.by_currency.iterator();
    currency: while (iter.next()) |kv| {
        for (operating_currencies) |cur| {
            if (std.mem.eql(u8, cur, kv.key_ptr.*)) {
                continue :currency;
            }
        }
        const units = kv.value_ptr.*;
        if (!units.is_zero()) {
            try zts.print(tpl, "balance", .{
                .units = units.withPrecision(2),
                .cur = kv.key_ptr.*,
            }, out);
        }
    }
    try zts.write(tpl, "balances_end", out);

    try zts.write(tpl, "account_end", out);

    // Render children with updated prefix
    if (has_children) {
        // Sort children by name
        const sorted_children = try alloc.dupe(u32, node.children.items);
        defer alloc.free(sorted_children);

        std.mem.sort(u32, sorted_children, tree, struct {
            fn lessThan(tr: *const Tree, a: u32, b: u32) bool {
                const name_a = tr.nodes.items[a].name;
                const name_b = tr.nodes.items[b].name;
                return std.mem.order(u8, name_a, name_b) == .lt;
            }
        }.lessThan);

        // Add current node's continuation state to prefix for children (if not root level)
        if (depth > 0) {
            try prefix.append(is_last);
        }

        for (sorted_children, 0..) |child, i| {
            const child_is_last = i == sorted_children.len - 1;
            try renderRec(
                alloc,
                out,
                operating_currencies,
                conversion,
                prices,
                tree,
                child,
                depth + 1,
                prefix,
                name_prefix,
                child_is_last,
            );
        }

        // Remove the continuation state we added
        if (depth > 0) {
            _ = prefix.pop();
        }
    }

    name_prefix.shrinkRetainingCapacity(name_prefix_len);
}
