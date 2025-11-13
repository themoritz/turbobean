const std = @import("std");
const log = std.log.scoped(.state);
const Project = @import("../project.zig");
const Self = @This();
const Uri = @import("../Uri.zig");
const Watcher = @import("../Watcher.zig").Platform;
const Broadcast = @import("../Broadcast.zig");

alloc: std.mem.Allocator,
watcher: Watcher,

broadcast: Broadcast = .{},

project_rwlock: std.Thread.RwLock = .{},
project: *Project,

/// Does not take ownership of the project.
pub fn init(alloc: std.mem.Allocator, project: *Project) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .watcher = try Watcher.init(Self, self, alloc),
        .project = project,
    };

    for (project.uris.items) |uri| {
        try self.watcher.addFile(uri.absolute());
    }
    try self.watcher.start();

    return self;
}

pub fn deinit(self: *Self) void {
    self.watcher.deinit();
    self.alloc.destroy(self);
}

pub fn onChange(self: *Self, path: []const u8) void {
    log.debug("File changed: {s}", .{path});

    self.updateProject(path) catch |err| {
        log.err("Failed to update project: {s}", .{@errorName(err)});
        return;
    };

    self.project.printErrors() catch {};

    self.broadcast.publishVersion();
}

pub fn acquireProject(self: *Self) void {
    self.project_rwlock.lockShared();
}

pub fn releaseProject(self: *Self) void {
    self.project_rwlock.unlockShared();
}

fn updateProject(self: *Self, path: []const u8) !void {
    var uri = try Uri.from_absolute(self.alloc, path);
    defer uri.deinit(self.alloc);
    const source = try uri.load_nullterminated(self.alloc);
    {
        self.project_rwlock.lock();
        defer self.project_rwlock.unlock();

        try self.project.update_file(uri.value, source);
    }
}
