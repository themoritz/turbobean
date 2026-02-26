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
const ztracy = @import("ztracy");

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

/// Load a project from a root file URI.
///
/// If `source` is provided, uses that as the source text of the root
/// project file, otherwise loads from file.
pub fn load(alloc: Allocator, uri: Uri, source: ?[:0]const u8) !Self {
    const tracy_zone = ztracy.ZoneNC(@src(), "Load project", 0x00_00_ff_00);
    defer tracy_zone.End();

    var self = Self{
        .alloc = alloc,
        .files = .{},
        .uris = .{},
        .files_by_uri = std.StringHashMap(usize).init(alloc),
        .sorted_entries = .{},

        .errors = .{},

        .accounts = std.StringHashMap(FileLine).init(alloc),
        .tags = std.StringHashMap(void).init(alloc),
        .links = std.StringHashMap(void).init(alloc),
    };
    errdefer self.deinit();
    try self.loadFileRec(uri, true, source);

    // Collect number of bytes, tokens, entries and postings
    // var chars: usize = 0;
    // var tokens: usize = 0;
    // var entries: usize = 0;
    // var postings: usize = 0;
    // for (self.files.items) |*data| {
    //     chars += data.source.len;
    //     tokens += data.tokens.items.len;
    //     entries += data.entries.items.len;
    //     postings += data.postings.len;
    // }
    //
    // std.log.debug(
    //     "Loaded {d} files, {d} bytes, {d} tokens, {d} entries, {d} postings",
    //     .{ self.files.items.len, chars, tokens, entries, postings },
    // );

    try self.pipeline();
    return self;
}

pub fn deinit(self: *Self) void {
    for (self.files.items) |*data| data.deinit();
    self.files.deinit(self.alloc);

    for (self.uris.items) |*uri| uri.deinit(self.alloc);
    self.uris.deinit(self.alloc);

    self.files_by_uri.deinit();

    self.sorted_entries.deinit(self.alloc);

    self.errors.deinit(self.alloc);

    self.accounts.deinit();
    self.tags.deinit();
    self.links.deinit();
}

/// Is the provided file_uri included in this project?
pub fn ownsFile(self: *const Self, file_uri: []const u8) bool {
    return self.files_by_uri.contains(file_uri);
}

/// Is the provided file_uri the root file of this project?
pub fn hasRoot(self: *const Self, file_uri: []const u8) bool {
    return std.mem.eql(u8, self.uris.items[0].value, file_uri);
}

fn loadFileRec(self: *Self, uri: Uri, is_root: bool, source: ?[:0]const u8) !void {
    if (self.files_by_uri.get(uri.value)) |_| return error.ImportCycle;
    const file_id, const imports = try self.loadSingleFile(uri, is_root, source);
    defer self.alloc.free(imports);
    for (imports) |import| {
        var import_uri = try uri.move_relative(self.alloc, import.path);
        defer import_uri.deinit(self.alloc);
        // Check if the file exists before recursing
        std.fs.accessAbsolute(import_uri.absolute(), .{}) catch {
            const data = &self.files.items[file_id];
            try data.errors.append(self.alloc, .{
                .tag = .include_file_not_found,
                .token = import.token,
                .uri = self.uris.items[file_id],
                .source = data.source,
            });
            continue;
        };
        try self.loadFileRec(import_uri, false, null);
    }
}

/// Parses a file and balances all transactions.
fn loadSingleFile(self: *Self, uri: Uri, is_root: bool, source: ?[:0]const u8) !struct { usize, Data.Imports.Slice } {
    const uri_owned = try uri.clone(self.alloc);
    try self.uris.append(self.alloc, uri_owned);

    const null_terminated = source orelse try uri_owned.load_nullterminated(self.alloc);

    var data, const imports = try Data.loadSource(self.alloc, uri_owned, null_terminated, is_root);
    errdefer data.deinit();
    errdefer self.alloc.free(imports);

    try data.balanceTransactions();

    try self.files.append(self.alloc, data);

    const file_id = self.files.items.len - 1;
    try self.files_by_uri.put(uri_owned.value, file_id);

    return .{ file_id, imports };
}

pub fn getConfig(self: *const Self) *Data.Config {
    // Config is always the first file since it's the entry point for loading
    // a project.
    return &self.files.items[0].config;
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
        while (iter.next()) |v| v.deinit(alloc);
        errors.deinit();
    }
    for (self.uris.items) |uri| {
        try errors.put(uri.value, std.ArrayList(ErrorDetails){});
    }
    for (self.files.items) |data| {
        for (data.errors.items) |err| {
            try errors.getPtr(err.uri.value).?.append(alloc, err);
        }
    }
    for (self.errors.items) |err| {
        try errors.getPtr(err.uri.value).?.append(alloc, err);
    }
    return errors;
}

pub fn printErrors(self: *Self) !void {
    var errors = try self.collectErrors(self.alloc);
    defer {
        var iter = errors.valueIterator();
        while (iter.next()) |v| v.deinit(self.alloc);
        errors.deinit();
    }

    if (errors.count() == 0) return;

    // Separate errors and warnings
    var error_list = std.ArrayList(ErrorDetails){};
    defer error_list.deinit(self.alloc);
    var warning_list = std.ArrayList(ErrorDetails){};
    defer warning_list.deinit(self.alloc);

    {
        var iter = errors.valueIterator();
        while (iter.next()) |v| {
            for (v.items) |err| {
                if (err.severity == .err) {
                    try error_list.append(self.alloc, err);
                } else {
                    try warning_list.append(self.alloc, err);
                }
            }
        }
    }

    const num_errors = error_list.items.len;
    const num_warnings = warning_list.items.len;

    var num_printed: usize = 0;

    // Print errors first
    for (error_list.items) |err| {
        if (num_printed == 10) {
            const remaining_errors = num_errors - num_printed;
            const remaining_warnings = num_warnings;
            std.debug.print("... and {d} errors and {d} warnings more\n", .{ remaining_errors, remaining_warnings });
            return;
        }
        try err.print(self.alloc);
        num_printed += 1;
    }

    // Then print warnings
    for (warning_list.items) |warn| {
        if (num_printed == 10) {
            const remaining_warnings = num_warnings - (num_printed - num_errors);
            std.debug.print("... and {d} errors and {d} warnings more\n", .{ 0, remaining_warnings });
            return;
        }
        try warn.print(self.alloc);
        num_printed += 1;
    }
}

pub fn sortEntries(self: *Self) !void {
    self.sorted_entries.clearRetainingCapacity();
    for (self.files.items, 0..) |data, f| {
        for (0..data.entries.items.len) |e| {
            try self.sorted_entries.append(self.alloc, SortedEntry{
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
    try self.check();
}

pub fn check(self: *Self) !void {
    const LastPad = struct {
        date: Date,
        pad: Token,
        pad_to: Token,
        pad_ptr: *Data.Pad,
    };

    // Padded account -> LastPad
    var lastPads: std.StringHashMap(LastPad) = std.StringHashMap(LastPad).init(self.alloc);
    defer lastPads.deinit();

    // pnl directive: lot-based account -> income account token
    var pnlAccounts: std.StringHashMap(Token) = std.StringHashMap(Token).init(self.alloc);
    defer pnlAccounts.deinit();

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
                if (try tree.open(open.account.slice, currencies, open.booking_method) == null) {
                    try self.addError(open.account, sorted.file, ErrorDetails.Tag.account_already_open);
                }
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
                    continue;
                }
                if (!tree.accountOpen(pad.pad_to.slice)) {
                    try self.addError(pad.pad_to, sorted.file, ErrorDetails.Tag.account_not_open);
                    continue;
                }
                if (!(tree.isPlainAccount(pad.pad_to.slice) catch unreachable)) {
                    try self.addError(pad.pad_to, sorted.file, ErrorDetails.Tag.pad_accounts_must_be_plain);
                    continue;
                }
                if (!(tree.isPlainAccount(pad.account.slice) catch unreachable)) {
                    try self.addError(pad.account, sorted.file, ErrorDetails.Tag.pad_accounts_must_be_plain);
                    continue;
                }

                if (lastPads.get(pad.account.slice)) |_| {
                    try self.addError(entry.main_token, sorted.file, .multiple_pads);
                } else {
                    try lastPads.put(pad.account.slice, .{
                        .date = entry.date,
                        .pad = pad.account,
                        .pad_to = pad.pad_to,
                        .pad_ptr = pad,
                    });
                }
            },
            .balance => |balance| {
                const accumulated = tree.balanceAggregatedByAccount(balance.account.slice, balance.amount.currency.?) catch |err| switch (err) {
                    error.AccountNotOpen => {
                        try self.addError(balance.account, sorted.file, ErrorDetails.Tag.account_not_open);
                        continue;
                    },
                    error.DoesNotHoldCurrency => {
                        try self.addError(balance.account, sorted.file, ErrorDetails.Tag.account_does_not_hold_currency);
                        continue;
                    },
                    else => return err,
                };

                const expected = balance.amount.number.?;
                if (lastPads.get(balance.account.slice)) |last_pad| {
                    const missing = expected.add(accumulated.negate());

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
                    try tree.addPosition(pad_posting.account.slice, pad_posting.amount.currency.?, pad_posting.amount.number.?);
                    last_pad.pad_ptr.pad_posting = pad_posting;

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
                    try tree.addPosition(pad_to_posting.account.slice, pad_to_posting.amount.currency.?, pad_to_posting.amount.number.?);
                    last_pad.pad_ptr.pad_to_posting = pad_to_posting;

                    // Remove last pad
                    _ = lastPads.remove(balance.account.slice);
                } else {
                    // Balance check in case of no padding
                    const tolerance = if (balance.tolerance) |t| t else balance.amount.number.?.getTolerance();
                    if (!expected.is_within_tolerance(accumulated, tolerance)) {
                        try self.addError(entry.main_token, sorted.file, .{ .balance_assertion_failed = .{
                            .expected = expected,
                            .accumulated = accumulated,
                        } });
                    }
                }
            },
            .pnl => |pnl| {
                if (!tree.accountOpen(pnl.account.slice)) {
                    try self.addError(pnl.account, sorted.file, .account_not_open);
                    continue;
                }
                if (!tree.accountOpen(pnl.income_account.slice)) {
                    try self.addError(pnl.income_account, sorted.file, .account_not_open);
                    continue;
                }
                if (tree.isPlainAccount(pnl.account.slice) catch unreachable) {
                    try self.addError(pnl.account, sorted.file, .pnl_account_must_be_lots);
                    continue;
                }
                try pnlAccounts.put(pnl.account.slice, pnl.income_account);
            },
            .transaction => |*tx| {
                if (tx.dirty) continue;

                if (tx.postings) |postings| {
                    var pnl_start: usize = 0;
                    var has_pnl = false;
                    for (postings.start..postings.end) |i| {
                        const posting = data.postings.get(i);
                        const post_result = try self.postInventoryRecovering(
                            &tree,
                            entry.date,
                            posting,
                            sorted.file,
                            tx,
                        );
                        if (post_result) |pr| {
                            if (pnlAccounts.get(posting.account.slice)) |income_token| {
                                if (posting.price) |price| {
                                    const sale_weight = if (price.total)
                                        price.amount.number.?
                                    else
                                        posting.amount.number.?.mul(price.amount.number.?);
                                    const pnl = sale_weight.sub(pr.cost_weight);
                                    if (!pnl.is_zero()) {
                                        if (!has_pnl) {
                                            pnl_start = data.postings.len;
                                            for (postings.start..postings.end) |j| {
                                                try data.postings.append(self.alloc, data.postings.get(j));
                                            }
                                            has_pnl = true;
                                        }
                                        const pnl_posting = Data.Posting{
                                            .flag = null,
                                            .account = income_token,
                                            .amount = .{
                                                .number = pnl,
                                                .currency = pr.cost_currency,
                                            },
                                            .lot_spec = null,
                                            .price = null,
                                            .meta = null,
                                        };
                                        try data.postings.append(self.alloc, pnl_posting);
                                        try tree.addPosition(income_token.slice, pr.cost_currency, pnl);
                                    }
                                }
                            }
                        }
                    }
                    if (has_pnl) {
                        tx.postings = .{ .start = pnl_start, .end = data.postings.len };
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
    tx: *Data.Transaction,
) !?Tree.PostResult {
    return tree.postInventory(date, posting) catch |err| {
        tx.dirty = true;
        switch (err) {
            error.DoesNotHoldCurrency => {
                try self.addError(posting.account, file_id, .account_does_not_hold_currency);
            },
            error.CannotAddToLotsInventory => {
                try self.addError(posting.account, file_id, .account_is_booked);
            },
            error.PlainInventoryDoesNotSupportLotSpec => {
                try self.addError(posting.account, file_id, .account_does_not_support_lot_spec);
            },
            error.AccountNotOpen => {
                try self.addError(posting.account, file_id, .account_not_open);
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
            error.CostCurrencyMismatch => {
                try self.addError(posting.account, file_id, .cost_currency_mismatch);
            },
            else => return err,
        }
        return null;
    };
}

pub const AccountIterator = struct {
    self: *const Self,
    file: u32,
    file_max: u32, // exclusive
    entry: u32,
    posting: u32,
    pad_to: bool,
    pnl_income: bool,

    pub fn init(self: *const Self, file: ?u32) AccountIterator {
        const file_max: u32 = if (file) |f| f + 1 else @intCast(self.files.items.len);
        return .{
            .self = self,
            .file = file orelse 0,
            .file_max = file_max,
            .entry = 0,
            .posting = 0,
            .pad_to = false,
            .pnl_income = false,
        };
    }

    pub const Kind = enum {
        open,
        close,
        pad,
        pad_to,
        pnl,
        pnl_income,
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
                    .pnl => |pnl| {
                        if (!it.pnl_income) {
                            it.pnl_income = true;
                            return .{ .file = it.file, .token = pnl.account, .kind = .pnl_income };
                        } else {
                            it.pnl_income = false;
                            it.entry += 1;
                            return .{ .file = it.file, .token = pnl.income_account, .kind = .pnl_income };
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

pub const TagLinkIterator = struct {
    self: *const Self,
    file: u32,
    file_max: u32, // exclusive
    entry: u32,
    taglink_idx: u32,

    pub fn init(self: *const Self, file: ?u32) TagLinkIterator {
        const file_max: u32 = if (file) |f| f + 1 else @intCast(self.files.items.len);
        return .{
            .self = self,
            .file = file orelse 0,
            .file_max = file_max,
            .entry = 0,
            .taglink_idx = 0,
        };
    }

    pub fn next(it: *TagLinkIterator) ?struct { file: u32, token: Token } {
        const self = it.self;
        while (it.file < it.file_max) {
            const data = self.files.items[it.file];

            while (it.entry < data.entries.items.len) {
                const entry = data.entries.items[it.entry];
                if (entry.tagslinks) |range| {
                    while (it.taglink_idx < range.end) {
                        const idx = it.taglink_idx;
                        it.taglink_idx += 1;

                        const taglink_token = data.tagslinks.items(.token)[idx];
                        const taglink_explicit = data.tagslinks.items(.explicit)[idx];

                        // Only return explicit tags/links (filter out pushtag-derived ones)
                        if (taglink_explicit) {
                            return .{
                                .file = it.file,
                                .token = taglink_token,
                            };
                        }
                    }
                }

                it.entry += 1;
                it.taglink_idx = if (it.entry < data.entries.items.len)
                    if (data.entries.items[it.entry].tagslinks) |range| @intCast(range.start) else 0
                else
                    0;
            }

            it.file += 1;
            it.entry = 0;
            it.taglink_idx = 0;
        }

        return null;
    }
};

pub fn tagLinkIterator(self: *const Self, uri: ?[]const u8) TagLinkIterator {
    const file: ?u32 = if (uri) |u| if (self.files_by_uri.get(u)) |f| @intCast(f) else null else null;
    return TagLinkIterator.init(self, file);
}

fn refreshLspCache(self: *Self) !void {
    self.accounts.clearRetainingCapacity();
    self.tags.clearRetainingCapacity();
    self.links.clearRetainingCapacity();

    for (self.files.items, 0..) |data, f| {
        for (data.entries.items) |entry| {
            if (entry.tagslinks) |range| {
                for (range.start..range.end) |i| {
                    const token = data.tagslinks.items(.token)[i];
                    const kind = data.tagslinks.items(.kind)[i];
                    switch (kind) {
                        .tag => try self.tags.put(token.slice, {}),
                        .link => try self.links.put(token.slice, {}),
                    }
                }
            }
            switch (entry.payload) {
                .open => |open| {
                    try self.accounts.put(open.account.slice, .{
                        .file = @intCast(f),
                        .line = entry.main_token.start_line,
                    });
                },
                else => {},
            }
        }
    }
}

/// Assumes checkAccountsOpen has been called.
pub fn accountInventoryUntilLine(
    self: *const Self,
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
                    _ = try tree.open(open.account.slice, currencies, open.booking_method);
                }
            },
            .transaction => |tx| {
                if (tx.dirty) continue;

                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        const posting = data.postings.get(i);
                        if (std.mem.eql(u8, posting.account.slice, account)) {
                            if (posting.account.start_line == line and sorted_entry.file == file) {
                                var before = try tree.inventoryAggregatedByAccount(self.alloc, account);
                                errdefer before.deinit();
                                _ = try tree.postInventory(entry.date, posting);
                                var after = try tree.inventoryAggregatedByAccount(self.alloc, account);
                                errdefer after.deinit();
                                return .{ .before = before, .after = after };
                            } else {
                                _ = try tree.postInventory(entry.date, posting);
                            }
                        }
                    }
                }
            },
            .pad => |pad| {
                if (pad.pad_posting) |posting| {
                    if (std.mem.eql(u8, pad.account.slice, account)) {
                        if (pad.account.start_line == line and sorted_entry.file == file) {
                            var before = try tree.inventoryAggregatedByAccount(self.alloc, account);
                            errdefer before.deinit();
                            _ = try tree.postInventory(entry.date, posting);
                            var after = try tree.inventoryAggregatedByAccount(self.alloc, account);
                            errdefer after.deinit();
                            return .{ .before = before, .after = after };
                        } else {
                            _ = try tree.postInventory(entry.date, posting);
                        }
                    }
                }
                if (pad.pad_to_posting) |posting| {
                    if (std.mem.eql(u8, pad.pad_to.slice, account)) {
                        if (pad.pad_to.start_line == line and sorted_entry.file == file) {
                            var before = try tree.inventoryAggregatedByAccount(self.alloc, account);
                            errdefer before.deinit();
                            _ = try tree.postInventory(entry.date, posting);
                            var after = try tree.inventoryAggregatedByAccount(self.alloc, account);
                            errdefer after.deinit();
                            return .{ .before = before, .after = after };
                        } else {
                            _ = try tree.postInventory(entry.date, posting);
                        }
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

pub fn get_account_open_pos(self: *const Self, account: []const u8) ?struct { Uri, u32 } {
    const entry = self.accounts.get(account) orelse return null;
    return .{ self.uris.items[entry.file], entry.line };
}

/// Takes ownership of source.
pub fn update_file(self: *Self, uri_value: []const u8, source: [:0]const u8) !void {
    const index = self.files_by_uri.get(uri_value) orelse return error.FileNotFound;
    const data = &self.files.items[index];

    const is_root = index == 0;

    const uri = self.uris.items[index];
    var new_data, const imports = try Data.loadSource(self.alloc, uri, source, is_root);
    defer self.alloc.free(imports);
    // TODO: Do something with imports
    try new_data.balanceTransactions();

    data.deinit();
    data.* = new_data;

    try self.pipeline();
}

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
                _ = try tree.open(open.account.slice, currencies, open.booking_method);
            },
            .transaction => |tx| {
                if (tx.dirty) continue;

                if (tx.postings) |postings| {
                    for (postings.start..postings.end) |i| {
                        _ = try tree.postInventory(entry.date, data.postings.get(i));
                    }
                }
            },
            .pad => |pad| {
                if (pad.pad_posting) |p| _ = try tree.postInventory(entry.date, p);
                if (pad.pad_to_posting) |p| _ = try tree.postInventory(entry.date, p);
            },
            else => {},
        }
    }

    try tree.print();
}

fn addErrorDetails(self: *Self, token: Token, file_id: u8, tag: ErrorDetails.Tag, severity: ErrorDetails.Severity) !void {
    const uri = self.uris.items[@intCast(file_id)];
    const source = self.files.items[file_id].source;
    try self.errors.append(self.alloc, ErrorDetails{
        .tag = tag,
        .severity = severity,
        .token = token,
        .uri = uri,
        .source = source,
    });
}

fn addWarning(self: *Self, token: Token, file_id: u8, tag: ErrorDetails.Tag) !void {
    try self.addErrorDetails(token, file_id, tag, .warn);
}

fn addError(self: *Self, token: Token, file_id: u8, tag: ErrorDetails.Tag) !void {
    try self.addErrorDetails(token, file_id, tag, .err);
}
