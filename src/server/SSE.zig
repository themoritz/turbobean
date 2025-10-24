const std = @import("std");
const Server = std.http.Server;
const BodyWriter = std.http.BodyWriter;
const Self = @This();

alloc: std.mem.Allocator,
body_writer: BodyWriter,
send_buffer: [1 << 17]u8, // ~ 130k

pub fn init(alloc: std.mem.Allocator, request: *Server.Request) !*Self {
    const self = try alloc.create(Self);
    self.alloc = alloc;
    self.body_writer = try request.respondStreaming(&self.send_buffer, .{
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
                .{ .name = "Cache-Control", .value = "no-cache" },
                .{ .name = "Connection", .value = "keep-alive" },
            },
        },
    });
    return self;
}

pub fn deinit(self: *Self) void {
    self.alloc.destroy(self);
}

const SendOptions = struct {
    event: ?[]const u8 = null,
    payload: []const u8,
};

pub fn send(self: *Self, options: SendOptions) !void {
    var writer = &self.body_writer.writer;
    if (options.event) |event| {
        try writer.print("event: {s}\n", .{event});
    }
    var iter = std.mem.splitScalar(u8, options.payload, '\n');
    while (iter.next()) |line| {
        try writer.print("data: {s}\n", .{line});
    }
    try writer.writeByte('\n');
    try writer.flush();
    try self.body_writer.flush();
}

pub fn end(self: *Self) !void {
    return self.body_writer.end();
}
