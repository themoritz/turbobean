const std = @import("std");
const Allocator = std.mem.Allocator;
const Project = @import("project.zig");
const journal = @import("server/journal.zig");
const balance_sheet = @import("server/balance_sheet.zig");
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

    const decoded = try http.decode_url_alloc(alloc, req.head.target);
    defer alloc.free(decoded);
    std.log.info("Request: {s} {s}", .{ @tagName(req.head.method), decoded });

    try route(alloc, state, static, &req);
}

fn route(alloc: Allocator, state: *State, static: *Static, request: *std.http.Server.Request) !void {
    const target = request.head.target;
    const method = request.head.method;

    if (method != .GET) {
        return request.respond("Method not allowed\n", .{ .status = .method_not_allowed });
    }

    if (std.mem.eql(u8, target, "/shutdown")) {
        running.store(false, .seq_cst);
        state.broadcast.stop();
        return request.respond("Shutdown initiated\n", .{ .status = .ok });
    }

    if (std.mem.startsWith(u8, target, "/static/")) {
        return static.handler(request);
    }

    if (std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/balance_sheet") or std.mem.startsWith(u8, target, "/journal")) {
        return index.handler(alloc, request, state);
    }

    if (std.mem.eql(u8, target, "/sse/balance_sheet")) {
        balance_sheet.handler(alloc, request, state) catch |err| switch (err) {
            error.BrokenPipe => return,
            else => return err,
        };
    }

    if (std.mem.startsWith(u8, target, "/sse/journal/")) {
        const raw_account = if (std.mem.indexOf(u8, target, "?")) |i| target[13..i] else target[13..];
        const account = try http.decode_url_alloc(alloc, raw_account);
        defer alloc.free(account);
        journal.handler(alloc, request, state, account) catch |err| switch (err) {
            error.BrokenPipe => return,
            else => return err,
        };
    }
}
