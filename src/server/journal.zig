const std = @import("std");
const zts = @import("zts");
const State = @import("State.zig");
const Project = @import("../project.zig");
const Tree = @import("../tree.zig");
const Date = @import("../date.zig").Date;
const Number = @import("../number.zig").Number;
const DisplaySettings = @import("DisplaySettings.zig");
const t = @import("templates.zig");
const tpl = t.journal;
const common = @import("common.zig");
const Prices = @import("../Prices.zig");
const StringStore = @import("../StringStore.zig");
const Inventory = @import("../inventory.zig");
const Data = @import("../data.zig");

pub fn handler(
    alloc: std.mem.Allocator,
    req: *std.http.Server.Request,
    state: *State,
    account: []const u8,
) !void {
    try common.SseHandler(common.PlotData, []const u8).run(
        alloc,
        req,
        state,
        account,
        render,
        "plot_points",
    );
}

fn render(
    alloc: std.mem.Allocator,
    project: *const Project,
    display: DisplaySettings,
    out: *std.Io.Writer,
    string_store: *StringStore,
    account: []const u8,
) !common.PlotData {
    var tree = try Tree.init(alloc, project.accounts, project.currencies);
    defer tree.deinit();

    var plot_data = common.PlotData{ .alloc = alloc };
    errdefer plot_data.deinit();

    const account_idx = project.findAccount(account) orelse return plot_data;
    const conversion_target: ?Data.CurrencyIndex = switch (display.conversion) {
        .units => null,
        .currency => |text| project.findCurrency(text),
    };

    const operating_currencies = try project.getConfig().getOperatingCurrencies(alloc);
    defer alloc.free(operating_currencies);

    var prices = Prices.init(alloc);
    defer prices.deinit();

    try common.renderPlotArea(operating_currencies, out);
    try zts.write(tpl, "table", out);

    var plain_inv = try Inventory.PlainInventory.init(alloc, null);
    defer plain_inv.deinit();

    var converted_inv = try Inventory.PlainInventory.init(alloc, null);
    defer converted_inv.deinit();

    for (project.sorted_entries.items) |sorted_entry| {
        const data = &project.files.items[sorted_entry.file];
        const entry = data.entryAt(sorted_entry.entry);
        switch (entry.payload()) {
            .open => |open| {
                if (open.account() == account_idx) {
                    _ = try tree.open(account_idx, null, open.open.booking_method);
                    if (display.isWithinDateRange(entry.date())) {
                        try zts.print(tpl, "open", .{ .date = entry.date() }, out);
                    }
                }
            },
            .transaction => |tx| {
                if (tx.tx.dirty) continue;
                if (!display.isWithinDateRange(entry.date())) continue;
                const postings = tx.tx.postings;
                for (postings.start..postings.end) |i| {
                    const p = data.postingAt(@intCast(i));
                    if (p.account() != account_idx) continue;

                    const hash = entry.hash() + i;
                    const flag_slice = data.tokenSlice(tx.tx.flag);

                    try zts.print(tpl, "transaction", .{
                        .date = entry.date(),
                        .flag = flag_slice,
                        .highlight = switch (flag_slice[0]) {
                            '!' => "flagged",
                            else => "",
                        },
                    }, out);

                    if (tx.payeeText()) |payee| {
                        try zts.print(tpl, "transaction_payee", .{
                            .payee = payee[1 .. payee.len - 1],
                        }, out);
                        if (tx.narrationText()) |n| if (n.len > 2) try zts.write(tpl, "transaction_separator", out);
                    }
                    if (tx.narrationText()) |n| if (n.len > 2) try zts.print(tpl, "transaction_narration", .{
                        .narration = n[1 .. n.len - 1],
                    }, out);

                    try zts.print(tpl, "transaction_legs", .{ .hash = hash }, out);

                    for (postings.start..postings.end) |_| {
                        try zts.write(tpl, "transaction_leg", out);
                    }

                    const p_cur = p.amountCurrency().unwrap().?;
                    const conv_units, const conv_cur_idx = tryConvert(
                        &prices,
                        conversion_target,
                        p.amountNumber().?,
                        p_cur,
                    );
                    try zts.print(tpl, "transaction_legs_end", .{
                        .change_units = conv_units.withPrecision(2),
                        .change_cur = project.currencies.get(@enumFromInt(@intFromEnum(conv_cur_idx))),
                    }, out);

                    if (try tree.isDescendant(account_idx, p.account())) {
                        try plain_inv.add(p_cur, p.amountNumber().?);
                    }

                    var conv_inv = blk: {
                        if (conversion_target) |to| {
                            try prices.convertInventory(&plain_inv, to, &converted_inv);
                            break :blk &converted_inv;
                        }
                        break :blk &plain_inv;
                    };

                    var inv_iter = conv_inv.by_currency.iterator();
                    while (inv_iter.next()) |kv| {
                        const units = kv.value_ptr.*;
                        if (!units.is_zero()) {
                            try zts.print(tpl, "transaction_balance_cur", .{
                                .units = units.withPrecision(2),
                                .cur = project.currencies.get(@enumFromInt(@intFromEnum(kv.key))),
                            }, out);
                        }
                    }

                    try zts.print(tpl, "transaction_balance_end", .{ .hash = hash }, out);

                    for (postings.start..postings.end) |j| {
                        const p2 = data.postingAt(@intCast(j));
                        try zts.write(tpl, "transaction_posting", out);

                        if (j < postings.end - 1) {
                            try zts.write(t.tree, "tree_node_middle", out);
                        } else {
                            try zts.write(t.tree, "tree_node_last", out);
                        }
                        try zts.write(tpl, "tree_icon", out);
                        try zts.write(t.tree, "icon_leaf", out);

                        {
                            const p2_cur = p2.amountCurrency().unwrap().?;
                            const units, const cur_idx = tryConvert(
                                &prices,
                                conversion_target,
                                p2.amountNumber().?,
                                p2_cur,
                            );
                            try zts.print(tpl, "tree_end", .{
                                .account = p2.accountText(),
                                .change_units = units.withPrecision(2),
                                .change_cur = project.currencies.get(@enumFromInt(@intFromEnum(cur_idx))),
                            }, out);
                        }
                    }

                    try zts.write(tpl, "transaction_end", out);

                    const balance = conv_inv.by_currency.get(conv_cur_idx).?;
                    try plot_data.points.append(alloc, .{
                        .date = try string_store.print("{f}", .{entry.date()}),
                        .currency = project.currencies.get(@enumFromInt(@intFromEnum(conv_cur_idx))),
                        .balance = balance.toFloat(),
                        .balance_rendered = try string_store.print("{f}", .{balance.withPrecision(2)}),
                    });
                }
            },
            .price => |price| {
                try prices.setPriceFromDecl(price);
            },
            else => {},
        }
    }

    try zts.write(tpl, "table_end", out);

    return plot_data;
}

fn tryConvert(
    prices: *const Prices,
    to_opt: ?Data.CurrencyIndex,
    amount: Number,
    from: Data.CurrencyIndex,
) struct { Number, Data.CurrencyIndex } {
    const to = to_opt orelse return .{ amount, from };
    if (prices.convert(amount, from, to)) |result| return .{ result, to };
    return .{ amount, from };
}
