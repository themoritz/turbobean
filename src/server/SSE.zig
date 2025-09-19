const std = @import("std");
const Server = std.http.Server;
const Self = @This();

alloc: std.mem.Allocator,
response: Server.Response,
send_buffer: [1 << 17]u8, // ~ 130k

pub fn init(alloc: std.mem.Allocator, request: *Server.Request) !*Self {
    const self = try alloc.create(Self);
    self.alloc = alloc;
    self.response = request.respondStreaming(.{
        .send_buffer = &self.send_buffer,
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
    const writer = self.response.writer();
    if (options.event) |event| {
        try std.fmt.format(writer, "event: {s}\n", .{event});
    }
    var iter = std.mem.splitScalar(u8, options.payload, '\n');
    while (iter.next()) |line| {
        try std.fmt.format(writer, "data: {s}\n", .{line});
    }
    try writer.writeByte('\n');
    try self.response.flush();
}

pub fn end(self: *Self) !void {
    return self.response.end();
}
