const std = @import("std");
const zts = @import("zts");
const http = @import("zzz").HTTP;
const ServerState = @import("../server.zig").ServerState;
const Uri = @import("../Uri.zig");
const Project = @import("../project.zig");
const Tree = @import("../tree.zig");

const Params = struct {
    account: []const u8,
};

pub fn handler(ctx: *const http.Context, state: *ServerState) !http.Respond {
    var sse = try http.SSE.init(ctx);

    const params = try http.Query(Params).parse(ctx.allocator, ctx);

    var body = std.ArrayList(u8).init(ctx.allocator);
    const out = body.writer();

    var listener = try state.watch.newListener(ctx.runtime);
    defer listener.deinit();

    while (true) {
        try render(ctx.allocator, state.project, params.account, out.any());

        sse.send(.{ .data = body.items }) catch |err| switch (err) {
            error.Closed => {
                std.log.debug("Client closed.", .{});
                break;
            },
            else => return err,
        };

        body.clearRetainingCapacity();

        const path = listener.awaitChanged();
        const uri = try Uri.from_absolute(ctx.allocator, path);
        const source = try uri.load_nullterminated(state.project.alloc);
        try state.project.update_file(uri.value, source);
    }

    return .responded;
}

fn render(
    alloc: std.mem.Allocator,
    project: *Project,
    account: []const u8,
    out: std.io.AnyWriter,
) !void {
    const t = @embedFile("../templates/journal.html");

    var tree = try Tree.init(alloc);

    try zts.write(t, "table", out);

    for (project.sorted_entries.items) |sorted_entry| {
        const data = project.files.items[sorted_entry.file];
        const entry = data.entries.items[sorted_entry.entry];
        switch (entry.payload) {
            .open => |open| {
                if (std.mem.eql(u8, open.account.slice, account)) {
                    _ = try tree.open(open.account.slice, null, open.booking_method);
                    try zts.print(t, "open_row", .{
                        .date = entry.date,
                    }, out);
                }
            },
            .transaction => |tx| {
                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        const p = data.postings.get(i);
                        if (std.mem.eql(u8, p.account.slice, account)) {
                            try zts.print(t, "tx_row", .{
                                .date = entry.date,
                                .flag = tx.flag.slice,
                            }, out);
                            if (tx.payee) |payee| {
                                try zts.print(t, "payee", .{ .payee = payee[1 .. payee.len - 1] }, out);
                                if (tx.narration) |_| try zts.print(t, "separator", .{}, out);
                            }
                            if (tx.narration) |n| try zts.print(t, "narration", .{ .narration = n[1 .. n.len - 1] }, out);
                            try zts.print(t, "tx_row_2", .{
                                .change_units = p.amount.number.?,
                                .change_cur = p.amount.currency.?,
                            }, out);
                            try tree.postInventory(entry.date, p);
                            var sum = try tree.inventoryAggregatedByAccount(alloc, account);
                            var iter = sum.by_currency.iterator();
                            while (iter.next()) |kv| {
                                const units = kv.value_ptr.total_units();
                                if (!units.is_zero()) {
                                    try zts.print(t, "balance_cur", .{
                                        .units = units,
                                        .cur = kv.key_ptr.*,
                                    }, out);
                                }
                            }
                            try zts.write(t, "end_tx_row", out);
                        }
                    }
                }
            },
            else => {},
        }
    }

    try zts.write(t, "end_table", out);
}
