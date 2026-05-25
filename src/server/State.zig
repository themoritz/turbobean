const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.state);
const Project = @import("../project.zig");
const Self = @This();
const Uri = @import("../Uri.zig");
const Watcher = @import("../Watcher.zig").Platform;
const Broadcast = @import("../Broadcast.zig");

alloc: std.mem.Allocator,
io: Io,
watcher: Watcher,

broadcast: Broadcast = .{},

project_rwlock: Io.RwLock = .init,
project: *Project,

/// Does not take ownership of the project.
pub fn init(alloc: std.mem.Allocator, io: Io, project: *Project) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .io = io,
        .watcher = try Watcher.init(Self, self, alloc, io),
        .project = project,
    };

    for (project.data.files.items) |f| {
        try self.watcher.addFile(f.uri.absolute());
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

    self.broadcast.publishVersion(self.io);
}

pub fn acquireProject(self: *Self) void {
    self.project_rwlock.lockSharedUncancelable(self.io);
}

pub fn releaseProject(self: *Self) void {
    self.project_rwlock.unlockShared(self.io);
}

fn updateProject(self: *Self, path: []const u8) !void {
    var uri = try Uri.from_absolute(self.alloc, path);
    defer uri.deinit(self.alloc);
    const source = try uri.load_nullterminated(self.alloc, self.io);
    {
        self.project_rwlock.lockUncancelable(self.io);
        defer self.project_rwlock.unlock(self.io);

        try self.project.update_file(uri.value, source);
    }
}
