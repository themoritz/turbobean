const std = @import("std");
const zts = @import("zts");
const tardy = @import("zzz").tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = @import("zzz").tardy.Runtime;
const Project = @import("project.zig");
const Tree = @import("tree.zig");

const Watch = @import("Watch.zig");

const http = @import("zzz").HTTP;

pub fn run(alloc: std.mem.Allocator, project: *Project) !void {
    var t = try Tardy.init(alloc, .{
        .threading = .single,
    });
    defer t.deinit();

    var watch = try Watch.init(alloc, ".");
    defer watch.deinit();

    const thread = try watch.start(0.2);
    defer thread.join();
    defer watch.stop();

    var router = try http.Router.init(alloc, &.{
        http.Route.init("/").get({}, index_handler).layer(),
        http.Route.init("/sse").get(&watch, sse_handler).layer(),
        http.Route.init("/journal").get(project, journal_handler).layer(),
    }, .{});
    defer router.deinit(alloc);

    var socket = try tardy.Socket.init(.{ .tcp = .{ .host = "0.0.0.0", .port = 8080 } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(256);

    const EntryParams = struct {
        router: *const http.Router,
        socket: tardy.Socket,
    };

    try t.entry(
        EntryParams{
            .router = &router,
            .socket = socket,
        },
        struct {
            fn init(rt: *Runtime, p: EntryParams) !void {
                var server = http.Server.init(.{
                    .stack_size = 1024 * 1024 * 4,
                    .socket_buffer_bytes = 1024 * 2,
                });
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.init,
    );
}

fn index_handler(ctx: *const http.Context, _: void) !http.Respond {
    const t = @embedFile("templates/index.html");
    var body = std.ArrayList(u8).init(ctx.allocator);
    try zts.writeHeader(t, body.writer());

    return ctx.response.apply(.{
        .status = .OK,
        .body = body.items,
        .mime = http.Mime.HTML,
    });
}

fn sse_handler(ctx: *const http.Context, watch: *Watch) !http.Respond {
    var sse = try http.SSE.init(ctx);

    var data = std.ArrayList(u8).init(ctx.allocator);
    var i: usize = 0;

    var listener = try watch.newListener(ctx.runtime);
    defer listener.deinit();

    while (true) {
        listener.awaitChanged();

        data.clearRetainingCapacity();
        // try zts.print(tmpl, "sse", .{ .count = i }, data.writer());
        sse.send(.{ .data = data.items }) catch |err| switch (err) {
            error.Closed => {
                std.log.debug("Client closed.", .{});
                break;
            },
            else => return err,
        };
        i += 1;
    }

    return .responded;
}

const JournalParams = struct {
    account: []const u8,
};

fn journal_handler(ctx: *const http.Context, project: *Project) !http.Respond {
    const params = try http.Query(JournalParams).parse(ctx.allocator, ctx);

    const t = @embedFile("templates/journal.html");
    var body = std.ArrayList(u8).init(ctx.allocator);
    const out = body.writer();

    var tree = try Tree.init(ctx.allocator);

    try zts.write(t, "table", out);

    for (project.sorted_entries.items) |sorted_entry| {
        const data = project.files.items[sorted_entry.file];
        const entry = data.entries.items[sorted_entry.entry];
        switch (entry.payload) {
            .open => |open| {
                if (std.mem.eql(u8, open.account.slice, params.account)) {
                    _ = try tree.open(open.account.slice, null, open.booking);
                    try zts.print(t, "open_row", .{
                        .date = entry.date,
                        .account = open.account.slice,
                    }, out);
                }
            },
            .transaction => |tx| {
                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        const p = data.postings.get(i);
                        if (std.mem.eql(u8, p.account.slice, params.account)) {
                            try zts.print(t, "tx_row", .{
                                .date = entry.date,
                                .payee = tx.payee,
                                .narration = tx.narration,
                                .change_units = p.amount.number.?,
                                .change_cur = p.amount.currency.?,
                            }, out);
                            try tree.postInventory(entry.date, p);
                            var sum = try tree.inventoryAggregatedByAccount(ctx.allocator, params.account);
                            var iter = sum.by_currency.iterator();
                            while (iter.next()) |kv| {
                                try zts.print(t, "balance_cur", .{
                                    .units = kv.value_ptr.total_units(),
                                    .cur = kv.key_ptr.*,
                                }, out);
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

    return ctx.response.apply(.{
        .status = .OK,
        .body = body.items,
        .mime = http.Mime.HTML,
    });
}
