const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config");
const assets = @import("assets");

pub const Static = if (config.embed_static) StaticEmbedded else StaticFiles;

pub const StaticEmbedded = struct {
    alloc: Allocator,
    assets: std.StaticStringMap([]const u8) = .initComptime(genMap()),

    const Asset = struct { []const u8, []const u8 };

    fn genMap() [assets.files.len]Asset {
        var embassets: [assets.files.len]Asset = undefined;
        comptime var i = 0;
        inline for (assets.files) |file| {
            embassets[i][0] = file;
            embassets[i][1] = @embedFile("../assets/" ++ file);
            i += 1;
        }
        return embassets;
    }

    pub fn init(alloc: Allocator) !StaticEmbedded {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *StaticEmbedded) void {
        _ = self;
    }

    pub fn handler(self: *StaticEmbedded, req: *std.http.Server.Request) !void {
        if (!std.mem.startsWith(u8, req.head.target, "/static/")) {
            return try req.respond("Asset not found\n", .{ .status = .not_found });
        }

        const sub_path = req.head.target[8..];
        const asset = self.assets.get(sub_path) orelse
            return try req.respond("Asset not found\n", .{ .status = .not_found });

        var response_headers = std.ArrayList(std.http.Header).init(self.alloc);
        defer response_headers.deinit();

        try response_headers.append(.{
            .name = "Content-Type",
            .value = getMime(sub_path),
        });

        // ETag and caching
        var hash = std.hash.Wyhash.init(0);
        hash.update(asset);
        const etag_hash = hash.final();

        const calc_etag = try std.fmt.allocPrint(self.alloc, "\"{d}\"", .{etag_hash});
        defer self.alloc.free(calc_etag);

        try response_headers.append(.{ .name = "ETag", .value = calc_etag });

        if (getHeader(req, "If-None-Match")) |etag| {
            if (std.mem.eql(u8, etag, calc_etag)) {
                return try req.respond("", .{
                    .status = .not_modified,
                });
            }
        }

        try req.respond(asset, .{
            .status = .ok,
            .extra_headers = response_headers.items,
        });
    }
};

const StaticFiles = struct {
    alloc: Allocator,
    assets: std.fs.Dir,

    pub fn init(alloc: Allocator) !StaticFiles {
        return .{
            .alloc = alloc,
            .assets = try std.fs.cwd().openDir("src/assets", .{}),
        };
    }

    pub fn deinit(self: *StaticFiles) void {
        self.assets.close();
    }

    pub fn handler(self: *StaticFiles, req: *std.http.Server.Request) !void {
        if (!std.mem.startsWith(u8, req.head.target, "/static/")) {
            return try req.respond("Asset not found\n", .{ .status = .not_found });
        }

        const sub_path = req.head.target[8..];
        const file = self.assets.openFile(sub_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return try req.respond("Asset not found\n", .{ .status = .not_found }),
            else => return err,
        };
        defer file.close();

        var response_headers = std.ArrayList(std.http.Header){};
        defer response_headers.deinit(self.alloc);

        try response_headers.append(self.alloc, .{
            .name = "Content-Type",
            .value = getMime(sub_path),
        });

        // ETag and caching
        const stat = try file.stat();

        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&stat.size));
        hash.update(std.mem.asBytes(&stat.mtime));
        const etag_hash = hash.final();

        const calc_etag = try std.fmt.allocPrint(self.alloc, "\"{d}\"", .{etag_hash});
        defer self.alloc.free(calc_etag);

        try response_headers.append(self.alloc, .{ .name = "ETag", .value = calc_etag });

        if (getHeader(req, "If-None-Match")) |etag| {
            if (std.mem.eql(u8, etag, calc_etag)) {
                return try req.respond("", .{
                    .status = .not_modified,
                });
            }
        }

        const contents = try file.readToEndAlloc(self.alloc, std.math.maxInt(usize));
        defer self.alloc.free(contents);

        try req.respond(contents, .{
            .status = .ok,
            .extra_headers = response_headers.items,
        });
    }
};

fn getHeader(req: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (std.mem.eql(u8, header.name, name)) {
            return header.value;
        }
    }
    return null;
}

fn getMime(path: []const u8) []const u8 {
    const extension_start = std.mem.lastIndexOfScalar(u8, path, '.');
    if (extension_start) |start| {
        if (path.len - start == 0) return "application/octet-stream";
        if (std.mem.eql(u8, path[start + 1 ..], "css")) return "text/css";
        if (std.mem.eql(u8, path[start + 1 ..], "js")) return "application/javascript";
        return "application/octet-stream";
    } else {
        return "application/octet-stream";
    }
}
