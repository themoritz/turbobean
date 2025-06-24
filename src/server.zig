const std = @import("std");
const zts = @import("zts");

const tmpl = @embedFile("./templates/foo.html");

pub fn loop(alloc: std.mem.Allocator) !void {
    _ = alloc;
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
