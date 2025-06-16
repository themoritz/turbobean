const std = @import("std");
const Allocator = std.mem.Allocator;
const Data = @import("data.zig");
const Tree = @import("tree.zig");

const Self = @This();

alloc: Allocator,
files: std.ArrayList(Data),
files_by_name: std.StringHashMap(usize),
sorted_entries: std.ArrayList(SortedEntry),

const SortedEntry = struct {
    file: u8,
    entry: u32,
};

pub fn load(alloc: Allocator, name: []const u8) !Self {
    var self = Self{
        .alloc = alloc,
        .files = std.ArrayList(Data).init(alloc),
        .files_by_name = std.StringHashMap(usize).init(alloc),
        .sorted_entries = std.ArrayList(SortedEntry).init(alloc),
    };
    try self.loadFileRec(name, true);
    return self;
}

pub fn deinit(self: *Self) void {
    for (self.files.items) |*data| data.deinit();
    self.files.deinit();

    var iter = self.files_by_name.iterator();
    while (iter.next()) |kv| {
        self.alloc.free(kv.key_ptr.*);
    }
    self.files_by_name.deinit();

    self.sorted_entries.deinit();
}

fn loadFileRec(self: *Self, name: []const u8, is_root: bool) !void {
    if (self.files_by_name.get(name)) |_| return error.ImportCycle;
    const imports = try self.loadSingleFile(name, is_root);
    defer self.alloc.free(imports);
    const dir = std.fs.path.dirname(name) orelse ".";
    for (imports) |import| {
        const joined = try std.fs.path.join(self.alloc, &.{ dir, import });
        defer self.alloc.free(joined);
        try self.loadFileRec(joined, false);
    }
}

fn loadSingleFile(self: *Self, name: []const u8, is_root: bool) !Data.Imports.Slice {
    const owned_name = try self.alloc.dupe(u8, name);

    const file = try std.fs.cwd().openFile(name, .{});
    defer file.close();

    const filesize = try file.getEndPos();
    const source = try self.alloc.alloc(u8, filesize + 1);

    _ = try file.readAll(source[0..filesize]);
    source[filesize] = 0;

    const null_terminated: [:0]u8 = source[0..filesize :0];

    const data, const imports = try Data.loadSource(self.alloc, null_terminated, is_root);
    try self.files.append(data);
    try self.files_by_name.put(owned_name, self.files.items.len - 1);
    return imports;
}

pub fn balanceTransactions(self: *Self) !void {
    for (self.files.items) |*data| {
        try data.balanceTransactions();
    }
}

/// Returns true if errors were printed
pub fn printErrors(self: *Self) !bool {
    var errors_printed = false;
    for (self.files.items) |*data| {
        if (try data.printErrors()) {
            errors_printed = true;
        }
    }
    return errors_printed;
}

pub fn sortEntries(self: *Self) !void {
    self.sorted_entries.clearRetainingCapacity();
    for (self.files.items, 0..) |data, f| {
        for (0..data.entries.items.len) |e| {
            try self.sorted_entries.append(SortedEntry{
                .file = @intCast(f),
                .entry = @intCast(e),
            });
        }
    }
    std.sort.block(SortedEntry, self.sorted_entries.items, self, lessThanFn);
}

fn lessThanFn(self: *Self, lhs: SortedEntry, rhs: SortedEntry) bool {
    const entry_lhs = self.files.items[lhs.file].entries.items[lhs.entry];
    const entry_rhs = self.files.items[rhs.file].entries.items[rhs.entry];
    return Data.Entry.compare({}, entry_lhs, entry_rhs);
}

/// Assumes balanced transactions
pub fn printTree(self: *Self) !void {
    var tree = try Tree.init(self.alloc);
    defer tree.deinit();

    for (self.sorted_entries.items) |sorted_entry| {
        const data = self.files.items[sorted_entry.file];
        const entry = data.entries.items[sorted_entry.entry];
        switch (entry.payload) {
            .open => |open| {
                _ = tree.open(open.account) catch |err| switch (err) {
                    error.AccountExists => {},
                    else => return err,
                };
            },
            .transaction => |tx| {
                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        try tree.addPosition(
                            data.postings.items(.account)[i],
                            data.postings.items(.amount)[i].number.?,
                            data.postings.items(.amount)[i].currency.?,
                        );
                    }
                }
            },
            else => {},
        }
    }

    try tree.print();
}
