const std = @import("std");
const Self = @This();
const log = std.log.scoped(.watcher);

alloc: std.mem.Allocator,
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
        .alloc = alloc,
        .watch_entries = std.ArrayList(WatchItem){},
        .kq = try std.posix.kqueue(),
        .onChange = struct {
            fn onChange(ctx_opaque: *anyopaque, path: []const u8) void {
                T.onChange(@ptrCast(@alignCast(ctx_opaque)), path);
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
    self.watch_entries.deinit(self.alloc);
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

    try self.watch_entries.append(self.alloc, .{ .path = path, .fd = fd });
}

fn threadMain(self: *Self) !void {
    while (self.running) {
        var changelist: [128]std.c.Kevent = undefined;
        @memset(&changelist, std.mem.zeroes(std.c.Kevent));

        log.debug("Waiting for events", .{});
        var count = std.posix.system.kevent(self.kq, &changelist, 0, &changelist, 128, null);
        log.debug("Received {d} events", .{count});

        // Give the events more time to coalesce
        if (count < 128 / 2) {
            std.Thread.sleep(10_000_000); // 10ms
            const remain = 128 - count;
            const extra = std.posix.system.kevent(
                self.kq,
                changelist[@intCast(count)..].ptr,
                0,
                changelist[@intCast(count)..].ptr,
                remain,
                &.{ .sec = 0, .nsec = 100_000 },
            );

            count += extra;
        }

        log.debug("{d} events after coalesce", .{count});

        var deduped: [128]std.c.Kevent = undefined;
        var deduped_count: u32 = 0;
        if (count > 0) {
            deduped[0] = changelist[0];
            deduped_count += 1;
            for (changelist[1..@intCast(count)]) |ev| {
                if (ev.udata != deduped[deduped_count - 1].udata) {
                    deduped[deduped_count] = ev;
                    deduped_count += 1;
                }
            }
        }

        log.debug("Deduped to {d} events", .{deduped_count});

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.running) {
            for (deduped[0..@intCast(deduped_count)]) |ev| {
                log.debug("Received event: {any}", .{ev});
                if (ev.fflags & std.c.NOTE.WRITE != 0) {
                    const path = self.watch_entries.items[@intCast(ev.udata)].path;
                    log.debug("Triggering callback for {s}", .{path});
                    self.onChange(self.ctx, path);
                }
            }
        }
    }
}
