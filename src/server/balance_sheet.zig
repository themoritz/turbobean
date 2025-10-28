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
const PlainInventory = @import("../inventory.zig").PlainInventory;
const Prices = @import("../Prices.zig");
const t = @embedFile("../templates/balance_sheet.html");

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

            const plot_points = try render(alloc, state.project, filter, &html.writer);
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
    inv: PlainInventory,
    next_emit_date: ?Date,
    plot_points: std.ArrayList(PlotPoint),

    pub fn init(
        alloc: std.mem.Allocator,
        prices: *Prices,
        operating_currencies: []const []const u8,
    ) !NetWorth {
        return .{
            .alloc = alloc,
            .prices = prices,
            .operating_currencies = operating_currencies,
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
            self.next_emit_date = date.nextSunday();
            return;
        }
        if (self.next_emit_date.?.compare(date) == .after) {
            var tmp_inv = try PlainInventory.init(self.alloc, null);
            defer tmp_inv.deinit();

            var iter = self.inv.by_currency.iterator();
            while (iter.next()) |kv| {
                const balance = kv.value_ptr.*;
                if (self.prices.convert(balance, kv.key_ptr.*, "EUR")) |converted| {
                    try tmp_inv.add("EUR", converted);
                } else {
                    try tmp_inv.add(kv.key_ptr.*, balance);
                }
            }

            var tmp_iter = tmp_inv.by_currency.iterator();
            while (tmp_iter.next()) |kv| {
                const balance = kv.value_ptr.*;
                try self.plot_points.append(self.alloc, .{
                    .date = try std.fmt.allocPrint(self.alloc, "{f}", .{self.next_emit_date.?}),
                    .currency = try self.alloc.dupe(u8, kv.key_ptr.*),
                    .balance = balance.toFloat(),
                    .balance_rendered = try std.fmt.allocPrint(self.alloc, "{f}", .{balance.withPrecision(2)}),
                });
            }
            self.next_emit_date = self.next_emit_date.?.nextSunday();
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

    pub fn snapshot(self: *const NetWorth, alloc: std.mem.Allocator) !std.StringHashMap(Number) {
        var result = std.StringHashMap(Number).init(alloc);
        errdefer result.deinit();

        var iter = self.inv.by_currency.iterator();
        while (iter.next()) |kv| {
            try result.put(kv.key_ptr.*, kv.value_ptr.*);
        }
        return result;
    }
};

const DateState = enum { before, within };

fn render(
    alloc: std.mem.Allocator,
    project: *Project,
    filter: EntryFilter,
    out: *std.Io.Writer,
) ![]PlotPoint {
    var tree = try Tree.init(alloc);
    defer tree.deinit();

    const operating_currencies = try project.getConfig().getOperatingCurrencies(alloc);
    defer alloc.free(operating_currencies);

    var prices = Prices.init(alloc);
    defer prices.deinit();

    var net_worth = try NetWorth.init(alloc, &prices, operating_currencies);
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

    // Render Tree
    try zts.write(t, "balance_sheet", out);
    try renderTable(alloc, out, &tree, operating_currencies, "Assets");
    try zts.write(t, "left_end", out);
    try renderTable(alloc, out, &tree, operating_currencies, "Liabilities");
    try renderTable(alloc, out, &tree, operating_currencies, "Equity");
    try zts.write(t, "right_end", out);

    return net_worth.plot_points.toOwnedSlice(alloc);
}

fn renderTable(
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    tree: *const Tree,
    operating_currencies: []const []const u8,
    title: []const u8,
) !void {
    for (tree.nodes.items[0].children.items) |i| {
        if (std.mem.eql(u8, tree.nodes.items[i].name, title)) {
            try zts.print(t, "table", .{
                .fixed_columns = MAX_TREE_DEPTH,
                .variable_columns = operating_currencies.len + 1,
                .after_name_line = MAX_TREE_DEPTH + 2,
            }, out);

            for (operating_currencies, 0..) |currency, j| {
                try zts.print(t, "header_title", .{
                    .title = currency,
                    .from_line = MAX_TREE_DEPTH + 2 + j,
                    .to_line = MAX_TREE_DEPTH + 2 + j + 1,
                }, out);
            }
            try zts.print(t, "header_title", .{
                .title = "Other",
                .from_line = MAX_TREE_DEPTH + 2 + operating_currencies.len,
                .to_line = MAX_TREE_DEPTH + 2 + operating_currencies.len + 1,
            }, out);

            try zts.write(t, "header_title_end", out);

            var prefix = std.array_list.Managed(bool).init(alloc);
            defer prefix.deinit();

            var name_prefix = std.array_list.Managed(u8).init(alloc);
            defer name_prefix.deinit();
            try name_prefix.appendSlice(title);

            try renderRec(alloc, out, operating_currencies, tree, i, 0, &prefix, &name_prefix, true);

            try zts.write(t, "table_end", out);
        }
    }
}

fn renderRec(
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    operating_currencies: []const []const u8,
    tree: *const Tree,
    node_index: u32,
    depth: u32,
    prefix: *std.array_list.Managed(bool),
    name_prefix: *std.array_list.Managed(u8),
    is_last: bool,
) !void {
    const node = tree.nodes.items[node_index];
    const has_children = node.children.items.len > 0;
    // var summary = try tree.inventoryAggregatedByNode(alloc, node_index);
    var summary = try node.inventory.summary(alloc);
    defer summary.deinit();

    try zts.write(t, "account", out);

    for (prefix.items) |last| {
        try zts.write(t, "tree", out);
        if (!last) {
            try zts.write(t, "tree_prefix", out);
        }
        try zts.write(t, "tree_end", out);
    }

    if (depth > 0) {
        try zts.write(t, "tree", out);
        if (is_last) {
            try zts.write(t, "tree_node_last", out);
        } else {
            try zts.write(t, "tree_node_middle", out);
        }
        try zts.write(t, "tree_end", out);
    }

    try zts.write(t, "icon", out);
    if (has_children) {
        try zts.write(t, "icon_open", out);
        try zts.write(t, "icon_line", out);
    } else {
        if (depth > 0) {
            try zts.write(t, "icon_leaf", out);
        } else {
            try zts.write(t, "icon_leaf_root", out);
        }
    }
    try zts.write(t, "icon_end", out);

    const name_prefix_len = name_prefix.items.len;
    if (depth > 0) {
        try name_prefix.append(':');
        try name_prefix.appendSlice(node.name);
    }

    try zts.print(t, "name", .{
        .name = node.name,
        .full_name = name_prefix.items,
        .from_line = depth + 2,
        .to_line = MAX_TREE_DEPTH + 2,
    }, out);

    for (operating_currencies, 0..) |currency, j| {
        try zts.print(t, "balances", .{
            .from_line = MAX_TREE_DEPTH + 2 + j,
            .to_line = MAX_TREE_DEPTH + 2 + j + 1,
        }, out);
        if (summary.by_currency.get(currency)) |balance| {
            const units = balance.total_units();
            if (!units.is_zero()) {
                try zts.print(t, "balance", .{
                    .units = units.withPrecision(2),
                    .cur = "",
                }, out);
            }
        }
        try zts.write(t, "balances_end", out);
    }

    try zts.print(t, "balances", .{
        .from_line = MAX_TREE_DEPTH + 2 + operating_currencies.len,
        .to_line = MAX_TREE_DEPTH + 2 + operating_currencies.len + 1,
    }, out);
    var iter = summary.by_currency.iterator();
    currency: while (iter.next()) |kv| {
        for (operating_currencies) |cur| {
            if (std.mem.eql(u8, cur, kv.key_ptr.*)) {
                continue :currency;
            }
        }
        const units = kv.value_ptr.total_units();
        if (!units.is_zero()) {
            try zts.print(t, "balance", .{
                .units = units.withPrecision(2),
                .cur = kv.key_ptr.*,
            }, out);
        }
    }
    try zts.write(t, "balances_end", out);

    try zts.write(t, "account_end", out);

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
