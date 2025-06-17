const std = @import("std");
const Allocator = std.mem.Allocator;
const Data = @import("data.zig");
const Tree = @import("tree.zig");
const Uri = @import("Uri.zig");
const ErrorDetails = @import("ErrorDetails.zig");

const Self = @This();

alloc: Allocator,
files: std.ArrayList(Data),
uris: std.ArrayList(Uri),
/// Keys are URI values, values are index into files and uris.
files_by_uri: std.StringHashMap(usize),
sorted_entries: std.ArrayList(SortedEntry),
errors: std.ArrayList(ErrorDetails),

const SortedEntry = struct {
    file: u8,
    entry: u32,
};

/// Load a project from a root file relative to the CWD.
pub fn load(alloc: Allocator, name: []const u8) !Self {
    var self = Self{
        .alloc = alloc,
        .files = std.ArrayList(Data).init(alloc),
        .uris = std.ArrayList(Uri).init(alloc),
        .files_by_uri = std.StringHashMap(usize).init(alloc),
        .sorted_entries = std.ArrayList(SortedEntry).init(alloc),
        .errors = std.ArrayList(ErrorDetails).init(alloc),
    };
    errdefer self.deinit();
    try self.loadFileRec(name, true);
    try self.pipeline();
    return self;
}

pub fn deinit(self: *Self) void {
    for (self.files.items) |*data| data.deinit();
    self.files.deinit();

    for (self.uris.items) |*uri| uri.deinit(self.alloc);
    self.uris.deinit();

    self.files_by_uri.deinit();

    self.sorted_entries.deinit();
    self.errors.deinit();
}

fn loadFileRec(self: *Self, name: []const u8, is_root: bool) !void {
    if (self.files_by_uri.get(name)) |_| return error.ImportCycle;
    const imports = try self.loadSingleFile(name, is_root);
    defer self.alloc.free(imports);
    const dir = std.fs.path.dirname(name) orelse ".";
    for (imports) |import| {
        const joined = try std.fs.path.join(self.alloc, &.{ dir, import });
        defer self.alloc.free(joined);
        try self.loadFileRec(joined, false);
    }
}

/// Parses a file and balances all transactions.
fn loadSingleFile(self: *Self, name: []const u8, is_root: bool) !Data.Imports.Slice {
    const uri = try Uri.from_relative_to_cwd(self.alloc, name);
    try self.uris.append(uri);

    const file = try std.fs.openFileAbsolute(uri.absolute(), .{});
    defer file.close();

    const filesize = try file.getEndPos();
    const source = try self.alloc.alloc(u8, filesize + 1);

    _ = try file.readAll(source[0..filesize]);
    source[filesize] = 0;

    const null_terminated: [:0]u8 = source[0..filesize :0];

    var data, const imports = try Data.loadSource(self.alloc, uri, null_terminated, is_root);
    try data.balanceTransactions();

    try self.files.append(data);

    try self.files_by_uri.put(uri.value, self.files.items.len - 1);

    return imports;
}

pub fn hasErrors(self: *Self) bool {
    for (self.files.items) |data| {
        if (data.errors.items.len > 0) return true;
    }
    if (self.errors.items.len > 0) return true;
    return false;
}

pub fn collectErrors(self: *const Self, alloc: Allocator) !std.StringHashMap(std.ArrayList(ErrorDetails)) {
    var errors = std.StringHashMap(std.ArrayList(ErrorDetails)).init(alloc);
    for (self.uris.items) |uri| {
        try errors.put(uri.value, std.ArrayList(ErrorDetails).init(alloc));
    }
    for (self.files.items) |data| {
        for (data.errors.items) |err| {
            try errors.getPtr(err.uri.value).?.append(err);
        }
    }
    for (self.errors.items) |err| {
        try errors.getPtr(err.uri.value).?.append(err);
    }
    return errors;
}

pub fn printErrors(self: *Self) !void {
    var num_errors: usize = 0;
    for (self.files.items) |data| {
        num_errors += data.errors.items.len;
    }
    num_errors += self.errors.items.len;
    if (num_errors == 0) return;

    std.debug.print("\x1b[31mError:\x1b[0m The following errors were encountered:\n\n", .{});

    var num_printed: usize = 0;
    for (self.files.items) |data| {
        for (data.errors.items) |err| {
            if (num_printed == 10) {
                std.debug.print("... and {d} more errors\n", .{num_errors - 10});
                return;
            }
            try err.print(self.alloc);
            num_printed += 1;
        }
    }
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

pub fn pipeline(self: *Self) !void {
    self.errors.clearRetainingCapacity();
    try self.sortEntries();
    // TODO: Perform all sorts of checks.
}

pub fn update_file(self: *Self, uri_value: []const u8, source: [:0]const u8) !void {
    const index = self.files_by_uri.get(uri_value) orelse return error.FileNotFound;
    const data = &self.files.items[index];

    const uri = self.uris.items[index];
    var new_data, _ = try Data.loadSource(self.alloc, uri, source, false);
    // TODO: Do something with imports
    try new_data.balanceTransactions();

    data.deinit();
    data.* = new_data;

    try self.pipeline();
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
