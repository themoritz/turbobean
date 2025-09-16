const std = @import("std");
const Allocator = std.mem.Allocator;
const Project = @import("project.zig");
const journal = @import("server/journal.zig");
const index = @import("server/index.zig");
const State = @import("server/State.zig");
const http = @import("server/http.zig");
const Static = @import("server/static.zig").Static;

var running: std.atomic.Value(bool) = .init(true);

pub fn loop(alloc: std.mem.Allocator, project: *Project) !void {
    var threads = std.ArrayList(std.Thread).init(alloc);
    defer threads.deinit();

    const state = try State.init(alloc, project);
    defer state.deinit();

    var static = try Static.init(alloc);
    defer static.deinit();

    {
        const address = try std.net.Address.parseIp("0.0.0.0", 8080);
        var net_server = try address.listen(.{ .reuse_address = true });
        defer net_server.deinit();

        std.log.info("Listening on {any}", .{address});

        while (running.load(.seq_cst)) {
            const conn = try net_server.accept();
            const thread = try std.Thread.spawn(.{}, handle_conn, .{ alloc, conn, state, &static });
            try threads.append(thread);
            // Wait 1 ms in case this connection is a shutdown request.
            std.Thread.sleep(1_000_000);
        }

        std.log.info("Server stopped, waiting for workers...", .{});
    }

    for (threads.items) |thread| thread.join();
}

fn handle_conn(
    alloc: Allocator,
    conn: std.net.Server.Connection,
    state: *State,
    static: *Static,
) !void {
    // Don't reuse connection because we don't want to block forever on receiveHead.
    defer conn.stream.close();

    var read_buffer: [8096]u8 = undefined;
    var server = std.http.Server.init(conn, &read_buffer);

    var req = server.receiveHead() catch |err| {
        switch (err) {
            error.HttpConnectionClosing => {},
            else => std.log.warn("Error while accepting HTTP request: {any}", .{err}),
        }
        return;
    };

    std.log.info("Request: {s} {s}", .{ @tagName(req.head.method), req.head.target });

    switch (req.head.method) {
        .GET => {
            if (std.mem.eql(u8, req.head.target, "/") or std.mem.startsWith(u8, req.head.target, "/journal")) {
                try index.handler(alloc, &req, state);
            } else if (std.mem.eql(u8, req.head.target, "/shutdown")) {
                running.store(false, .seq_cst);
                state.broadcast.stop();
                try req.respond("Shutdown initiated\n", .{ .status = .ok });
            } else if (std.mem.startsWith(u8, req.head.target, "/sse/journal")) {
                journal.handler(alloc, &req, state) catch |err| switch (err) {
                    error.BrokenPipe => {},
                    else => return err,
                };
            } else {
                try static.handler(&req);
            }
        },
        else => try req.respond("Method not allowed\n", .{ .status = .method_not_allowed }),
    }
}
