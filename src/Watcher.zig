const std = @import("std");
const Self = @This();

watch_entries: std.ArrayList(WatchItem),
kq: i32,
onChange: *const fn (self: *anyopaque, path: []const u8) void,
ctx: *anyopaque,
running: bool,
thread: std.Thread,
mutex: std.Thread.Mutex,

const WatchItem = struct {
    path: []const u8,
    fd: std.fs.File,
};

pub fn init(comptime T: type, ctx: *T, alloc: std.mem.Allocator) !Self {
    return .{
        .watch_entries = std.ArrayList(WatchItem).init(alloc),
        .kq = try std.posix.kqueue(),
        .onChange = struct {
            fn onChange(ctx_opaque: *anyopaque, path: []const u8) void {
                T.onChange(@alignCast(@ptrCast(ctx_opaque)), path);
            }
        }.onChange,
        .ctx = ctx,
        .running = true,
        .thread = undefined,
        .mutex = .{},
    };
}

pub fn start(self: *Self) !void {
    self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
}

pub fn deinit(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    self.running = false;
    for (self.watch_entries.items) |item| {
        item.fd.close();
    }
    self.watch_entries.deinit();
    std.posix.close(self.kq);
}

pub fn addFile(self: *Self, path: []const u8) !void {
    const fd = try std.fs.openFileAbsolute(path, .{});
    errdefer fd.close();

    self.mutex.lock();
    defer self.mutex.unlock();

    var event = std.mem.zeroes(std.c.Kevent);
    event.flags = std.c.EV.ADD | std.c.EV.CLEAR | std.c.EV.ENABLE;
    event.filter = std.c.EVFILT.VNODE;
    event.fflags = std.c.NOTE.WRITE;
    event.ident = @intCast(fd.handle);
    event.udata = self.watch_entries.items.len;

    var events: [1]std.c.Kevent = .{event};
    _ = std.posix.system.kevent(
        self.kq,
        @as([]std.c.Kevent, events[0..1]).ptr,
        1,
        @as([]std.c.Kevent, events[0..1]).ptr,
        0,
        null,
    );

    try self.watch_entries.append(.{ .path = path, .fd = fd });
}

fn threadMain(self: *Self) !void {
    while (self.running) {
        var changelist: [1]std.c.Kevent = undefined;
        @memset(&changelist, std.mem.zeroes(std.c.Kevent));

        const count = std.posix.system.kevent(self.kq, &changelist, 0, &changelist, 1, null);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.running) {
            for (changelist[0..@intCast(count)]) |ev| {
                if (ev.fflags & std.c.NOTE.WRITE != 0) {
                    self.onChange(self.ctx, self.watch_entries.items[@intCast(ev.udata)].path);
                }
            }
        }
    }
}
