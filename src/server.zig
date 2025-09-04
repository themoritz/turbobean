const std = @import("std");
const zts = @import("zts");
const tardy = @import("zzz").tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = @import("zzz").tardy.Runtime;
const Project = @import("project.zig");
const journal = @import("server/journal.zig");

const Watch = @import("Watch.zig");

const http = @import("zzz").HTTP;

pub const ServerState = struct {
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
        http.Route.init("/journal").get({}, index_handler).layer(),
        http.Route.init("/sse/journal").get(&state, journal.handler).layer(),
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
    defer body.deinit();
    try zts.writeHeader(t, body.writer());

    return ctx.response.apply(.{
        .status = .OK,
        .body = body.items,
        .mime = http.Mime.HTML,
    });
}
