const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Data = @import("data.zig");
const File = @import("file.zig");
const Tree = @import("tree.zig");
const Uri = @import("Uri.zig");
const ErrorDetails = @import("ErrorDetails.zig");
const Ast = @import("Ast.zig");
const Token = @import("lexer.zig").Lexer.Token;
const Inventory = @import("inventory.zig").Inventory;
const InvSummary = @import("inventory.zig").Summary;
const Date = @import("date.zig").Date;
const Number = @import("number.zig").Number;
const Solver = @import("solver.zig").Solver;
const string_pool = @import("string_pool.zig");
const AccountPool = string_pool.AccountPool;
const CurrencyPool = string_pool.CurrencyPool;
const AccountMap = @import("pool_maps.zig").AccountMap;
const AccountIndex = Data.AccountIndex;
const CurrencyIndex = Data.CurrencyIndex;
const ztracy = @import("ztracy");

const Self = @This();

alloc: Allocator,
io: Io,

/// Storage layer: per-file ASTs plus the merged semantic tables.
data: Data,

/// Project-level errors (cross-file analysis: balance, check). Per-file parse
/// errors live on each `File.errors`.
errors: std.ArrayList(ErrorDetails),

// LSP specific caches
account_open_pos: AccountMap(FileLine),
tags: std.StringHashMap(void),
links: std.StringHashMap(void),

const FileLine = struct {
    file: u32,
    line: u32,
};

/// Load a project from a root file URI.
///
/// If `source` is provided, uses that as the source text of the root
/// project file, otherwise loads from file.
pub fn load(alloc: Allocator, io: Io, uri: Uri, source: ?[:0]const u8) !Self {
    const tracy_zone = ztracy.ZoneNC(@src(), "Load project", 0x00_00_ff_00);
    defer tracy_zone.End();

    var self = Self{
        .alloc = alloc,
        .io = io,
        .data = try Data.init(alloc),
        .errors = .empty,
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
    self.data.deinit();
    self.errors.deinit(self.alloc);

    self.account_open_pos.deinit(self.alloc);
    self.tags.deinit();
    self.links.deinit();
}

// --- forwarding accessors ---------------------------------------------------

pub fn getConfig(self: *const Self) *const Data.Config {
    return &self.data.config;
}

/// Is the provided file_uri included in this project?
pub fn ownsFile(self: *const Self, file_uri: []const u8) bool {
    return self.data.files_by_uri.contains(file_uri);
}

/// Is the provided file_uri the root file of this project?
pub fn hasRoot(self: *const Self, file_uri: []const u8) bool {
    if (self.data.files.items.len == 0) return false;
    return std.mem.eql(u8, self.data.files.items[0].uri.value, file_uri);
}

pub fn findCurrency(self: *const Self, text: []const u8) ?CurrencyIndex {
    return self.data.findCurrency(text);
}

pub fn findAccount(self: *const Self, text: []const u8) ?AccountIndex {
    return self.data.findAccount(text);
}

pub fn rootUri(self: *const Self) Uri {
    return self.data.files.items[0].uri;
}

pub fn fileUri(self: *const Self, file_id: usize) Uri {
    return self.data.files.items[file_id].uri;
}

pub fn fileCount(self: *const Self) usize {
    return self.data.files.items.len;
}

pub fn fileIndex(self: *const Self, uri_value: []const u8) ?usize {
    return self.data.files_by_uri.get(uri_value);
}

pub fn fileAt(self: *const Self, file_id: usize) *const File {
    return &self.data.files.items[file_id];
}

// --- file loading -----------------------------------------------------------

fn loadFileRec(self: *Self, uri: Uri, is_root: bool, source: ?[:0]const u8) !void {
    if (self.data.files_by_uri.get(uri.value)) |_| return error.ImportCycle;

    const uri_owned = try uri.clone(self.alloc);
    const null_terminated = source orelse uri_owned.load_nullterminated(self.alloc, self.io) catch |err| {
        var u = uri_owned;
        u.deinit(self.alloc);
        return err;
    };

    const file_id, const imports = try self.data.loadFile(uri_owned, is_root, null_terminated);
    defer self.alloc.free(imports);

    for (imports) |import| {
        var import_uri = try uri_owned.move_relative(self.alloc, import.path);
        defer import_uri.deinit(self.alloc);
        // Check if the file exists before recursing
        std.Io.Dir.accessAbsolute(self.io, import_uri.absolute(), .{}) catch {
            const f = &self.data.files.items[file_id];
            try f.errors.append(self.alloc, .{
                .tag = .include_file_not_found,
                .token = import.token,
                .uri = f.uri,
                .source = f.source,
            });
            continue;
        };
        try self.loadFileRec(import_uri, false, null);
    }
}

// --- error helpers ----------------------------------------------------------

pub fn hasErrors(self: *const Self) bool {
    if (self.data.hasFileErrors()) return true;
    if (self.errors.items.len > 0) return true;
    return false;
}

pub fn hasSevereErrors(self: *const Self) bool {
    for (self.data.files.items) |f| {
        for (f.errors.items) |err| {
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
    for (self.data.files.items) |f| {
        try errors.put(f.uri.value, std.ArrayList(ErrorDetails).empty);
    }
    for (self.data.files.items) |f| {
        for (f.errors.items) |err| {
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
    var error_list = std.ArrayList(ErrorDetails).empty;
    defer error_list.deinit(self.alloc);
    var warning_list = std.ArrayList(ErrorDetails).empty;
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
        try err.print(self.alloc, self.io);
        num_printed += 1;
    }

    // Then print warnings
    for (warning_list.items) |warn| {
        if (num_printed == 10) {
            const remaining_warnings = num_warnings - (num_printed - num_errors);
            std.debug.print("... and {d} errors and {d} warnings more\n", .{ 0, remaining_warnings });
            return;
        }
        try warn.print(self.alloc, self.io);
        num_printed += 1;
    }
}

// --- pipeline ---------------------------------------------------------------

pub fn pipeline(self: *Self) !void {
    self.errors.clearRetainingCapacity();
    try self.balanceTransactions();
    self.sortEntries();
    try self.refreshLspCache();
    try self.check();
}

/// Sort `data.entries` in place by date+time-of-day. Posting/TagLink/Meta
/// arrays are unchanged — each Entry's `Range` fields keep pointing at a
/// contiguous run regardless of the entry's position.
pub fn sortEntries(self: *Self) void {
    const Ctx = struct {
        slice: Data.Entries.Slice,

        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return Data.Entry.compare(ctx.slice.get(a), ctx.slice.get(b));
        }
    };
    self.data.entries.sort(Ctx{ .slice = self.data.entries.slice() });
}

pub fn check(self: *Self) !void {
    var lastPads: AccountMap(Data.PadView) = .{};
    defer lastPads.deinit(self.alloc);

    var pnlAccounts: AccountMap(Data.TokenLoc) = .{};
    defer pnlAccounts.deinit(self.alloc);

    var tree = try Tree.init(self.alloc, &self.data.accounts, &self.data.currencies);
    defer tree.deinit();

    var entry_iter = self.data.iterEntries();
    while (entry_iter.next()) |entry| {
        switch (entry.payload()) {
            .open => |open| {
                if (try tree.open(open.account(), open.currencies(), open.open.booking_method) == null) {
                    try self.addError(open.accountLoc(), ErrorDetails.Tag.account_already_open);
                }
            },
            .close => |close| {
                tree.close(close.account()) catch |err| switch (err) {
                    error.AccountNotOpen => try self.addError(close.accountLoc(), ErrorDetails.Tag.account_not_open),
                };
            },
            .pad => |pad| {
                const acc_idx = pad.account();
                const pad_to_idx = pad.padToAccount();
                if (!tree.accountOpen(acc_idx)) {
                    try self.addError(pad.accountLoc(), ErrorDetails.Tag.account_not_open);
                    continue;
                }
                if (!tree.accountOpen(pad_to_idx)) {
                    try self.addError(pad.padToAccountLoc(), ErrorDetails.Tag.account_not_open);
                    continue;
                }
                if (!(tree.isPlainAccount(pad_to_idx) catch unreachable)) {
                    try self.addError(pad.padToAccountLoc(), ErrorDetails.Tag.pad_accounts_must_be_plain);
                    continue;
                }
                if (!(tree.isPlainAccount(acc_idx) catch unreachable)) {
                    try self.addError(pad.accountLoc(), ErrorDetails.Tag.pad_accounts_must_be_plain);
                    continue;
                }

                if (lastPads.contains(acc_idx)) {
                    try self.addError(entry.mainTokenLoc(), .multiple_pads);
                } else {
                    try lastPads.put(self.alloc, acc_idx, pad);
                }
            },
            .balance => |balance| {
                const acc_idx = balance.account;
                const cur_idx = balance.amount_currency;
                const accumulated = tree.balanceAggregatedByAccount(acc_idx, cur_idx) catch |err| switch (err) {
                    error.AccountNotOpen => {
                        try self.addError(balance.accountLoc(), ErrorDetails.Tag.account_not_open);
                        continue;
                    },
                    error.DoesNotHoldCurrency => {
                        try self.addError(balance.accountLoc(), ErrorDetails.Tag.account_does_not_hold_currency);
                        continue;
                    },
                    else => return err,
                };

                const expected = balance.amount;
                if (lastPads.get(acc_idx)) |last_pad| {
                    const missing = expected.add(accumulated.negate());

                    try last_pad.setPadAmount(missing, cur_idx);
                    try last_pad.setPadToAmount(missing.negate(), cur_idx);

                    try tree.addPosition(last_pad.account(), cur_idx, missing);
                    try tree.addPosition(last_pad.padToAccount(), cur_idx, missing.negate());

                    lastPads.remove(acc_idx);
                } else {
                    const tolerance = if (balance.tolerance) |t| t else expected.getTolerance();
                    if (!expected.is_within_tolerance(accumulated, tolerance)) {
                        try self.addError(entry.mainTokenLoc(), .{ .balance_assertion_failed = .{
                            .expected = expected,
                            .accumulated = accumulated,
                        } });
                    }
                }
            },
            .pnl => |pnl| {
                const file = &self.data.files.items[entry.file()];
                const acc_idx = file.accountOf(pnl.account);
                const inc_idx = file.accountOf(pnl.income_account);
                if (!tree.accountOpen(acc_idx)) {
                    try self.addError(entry.loc(pnl.account), .account_not_open);
                    continue;
                }
                if (!tree.accountOpen(inc_idx)) {
                    try self.addError(entry.loc(pnl.income_account), .account_not_open);
                    continue;
                }
                if (tree.isPlainAccount(acc_idx) catch unreachable) {
                    try self.addError(entry.loc(pnl.account), .pnl_account_must_be_lots);
                    continue;
                }
                try pnlAccounts.put(self.alloc, acc_idx, entry.loc(pnl.income_account));
            },
            .transaction => |tx| {
                if (tx.dirty()) continue;

                var pnl_buf: [16]Data.Posting = undefined;
                var num_pnl: usize = 0;

                var it = tx.postings();
                while (it.next()) |posting| {
                    const post_result = try self.postInventoryRecovering(
                        &tree,
                        entry.date(),
                        posting,
                        tx.dirtyPtr(),
                    );
                    if (post_result) |pr| {
                        if (pnlAccounts.get(posting.account())) |pnl_loc| {
                            if (posting.price()) |price| {
                                const amount_num = posting.amountNumber().?;
                                const sale_weight = if (price.total)
                                    price.amount.?
                                else
                                    amount_num.mul(price.amount.?);
                                const pnl_amount = sale_weight.sub(pr.cost_weight);
                                if (!pnl_amount.is_zero()) {
                                    pnl_buf[num_pnl] = .simple(pnl_loc.index, pnl_amount, pr.cost_currency);
                                    num_pnl += 1;
                                    const pnl_account_idx = self.data.files.items[pnl_loc.file_id].accountOf(pnl_loc.index);
                                    try tree.addPosition(pnl_account_idx, pr.cost_currency, pnl_amount);
                                }
                            }
                        }
                    }
                }
                try tx.addPnlPostings(pnl_buf[0..num_pnl]);
            },
            .note => |note| {
                const file = &self.data.files.items[entry.file()];
                const acc_idx = file.accountOf(note.account);
                if (!tree.accountOpen(acc_idx)) {
                    try self.addError(entry.loc(note.account), .account_not_open);
                }
            },
            .document => |document| {
                const file = &self.data.files.items[entry.file()];
                const acc_idx = file.accountOf(document.account);
                if (!tree.accountOpen(acc_idx)) {
                    try self.addError(entry.loc(document.account), .account_not_open);
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
    dirty_ptr: *bool,
) !?Tree.PostResult {
    return tree.postInventory(date, posting) catch |err| {
        dirty_ptr.* = true;
        const loc = posting.accountLoc();
        switch (err) {
            error.DoesNotHoldCurrency => {
                try self.addError(loc, .account_does_not_hold_currency);
            },
            error.CannotAddToLotsInventory => {
                try self.addError(loc, .account_is_booked);
            },
            error.PlainInventoryDoesNotSupportLotSpec => {
                try self.addError(loc, .account_does_not_support_lot_spec);
            },
            error.AccountNotOpen => {
                try self.addError(loc, .account_not_open);
            },
            error.LotSpecAmbiguousMatch => {
                try self.addError(loc, .lot_spec_ambiguous_match);
            },
            error.LotSpecMatchTooSmall => {
                try self.addError(loc, .lot_spec_match_too_small);
            },
            error.LotSpecNoMatch => {
                try self.addError(loc, .lot_spec_no_match);
            },
            error.AmbiguousStrictBooking => {
                try self.addError(loc, .ambiguous_strict_booking);
            },
            error.CostCurrencyMismatch => {
                try self.addError(loc, .cost_currency_mismatch);
            },
            else => return err,
        }
        return null;
    };
}

/// Run the balancer over every transaction in the project, solving for
/// unknown numbers and currencies. Sets `dirty = true` on transactions that
/// cannot be solved.
fn balanceTransactions(self: *Self) !void {
    const tracy_zone = ztracy.ZoneNC(@src(), "Project.balanceTransactions", 0x00_00_ff_00);
    defer tracy_zone.End();

    var solver = Solver.init(self.alloc);
    defer solver.deinit();
    var diagnostics: Solver.CurrencyImbalance = undefined;

    var one: ?Number = Number.fromFloat(1);

    // Stable, reused per-tx staging buffers. We ensureTotalCapacity before
    // filling so that the pointers we hand to the solver stay valid during
    // `solve()`.
    var stage_numbers: std.ArrayList(?Number) = .empty;
    defer stage_numbers.deinit(self.alloc);
    var stage_currencies: std.ArrayList(?[]const u8) = .empty;
    defer stage_currencies.deinit(self.alloc);
    var stage_prices: std.ArrayList(?Number) = .empty;
    defer stage_prices.deinit(self.alloc);
    var stage_price_currencies: std.ArrayList(?[]const u8) = .empty;
    defer stage_price_currencies.deinit(self.alloc);

    const data = &self.data;
    const payloads = data.entries.items(.payload);
    const main_tokens = data.entries.items(.main_token);
    const entry_files = data.entries.items(.file);

    entries: for (payloads, 0..) |*ep, entry_idx| {
        if (std.meta.activeTag(ep.*) != .transaction) continue;
        const tx = &ep.transaction;
        const postings = tx.postings;
        if (postings.isEmpty()) continue;

        const file_id = entry_files[entry_idx];

        const n = postings.len();
        stage_numbers.clearRetainingCapacity();
        stage_currencies.clearRetainingCapacity();
        stage_prices.clearRetainingCapacity();
        stage_price_currencies.clearRetainingCapacity();
        try stage_numbers.ensureTotalCapacity(self.alloc, n);
        try stage_currencies.ensureTotalCapacity(self.alloc, n);
        try stage_prices.ensureTotalCapacity(self.alloc, n);
        try stage_price_currencies.ensureTotalCapacity(self.alloc, n);

        for (postings.start..postings.end) |i| {
            stage_numbers.appendAssumeCapacity(data.postings.items(.amount_number)[i].unpack());
            stage_currencies.appendAssumeCapacity(data.optCurrencyText(data.postings.items(.amount_currency)[i]));

            if (data.postings.items(.price)[i].unwrap()) |pidx| {
                const pr = data.prices.items[@intFromEnum(pidx)];
                stage_prices.appendAssumeCapacity(pr.amount);
                stage_price_currencies.appendAssumeCapacity(data.optCurrencyText(pr.amount_currency));
            } else {
                stage_prices.appendAssumeCapacity(null);
                stage_price_currencies.appendAssumeCapacity(null);
            }
        }

        for (postings.start..postings.end, 0..) |i, k| {
            const has_price = data.postings.items(.price)[i].unwrap() != null;
            var price_ptr: *?Number = undefined;
            var currency_ptr: *?[]const u8 = undefined;
            var rounding_currency: ?[]const u8 = null;

            if (has_price) {
                if (stage_currencies.items[k] == null) {
                    try self.addError(.{ .file_id = file_id, .index = data.postings.items(.account)[i] }, .cannot_infer_amount_currency_when_price_set);
                    tx.dirty = true;
                    solver.clear();
                    continue :entries;
                }
                currency_ptr = &stage_price_currencies.items[k];
                price_ptr = &stage_prices.items[k];
                if (stage_numbers.items[k] == null) {
                    rounding_currency = stage_currencies.items[k];
                } else if (stage_prices.items[k] == null) {
                    rounding_currency = stage_price_currencies.items[k];
                }
            } else {
                currency_ptr = &stage_currencies.items[k];
                price_ptr = &one;
            }

            try solver.addTriple(price_ptr, &stage_numbers.items[k], currency_ptr, rounding_currency);

            if (stage_numbers.items[k]) |num| {
                if (stage_currencies.items[k]) |c| {
                    try solver.addToleranceInput(num, c);
                }
            }
        }

        _ = solver.solve(&diagnostics) catch |err| {
            const tag: ErrorDetails.Tag = switch (err) {
                error.NoCurrency => .tx_balance_no_currency,
                error.DoesNotBalance => .{ .tx_does_not_balance = diagnostics },
                error.NoSolution => .tx_no_solution,
                error.TooManyVariables => .tx_too_many_variables,
                error.DivisionByZero => .tx_division_by_zero,
                error.MultipleSolutions => .tx_multiple_solutions,
                else => return err,
            };
            tx.dirty = true;
            try self.addError(.{ .file_id = file_id, .index = main_tokens[entry_idx] }, tag);
            continue;
        };

        // Write solved values back.
        for (postings.start..postings.end, 0..) |i, k| {
            data.postings.items(.amount_number)[i] = Data.PackedNumber.pack(stage_numbers.items[k]);
            data.postings.items(.amount_currency)[i] = try data.internCurrencyOpt(stage_currencies.items[k]);
            if (data.postings.items(.price)[i].unwrap()) |pidx| {
                const p_ptr = &data.prices.items[@intFromEnum(pidx)];
                p_ptr.amount = stage_prices.items[k];
                p_ptr.amount_currency = try data.internCurrencyOpt(stage_price_currencies.items[k]);
            }
        }
    }
}

// --- iterators on the project ----------------------------------------------

/// Visits every account-bearing token (entry-level and posting), optionally
/// restricted to one file. Order is per-entry but otherwise unspecified.
pub const AccountIterator = struct {
    self: *const Self,
    /// `null` means all files.
    file_filter: ?u8,
    entry: u32,
    /// For pad/pnl, becomes `true` after the first slot has been yielded so
    /// the next `next()` returns the second slot of the same entry.
    second_slot: bool,
    /// True while we're partway through a transaction's postings. Disambiguates
    /// "fresh entry, need to init" from "exhausted, need to advance entry".
    in_tx: bool,
    posting: u32,
    posting_end: u32,

    pub fn init(self: *const Self, file: ?u8) AccountIterator {
        return .{
            .self = self,
            .file_filter = file,
            .entry = 0,
            .second_slot = false,
            .in_tx = false,
            .posting = 0,
            .posting_end = 0,
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

    pub fn next(it: *AccountIterator) ?struct { file: u8, token: Token, kind: Kind } {
        const data = &it.self.data;
        const entry_files = data.entries.items(.file);
        const payloads = data.entries.items(.payload);

        while (it.entry < data.entries.len) {
            const file = entry_files[it.entry];
            const fdata = &data.files.items[file];

            // Drain in-progress transaction first. The filter was already
            // applied when we entered this transaction.
            if (it.in_tx) {
                while (it.posting < it.posting_end) {
                    const idx = it.posting;
                    it.posting += 1;
                    if (data.postings.items(.ast_node)[idx] == .none) continue;
                    const acc_tok = data.postings.items(.account)[idx];
                    return .{ .file = file, .token = fdata.token(acc_tok), .kind = .posting };
                }
                it.in_tx = false;
                it.entry += 1;
                continue;
            }

            if (it.file_filter) |f| {
                if (file != f) {
                    it.entry += 1;
                    continue;
                }
            }

            switch (payloads[it.entry]) {
                .open => |open| {
                    it.entry += 1;
                    return .{ .file = file, .token = fdata.token(open.account), .kind = .open };
                },
                .close => |close| {
                    it.entry += 1;
                    return .{ .file = file, .token = fdata.token(close.account), .kind = .close };
                },
                .pad => |pad| {
                    if (!it.second_slot) {
                        it.second_slot = true;
                        return .{ .file = file, .token = fdata.token(pad.account), .kind = .pad };
                    }
                    it.second_slot = false;
                    it.entry += 1;
                    return .{ .file = file, .token = fdata.token(pad.pad_to), .kind = .pad_to };
                },
                .pnl => |pnl| {
                    if (!it.second_slot) {
                        it.second_slot = true;
                        return .{ .file = file, .token = fdata.token(pnl.account), .kind = .pnl };
                    }
                    it.second_slot = false;
                    it.entry += 1;
                    return .{ .file = file, .token = fdata.token(pnl.income_account), .kind = .pnl_income };
                },
                .balance => |balance| {
                    it.entry += 1;
                    return .{ .file = file, .token = fdata.token(balance.account), .kind = .balance };
                },
                .note => |note| {
                    it.entry += 1;
                    return .{ .file = file, .token = fdata.token(note.account), .kind = .note };
                },
                .document => |doc| {
                    it.entry += 1;
                    return .{ .file = file, .token = fdata.token(doc.account), .kind = .document };
                },
                .transaction => |tx| {
                    // Mark in-progress; the next loop iteration drains it.
                    it.in_tx = true;
                    it.posting = tx.postings.start;
                    it.posting_end = tx.postings.end;
                },
                else => it.entry += 1,
            }
        }
        return null;
    }
};

pub fn accountIterator(self: *const Self, uri: ?[]const u8) AccountIterator {
    const file: ?u8 = if (uri) |u| if (self.data.files_by_uri.get(u)) |f| @intCast(f) else null else null;
    return AccountIterator.init(self, file);
}

/// Visits every explicit tag/link token, optionally restricted to one file.
pub const TagLinkIterator = struct {
    self: *const Self,
    file_filter: ?u8,
    entry: u32,
    /// True while we're partway through an entry's tagslinks range.
    /// Disambiguates "fresh entry" from "exhausted, advance entry".
    in_range: bool,
    tl_idx: u32,
    tl_end: u32,

    pub fn init(self: *const Self, file: ?u8) TagLinkIterator {
        return .{
            .self = self,
            .file_filter = file,
            .entry = 0,
            .in_range = false,
            .tl_idx = 0,
            .tl_end = 0,
        };
    }

    pub fn next(it: *TagLinkIterator) ?struct { file: u32, token: Token } {
        const data = &it.self.data;
        const entry_files = data.entries.items(.file);
        const entry_taglinks = data.entries.items(.tagslinks);
        const tl_tokens = data.tagslinks.items(.token);
        const tl_explicit = data.tagslinks.items(.explicit);

        while (it.entry < data.entries.len) {
            const file = entry_files[it.entry];
            if (it.file_filter) |f| {
                if (file != f) {
                    it.entry += 1;
                    continue;
                }
            }
            const fdata = &data.files.items[file];

            if (!it.in_range) {
                const tl_range = entry_taglinks[it.entry];
                it.tl_idx = tl_range.start;
                it.tl_end = tl_range.end;
                it.in_range = true;
            }
            while (it.tl_idx < it.tl_end) {
                const idx = it.tl_idx;
                it.tl_idx += 1;
                if (tl_explicit[idx]) {
                    return .{ .file = file, .token = fdata.token(tl_tokens[idx]) };
                }
            }
            // Done with this entry.
            it.in_range = false;
            it.entry += 1;
        }
        return null;
    }
};

pub fn tagLinkIterator(self: *const Self, uri: ?[]const u8) TagLinkIterator {
    const file: ?u8 = if (uri) |u| if (self.data.files_by_uri.get(u)) |f| @intCast(f) else null else null;
    return TagLinkIterator.init(self, file);
}

fn refreshLspCache(self: *Self) !void {
    self.account_open_pos.clear();
    self.tags.clearRetainingCapacity();
    self.links.clearRetainingCapacity();

    var entry_iter = self.data.iterEntries();
    while (entry_iter.next()) |entry| {
        const file_id = entry.file();
        const fdata = &self.data.files.items[file_id];

        // Tags/links in this entry's range — need file context to slice text.
        var tl = entry.tagslinks();
        while (tl.next()) |t| {
            const slice = fdata.tokenSlice(t.token);
            switch (t.kind) {
                .tag => try self.tags.put(slice, {}),
                .link => try self.links.put(slice, {}),
            }
        }

        if (entry.tag() == .open) {
            const open = entry.payload().open;
            const acc_idx = open.account();
            try self.account_open_pos.put(self.alloc, acc_idx, .{
                .file = file_id,
                .line = fdata.token(entry.mainToken()).start_line,
            });
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
    const file = self.data.files_by_uri.get(uri) orelse return null;
    const account_idx = self.data.accounts.find(account) orelse return null;

    var tree = try Tree.init(self.alloc, &self.data.accounts, &self.data.currencies);
    defer tree.deinit();

    var entry_iter = self.data.iterEntries();
    while (entry_iter.next()) |entry| {
        const entry_file = entry.file();
        const fdata = &self.data.files.items[entry_file];
        switch (entry.payload()) {
            .open => |open| {
                if (open.account() == account_idx) {
                    _ = try tree.open(account_idx, open.currencies(), open.open.booking_method);
                }
            },
            .transaction => |tx| {
                if (tx.dirty()) continue;
                var it = tx.postings();
                while (it.next()) |posting| {
                    if (posting.account() != account_idx) continue;
                    const acc_line = fdata.token(posting.accountToken()).start_line;
                    if (acc_line == line and entry_file == file) {
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
                if (pad.padPosting()) |posting| {
                    if (posting.account() == account_idx) {
                        const acc_line = fdata.token(posting.accountToken()).start_line;
                        if (acc_line == line and entry_file == file) {
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
                if (pad.padToPosting()) |posting| {
                    if (posting.account() == account_idx) {
                        const acc_line = fdata.token(posting.accountToken()).start_line;
                        if (acc_line == line and entry_file == file) {
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
    const idx = self.data.accounts.find(account) orelse return null;
    const pos = self.account_open_pos.get(idx) orelse return null;
    return .{ self.data.files.items[pos.file].uri, pos.line };
}

/// LSP completion: iterate over all known account texts.
pub fn accountsIterator(self: *const Self) AccountsTextIterator {
    return .{ .project = self, .inner = self.account_open_pos.iterator() };
}

pub const AccountsTextIterator = struct {
    project: *const Self,
    inner: AccountMap(FileLine).Iterator,

    pub fn next(it: *AccountsTextIterator) ?[]const u8 {
        const entry = it.inner.next() orelse return null;
        return it.project.data.accounts.get(entry.key);
    }
};

/// Takes ownership of source.
pub fn update_file(self: *Self, uri_value: []const u8, source: [:0]const u8) !void {
    try self.data.updateFile(uri_value, source);
    try self.pipeline();
}

pub fn printTree(self: *Self) !void {
    var tree = try Tree.init(self.alloc, &self.data.accounts, &self.data.currencies);
    defer tree.deinit();

    var entry_iter = self.data.iterEntries();
    while (entry_iter.next()) |entry| {
        switch (entry.payload()) {
            .open => |open| {
                _ = try tree.open(open.account(), open.currencies(), open.open.booking_method);
            },
            .transaction => |tx| {
                if (tx.tx.dirty) continue;
                var it = tx.postings();
                while (it.next()) |p| {
                    _ = try tree.postInventory(entry.date(), p);
                }
            },
            .pad => |pad| {
                if (pad.padPosting()) |posting| {
                    _ = try tree.postInventory(entry.date(), posting);
                }
                if (pad.padToPosting()) |posting| {
                    _ = try tree.postInventory(entry.date(), posting);
                }
            },
            else => {},
        }
    }

    try tree.print();
}

fn addErrorDetails(self: *Self, loc: Data.TokenLoc, tag: ErrorDetails.Tag, severity: ErrorDetails.Severity) !void {
    const f = &self.data.files.items[loc.file_id];
    try self.errors.append(self.alloc, ErrorDetails{
        .tag = tag,
        .severity = severity,
        .token = f.token(loc.index),
        .uri = f.uri,
        .source = f.source,
    });
}

fn addError(self: *Self, loc: Data.TokenLoc, tag: ErrorDetails.Tag) !void {
    try self.addErrorDetails(loc, tag, .err);
}
