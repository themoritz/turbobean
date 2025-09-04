const std = @import("std");
const zts = @import("zts");
const http = @import("zzz").HTTP;
const ServerState = @import("../server.zig").ServerState;
const Uri = @import("../Uri.zig");
const Project = @import("../project.zig");
const Tree = @import("../tree.zig");
const Date = @import("../date.zig").Date;

const Params = struct {
    account: []const u8,
    startDate: ?[]const u8 = null,
    endDate: ?[]const u8 = null,

    pub fn deinit(self: *Params, alloc: std.mem.Allocator) void {
        alloc.free(self.account);
        if (self.startDate) |start| alloc.free(start);
        if (self.endDate) |end| alloc.free(end);
    }
};

fn isWithinDateRange(entry_date: Date, start_date: ?[]const u8, end_date: ?[]const u8) bool {
    if (start_date) |start| {
        const start_parsed = Date.fromSlice(start) catch return false;
        if (entry_date.compare(start_parsed) == .after) {
            return false;
        }
    }

    if (end_date) |end| {
        const end_parsed = Date.fromSlice(end) catch return false;
        if (entry_date.compare(end_parsed) == .before) {
            return false;
        }
    }

    return true;
}

pub fn handler(ctx: *const http.Context, state: *ServerState) !http.Respond {
    const alloc = state.project.alloc;
    var sse = try http.SSE.init(ctx);

    var params = try http.Query(Params).parse(alloc, ctx);
    defer params.deinit(alloc);

    var html = std.ArrayList(u8).init(alloc);
    defer html.deinit();
    const html_out = html.writer();

    var json = std.ArrayList(u8).init(alloc);
    defer json.deinit();
    const json_out = json.writer();

    var listener = try state.watch.newListener(ctx.runtime);
    defer listener.deinit();

    while (true) {
        const plot_points = try render(alloc, state.project, params, html_out.any());
        // defer {
        //     for (plot_points.items) |*plot_point| {
        //         plot_point.deinit(alloc);
        //     }
        //     plot_points.deinit();
        // }
        try std.json.stringify(plot_points.items, .{}, json_out);

        sse.send(.{ .data = html.items }) catch |err| switch (err) {
            error.Closed => {
                std.log.debug("Client closed.", .{});
                break;
            },
            else => return err,
        };

        sse.send(.{ .data = json.items, .event = "plot_points" }) catch |err| switch (err) {
            error.Closed => {
                std.log.debug("Client closed.", .{});
                break;
            },
            else => return err,
        };

        html.clearRetainingCapacity();
        json.clearRetainingCapacity();

        const path = listener.awaitChanged();
        sse.send(.{ .event = "ping" }) catch |err| switch (err) {
            error.Closed => {
                std.log.debug("Client closed.", .{});
                break;
            },
            else => return err,
        };
        const uri = try Uri.from_absolute(alloc, path);
        const source = try uri.load_nullterminated(state.project.alloc);
        try state.project.update_file(uri.value, source);
    }

    return .responded;
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
    params: Params,
    out: std.io.AnyWriter,
) !std.ArrayList(PlotPoint) {
    const t = @embedFile("../templates/journal.html");

    var tree = try Tree.init(alloc);
    defer tree.deinit();
    var plot_points = std.ArrayList(PlotPoint).init(alloc);
    errdefer {
        for (plot_points.items) |*plot_point| {
            plot_point.deinit(alloc);
        }
        plot_points.deinit();
    }

    try zts.write(t, "table", out);

    for (project.sorted_entries.items) |sorted_entry| {
        const data = project.files.items[sorted_entry.file];
        const entry = data.entries.items[sorted_entry.entry];
        switch (entry.payload) {
            .open => |open| {
                if (std.mem.eql(u8, open.account.slice, params.account)) {
                    // We have to open the account even if it's outside the date filter.
                    _ = try tree.open(open.account.slice, null, open.booking_method);
                    if (isWithinDateRange(entry.date, params.startDate, params.endDate)) {
                        try zts.print(t, "open", .{
                            .date = entry.date,
                        }, out);
                    }
                }
            },
            .transaction => |tx| {
                if (!isWithinDateRange(entry.date, params.startDate, params.endDate)) continue;
                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        const p = data.postings.get(i);
                        if (std.mem.eql(u8, p.account.slice, params.account)) {
                            // Add i to get different hashes when the same transaction
                            // has multiple postings to the queried account.
                            const hash = entry.hash() + i;

                            try zts.print(t, "transaction", .{
                                .date = entry.date,
                                .flag = tx.flag.slice,
                            }, out);

                            if (tx.payee) |payee| {
                                try zts.print(t, "transaction_payee", .{
                                    .payee = payee[1 .. payee.len - 1],
                                }, out);
                                if (tx.narration) |_| try zts.write(t, "transaction_separator", out);
                            }
                            if (tx.narration) |n| try zts.print(t, "transaction_narration", .{
                                .narration = n[1 .. n.len - 1],
                            }, out);

                            try zts.print(t, "transaction_legs", .{
                                .hash = hash,
                            }, out);

                            for (postings.start..postings.end) |_| {
                                try zts.write(t, "transaction_leg", out);
                            }

                            try zts.print(t, "transaction_legs_end", .{
                                .change_units = p.amount.number.?,
                                .change_cur = p.amount.currency.?,
                            }, out);

                            try tree.postInventory(entry.date, p);
                            var sum = try tree.inventoryAggregatedByAccount(alloc, params.account);
                            defer sum.deinit();
                            var iter = sum.by_currency.iterator();
                            while (iter.next()) |kv| {
                                const units = kv.value_ptr.total_units();
                                if (!units.is_zero()) {
                                    try zts.print(t, "transaction_balance_cur", .{
                                        .units = units,
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
                                    .change_units = p2.amount.number.?,
                                    .change_cur = p2.amount.currency.?,
                                }, out);
                            }

                            try zts.write(t, "transaction_end", out);

                            const balance = sum.by_currency.get(p.amount.currency.?).?.total_units();
                            try plot_points.append(.{
                                .hash = hash,
                                .date = try std.fmt.allocPrint(alloc, "{any}", .{entry.date}),
                                .currency = try alloc.dupe(u8, p.amount.currency.?),
                                .balance = balance.toFloat(),
                                .balance_rendered = try std.fmt.allocPrint(alloc, "{any:.2}", .{balance}),
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
