const std = @import("std");
const log = std.log.scoped(.watch);
const fzwatch = @import("fzwatch");
const Runtime = @import("zzz").tardy.Runtime;

const Self = @This();

mutex: std.Thread.Mutex,
rt: ?*Runtime,
listeners: std.AutoHashMap(usize, ListenerEntry),
watcher: fzwatch.Watcher,
next_listener_id: usize = 0,

const ListenerEntry = struct {
    changed: bool,
    task_index: usize,
};

pub const Listener = struct {
    inner: *Self,
    index: usize,

    pub fn awaitChanged(self: Listener) void {
        while (true) {
            self.inner.mutex.lock();
            const ptr = &self.inner.listeners.getPtr(self.index).?;
            if (ptr.*.changed) {
                ptr.*.changed = false;
                self.inner.mutex.unlock();
                break;
            } else {
                self.inner.mutex.unlock();
                try self.inner.rt.?.scheduler.trigger_await();
            }
        }
    }

    pub fn deinit(self: Listener) void {
        log.debug("Removing listener {d}", .{self.index});
        self.inner.mutex.lock();
        defer self.inner.mutex.unlock();
        const removed = self.inner.listeners.remove(self.index);
        std.debug.assert(removed);
    }
};

fn callback(context: ?*anyopaque, event: fzwatch.Event) void {
    const self: *Self = @as(*Self, @ptrCast(@alignCast(context.?)));
    switch (event) {
        .modified => {
            log.debug("Watcher callback tiggered", .{});
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.rt) |rt| {
                var iter = self.listeners.valueIterator();
                while (iter.next()) |entry| {
                    entry.*.changed = true;
                    const index = entry.*.task_index;
                    log.debug("Triggering task {d}", .{index});
                    rt.scheduler.trigger(index) catch |err| {
                        log.err("Failed to trigger task: {s}", .{@errorName(err)});
                    };
                }
                rt.wake() catch |err| {
                    log.err("Failed to wake runtime: {s}", .{@errorName(err)});
                };
            } else {
                log.debug("No runtime, so no listener defined", .{});
            }
        },
    }
}

fn watcherThread(watcher: *fzwatch.Watcher, latency: f16) !void {
    try watcher.start(.{ .latency = latency });
}

pub fn init(alloc: std.mem.Allocator, path: []const u8) !Self {
    var watcher = try fzwatch.Watcher.init(alloc);
    try watcher.addFile(path);
    return Self{
        .mutex = .{},
        .rt = null,
        .listeners = std.AutoHashMap(usize, ListenerEntry).init(alloc),
        .watcher = watcher,
    };
}

pub fn deinit(self: *Self) void {
    self.watcher.deinit();
    self.listeners.deinit();
}

pub fn start(self: *Self, latency: f16) !std.Thread {
    self.watcher.setCallback(callback, self);
    return std.Thread.spawn(.{}, watcherThread, .{ &self.watcher, latency });
}

pub fn stop(self: *Self) void {
    log.debug("Stopping watcher", .{});
    self.watcher.stop();
}

pub fn newListener(self: *Self, rt: *Runtime) !Listener {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.rt == null) {
        self.rt = rt;
    } else {
        std.debug.assert(self.rt.? == rt);
    }

    const id = self.next_listener_id;
    self.next_listener_id += 1;

    try self.listeners.put(id, ListenerEntry{
        .changed = false,
        .task_index = rt.current_task.?,
    });

    log.debug("Added listener {d}", .{id});

    return Listener{ .inner = self, .index = id };
}
