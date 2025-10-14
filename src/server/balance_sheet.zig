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
) !void {
    var sse = try SSE.init(alloc, req);
    defer sse.deinit();

    var parsed_request = try http.ParsedRequest.parse(alloc, req.head.target);
    defer parsed_request.deinit(alloc);
    var filter = try http.Query(EntryFilter).parse(alloc, &parsed_request.params);
    defer filter.deinit(alloc);

    var html = std.ArrayList(u8).init(alloc);
    defer html.deinit();
    const html_out = html.writer();

    var json = std.ArrayList(u8).init(alloc);
    defer json.deinit();
    const json_out = json.writer();

    var listener = state.broadcast.newListener();

    while (true) {
        {
            state.acquireProject();
            defer state.releaseProject();

            const plot_points = try render(alloc, state.project, filter, html_out.any());
            defer {
                for (plot_points.items) |*plot_point| plot_point.deinit(alloc);
                plot_points.deinit();
            }
            try std.json.stringify(plot_points.items, .{}, json_out);
        }

        try sse.send(.{ .payload = html.items });
        try sse.send(.{ .payload = json.items, .event = "plot_points" });

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
    out: std.io.AnyWriter,
) !std.ArrayList(PlotPoint) {
    const t = @embedFile("../templates/balance_sheet.html");

    var tree = try Tree.init(alloc);
    defer tree.deinit();

    var plot_points = std.ArrayList(PlotPoint).init(alloc);
    errdefer {
        for (plot_points.items) |*plot_point| {
            plot_point.deinit(alloc);
        }
        plot_points.deinit();
    }

    var before_start = true;

    for (project.sorted_entries.items) |sorted_entry| {
        const data = project.files.items[sorted_entry.file];
        const entry = data.entries.items[sorted_entry.entry];

        if (filter.isAfterStart(entry.date)) {
            try tree.clearEarnings("Equity:Earnings:Previous");
            before_start = false;
        }

        if (!before_start and filter.isAfterEnd(entry.date)) {
            break;
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
                    try tree.postInventory(entry.date, project.synthetic_postings.get(i));
                }
            },
            else => {},
        }
    }

    try tree.clearEarnings("Equity:Earnings:Current");

    // Render Tree
    try zts.write(t, "table", out);

    try zts.write(t, "table_end", out);

    return plot_points;
}
