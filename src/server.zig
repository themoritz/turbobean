const std = @import("std");
const zts = @import("zts");
const Tardy = @import("zzz").tardy.Tardy(.auto);
const Runtime = @import("zzz").tardy.Runtime;
const Watch = @import("Watch.zig");

const tmpl = @embedFile("./templates/foo.html");

pub fn tst(alloc: std.mem.Allocator) !void {
    var t = try Tardy.init(alloc, .{
        .threading = .single,
    });
    defer t.deinit();

    var watch = try Watch.init(alloc, "README.md");
    defer watch.deinit();

    const thread = try watch.start();

    try t.entry(&watch, struct {
        fn init(rt: *Runtime, w: *Watch) !void {
            try rt.spawn(.{ rt, w.task(rt) }, frame, 1024 * 16);
        }
    }.init);

    thread.join();
}

fn frame(rt: *Runtime, task: Watch.Task) !void {
    _ = rt;
    while (true) {
        std.log.debug("Waiting...", .{});
        task.await_changed();
        std.log.debug("Changed!", .{});
    }
}

pub fn loop(alloc: std.mem.Allocator) !void {
    try tst(alloc);
    var read_buffer: [8096]u8 = undefined;
    var send_buffer: [8096]u8 = undefined;
    const address = try std.net.Address.parseIp("0.0.0.0", 8080);
    var net_server = try address.listen(.{ .reuse_address = true });
    defer net_server.deinit();

    std.debug.print("Listening on {any}\n", .{address});

    while (true) {
        const conn = try net_server.accept();
        var server = std.http.Server.init(conn, &read_buffer);

        var req = try server.receiveHead();

        const header = read_buffer[0..req.head_end];
        std.debug.print("Header: {s}\n", .{header});

        var iter = std.mem.splitScalar(u8, header, ' ');

        if (iter.next()) |method| {
            if (std.mem.eql(u8, method, "GET")) {
                if (iter.next()) |path| {
                    if (std.mem.eql(u8, path, "/")) {
                        var response = req.respondStreaming(.{
                            .send_buffer = &send_buffer,
                        });
                        try zts.print(tmpl, "site", .{"from Zig"}, response.writer());
                        try response.end();
                    } else if (std.mem.eql(u8, path, "/bar")) {
                        var response = req.respondStreaming(.{
                            .send_buffer = &send_buffer,
                        });
                        try zts.print(tmpl, "bar", .{"Bar"}, response.writer());
                        try response.end();
                    }
                }
            } else {
                try req.respond("Bad request", .{ .status = .method_not_allowed });
            }
        } else {
            try req.respond("Bad request", .{ .status = .bad_request });
        }
    }
}
