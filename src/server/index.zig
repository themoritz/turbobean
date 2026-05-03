const std = @import("std");
const Allocator = std.mem.Allocator;
const zts = @import("zts");
const State = @import("State.zig");
const t = @import("templates.zig").index;

pub fn handler(alloc: Allocator, req: *std.http.Server.Request, state: *State) !void {
    var body = std.array_list.Managed(u8).init(alloc);
    defer body.deinit();
    try zts.writeHeader(t, body.writer());

    state.acquireProject();
    defer state.releaseProject();

    var entry_iter = state.project.data.iterEntries();
    while (entry_iter.next()) |entry| {
        switch (entry.payload()) {
            .open => |open| {
                try zts.print(t, "nav_account", .{
                    .account = open.accountText(),
                }, body.writer());
            },
            else => {},
        }
    }

    try zts.write(t, "nav_end", body.writer());

    try req.respond(body.items, .{});
}
