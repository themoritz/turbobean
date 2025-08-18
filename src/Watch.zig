//! Integrates Watcher.zig with the tardy runtime.

const std = @import("std");
const log = std.log.scoped(.watch);
const Watcher = @import("Watcher.zig");
const Runtime = @import("zzz").tardy.Runtime;

const Self = @This();

alloc: std.mem.Allocator,
mutex: std.Thread.Mutex,
watcher: Watcher,
rt: ?*Runtime,
listeners: std.AutoHashMap(usize, ListenerEntry), // id -> ListenerEntry
next_listener_id: usize = 0,

/// Listener as kept track of by the watcher.
const ListenerEntry = struct {
    changed_path: ?[]const u8,
    task_index: usize,
};

pub const Listener = struct {
    inner: *Self,
    id: usize,

    pub fn awaitChanged(self: Listener) []const u8 {
        while (true) {
            self.inner.mutex.lock();
            const ptr = &self.inner.listeners.getPtr(self.id).?;
            if (ptr.*.changed_path) |path| {
                ptr.*.changed_path = null;
                self.inner.mutex.unlock();
                return path;
            } else {
                self.inner.mutex.unlock();
                try self.inner.rt.?.scheduler.trigger_await();
            }
        }
    }

    pub fn deinit(self: Listener) void {
        log.debug("Removing listener {d}", .{self.id});
        self.inner.mutex.lock();
        defer self.inner.mutex.unlock();
        const removed = self.inner.listeners.remove(self.id);
        std.debug.assert(removed);
    }
};

pub fn onChange(self: *Self, path: []const u8) void {
    log.debug("Watcher callback tiggered", .{});
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.rt) |rt| {
        var iter = self.listeners.valueIterator();
        while (iter.next()) |entry| {
            entry.*.changed_path = path;
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
}

pub fn init(alloc: std.mem.Allocator) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .mutex = .{},
        .rt = null,
        .listeners = std.AutoHashMap(usize, ListenerEntry).init(alloc),
        .watcher = try Watcher.init(Self, self, alloc),
    };
    return self;
}

pub fn deinit(self: *Self) void {
    self.watcher.deinit();
    self.listeners.deinit();
    self.alloc.destroy(self);
}

pub fn start(self: *Self) !void {
    try self.watcher.start();
}

pub fn addFile(self: *Self, path: []const u8) !void {
    try self.watcher.addFile(path);
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
        .changed_path = null,
        .task_index = rt.current_task.?,
    });

    log.debug("Added listener {d}", .{id});

    return Listener{ .inner = self, .id = id };
}
