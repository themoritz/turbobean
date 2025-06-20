const std = @import("std");
const Allocator = std.mem.Allocator;
const Data = @import("data.zig");
const Tree = @import("tree.zig");
const Uri = @import("Uri.zig");
const ErrorDetails = @import("ErrorDetails.zig");
const Token = @import("lexer.zig").Lexer.Token;
const Inventory = @import("inventory.zig").Inventory;

const Self = @This();

alloc: Allocator,
files: std.ArrayList(Data),
uris: std.ArrayList(Uri),
/// Keys are URI values, values are index into files and uris.
files_by_uri: std.StringHashMap(usize),
sorted_entries: std.ArrayList(SortedEntry),
errors: std.ArrayList(ErrorDetails),

// LSP specific caches
accounts: std.StringHashMap(FileLine),
tags: std.StringHashMap(void),
links: std.StringHashMap(void),

const SortedEntry = struct {
    file: u8,
    entry: u32,
};

const FileLine = struct {
    file: u32,
    line: u32,
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

        .accounts = std.StringHashMap(FileLine).init(alloc),
        .tags = std.StringHashMap(void).init(alloc),
        .links = std.StringHashMap(void).init(alloc),
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

    self.accounts.deinit();
    self.tags.deinit();
    self.links.deinit();
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
    errdefer {
        var iter = errors.valueIterator();
        while (iter.next()) |v| v.deinit();
        errors.deinit();
    }
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
    var errors = try self.collectErrors(self.alloc);
    defer {
        var iter = errors.valueIterator();
        while (iter.next()) |v| v.deinit();
        errors.deinit();
    }

    var num_errors: usize = 0;
    {
        var iter = errors.valueIterator();
        while (iter.next()) |v| num_errors += v.*.items.len;
    }
    if (num_errors == 0) return;

    var num_printed: usize = 0;

    var iter = errors.valueIterator();
    while (iter.next()) |v| {
        for (v.items) |err| {
            if (num_printed == 10) {
                std.debug.print("... and {d} more errors\n", .{num_errors - 10});
                return;
            }
            try err.print(self.alloc, true);
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
    try self.checkAccountsOpen();
    // Can only post to currencies defined at open
    // Check balance assertions
    // Introduce txs for padding

    try self.refreshLspCache();
}

// Assumes sorted entries.
pub fn checkAccountsOpen(self: *Self) !void {
    var open_accounts = std.StringHashMap(void).init(self.alloc);
    defer open_accounts.deinit();

    for (self.sorted_entries.items) |sorted| {
        const entry = self.files.items[sorted.file].entries.items[sorted.entry];
        switch (entry.payload) {
            .open => |open| {
                try open_accounts.put(open.account.slice, {});
            },
            .close => |close| {
                const removed = open_accounts.remove(close.account.slice);
                if (!removed) {
                    try self.addError(close.account, sorted.file, ErrorDetails.Tag.account_not_open);
                }
            },
            .pad => |pad| {
                if (!open_accounts.contains(pad.account.slice)) {
                    try self.addError(pad.account, sorted.file, ErrorDetails.Tag.account_not_open);
                }
                if (!open_accounts.contains(pad.pad_to.slice)) {
                    try self.addError(pad.pad_to, sorted.file, ErrorDetails.Tag.account_not_open);
                }
            },
            .balance => |balance| {
                if (!open_accounts.contains(balance.account.slice)) {
                    try self.addError(balance.account, sorted.file, ErrorDetails.Tag.account_not_open);
                }
            },
            .transaction => |tx| {
                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        const account = self.files.items[sorted.file].postings.items(.account)[i];
                        if (!open_accounts.contains(account.slice)) {
                            try self.addError(account, sorted.file, ErrorDetails.Tag.account_not_open);
                        }
                    }
                }
            },
            .note => |note| {
                if (!open_accounts.contains(note.account.slice)) {
                    try self.addWarning(note.account, sorted.file, ErrorDetails.Tag.account_not_open);
                }
            },
            .document => |document| {
                if (!open_accounts.contains(document.account.slice)) {
                    try self.addWarning(document.account, sorted.file, ErrorDetails.Tag.account_not_open);
                }
            },
            else => {},
        }
    }
}

pub const AccountIterator = struct {
    self: *const Self,
    file: u32,
    file_max: u32, // exclusive
    entry: u32,
    posting: u32,
    pad_to: bool,

    pub fn init(self: *const Self, file: ?u32) AccountIterator {
        const file_max: u32 = if (file) |f| f + 1 else @intCast(self.files.items.len);
        return .{
            .self = self,
            .file = file orelse 0,
            .file_max = file_max,
            .entry = 0,
            .posting = 0,
            .pad_to = false,
        };
    }

    pub const Kind = enum { open, close, pad, pad_to, balance, posting, note, document };

    pub fn next(it: *AccountIterator) ?struct { file: u32, token: Token, kind: Kind } {
        const self = it.self;
        while (it.file < it.file_max) {
            const data = self.files.items[it.file];

            // Entries
            while (it.entry < data.entries.items.len) {
                const entry = data.entries.items[it.entry];
                switch (entry.payload) {
                    .open => |open| {
                        it.entry += 1;
                        return .{ .file = it.file, .token = open.account, .kind = .open };
                    },
                    .close => |close| {
                        it.entry += 1;
                        return .{ .file = it.file, .token = close.account, .kind = .close };
                    },
                    .pad => |pad| {
                        if (!it.pad_to) {
                            it.pad_to = true;
                            return .{ .file = it.file, .token = pad.account, .kind = .pad };
                        } else {
                            it.pad_to = false;
                            it.entry += 1;
                            return .{ .file = it.file, .token = pad.pad_to, .kind = .pad_to };
                        }
                    },
                    .balance => |balance| {
                        it.entry += 1;
                        return .{ .file = it.file, .token = balance.account, .kind = .balance };
                    },
                    .note => |note| {
                        it.entry += 1;
                        return .{ .file = it.file, .token = note.account, .kind = .note };
                    },
                    .document => |document| {
                        it.entry += 1;
                        return .{ .file = it.file, .token = document.account, .kind = .document };
                    },
                    else => {
                        it.entry += 1;
                    },
                }
            }

            // Postings
            while (it.posting < data.postings.len) {
                const token = data.postings.items(.account)[it.posting];
                it.posting += 1;
                return .{ .file = it.file, .token = token, .kind = .posting };
            }

            it.file += 1;
            it.entry = 0;
            it.posting = 0;
        }

        return null;
    }
};

pub fn accountIterator(self: *const Self, uri: ?[]const u8) AccountIterator {
    const file: ?u32 = if (uri) |u| if (self.files_by_uri.get(u)) |f| @intCast(f) else null else null;
    return AccountIterator.init(self, file);
}

fn refreshLspCache(self: *Self) !void {
    self.accounts.clearRetainingCapacity();
    self.tags.clearRetainingCapacity();
    self.links.clearRetainingCapacity();

    for (self.files.items, 0..) |data, f| {
        for (data.entries.items) |entry| {
            if (entry.tagslinks) |range| {
                for (range.start..range.end) |i| {
                    const slice = data.tagslinks.items(.slice)[i];
                    const kind = data.tagslinks.items(.kind)[i];
                    switch (kind) {
                        .tag => try self.tags.put(slice, {}),
                        .link => try self.links.put(slice, {}),
                    }
                }
            }
            switch (entry.payload) {
                .open => |open| {
                    try self.accounts.put(open.account.slice, .{
                        .file = @intCast(f),
                        .line = entry.main_token.line,
                    });
                },
                else => {},
            }
        }
    }
}

pub fn accountInventoryUntilLine(
    self: *Self,
    account: []const u8,
    uri: []const u8,
    line: u32,
) !?struct { before: Inventory, after: Inventory } {
    const file = self.files_by_uri.get(uri) orelse return null;
    var inv = Inventory.init(self.alloc);
    errdefer inv.deinit();
    for (self.sorted_entries.items) |sorted_entry| {
        const entry = self.files.items[sorted_entry.file].entries.items[sorted_entry.entry];
        switch (entry.payload) {
            .transaction => |tx| {
                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        const p = self.files.items[sorted_entry.file].postings;
                        const p_account = p.items(.account)[i];
                        if (std.mem.eql(u8, p_account.slice, account)) {
                            if (p_account.line == line and sorted_entry.file == file) {
                                var after = try inv.clone(self.alloc);
                                errdefer after.deinit();
                                try after.add(p.items(.amount)[i].number.?, p.items(.amount)[i].currency.?);
                                return .{ .before = inv, .after = after };
                            } else {
                                try inv.add(p.items(.amount)[i].number.?, p.items(.amount)[i].currency.?);
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

pub fn get_account_open_pos(self: *Self, account: []const u8) ?struct { Uri, u32 } {
    const entry = self.accounts.get(account) orelse return null;
    return .{ self.uris.items[entry.file], entry.line };
}

pub fn update_file(self: *Self, uri_value: []const u8, source: [:0]const u8) !void {
    const index = self.files_by_uri.get(uri_value) orelse return error.FileNotFound;
    const data = &self.files.items[index];

    const uri = self.uris.items[index];
    var new_data, const imports = try Data.loadSource(self.alloc, uri, source, false);
    defer self.alloc.free(imports);
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
                _ = tree.open(open.account.slice) catch |err| switch (err) {
                    error.AccountExists => {},
                    else => return err,
                };
            },
            .transaction => |tx| {
                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        try tree.addPosition(
                            data.postings.items(.account)[i].slice,
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

fn addErrorDetails(self: *Self, token: Token, file_id: u8, tag: ErrorDetails.Tag, severity: ErrorDetails.Severity) !void {
    const uri = self.uris.items[@intCast(file_id)];
    const source = self.files.items[file_id].source;
    try self.errors.append(ErrorDetails{
        .tag = tag,
        .severity = severity,
        .token = token,
        .uri = uri,
        .source = source,
        .expected = null,
    });
}

fn addWarning(self: *Self, token: Token, file_id: u8, tag: ErrorDetails.Tag) !void {
    try self.addErrorDetails(token, file_id, tag, .warn);
}

fn addError(self: *Self, token: Token, file_id: u8, tag: ErrorDetails.Tag) !void {
    try self.addErrorDetails(token, file_id, tag, .err);
}
