const std = @import("std");
const Allocator = std.mem.Allocator;
const zts = @import("zts");
const State = @import("State.zig");

pub fn handler(alloc: Allocator, req: *std.http.Server.Request, state: *State) !void {
    const t = @embedFile("../templates/index.html");
    var body = std.array_list.Managed(u8).init(alloc);
    defer body.deinit();
    try zts.writeHeader(t, body.writer());

    state.acquireProject();
    defer state.releaseProject();

    for (state.project.sorted_entries.items) |sorted_entry| {
        const data = state.project.files.items[sorted_entry.file];
        const entry = data.entries.items[sorted_entry.entry];
        switch (entry.payload) {
            .open => |open| {
                try zts.print(t, "nav_account", .{
                    .account = open.account.slice,
                }, body.writer());
            },
            else => {},
        }
    }

    try zts.write(t, "nav_end", body.writer());

    try req.respond(body.items, .{});
}
