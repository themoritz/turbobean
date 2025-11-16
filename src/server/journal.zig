const std = @import("std");
const zts = @import("zts");
const http = @import("http.zig");
const State = @import("State.zig");
const Uri = @import("../Uri.zig");
const Project = @import("../project.zig");
const Tree = @import("../tree.zig");
const Date = @import("../date.zig").Date;
const Number = @import("../number.zig").Number;
const SSE = @import("SSE.zig");
const DisplaySettings = @import("DisplaySettings.zig");
const t = @import("templates.zig");
const tpl = t.journal;
const common = @import("common.zig");
const Prices = @import("../Prices.zig");
const StringStore = @import("../StringStore.zig");
const Inventory = @import("../inventory.zig");

pub fn handler(
    alloc: std.mem.Allocator,
    req: *std.http.Server.Request,
    state: *State,
    account: []const u8,
) !void {
    var sse = try SSE.init(alloc, req);
    defer sse.deinit();

    var parsed_request = try http.ParsedRequest.parse(alloc, req.head.target);
    defer parsed_request.deinit(alloc);
    var display = try http.Query(DisplaySettings).parse(alloc, &parsed_request.params);
    defer display.deinit(alloc);

    var string_store = StringStore.init(alloc);
    defer string_store.deinit();

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

            var plot_points = try render(alloc, state.project, display, account, &html.writer, &string_store);
            defer plot_points.deinit(alloc);

            const elapsed_ns = timer.read();
            const elapsed_ms = @divFloor(elapsed_ns, std.time.ns_per_ms);
            std.log.info("Except JSON in {d} ms", .{elapsed_ms});

            try stringify.write(plot_points.items);
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

        string_store.clearRetainingCapacity();
        html.clearRetainingCapacity();
        json.clearRetainingCapacity();

        if (!listener.waitForNewVersion()) break;
    }
    try sse.end();
}

const PlotPoint = struct {
    date: StringStore.String,
    currency: []const u8,
    balance: f64,
    balance_rendered: StringStore.String,
};

fn render(
    alloc: std.mem.Allocator,
    project: *Project,
    display: DisplaySettings,
    account: []const u8,
    out: *std.Io.Writer,
    string_store: *StringStore,
) !std.ArrayList(PlotPoint) {
    var tree = try Tree.init(alloc);
    defer tree.deinit();

    const operating_currencies = try project.getConfig().getOperatingCurrencies(alloc);
    defer alloc.free(operating_currencies);

    var prices = Prices.init(alloc);
    defer prices.deinit();

    var plot_points = std.ArrayList(PlotPoint){};
    errdefer plot_points.deinit(alloc);

    try common.renderPlotArea(operating_currencies, out);
    try zts.write(tpl, "table", out);

    var converted_inv = try Inventory.PlainInventory.init(alloc, null);
    defer converted_inv.deinit();

    for (project.sorted_entries.items) |sorted_entry| {
        const data = project.files.items[sorted_entry.file];
        const entry = data.entries.items[sorted_entry.entry];
        switch (entry.payload) {
            .open => |open| {
                if (std.mem.eql(u8, open.account.slice, account)) {
                    // We have to open the account even if it's outside the date filter.
                    _ = try tree.open(open.account.slice, null, open.booking_method);
                    if (display.isWithinDateRange(entry.date)) {
                        try zts.print(tpl, "open", .{
                            .date = entry.date,
                        }, out);
                    }
                }
            },
            .transaction => |tx| {
                if (tx.dirty) continue;

                if (!display.isWithinDateRange(entry.date)) continue;
                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        const p = data.postings.get(i);
                        if (std.mem.eql(u8, p.account.slice, account)) {
                            // Add i to get different hashes when the same transaction
                            // has multiple postings to the queried account.
                            const hash = entry.hash() + i;

                            try zts.print(tpl, "transaction", .{
                                .date = entry.date,
                                .flag = tx.flag.slice,
                                .highlight = switch (tx.flag.slice[0]) {
                                    '!' => "flagged",
                                    else => "",
                                },
                            }, out);

                            if (tx.payee) |payee| {
                                try zts.print(tpl, "transaction_payee", .{
                                    .payee = payee[1 .. payee.len - 1],
                                }, out);
                                if (tx.narration) |n| if (n.len > 2) try zts.write(tpl, "transaction_separator", out);
                            }
                            if (tx.narration) |n| if (n.len > 2) try zts.print(tpl, "transaction_narration", .{
                                .narration = n[1 .. n.len - 1],
                            }, out);

                            try zts.print(tpl, "transaction_legs", .{
                                .hash = hash,
                            }, out);

                            for (postings.start..postings.end) |_| {
                                try zts.write(tpl, "transaction_leg", out);
                            }

                            const conv_units, const conv_cur = tryConvert(
                                &prices,
                                display.conversion,
                                p.amount.number.?,
                                p.amount.currency.?,
                            );
                            try zts.print(tpl, "transaction_legs_end", .{
                                .change_units = conv_units.withPrecision(2),
                                .change_cur = conv_cur,
                            }, out);

                            try tree.postInventory(entry.date, p);

                            var sum = try tree.inventoryAggregatedByAccount(alloc, account);
                            defer sum.deinit();

                            var plain = try sum.toPlain(alloc);
                            defer plain.deinit();

                            var conv_inv = blk: switch (display.conversion) {
                                .units => break :blk &plain,
                                .currency => |to| {
                                    try prices.convertInventory(&plain, to, &converted_inv);
                                    break :blk &converted_inv;
                                },
                            };

                            var iter = conv_inv.by_currency.iterator();
                            while (iter.next()) |kv| {
                                const units = kv.value_ptr.*;
                                if (!units.is_zero()) {
                                    try zts.print(tpl, "transaction_balance_cur", .{
                                        .units = units.withPrecision(2),
                                        .cur = kv.key_ptr.*,
                                    }, out);
                                }
                            }

                            try zts.print(tpl, "transaction_balance_end", .{
                                .hash = hash,
                            }, out);

                            for (postings.start..postings.end) |j| {
                                const p2 = data.postings.get(j);
                                try zts.write(tpl, "transaction_posting", out);

                                if (j < postings.end - 1) {
                                    try zts.write(t.tree, "tree_node_middle", out);
                                } else {
                                    try zts.write(t.tree, "tree_node_last", out);
                                }
                                try zts.write(tpl, "tree_icon", out);
                                try zts.write(t.tree, "icon_leaf", out);

                                {
                                    const units, const cur = tryConvert(
                                        &prices,
                                        display.conversion,
                                        p2.amount.number.?,
                                        p2.amount.currency.?,
                                    );
                                    try zts.print(tpl, "tree_end", .{
                                        .account = p2.account.slice,
                                        .change_units = units.withPrecision(2),
                                        .change_cur = cur,
                                    }, out);
                                }
                            }

                            try zts.write(tpl, "transaction_end", out);

                            const balance = conv_inv.by_currency.get(conv_cur).?;
                            try plot_points.append(alloc, .{
                                .date = try string_store.print("{f}", .{entry.date}),
                                .currency = conv_cur,
                                .balance = balance.toFloat(),
                                .balance_rendered = try string_store.print("{f}", .{balance.withPrecision(2)}),
                            });
                        }
                    }
                }
            },
            .price => |price| {
                try prices.setPrice(price);
            },
            else => {},
        }
    }

    try zts.write(tpl, "table_end", out);

    return plot_points;
}

fn tryConvert(
    prices: *const Prices,
    conversion: DisplaySettings.Conversion,
    amount: Number,
    from: []const u8,
) struct { Number, []const u8 } {
    return switch (conversion) {
        .units => .{ amount, from },
        .currency => |to| if (prices.convert(amount, from, to)) |result|
            .{ result, to }
        else
            .{ amount, from },
    };
}
