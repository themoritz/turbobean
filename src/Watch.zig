const std = @import("std");
const log = std.log.scoped(.watch);

const fzwatch = @import("fzwatch");

const tardy = @import("zzz").tardy;
const Runtime = tardy.Runtime;

const Self = @This();

rt: std.atomic.Value(?*Runtime) align(std.atomic.cache_line),
changed: std.atomic.Value(bool) align(std.atomic.cache_line),
task_index: std.atomic.Value(usize) align(std.atomic.cache_line),

watcher: fzwatch.Watcher,

pub const Task = struct {
    inner: *Self,
    rt: *Runtime,

    pub fn await_changed(self: Task) void {
        while (true) {
            if (self.inner.changed.load(.acquire)) {
                self.inner.changed.store(false, .release);
                break;
            } else {
                const index = self.rt.current_task.?;
                log.debug("Waiting with task id {d}", .{index});
                self.inner.task_index.store(index, .release);
                try self.rt.scheduler.trigger_await();
            }
        }
    }
};

fn callback(context: ?*anyopaque, event: fzwatch.Event) void {
    const self: *Self = @as(*Self, @ptrCast(@alignCast(context.?)));
    switch (event) {
        .modified => {
            log.debug("Watcher callback tiggered", .{});
            self.changed.store(true, .release);
            if (self.rt.load(.acquire)) |rt| {
                const index = self.task_index.load(.acquire);
                log.debug("Triggering task {d}", .{index});
                rt.scheduler.trigger(index) catch |err| {
                    log.err("Failed to trigger task: {s}", .{@errorName(err)});
                };
                rt.wake() catch |err| {
                    log.err("Failed to wake runtime: {s}", .{@errorName(err)});
                };
            } else {
                log.debug("Task hasn't started yet.", .{});
            }
        },
    }
}

fn watcherThread(watcher: *fzwatch.Watcher) !void {
    try watcher.start(.{});
}

pub fn init(alloc: std.mem.Allocator, path: []const u8) !Self {
    var watcher = try fzwatch.Watcher.init(alloc);
    try watcher.addFile(path);
    return Self{
        .changed = .{ .raw = false },
        .task_index = .{ .raw = 0 },
        .watcher = watcher,
        .rt = .{ .raw = null },
    };
}

pub fn deinit(self: *Self) void {
    self.watcher.deinit();
}

pub fn start(self: *Self) !std.Thread {
    self.watcher.setCallback(callback, self);
    return try std.Thread.spawn(.{}, watcherThread, .{&self.watcher});
}

pub fn task(self: *Self, runtime: *Runtime) Task {
    if (self.rt.cmpxchgStrong(null, runtime, .acq_rel, .acquire)) |_| {
        @panic("Only one watch task can exist for a Watcher");
    }
    return Task{
        .inner = self,
        .rt = runtime,
    };
}
