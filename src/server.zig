const std = @import("std");
const Allocator = std.mem.Allocator;
const zts = @import("zts");
const Project = @import("project.zig");
const journal = @import("server/journal.zig");
const State = @import("server/State.zig");
const http = @import("server/http.zig");

pub fn loop(alloc: std.mem.Allocator, project: *Project) !void {
    const address = try std.net.Address.parseIp("0.0.0.0", 8080);
    var net_server = try address.listen(.{ .reuse_address = true });
    defer net_server.deinit();

    std.debug.print("Listening on {any}\n", .{address});

    const state = try State.init(alloc, project);
    const assets = try std.fs.cwd().openDir("assets", .{});

    while (true) {
        const conn = try net_server.accept();
        _ = try std.Thread.spawn(.{}, handle_conn, .{ alloc, conn, state, assets });
    }

    // var router = try http.Router.init(alloc, &.{
    //     http.Route.init("/").get({}, index_handler).layer(),
    //     http.Route.init("/journal").get({}, index_handler).layer(),
    //     http.Route.init("/sse/journal").get(&state, journal.handler).layer(),
    //     http.FsDir.serve("/static", static_dir),
    // }, .{});
    // defer router.deinit(alloc);
}

fn handle_conn(
    alloc: Allocator,
    conn: std.net.Server.Connection,
    state: *State,
    assets: std.fs.Dir,
) !void {
    var read_buffer: [8096]u8 = undefined;

    var server = std.http.Server.init(conn, &read_buffer);

    while (true) {
        var req = server.receiveHead() catch |err| {
            switch (err) {
                error.HttpConnectionClosing => {},
                else => std.log.warn("Error while accepting HTTP request: {any}", .{err}),
            }
            break;
        };

        std.log.info("Request: {s} {s}", .{ @tagName(req.head.method), req.head.target });

        switch (req.head.method) {
            .GET => {
                if (std.mem.eql(u8, req.head.target, "/") or std.mem.startsWith(u8, req.head.target, "/journal")) {
                    try index_handler(alloc, &req);
                } else if (std.mem.startsWith(u8, req.head.target, "/sse/journal")) {
                    journal.handler(alloc, &req, state) catch |err| switch (err) {
                        error.BrokenPipe => break,
                        else => return err,
                    };
                } else {
                    try static_handler(alloc, &req, assets);
                }
            },
            else => try req.respond("Method not allowed\n", .{ .status = .method_not_allowed }),
        }
    }
}

fn index_handler(alloc: Allocator, req: *std.http.Server.Request) !void {
    const t = @embedFile("templates/index.html");
    var body = std.ArrayList(u8).init(alloc);
    defer body.deinit();
    try zts.writeHeader(t, body.writer());

    try req.respond(body.items, .{});
}

fn static_handler(alloc: Allocator, req: *std.http.Server.Request, assets: std.fs.Dir) !void {
    if (std.mem.startsWith(u8, req.head.target, "/static/")) {
        const sub_path = req.head.target[8..];
        const file = assets.openFile(sub_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return try req.respond("Asset not found\n", .{ .status = .not_found }),
            else => return err,
        };
        defer file.close();

        const extension_start = std.mem.lastIndexOfScalar(u8, sub_path, '.');
        const mime: []const u8 = blk: {
            if (extension_start) |start| {
                if (sub_path.len - start == 0) break :blk "application/octet-stream";
                if (std.mem.eql(u8, sub_path[start + 1 ..], "css")) break :blk "text/css";
                if (std.mem.eql(u8, sub_path[start + 1 ..], "js")) break :blk "application/javascript";
                break :blk "application/octet-stream";
            } else {
                break :blk "application/octet-stream";
            }
        };

        var response_headers = std.ArrayList(std.http.Header).init(alloc);
        defer response_headers.deinit();

        try response_headers.append(.{ .name = "Content-Type", .value = mime });

        // ETag and caching
        const meta = try file.metadata();

        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&meta.size()));
        hash.update(std.mem.asBytes(&meta.modified()));
        const etag_hash = hash.final();

        const calc_etag = try std.fmt.allocPrint(alloc, "\"{d}\"", .{etag_hash});
        try response_headers.append(.{ .name = "ETag", .value = calc_etag });

        if (getHeader(req, "If-None-Match")) |etag| {
            if (std.mem.eql(u8, etag, calc_etag)) {
                return try req.respond("", .{
                    .status = .not_modified,
                });
            }
        }

        const contents = try file.readToEndAlloc(alloc, std.math.maxInt(usize));
        defer alloc.free(contents);

        try req.respond(contents, .{
            .status = .ok,
            .extra_headers = response_headers.items,
        });
    } else {
        try req.respond("Asset not found\n", .{ .status = .not_found });
    }
}

fn getHeader(req: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (std.mem.eql(u8, header.name, name)) {
            return header.value;
        }
    }
    return null;
}
