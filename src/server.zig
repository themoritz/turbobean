const std = @import("std");
const zts = @import("zts");
const tardy = @import("zzz").tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = @import("zzz").tardy.Runtime;

const Watch = @import("Watch.zig");

const http = @import("zzz").HTTP;

const tmpl = @embedFile("templates/foo.html");

pub fn loop(alloc: std.mem.Allocator) !void {
    var t = try Tardy.init(alloc, .{
        .threading = .single,
    });
    defer t.deinit();

    var router = try http.Router.init(alloc, &.{
        http.Route.init("/").get({}, index_handler).layer(),
        http.Route.init("/bar").get({}, bar_handler).layer(),
        http.Route.init("/sse").get({}, sse_handler).layer(),
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
    var body = std.ArrayList(u8).init(ctx.allocator);
    try zts.print(tmpl, "site", .{"from Zig"}, body.writer());

    return ctx.response.apply(.{
        .status = .OK,
        .body = body.items,
        .mime = http.Mime.HTML,
    });
}

fn sse_handler(ctx: *const http.Context, _: void) !http.Respond {
    var sse = try http.SSE.init(ctx);

    var data = std.ArrayList(u8).init(ctx.allocator);
    var i: usize = 0;

    var watch = try Watch.init(ctx.allocator, "README.md");
    defer watch.deinit();

    const thread = try watch.start();
    defer thread.join();
    defer watch.stop();

    var task = watch.task(ctx.runtime);

    while (true) {
        task.await_changed();
        // try tardy.Timer.delay(ctx.runtime, .{ .seconds = 10 });

        data.clearRetainingCapacity();
        try zts.print(tmpl, "sse", .{ .count = i }, data.writer());
        sse.send(.{ .data = data.items }) catch break;
        i += 1;
    }

    return .responded;
}

fn bar_handler(ctx: *const http.Context, _: void) !http.Respond {
    var body = std.ArrayList(u8).init(ctx.allocator);
    try zts.print(tmpl, "bar", .{}, body.writer());

    return ctx.response.apply(.{
        .status = .OK,
        .body = body.items,
        .mime = http.Mime.HTML,
    });
}

fn frame(rt: *Runtime, task: Watch.Task) !void {
    _ = rt;
    while (true) {
        std.log.debug("Waiting...", .{});
        task.await_changed();
        std.log.debug("Changed!", .{});
    }
}
