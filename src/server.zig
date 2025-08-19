const std = @import("std");
const zts = @import("zts");
const tardy = @import("zzz").tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = @import("zzz").tardy.Runtime;
const Project = @import("project.zig");
const Tree = @import("tree.zig");
const Uri = @import("Uri.zig");

const Watch = @import("Watch.zig");

const http = @import("zzz").HTTP;

const ServerState = struct {
    project: *Project,
    watch: *Watch,
};

pub fn run(alloc: std.mem.Allocator, project: *Project) !void {
    var t = try Tardy.init(alloc, .{
        .threading = .single,
    });
    defer t.deinit();

    var watch = try Watch.init(alloc);
    defer watch.deinit();

    for (project.uris.items) |uri| {
        try watch.addFile(uri.absolute());
    }

    try watch.start();

    var state = ServerState{
        .project = project,
        .watch = watch,
    };

    const static_dir = tardy.Dir.from_std(try std.fs.cwd().openDir("assets", .{}));

    var router = try http.Router.init(alloc, &.{
        http.Route.init("/").get({}, index_handler).layer(),
        http.Route.init("/journal").get(&state, journal_handler).layer(),
        http.FsDir.serve("/static", static_dir),
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

const JournalParams = struct {
    account: []const u8,
};

fn journal_handler(ctx: *const http.Context, state: *ServerState) !http.Respond {
    var sse = try http.SSE.init(ctx);

    const params = try http.Query(JournalParams).parse(ctx.allocator, ctx);

    var body = std.ArrayList(u8).init(ctx.allocator);
    const out = body.writer();

    var listener = try state.watch.newListener(ctx.runtime);
    defer listener.deinit();

    while (true) {
        try render_journal(ctx.allocator, state.project, params.account, out.any());

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

fn render_journal(
    alloc: std.mem.Allocator,
    project: *Project,
    account: []const u8,
    out: std.io.AnyWriter,
) !void {
    const t = @embedFile("templates/journal.html");

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
                                .payee = tx.payee,
                                .narration = tx.narration,
                                .change_units = p.amount.number.?,
                                .change_cur = p.amount.currency.?,
                            }, out);
                            try tree.postInventory(entry.date, p);
                            var sum = try tree.inventoryAggregatedByAccount(alloc, account);
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
}
