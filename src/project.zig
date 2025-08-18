const std = @import("std");
const Allocator = std.mem.Allocator;
const Data = @import("data.zig");
const Tree = @import("tree.zig");
const Uri = @import("Uri.zig");
const ErrorDetails = @import("ErrorDetails.zig");
const Token = @import("lexer.zig").Lexer.Token;
const Inventory = @import("inventory.zig").Inventory;
const InvSummary = @import("inventory.zig").Summary;
const Date = @import("date.zig").Date;

const Self = @This();

alloc: Allocator,
files: std.ArrayList(Data),
uris: std.ArrayList(Uri),
/// Keys are URI values, values are index into files and uris.
files_by_uri: std.StringHashMap(usize),
sorted_entries: std.ArrayList(SortedEntry),

synthetic_entries: std.ArrayList(Data.Entry),
synthetic_postings: std.MultiArrayList(Data.Posting),

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

        .synthetic_entries = std.ArrayList(Data.Entry).init(alloc),
        .synthetic_postings = .{},

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

    self.synthetic_entries.deinit();
    self.synthetic_postings.deinit(self.alloc);

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

    const null_terminated = try uri.load_nullterminated(self.alloc);

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

pub fn hasSevereErrors(self: *Self) bool {
    for (self.files.items) |data| {
        for (data.errors.items) |err| {
            if (err.severity == .err) return true;
        }
    }
    for (self.errors.items) |err| {
        if (err.severity == .err) return true;
    }
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

    try self.refreshLspCache();

    if (!self.hasSevereErrors()) {
        try self.check();
    }
}

pub fn check(self: *Self) !void {
    const LastPad = struct {
        date: Date,
        pad: Token,
        pad_to: Token,
        synthetic_index_ptr: *?usize,
    };

    // Padded account -> LastPad
    var lastPads: std.StringHashMap(LastPad) = std.StringHashMap(LastPad).init(self.alloc);
    defer lastPads.deinit();

    var tree = try Tree.init(self.alloc);
    defer tree.deinit();

    for (self.sorted_entries.items) |sorted| {
        const data = &self.files.items[sorted.file];
        var entry = &data.entries.items[sorted.entry];
        switch (entry.payload) {
            .open => |open| {
                const currencies = if (open.currencies) |c|
                    data.currencies.items[c.start..c.end]
                else
                    null;
                _ = try tree.open(open.account.slice, currencies, open.booking);
            },
            .close => |close| {
                tree.close(close.account.slice) catch |err| switch (err) {
                    error.AccountNotOpen => try self.addError(close.account, sorted.file, ErrorDetails.Tag.account_not_open),
                    else => return err,
                };
            },
            .pad => |*pad| {
                if (!tree.accountOpen(pad.account.slice)) {
                    try self.addError(pad.account, sorted.file, ErrorDetails.Tag.account_not_open);
                }
                if (!tree.accountOpen(pad.pad_to.slice)) {
                    try self.addError(pad.pad_to, sorted.file, ErrorDetails.Tag.account_not_open);
                }

                if (lastPads.get(pad.account.slice)) |_| {
                    try self.addError(entry.main_token, sorted.file, .multiple_pads);
                } else {
                    try lastPads.put(pad.account.slice, .{
                        .date = entry.date,
                        .pad = pad.account,
                        .pad_to = pad.pad_to,
                        .synthetic_index_ptr = &pad.synthetic_index,
                    });
                }
            },
            .balance => |balance| {
                var inv = tree.inventoryAggregatedByAccount(self.alloc, balance.account.slice) catch |err| switch (err) {
                    error.AccountDoesNotExist => {
                        try self.addError(balance.account, sorted.file, ErrorDetails.Tag.account_not_open);
                        continue;
                    },
                    else => return err,
                };
                defer inv.deinit();

                const number = inv.balance(balance.amount.currency.?);
                const missing = balance.amount.number.?.add(number.negate());
                if (lastPads.get(balance.account.slice)) |last_pad| {
                    // Build tx
                    const postings_top = self.synthetic_postings.len;

                    const pad_posting = Data.Posting{
                        .flag = null,
                        .account = balance.account,
                        .amount = .{
                            .number = missing,
                            .currency = balance.amount.currency,
                        },
                        .lot_spec = null,
                        .price = null,
                        .meta = null,
                    };
                    try self.synthetic_postings.append(self.alloc, pad_posting);
                    try self.postInventoryRecovering(&tree, entry.date, pad_posting, sorted.file);

                    const pad_to_posting = Data.Posting{
                        .flag = null,
                        .account = last_pad.pad_to,
                        .amount = .{
                            .number = missing.negate(),
                            .currency = balance.amount.currency,
                        },
                        .lot_spec = null,
                        .price = null,
                        .meta = null,
                    };
                    try self.synthetic_postings.append(self.alloc, pad_to_posting);
                    try self.postInventoryRecovering(&tree, entry.date, pad_to_posting, sorted.file);

                    const postings = Data.Range.create(postings_top, self.synthetic_postings.len);
                    const payload = Data.Entry.Payload{
                        .transaction = .{
                            .flag = .{
                                .slice = entry.main_token.slice,
                                .tag = .flag,
                                .line = 0,
                                .start_col = 0,
                                .end_col = 0,
                            },
                            .payee = null,
                            .narration = null,
                            .postings = postings,
                        },
                    };
                    const synthetic_entry = Data.Entry{
                        .date = last_pad.date,
                        .main_token = entry.main_token,
                        .payload = payload,
                        .tagslinks = null,
                        .meta = null,
                    };
                    const tx_index: u32 = @intCast(self.synthetic_entries.items.len);
                    try self.synthetic_entries.append(synthetic_entry);
                    last_pad.synthetic_index_ptr.* = tx_index;

                    // Remove last pad
                    _ = lastPads.remove(balance.account.slice);
                } else {
                    // Balance check in case of no padding
                    if (!missing.is_zero()) {
                        std.debug.print("Balance assertion failed: {any}\n", .{missing});
                        try self.addError(entry.main_token, sorted.file, .balance_assertion_failed);
                    }
                }
            },
            .transaction => |tx| {
                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        try self.postInventoryRecovering(
                            &tree,
                            entry.date,
                            data.postings.get(i),
                            sorted.file,
                        );
                    }
                }
            },
            .note => |note| {
                if (!tree.accountOpen(note.account.slice)) {
                    try self.addError(note.account, sorted.file, .account_not_open);
                }
            },
            .document => |document| {
                if (!tree.accountOpen(document.account.slice)) {
                    try self.addError(document.account, sorted.file, .account_not_open);
                }
            },
            else => {},
        }
    }
}

fn postInventoryRecovering(
    self: *Self,
    tree: *Tree,
    date: Date,
    posting: Data.Posting,
    file_id: u8,
) !void {
    tree.postInventory(date, posting) catch |err| switch (err) {
        error.DoesNotHoldCurrency => {
            try self.addError(posting.account, file_id, .account_does_not_hold_currency);
        },
        error.CannotAddToLotsInventory => {
            try self.addError(posting.account, file_id, .account_is_booked);
        },
        error.CannotBookToPlainInventory => {
            try self.addError(posting.account, file_id, .account_is_not_booked);
        },
        error.AccountNotOpen => {
            try self.addError(posting.account, file_id, .account_not_open);
        },
        error.CostCurrencyDoesNotMatch => {
            try self.addError(posting.account, file_id, .cost_currency_does_not_match);
        },
        error.LotSpecAmbiguousMatch => {
            try self.addError(posting.account, file_id, .lot_spec_ambiguous_match);
        },
        error.LotSpecMatchTooSmall => {
            try self.addError(posting.account, file_id, .lot_spec_match_too_small);
        },
        error.LotSpecNoMatch => {
            try self.addError(posting.account, file_id, .lot_spec_no_match);
        },
        error.AmbiguousStrictBooking => {
            try self.addError(posting.account, file_id, .ambiguous_strict_booking);
        },
        else => return err,
    };
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

    pub const Kind = enum {
        open,
        close,
        pad,
        pad_to,
        balance,
        posting,
        note,
        document,
    };

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

/// Assumes checkAccountsOpen has been called.
pub fn accountInventoryUntilLine(
    self: *Self,
    account: []const u8,
    uri: []const u8,
    line: u32,
) !?struct { before: InvSummary, after: InvSummary } {
    const file = self.files_by_uri.get(uri) orelse return null;

    var tree = try Tree.init(self.alloc);
    defer tree.deinit();

    for (self.sorted_entries.items) |sorted_entry| {
        const data = self.files.items[sorted_entry.file];
        const entry = data.entries.items[sorted_entry.entry];
        switch (entry.payload) {
            .open => |open| {
                if (std.mem.eql(u8, open.account.slice, account)) {
                    const currencies = if (open.currencies) |c|
                        self.files.items[sorted_entry.file].currencies.items[c.start..c.end]
                    else
                        null;
                    _ = try tree.open(open.account.slice, currencies, open.booking);
                }
            },
            .transaction => |tx| {
                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        const posting = data.postings.get(i);
                        if (std.mem.eql(u8, posting.account.slice, account)) {
                            if (posting.account.line == line and sorted_entry.file == file) {
                                var before = try tree.inventoryAggregatedByAccount(self.alloc, account);
                                errdefer before.deinit();
                                try tree.postInventory(entry.date, posting);
                                var after = try tree.inventoryAggregatedByAccount(self.alloc, account);
                                errdefer after.deinit();
                                return .{ .before = before, .after = after };
                            } else {
                                try tree.postInventory(entry.date, posting);
                            }
                        }
                    }
                }
            },
            .pad => |pad| {
                const index = pad.synthetic_index.?;
                const synthetic_entry = self.synthetic_entries.items[index];
                const tx = synthetic_entry.payload.transaction;
                const postings = tx.postings.?;
                std.debug.assert(postings.end - postings.start == 2);
                if (std.mem.eql(u8, pad.account.slice, account)) {
                    const posting = self.synthetic_postings.get(postings.start);
                    if (pad.account.line == line and sorted_entry.file == file) {
                        var before = try tree.inventoryAggregatedByAccount(self.alloc, account);
                        errdefer before.deinit();
                        try tree.postInventory(entry.date, posting);
                        var after = try tree.inventoryAggregatedByAccount(self.alloc, account);
                        errdefer after.deinit();
                        return .{ .before = before, .after = after };
                    } else {
                        try tree.postInventory(entry.date, posting);
                    }
                }
                if (std.mem.eql(u8, pad.pad_to.slice, account)) {
                    const posting = self.synthetic_postings.get(postings.end - 1);
                    if (pad.pad_to.line == line and sorted_entry.file == file) {
                        var before = try tree.inventoryAggregatedByAccount(self.alloc, account);
                        errdefer before.deinit();
                        try tree.postInventory(entry.date, posting);
                        var after = try tree.inventoryAggregatedByAccount(self.alloc, account);
                        errdefer after.deinit();
                        return .{ .before = before, .after = after };
                    } else {
                        try tree.postInventory(entry.date, posting);
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

/// Takes ownership of source.
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

// Assumes balanced transactions and checks passed
pub fn printTree(self: *Self) !void {
    var tree = try Tree.init(self.alloc);
    defer tree.deinit();

    for (self.sorted_entries.items) |sorted_entry| {
        const data = self.files.items[sorted_entry.file];
        const entry = data.entries.items[sorted_entry.entry];
        switch (entry.payload) {
            .open => |open| {
                const currencies = if (open.currencies) |c|
                    self.files.items[sorted_entry.file].currencies.items[c.start..c.end]
                else
                    null;
                _ = try tree.open(open.account.slice, currencies, open.booking);
            },
            .transaction => |tx| {
                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        try tree.postInventory(entry.date, data.postings.get(i));
                    }
                }
            },
            .pad => |pad| {
                const index = pad.synthetic_index.?;
                const synthetic_entry = self.synthetic_entries.items[index];
                const tx = synthetic_entry.payload.transaction;
                const postings = tx.postings.?;
                for (postings.start..postings.end) |i| {
                    try tree.postInventory(entry.date, self.synthetic_postings.get(i));
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
