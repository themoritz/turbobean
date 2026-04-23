const std = @import("std");
const Allocator = std.mem.Allocator;
const Data = @import("data.zig");
const Tree = @import("tree.zig");
const Uri = @import("Uri.zig");
const ErrorDetails = @import("ErrorDetails.zig");
const Ast = @import("Ast.zig");
const Token = @import("lexer.zig").Lexer.Token;
const Inventory = @import("inventory.zig").Inventory;
const InvSummary = @import("inventory.zig").Summary;
const Date = @import("date.zig").Date;
const Number = @import("number.zig").Number;
const StringPool = @import("StringPool.zig");
const pool_maps = @import("pool_maps.zig");
const AccountIndex = Data.AccountIndex;
const CurrencyIndex = Data.CurrencyIndex;
const ztracy = @import("ztracy");

const Self = @This();

alloc: Allocator,
/// Project-wide intern pools, shared by every `Data` and by `Tree`.
/// Interned account/currency indices are therefore comparable across files.
///
/// Heap-allocated so their addresses stay stable — `Data` caches pool
/// pointers at construction time, and `Project` itself gets moved (returned
/// by value from `load`, appended into `ArrayList(Project)` in the LSP) in
/// ways that would invalidate pointers to inline fields.
accounts: *StringPool,
currencies: *StringPool,
files: std.ArrayList(Data),
uris: std.ArrayList(Uri),
/// Keys are URI values, values are index into files and uris.
files_by_uri: std.StringHashMap(usize),
sorted_entries: std.ArrayList(SortedEntry),

errors: std.ArrayList(ErrorDetails),

/// Dense lookup `AccountIndex → FileLine` for opened accounts. Missing for
/// indices that were interned (e.g., via posting text) but not explicitly
/// opened.
account_open_pos: pool_maps.AccountMap(FileLine),
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

    const accounts = try alloc.create(StringPool);
    errdefer alloc.destroy(accounts);
    accounts.* = try StringPool.init(alloc);
    errdefer accounts.deinit(alloc);

    const currencies = try alloc.create(StringPool);
    errdefer alloc.destroy(currencies);
    currencies.* = try StringPool.init(alloc);
    errdefer currencies.deinit(alloc);

    var self = Self{
        .alloc = alloc,
        .accounts = accounts,
        .currencies = currencies,
        .files = .{},
        .uris = .{},
        .files_by_uri = std.StringHashMap(usize).init(alloc),
        .sorted_entries = .{},

        .errors = .{},

        .account_open_pos = .{},
        .tags = std.StringHashMap(void).init(alloc),
        .links = std.StringHashMap(void).init(alloc),
    };
    errdefer self.deinit();
    try self.loadFileRec(uri, true, source);

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

    self.account_open_pos.deinit(self.alloc);
    self.tags.deinit();
    self.links.deinit();

    self.accounts.deinit(self.alloc);
    self.currencies.deinit(self.alloc);
    self.alloc.destroy(self.accounts);
    self.alloc.destroy(self.currencies);
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
fn loadSingleFile(self: *Self, uri: Uri, is_root: bool, source: ?[:0]const u8) !struct { usize, Data.Imports } {
    const uri_owned = try uri.clone(self.alloc);
    try self.uris.append(self.alloc, uri_owned);

    const null_terminated = source orelse try uri_owned.load_nullterminated(self.alloc);

    var data, const imports = try Data.loadSource(
        self.alloc,
        self.accounts,
        self.currencies,
        uri_owned,
        null_terminated,
        is_root,
    );
    errdefer data.deinit();
    errdefer self.alloc.free(imports);

    try data.balanceTransactions();

    try self.files.append(self.alloc, data);

    const file_id = self.files.items.len - 1;
    try self.files_by_uri.put(uri_owned.value, file_id);

    return .{ file_id, imports };
}

pub fn getConfig(self: *const Self) *Data.Config {
    return &self.files.items[0].config;
}

/// Look up a currency text in the shared pool without adding it. Handy for
/// translating URL params and other user-supplied strings.
pub fn findCurrency(self: *const Self, text: []const u8) ?CurrencyIndex {
    const raw = self.currencies.find(text) orelse return null;
    return @enumFromInt(@intFromEnum(raw));
}

pub fn findAccount(self: *const Self, text: []const u8) ?AccountIndex {
    const raw = self.accounts.find(text) orelse return null;
    return @enumFromInt(@intFromEnum(raw));
}

/// Intern `text` into the project's account pool, adding it if needed.
pub fn internAccount(self: *Self, text: []const u8) !AccountIndex {
    const raw = try self.accounts.intern(self.alloc, text);
    return @enumFromInt(@intFromEnum(raw));
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
        for (0..data.entries.len) |e| {
            try self.sorted_entries.append(self.alloc, SortedEntry{
                .file = @intCast(f),
                .entry = @intCast(e),
            });
        }
    }
    std.sort.block(SortedEntry, self.sorted_entries.items, self, lessThanFn);
}

fn lessThanFn(self: *Self, lhs: SortedEntry, rhs: SortedEntry) bool {
    const entry_lhs = self.files.items[lhs.file].entries.get(lhs.entry);
    const entry_rhs = self.files.items[rhs.file].entries.get(rhs.entry);
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
        pad_account_token: Ast.TokenIndex,
        pad_to_token: Ast.TokenIndex,
        pad_ptr: *Data.Pad,
        file: u8,
    };

    var lastPads: std.AutoHashMap(AccountIndex, LastPad) = .init(self.alloc);
    defer lastPads.deinit();

    const PnlEntry = struct {
        income_token: Ast.TokenIndex,
        file: u8,
    };
    var pnlAccounts: std.AutoHashMap(AccountIndex, PnlEntry) = .init(self.alloc);
    defer pnlAccounts.deinit();

    var tree = try Tree.init(self.alloc, self.accounts, self.currencies);
    defer tree.deinit();

    for (self.sorted_entries.items) |sorted| {
        const data = &self.files.items[sorted.file];
        const entry = data.entryAt(sorted.entry);
        switch (entry.payload()) {
            .open => |open| {
                const acc_idx = data.accountOf(open.open.account);
                var cur_list = std.ArrayList(CurrencyIndex){};
                defer cur_list.deinit(self.alloc);
                var cit = open.currencies();
                while (cit.next()) |c| try cur_list.append(self.alloc, c);
                const cur_slice: ?[]const CurrencyIndex = if (cur_list.items.len == 0) null else cur_list.items;
                if (try tree.open(acc_idx, cur_slice, open.open.booking_method) == null) {
                    try self.addError(open.open.account, sorted.file, ErrorDetails.Tag.account_already_open);
                }
            },
            .close => |close| {
                const acc_idx = data.accountOf(close.account);
                tree.close(acc_idx) catch |err| switch (err) {
                    error.AccountNotOpen => try self.addError(close.account, sorted.file, ErrorDetails.Tag.account_not_open),
                    else => return err,
                };
            },
            .pad => |pad| {
                const acc_idx = data.accountOf(pad.account);
                const pad_to_idx = data.accountOf(pad.pad_to);
                if (!tree.accountOpen(acc_idx)) {
                    try self.addError(pad.account, sorted.file, ErrorDetails.Tag.account_not_open);
                    continue;
                }
                if (!tree.accountOpen(pad_to_idx)) {
                    try self.addError(pad.pad_to, sorted.file, ErrorDetails.Tag.account_not_open);
                    continue;
                }
                if (!(tree.isPlainAccount(pad_to_idx) catch unreachable)) {
                    try self.addError(pad.pad_to, sorted.file, ErrorDetails.Tag.pad_accounts_must_be_plain);
                    continue;
                }
                if (!(tree.isPlainAccount(acc_idx) catch unreachable)) {
                    try self.addError(pad.account, sorted.file, ErrorDetails.Tag.pad_accounts_must_be_plain);
                    continue;
                }

                if (lastPads.get(acc_idx)) |_| {
                    try self.addError(entry.mainToken(), sorted.file, .multiple_pads);
                } else {
                    const pad_ptr: *Data.Pad = &data.entries.items(.payload)[sorted.entry].pad;
                    try lastPads.put(acc_idx, .{
                        .date = entry.date(),
                        .pad_account_token = pad.account,
                        .pad_to_token = pad.pad_to,
                        .pad_ptr = pad_ptr,
                        .file = sorted.file,
                    });
                }
            },
            .balance => |balance| {
                const acc_idx = balance.account;
                const cur_idx = balance.amount_currency.unwrap() orelse {
                    try self.addError(balance.account_token, sorted.file, ErrorDetails.Tag.account_does_not_hold_currency);
                    continue;
                };
                const accumulated = tree.balanceAggregatedByAccount(acc_idx, cur_idx) catch |err| switch (err) {
                    error.AccountNotOpen => {
                        try self.addError(balance.account_token, sorted.file, ErrorDetails.Tag.account_not_open);
                        continue;
                    },
                    error.DoesNotHoldCurrency => {
                        try self.addError(balance.account_token, sorted.file, ErrorDetails.Tag.account_does_not_hold_currency);
                        continue;
                    },
                    else => return err,
                };

                const expected = balance.amount;
                if (lastPads.get(acc_idx)) |last_pad| {
                    const missing = expected.add(accumulated.negate());

                    const pad_posting = Data.Posting{
                        .account = balance.account_token,
                        .flag = .none,
                        .amount_number = Data.PackedNumber.pack(missing),
                        .amount_currency = cur_idx.toOptional(),
                        .price = .none,
                        .lot_spec = .none,
                        .meta = Data.Range.empty,
                        .ast_node = .none,
                    };
                    const pad_idx = try data.appendPosting(pad_posting);
                    try tree.addPosition(acc_idx, cur_idx, missing);
                    last_pad.pad_ptr.pad_posting = pad_idx.toOptional();

                    const pad_file_data = &self.files.items[last_pad.file];
                    const pad_to_acc_idx = pad_file_data.accountOf(last_pad.pad_to_token);

                    const pad_to_posting = Data.Posting{
                        .account = last_pad.pad_to_token,
                        .flag = .none,
                        .amount_number = Data.PackedNumber.pack(missing.negate()),
                        .amount_currency = cur_idx.toOptional(),
                        .price = .none,
                        .lot_spec = .none,
                        .meta = Data.Range.empty,
                        .ast_node = .none,
                    };
                    const pad_to_idx = try pad_file_data.appendPosting(pad_to_posting);
                    try tree.addPosition(pad_to_acc_idx, cur_idx, missing.negate());
                    last_pad.pad_ptr.pad_to_posting = pad_to_idx.toOptional();

                    _ = lastPads.remove(acc_idx);
                } else {
                    const tolerance = if (balance.tolerance) |t| t else expected.getTolerance();
                    if (!expected.is_within_tolerance(accumulated, tolerance)) {
                        try self.addError(entry.mainToken(), sorted.file, .{ .balance_assertion_failed = .{
                            .expected = expected,
                            .accumulated = accumulated,
                        } });
                    }
                }
            },
            .pnl => |pnl| {
                const acc_idx = data.accountOf(pnl.account);
                const inc_idx = data.accountOf(pnl.income_account);
                if (!tree.accountOpen(acc_idx)) {
                    try self.addError(pnl.account, sorted.file, .account_not_open);
                    continue;
                }
                if (!tree.accountOpen(inc_idx)) {
                    try self.addError(pnl.income_account, sorted.file, .account_not_open);
                    continue;
                }
                if (tree.isPlainAccount(acc_idx) catch unreachable) {
                    try self.addError(pnl.account, sorted.file, .pnl_account_must_be_lots);
                    continue;
                }
                try pnlAccounts.put(acc_idx, .{ .income_token = pnl.income_account, .file = sorted.file });
            },
            .transaction => |_| {
                const tx_ptr: *Data.Transaction = &data.entries.items(.payload)[sorted.entry].transaction;
                if (tx_ptr.dirty) continue;

                const postings = tx_ptr.postings;
                if (postings.isEmpty()) continue;

                var pnl_start: u32 = 0;
                var has_pnl = false;

                for (postings.start..postings.end) |i| {
                    const posting = data.postingAt(@intCast(i));
                    const post_result = try self.postInventoryRecovering(
                        &tree,
                        entry.date(),
                        posting,
                        sorted.file,
                        tx_ptr,
                    );
                    if (post_result) |pr| {
                        if (pnlAccounts.get(posting.account())) |pnl_entry| {
                            if (posting.price()) |price| {
                                const amount_num = posting.amountNumber().?;
                                const sale_weight = if (price.total)
                                    price.amount.?
                                else
                                    amount_num.mul(price.amount.?);
                                const pnl_amount = sale_weight.sub(pr.cost_weight);
                                if (!pnl_amount.is_zero()) {
                                    if (!has_pnl) {
                                        pnl_start = @intCast(data.postings.len);
                                        for (postings.start..postings.end) |j| {
                                            const orig = data.postings.get(j);
                                            _ = try data.appendPosting(orig);
                                        }
                                        has_pnl = true;
                                    }
                                    const pnl_posting = Data.Posting{
                                        .account = pnl_entry.income_token,
                                        .flag = .none,
                                        .amount_number = Data.PackedNumber.pack(pnl_amount),
                                        .amount_currency = pr.cost_currency.toOptional(),
                                        .price = .none,
                                        .lot_spec = .none,
                                        .meta = Data.Range.empty,
                                        .ast_node = .none,
                                    };
                                    _ = try data.appendPosting(pnl_posting);
                                    const inc_acc_idx = data.accountOf(pnl_entry.income_token);
                                    try tree.addPosition(inc_acc_idx, pr.cost_currency, pnl_amount);
                                }
                            }
                        }
                    }
                }
                if (has_pnl) {
                    tx_ptr.postings = .{ .start = pnl_start, .end = @intCast(data.postings.len) };
                }
            },
            .note => |note| {
                const acc_idx = data.accountOf(note.account);
                if (!tree.accountOpen(acc_idx)) {
                    try self.addError(note.account, sorted.file, .account_not_open);
                }
            },
            .document => |document| {
                const acc_idx = data.accountOf(document.account);
                if (!tree.accountOpen(acc_idx)) {
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
    posting: Data.PostingView,
    file_id: u8,
    tx: *Data.Transaction,
) !?Tree.PostResult {
    return tree.postInventory(date, posting) catch |err| {
        tx.dirty = true;
        const account_tok = posting.accountToken();
        switch (err) {
            error.DoesNotHoldCurrency => try self.addError(account_tok, file_id, .account_does_not_hold_currency),
            error.CannotAddToLotsInventory => try self.addError(account_tok, file_id, .account_is_booked),
            error.PlainInventoryDoesNotSupportLotSpec => try self.addError(account_tok, file_id, .account_does_not_support_lot_spec),
            error.AccountNotOpen => try self.addError(account_tok, file_id, .account_not_open),
            error.LotSpecAmbiguousMatch => try self.addError(account_tok, file_id, .lot_spec_ambiguous_match),
            error.LotSpecMatchTooSmall => try self.addError(account_tok, file_id, .lot_spec_match_too_small),
            error.LotSpecNoMatch => try self.addError(account_tok, file_id, .lot_spec_no_match),
            error.AmbiguousStrictBooking => try self.addError(account_tok, file_id, .ambiguous_strict_booking),
            error.CostCurrencyMismatch => try self.addError(account_tok, file_id, .cost_currency_mismatch),
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
            const data = &self.files.items[it.file];

            while (it.entry < data.entries.len) {
                const payload = data.entries.items(.payload)[it.entry];
                switch (payload) {
                    .open => |open| {
                        it.entry += 1;
                        return .{ .file = it.file, .token = data.token(open.account), .kind = .open };
                    },
                    .close => |close| {
                        it.entry += 1;
                        return .{ .file = it.file, .token = data.token(close.account), .kind = .close };
                    },
                    .pad => |pad| {
                        if (!it.pad_to) {
                            it.pad_to = true;
                            return .{ .file = it.file, .token = data.token(pad.account), .kind = .pad };
                        } else {
                            it.pad_to = false;
                            it.entry += 1;
                            return .{ .file = it.file, .token = data.token(pad.pad_to), .kind = .pad_to };
                        }
                    },
                    .pnl => |pnl| {
                        if (!it.pnl_income) {
                            it.pnl_income = true;
                            return .{ .file = it.file, .token = data.token(pnl.account), .kind = .pnl_income };
                        } else {
                            it.pnl_income = false;
                            it.entry += 1;
                            return .{ .file = it.file, .token = data.token(pnl.income_account), .kind = .pnl_income };
                        }
                    },
                    .balance => |balance| {
                        it.entry += 1;
                        return .{ .file = it.file, .token = data.token(balance.account), .kind = .balance };
                    },
                    .note => |note| {
                        it.entry += 1;
                        return .{ .file = it.file, .token = data.token(note.account), .kind = .note };
                    },
                    .document => |document| {
                        it.entry += 1;
                        return .{ .file = it.file, .token = data.token(document.account), .kind = .document };
                    },
                    else => {
                        it.entry += 1;
                    },
                }
            }

            while (it.posting < data.postings.len) {
                const acc_tok = data.postings.items(.account)[it.posting];
                const ast_node = data.postings.items(.ast_node)[it.posting];
                it.posting += 1;
                if (ast_node == .none) continue;
                return .{ .file = it.file, .token = data.token(acc_tok), .kind = .posting };
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
    taglink_idx: u32,

    pub fn init(self: *const Self, file: ?u32) TagLinkIterator {
        const file_max: u32 = if (file) |f| f + 1 else @intCast(self.files.items.len);
        return .{
            .self = self,
            .file = file orelse 0,
            .file_max = file_max,
            .taglink_idx = 0,
        };
    }

    pub fn next(it: *TagLinkIterator) ?struct { file: u32, token: Token } {
        const self = it.self;
        while (it.file < it.file_max) {
            const data = &self.files.items[it.file];
            const tokens = data.tagslinks.items(.token);
            const explicits = data.tagslinks.items(.explicit);
            while (it.taglink_idx < tokens.len) {
                const idx = it.taglink_idx;
                it.taglink_idx += 1;
                if (explicits[idx]) {
                    return .{
                        .file = it.file,
                        .token = data.token(tokens[idx]),
                    };
                }
            }

            it.file += 1;
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
    // Clear dense account table; entries are repopulated below.
    self.account_open_pos.clear();
    self.tags.clearRetainingCapacity();
    self.links.clearRetainingCapacity();

    for (self.files.items, 0..) |*data, f| {
        const tokens = data.tagslinks.items(.token);
        const kinds = data.tagslinks.items(.kind);
        for (tokens, kinds) |tok, kind| {
            const slice = data.tokenSlice(tok);
            switch (kind) {
                .tag => try self.tags.put(slice, {}),
                .link => try self.links.put(slice, {}),
            }
        }

        var it = data.iterEntriesOfKind(.open);
        while (it.next()) |entry| {
            const open = switch (entry.payload()) {
                .open => |o| o,
                else => unreachable,
            };
            const acc_idx = open.account();
            try self.account_open_pos.put(self.alloc, acc_idx, .{
                .file = @intCast(f),
                .line = data.token(entry.mainToken()).start_line,
            });
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
    const raw_idx = self.accounts.find(account) orelse return null;
    const account_idx: AccountIndex = @enumFromInt(@intFromEnum(raw_idx));

    var tree = try Tree.init(self.alloc, self.accounts, self.currencies);
    defer tree.deinit();

    for (self.sorted_entries.items) |sorted_entry| {
        const data = &self.files.items[sorted_entry.file];
        const entry = data.entryAt(sorted_entry.entry);
        switch (entry.payload()) {
            .open => |open| {
                if (open.account() == account_idx) {
                    var cur_list = std.ArrayList(CurrencyIndex){};
                    defer cur_list.deinit(self.alloc);
                    var cit = open.currencies();
                    while (cit.next()) |c| try cur_list.append(self.alloc, c);
                    const cur_slice: ?[]const CurrencyIndex = if (cur_list.items.len == 0) null else cur_list.items;
                    _ = try tree.open(account_idx, cur_slice, open.open.booking_method);
                }
            },
            .transaction => |tx| {
                if (tx.tx.dirty) continue;
                const postings = tx.tx.postings;
                for (postings.start..postings.end) |i| {
                    const posting = data.postingAt(@intCast(i));
                    if (posting.account() != account_idx) continue;
                    const acc_line = data.token(posting.accountToken()).start_line;
                    if (acc_line == line and sorted_entry.file == file) {
                        var before = try tree.inventoryAggregatedByAccount(self.alloc, account_idx);
                        errdefer before.deinit();
                        _ = try tree.postInventory(entry.date(), posting);
                        var after = try tree.inventoryAggregatedByAccount(self.alloc, account_idx);
                        errdefer after.deinit();
                        return .{ .before = before, .after = after };
                    } else {
                        _ = try tree.postInventory(entry.date(), posting);
                    }
                }
            },
            .pad => |pad| {
                if (pad.pad_posting.unwrap()) |pidx| {
                    const posting = data.postingAt(@intFromEnum(pidx));
                    if (posting.account() == account_idx) {
                        const acc_line = data.token(posting.accountToken()).start_line;
                        if (acc_line == line and sorted_entry.file == file) {
                            var before = try tree.inventoryAggregatedByAccount(self.alloc, account_idx);
                            errdefer before.deinit();
                            _ = try tree.postInventory(entry.date(), posting);
                            var after = try tree.inventoryAggregatedByAccount(self.alloc, account_idx);
                            errdefer after.deinit();
                            return .{ .before = before, .after = after };
                        } else {
                            _ = try tree.postInventory(entry.date(), posting);
                        }
                    }
                }
                if (pad.pad_to_posting.unwrap()) |pidx| {
                    const posting = data.postingAt(@intFromEnum(pidx));
                    if (posting.account() == account_idx) {
                        const acc_line = data.token(posting.accountToken()).start_line;
                        if (acc_line == line and sorted_entry.file == file) {
                            var before = try tree.inventoryAggregatedByAccount(self.alloc, account_idx);
                            errdefer before.deinit();
                            _ = try tree.postInventory(entry.date(), posting);
                            var after = try tree.inventoryAggregatedByAccount(self.alloc, account_idx);
                            errdefer after.deinit();
                            return .{ .before = before, .after = after };
                        } else {
                            _ = try tree.postInventory(entry.date(), posting);
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
    const raw = self.accounts.find(account) orelse return null;
    const idx: AccountIndex = @enumFromInt(@intFromEnum(raw));
    const pos = self.account_open_pos.get(idx) orelse return null;
    return .{ self.uris.items[pos.file], pos.line };
}

/// LSP completion: iterate over all known account texts.
pub fn accountsIterator(self: *const Self) AccountsTextIterator {
    return .{ .project = self, .inner = self.account_open_pos.iterator() };
}

pub const AccountsTextIterator = struct {
    project: *const Self,
    inner: pool_maps.AccountMap(FileLine).Iterator,

    pub fn next(it: *AccountsTextIterator) ?[]const u8 {
        const entry = it.inner.next() orelse return null;
        return it.project.accounts.get(@enumFromInt(@intFromEnum(entry.key)));
    }
};

/// Takes ownership of source.
pub fn update_file(self: *Self, uri_value: []const u8, source: [:0]const u8) !void {
    const index = self.files_by_uri.get(uri_value) orelse return error.FileNotFound;
    const data = &self.files.items[index];

    const is_root = index == 0;

    const uri = self.uris.items[index];
    var new_data, const imports = try Data.loadSource(
        self.alloc,
        self.accounts,
        self.currencies,
        uri,
        source,
        is_root,
    );
    defer self.alloc.free(imports);
    try new_data.balanceTransactions();

    data.deinit();
    data.* = new_data;

    try self.pipeline();
}

pub fn printTree(self: *Self) !void {
    var tree = try Tree.init(self.alloc, self.accounts, self.currencies);
    defer tree.deinit();

    for (self.sorted_entries.items) |sorted_entry| {
        const data = &self.files.items[sorted_entry.file];
        const entry = data.entryAt(sorted_entry.entry);
        switch (entry.payload()) {
            .open => |open| {
                var cur_list = std.ArrayList(CurrencyIndex){};
                defer cur_list.deinit(self.alloc);
                var cit = open.currencies();
                while (cit.next()) |c| try cur_list.append(self.alloc, c);
                const cur_slice: ?[]const CurrencyIndex = if (cur_list.items.len == 0) null else cur_list.items;
                _ = try tree.open(open.account(), cur_slice, open.open.booking_method);
            },
            .transaction => |tx| {
                if (tx.tx.dirty) continue;
                const postings = tx.tx.postings;
                for (postings.start..postings.end) |i| {
                    _ = try tree.postInventory(entry.date(), data.postingAt(@intCast(i)));
                }
            },
            .pad => |pad| {
                if (pad.pad_posting.unwrap()) |pidx| {
                    _ = try tree.postInventory(entry.date(), data.postingAt(@intFromEnum(pidx)));
                }
                if (pad.pad_to_posting.unwrap()) |pidx| {
                    _ = try tree.postInventory(entry.date(), data.postingAt(@intFromEnum(pidx)));
                }
            },
            else => {},
        }
    }

    try tree.print();
}

fn addErrorDetails(self: *Self, tok: Ast.TokenIndex, file_id: u8, tag: ErrorDetails.Tag, severity: ErrorDetails.Severity) !void {
    const uri = self.uris.items[@intCast(file_id)];
    const data = &self.files.items[file_id];
    try self.errors.append(self.alloc, ErrorDetails{
        .tag = tag,
        .severity = severity,
        .token = data.token(tok),
        .uri = uri,
        .source = data.source,
    });
}

fn addError(self: *Self, tok: Ast.TokenIndex, file_id: u8, tag: ErrorDetails.Tag) !void {
    try self.addErrorDetails(tok, file_id, tag, .err);
}
