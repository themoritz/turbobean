const std = @import("std");
const zts = @import("zts");
const http = @import("http.zig");
const State = @import("State.zig");
const Uri = @import("../Uri.zig");
const Project = @import("../project.zig");
const Tree = @import("../tree.zig");
const Date = @import("../date.zig").Date;
const SSE = @import("SSE.zig");
const EntryFilter = @import("EntryFilter.zig");

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

            var plot_points = try render(alloc, state.project, filter, account, &html.writer);
            defer {
                for (plot_points.items) |*plot_point| plot_point.deinit(alloc);
                plot_points.deinit(alloc);
            }
            try stringify.write(plot_points.items);
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
    hash: u64,
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

fn render(
    alloc: std.mem.Allocator,
    project: *Project,
    filter: EntryFilter,
    account: []const u8,
    out: *std.Io.Writer,
) !std.ArrayList(PlotPoint) {
    const t = @embedFile("../templates/journal.html");

    var tree = try Tree.init(alloc);
    defer tree.deinit();
    var plot_points = std.ArrayList(PlotPoint){};
    errdefer {
        for (plot_points.items) |*plot_point| {
            plot_point.deinit(alloc);
        }
        plot_points.deinit(alloc);
    }

    try zts.write(t, "table", out);

    for (project.sorted_entries.items) |sorted_entry| {
        const data = project.files.items[sorted_entry.file];
        const entry = data.entries.items[sorted_entry.entry];
        switch (entry.payload) {
            .open => |open| {
                if (std.mem.eql(u8, open.account.slice, account)) {
                    // We have to open the account even if it's outside the date filter.
                    _ = try tree.open(open.account.slice, null, open.booking_method);
                    if (filter.isWithinDateRange(entry.date)) {
                        try zts.print(t, "open", .{
                            .date = entry.date,
                        }, out);
                    }
                }
            },
            .transaction => |tx| {
                if (tx.dirty) continue;

                if (!filter.isWithinDateRange(entry.date)) continue;
                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        const p = data.postings.get(i);
                        if (std.mem.eql(u8, p.account.slice, account)) {
                            // Add i to get different hashes when the same transaction
                            // has multiple postings to the queried account.
                            const hash = entry.hash() + i;

                            try zts.print(t, "transaction", .{
                                .date = entry.date,
                                .flag = tx.flag.slice,
                                .highlight = switch (tx.flag.slice[0]) {
                                    '!' => "flagged",
                                    else => "",
                                },
                            }, out);

                            if (tx.payee) |payee| {
                                try zts.print(t, "transaction_payee", .{
                                    .payee = payee[1 .. payee.len - 1],
                                }, out);
                                if (tx.narration) |n| if (n.len > 2) try zts.write(t, "transaction_separator", out);
                            }
                            if (tx.narration) |n| if (n.len > 2) try zts.print(t, "transaction_narration", .{
                                .narration = n[1 .. n.len - 1],
                            }, out);

                            try zts.print(t, "transaction_legs", .{
                                .hash = hash,
                            }, out);

                            for (postings.start..postings.end) |_| {
                                try zts.write(t, "transaction_leg", out);
                            }

                            try zts.print(t, "transaction_legs_end", .{
                                .change_units = p.amount.number.?.withPrecision(2),
                                .change_cur = p.amount.currency.?,
                            }, out);

                            try tree.postInventory(entry.date, p);
                            var sum = try tree.inventoryAggregatedByAccount(alloc, account);
                            defer sum.deinit();
                            var iter = sum.by_currency.iterator();
                            while (iter.next()) |kv| {
                                const units = kv.value_ptr.total_units();
                                if (!units.is_zero()) {
                                    try zts.print(t, "transaction_balance_cur", .{
                                        .units = units.withPrecision(2),
                                        .cur = kv.key_ptr.*,
                                    }, out);
                                }
                            }
                            try zts.print(t, "transaction_balance_end", .{
                                .hash = hash,
                            }, out);

                            for (postings.start..postings.end) |j| {
                                const p2 = data.postings.get(j);
                                try zts.write(t, "transaction_posting", out);

                                if (j < postings.end - 1) {
                                    try zts.write(t, "tree_middle", out);
                                } else {
                                    try zts.write(t, "tree_last", out);
                                }

                                try zts.print(t, "tree_end", .{
                                    .account = p2.account.slice,
                                    .change_units = p2.amount.number.?.withPrecision(2),
                                    .change_cur = p2.amount.currency.?,
                                }, out);
                            }

                            try zts.write(t, "transaction_end", out);

                            const balance = sum.by_currency.get(p.amount.currency.?).?.total_units();
                            try plot_points.append(alloc, .{
                                .hash = hash,
                                .date = try std.fmt.allocPrint(alloc, "{f}", .{entry.date}),
                                .currency = try alloc.dupe(u8, p.amount.currency.?),
                                .balance = balance.toFloat(),
                                .balance_rendered = try std.fmt.allocPrint(alloc, "{f}", .{balance.withPrecision(2)}),
                            });
                        }
                    }
                }
            },
            else => {},
        }
    }

    try zts.write(t, "table_end", out);

    return plot_points;
}
