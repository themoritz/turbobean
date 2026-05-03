const std = @import("std");
const Allocator = std.mem.Allocator;
const Date = @import("date.zig").Date;
const Ast = @import("Ast.zig");
const Number = @import("number.zig").Number;
const Inventory = @import("inventory.zig");
const ErrorDetails = @import("ErrorDetails.zig");
const Uri = @import("Uri.zig");
const Lexer = @import("lexer.zig").Lexer;
const CurrencyPool = @import("string_pool.zig").CurrencyPool;
const AccountPool = @import("string_pool.zig").AccountPool;
const ztracy = @import("ztracy");

const Sema = @import("Sema.zig");
const Parser = @import("Parser.zig");
const File = @import("file.zig");

const Self = @This();

alloc: Allocator,

/// Project-wide intern pools. Interned account/currency indices are comparable
/// across files.
accounts: AccountPool,
currencies: CurrencyPool,

/// Per-file state (Ast, source, URI, token-interning side table). Indexed by
/// `Entry.file`. Files are inserted in load order (root file at index 0,
/// imports follow).
files: std.ArrayList(File),
/// Keys are URI values, values are index into `files`.
files_by_uri: std.StringHashMap(usize),

entries: Entries,
postings: Postings,

/// Stored price annotations, referenced from `Posting.price`.
prices: std.ArrayList(Price),
/// Stored lot specs, referenced from `Posting.lot_spec`.
lot_specs: std.ArrayList(LotSpec),
/// Flat list of currencies for open directives. `Open.currencies` is a `Range` into this.
open_currencies: std.ArrayList(CurrencyIndex),

tagslinks: TagsLinks,
meta: Meta,

config: Config,

pub const Entries = std.MultiArrayList(Entry);
pub const Postings = std.MultiArrayList(Posting);
pub const TagsLinks = std.MultiArrayList(TagLink);
pub const Meta = std.MultiArrayList(KeyValue);

pub const Import = struct {
    path: []const u8,
    token: Lexer.Token,
};
pub const Imports = []Import;

// --- typed indices ----------------------------------------------------------

pub const AccountIndex = enum(u32) {
    _,

    pub fn toOptional(i: AccountIndex) OptionalAccountIndex {
        const r: OptionalAccountIndex = @enumFromInt(@intFromEnum(i));
        std.debug.assert(r != .none);
        return r;
    }
};

pub const OptionalAccountIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oi: OptionalAccountIndex) ?AccountIndex {
        return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
    }

    pub fn fromOptional(oi: ?AccountIndex) OptionalAccountIndex {
        return if (oi) |i| i.toOptional() else .none;
    }
};

pub const CurrencyIndex = enum(u32) {
    _,

    pub fn toOptional(i: CurrencyIndex) OptionalCurrencyIndex {
        const r: OptionalCurrencyIndex = @enumFromInt(@intFromEnum(i));
        std.debug.assert(r != .none);
        return r;
    }
};

pub const OptionalCurrencyIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oi: OptionalCurrencyIndex) ?CurrencyIndex {
        return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
    }

    pub fn fromOptional(oi: ?CurrencyIndex) OptionalCurrencyIndex {
        return if (oi) |i| i.toOptional() else .none;
    }
};

pub const PriceIndex = enum(u32) {
    _,

    pub fn toOptional(i: PriceIndex) OptionalPriceIndex {
        const r: OptionalPriceIndex = @enumFromInt(@intFromEnum(i));
        std.debug.assert(r != .none);
        return r;
    }
};

pub const OptionalPriceIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oi: OptionalPriceIndex) ?PriceIndex {
        return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
    }

    pub fn fromOptional(oi: ?PriceIndex) OptionalPriceIndex {
        return if (oi) |i| i.toOptional() else .none;
    }
};

pub const LotSpecIndex = enum(u32) {
    _,

    pub fn toOptional(i: LotSpecIndex) OptionalLotSpecIndex {
        const r: OptionalLotSpecIndex = @enumFromInt(@intFromEnum(i));
        std.debug.assert(r != .none);
        return r;
    }
};

pub const OptionalLotSpecIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oi: OptionalLotSpecIndex) ?LotSpecIndex {
        return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
    }

    pub fn fromOptional(oi: ?LotSpecIndex) OptionalLotSpecIndex {
        return if (oi) |i| i.toOptional() else .none;
    }
};

pub const PostingIndex = enum(u32) {
    _,

    pub fn toOptional(i: PostingIndex) OptionalPostingIndex {
        const r: OptionalPostingIndex = @enumFromInt(@intFromEnum(i));
        std.debug.assert(r != .none);
        return r;
    }
};

pub const OptionalPostingIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oi: OptionalPostingIndex) ?PostingIndex {
        return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
    }
};

/// Half-open range into a sibling array. `start == end` means empty.
pub const Range = struct {
    start: u32,
    end: u32,

    pub const empty: Range = .{ .start = 0, .end = 0 };

    pub fn from(start: usize, end: usize) Range {
        return .{ .start = @intCast(start), .end = @intCast(end) };
    }

    pub fn len(r: Range) u32 {
        return r.end - r.start;
    }

    pub fn isEmpty(r: Range) bool {
        return r.start == r.end;
    }
};

// --- Entry ------------------------------------------------------------------

pub const Entry = struct {
    file: u8,
    date: Date,
    main_token: Ast.TokenIndex,
    tagslinks: Range,
    meta: Range,
    payload: Payload,

    pub const Tag = enum(u8) {
        transaction,
        open,
        close,
        commodity,
        pad,
        pnl,
        balance,
        price,
        event,
        query,
        note,
        document,
    };

    pub const Payload = union(Tag) {
        transaction: Transaction,
        open: Open,
        close: Close,
        commodity: Commodity,
        pad: Pad,
        pnl: Pnl,
        balance: Balance,
        price: PriceDecl,
        event: Event,
        query: Query,
        note: Note,
        document: Document,
    };

    /// Sort entries by date, then by "time of day": commodity/price/open/pnl < balance < tx < close.
    pub fn compare(self: Entry, other: Entry) bool {
        return switch (self.date.compare(other.date)) {
            .after => true,
            .before => false,
            .equal => timeOfDay(self.payload) < timeOfDay(other.payload),
        };
    }

    fn timeOfDay(p: Payload) u8 {
        return switch (p) {
            .commodity, .price, .open, .pnl => 0,
            .balance => 1,
            .close => 3,
            else => 2,
        };
    }
};

pub const Transaction = struct {
    flag: Ast.TokenIndex,
    payee: Ast.OptionalTokenIndex,
    narration: Ast.OptionalTokenIndex,
    /// Posting indices covered by this transaction, in `Data.postings`.
    postings: Range,
    /// Set by the balancer when the transaction cannot be solved.
    dirty: bool = false,
};

pub const Open = struct {
    account: Ast.TokenIndex,
    booking_method: ?Inventory.BookingMethod = null,
    /// Range into `Data.open_currencies`.
    currencies: Range,
};

pub const Close = struct {
    account: Ast.TokenIndex,
};

pub const Commodity = struct {
    currency: CurrencyIndex,
};

pub const Pad = struct {
    account: Ast.TokenIndex,
    pad_to: Ast.TokenIndex,
    /// Synthetic posting indices created by the balancer.
    pad_posting: OptionalPostingIndex = .none,
    pad_to_posting: OptionalPostingIndex = .none,
};

pub const Pnl = struct {
    account: Ast.TokenIndex,
    income_account: Ast.TokenIndex,
};

pub const Balance = struct {
    account: Ast.TokenIndex,
    amount: PackedNumber,
    amount_currency: CurrencyIndex,
    tolerance: PackedNumber,
};

pub const PriceDecl = struct {
    currency: CurrencyIndex,
    amount_currency: CurrencyIndex,
    amount_number: PackedNumber,
};

pub const Event = struct {
    variable: Ast.TokenIndex,
    value: Ast.TokenIndex,
};

pub const Query = struct {
    name: Ast.TokenIndex,
    sql: Ast.TokenIndex,
};

pub const Note = struct {
    account: Ast.TokenIndex,
    note: Ast.TokenIndex,
};

pub const Document = struct {
    account: Ast.TokenIndex,
    filename: Ast.TokenIndex,
};

// --- Posting ----------------------------------------------------------------

pub const Posting = struct {
    account: Ast.TokenIndex,
    flag: Ast.OptionalTokenIndex,
    amount_number: PackedNumber,
    amount_currency: OptionalCurrencyIndex,
    /// Index into `Data.prices`. `.none` for most postings.
    price: OptionalPriceIndex,
    /// Index into `Data.lot_specs`. `.none` for most postings.
    lot_spec: OptionalLotSpecIndex,
    /// Meta KV range in `Data.meta`. `isEmpty()` means no metadata.
    meta: Range,
    /// AST posting node for source recovery. `.none` for synthetic postings (pad, pnl).
    ast_node: Ast.Node.OptionalIndex = .none,

    pub fn simple(account: Ast.TokenIndex, number: Number, currency: CurrencyIndex) Posting {
        return .{
            .account = account,
            .flag = .none,
            .amount_number = PackedNumber.pack(number),
            .amount_currency = currency.toOptional(),
            .price = .none,
            .lot_spec = .none,
            .meta = Range.empty,
            .ast_node = .none,
        };
    }
};

pub const Price = struct {
    amount: ?Number,
    amount_currency: OptionalCurrencyIndex,
    total: bool, // true for @@ (total price), false for @ (per-unit)
};

pub const LotSpec = struct {
    price: ?Number,
    price_currency: OptionalCurrencyIndex,
    date: ?Date,
    label: Ast.OptionalTokenIndex,
};

// --- Auxiliary --------------------------------------------------------------

pub const TagLink = struct {
    kind: Kind,
    token: Ast.TokenIndex,
    /// True if written in source; false if added via `pushtag`.
    explicit: bool,

    pub const Kind = enum { tag, link };
};

pub const KeyValue = struct {
    key: Ast.TokenIndex,
    value: Ast.TokenIndex,
};

pub const Config = struct {
    alloc: Allocator,
    options: std.ArrayList(OptionPair),
    plugins: std.ArrayList([]const u8),

    pub const OptionPair = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn init(alloc: Allocator) Config {
        return .{
            .alloc = alloc,
            .options = .{},
            .plugins = .{},
        };
    }

    pub fn deinit(self: *Config) void {
        self.options.deinit(self.alloc);
        self.plugins.deinit(self.alloc);
    }

    pub fn clear(self: *Config) void {
        self.options.clearRetainingCapacity();
        self.plugins.clearRetainingCapacity();
    }

    pub fn addOption(self: *Config, key: []const u8, value: []const u8) !void {
        try self.options.append(self.alloc, .{ .key = key, .value = value });
    }

    pub fn addPlugin(self: *Config, plugin: []const u8) !void {
        try self.plugins.append(self.alloc, plugin);
    }

    pub fn getOperatingCurrencies(self: *const Config, alloc: Allocator) ![][]const u8 {
        var result: std.ArrayList([]const u8) = .{};
        defer result.deinit(alloc);
        for (self.options.items) |option| {
            const stripped_key = std.mem.trim(u8, option.key, "\"");
            const stripped_value = std.mem.trim(u8, option.value, "\"");
            if (std.mem.eql(u8, stripped_key, "operating_currency")) {
                try result.append(alloc, stripped_value);
            }
        }
        return result.toOwnedSlice(alloc);
    }
};

// --- init / deinit ----------------------------------------------------------

pub fn init(alloc: Allocator) !Self {
    var accounts = try AccountPool.init(alloc);
    errdefer accounts.deinit(alloc);

    var currencies = try CurrencyPool.init(alloc);
    errdefer currencies.deinit(alloc);

    return .{
        .alloc = alloc,
        .accounts = accounts,
        .currencies = currencies,
        .files = .{},
        .files_by_uri = std.StringHashMap(usize).init(alloc),
        .entries = .{},
        .postings = .{},
        .prices = .{},
        .lot_specs = .{},
        .open_currencies = .{},
        .tagslinks = .{},
        .meta = .{},
        .config = Config.init(alloc),
    };
}

pub fn deinit(self: *Self) void {
    for (self.files.items) |*f| f.deinit(self.alloc);
    self.files.deinit(self.alloc);
    self.files_by_uri.deinit();

    self.entries.deinit(self.alloc);
    self.postings.deinit(self.alloc);
    self.prices.deinit(self.alloc);
    self.lot_specs.deinit(self.alloc);
    self.open_currencies.deinit(self.alloc);
    self.tagslinks.deinit(self.alloc);
    self.meta.deinit(self.alloc);
    self.config.deinit();

    self.accounts.deinit(self.alloc);
    self.currencies.deinit(self.alloc);
}

/// Clear all merged-record arrays, but keep `files` and `files_by_uri` and the
/// intern pools intact. Used by `rebuildFromFiles` ahead of re-running Sema.
fn clearRecords(self: *Self) void {
    self.entries.clearRetainingCapacity();
    self.postings.clearRetainingCapacity();
    self.prices.clearRetainingCapacity();
    self.lot_specs.clearRetainingCapacity();
    self.open_currencies.clearRetainingCapacity();
    self.tagslinks.clearRetainingCapacity();
    self.meta.clearRetainingCapacity();
    self.config.clear();
}

/// Returns true if any file has a parse error.
pub fn hasFileErrors(self: *const Self) bool {
    for (self.files.items) |f| {
        if (f.errors.items.len > 0) return true;
    }
    return false;
}

// --- token / intern lookup helpers (project-level) --------------------------

pub const TokenLoc = struct { file_id: u8, index: Ast.TokenIndex };
pub const OptionalTokenLoc = struct { file_id: u8, index: Ast.OptionalTokenIndex };

pub fn token(self: *const Self, file_id: u8, index: Ast.TokenIndex) Lexer.Token {
    return self.files.items[file_id].token(index);
}

pub fn tokenSlice(self: *const Self, file_id: u8, index: Ast.TokenIndex) []const u8 {
    return self.files.items[file_id].tokenSlice(index);
}

pub fn optTokenSlice(self: *const Self, file_id: u8, index: Ast.OptionalTokenIndex) ?[]const u8 {
    return self.files.items[file_id].optTokenSlice(index);
}

pub fn accountText(self: *const Self, i: AccountIndex) []const u8 {
    return self.accounts.get(i);
}

pub fn currencyText(self: *const Self, i: CurrencyIndex) []const u8 {
    return self.currencies.get(i);
}

pub fn accountTextOpt(self: *const Self, oi: OptionalAccountIndex) ?[]const u8 {
    const i = oi.unwrap() orelse return null;
    return self.accountText(i);
}

pub fn currencyTextOpt(self: *const Self, oi: OptionalCurrencyIndex) ?[]const u8 {
    const i = oi.unwrap() orelse return null;
    return self.currencyText(i);
}

/// Alias for `currencyTextOpt`, kept for symmetry with callers that already
/// have an `OptionalCurrencyIndex` in hand.
pub fn optCurrencyText(self: *const Self, oi: OptionalCurrencyIndex) ?[]const u8 {
    return self.currencyTextOpt(oi);
}

/// Resolve an account token to its interned `AccountIndex`.
pub fn accountOf(self: *const Self, file_id: u8, tok: Ast.TokenIndex) AccountIndex {
    return self.files.items[file_id].accountOf(tok);
}

/// Resolve a currency token to its interned `CurrencyIndex`.
pub fn currencyOf(self: *const Self, file_id: u8, tok: Ast.TokenIndex) CurrencyIndex {
    return self.files.items[file_id].currencyOf(tok);
}

pub fn findAccount(self: *const Self, text: []const u8) ?AccountIndex {
    return self.accounts.find(text);
}

pub fn findCurrency(self: *const Self, text: []const u8) ?CurrencyIndex {
    return self.currencies.find(text);
}

// --- views and iterators ----------------------------------------------------

pub const EntryView = struct {
    data: *Self,
    idx: u32,

    pub fn date(v: EntryView) Date {
        return v.data.entries.items(.date)[v.idx];
    }

    pub fn mainToken(v: EntryView) Ast.TokenIndex {
        return v.data.entries.items(.main_token)[v.idx];
    }

    pub fn file(v: EntryView) u8 {
        return v.data.entries.items(.file)[v.idx];
    }

    /// Bundle a token index from this entry's file into a project-global
    /// `TokenLoc`. Use for raw payload tokens (e.g. `pnl.account`) that aren't
    /// exposed as a typed `*Loc()` helper on a sub-view.
    pub fn loc(v: EntryView, idx: Ast.TokenIndex) TokenLoc {
        return .{ .file_id = v.file(), .index = idx };
    }

    pub fn mainTokenLoc(v: EntryView) TokenLoc {
        return v.loc(v.mainToken());
    }

    pub fn tag(v: EntryView) Entry.Tag {
        return std.meta.activeTag(v.data.entries.items(.payload)[v.idx]);
    }

    pub fn payload(v: EntryView) PayloadView {
        const file_id = v.file();
        return switch (v.data.entries.items(.payload)[v.idx]) {
            .transaction => |*tx| .{ .transaction = .{ .data = v.data, .file = file_id, .tx = tx } },
            .open => |o| .{ .open = .{ .data = v.data, .file = file_id, .open = o } },
            .close => |c| .{ .close = .{ .data = v.data, .file = file_id, .close = c } },
            .commodity => |c| .{ .commodity = c },
            .pad => |*p| .{ .pad = .{ .data = v.data, .file = file_id, .pad = p } },
            .pnl => |p2| .{ .pnl = p2 },
            .balance => |b| .{ .balance = .{
                .data = v.data,
                .file = file_id,
                .account = v.data.files.items[file_id].accountOf(b.account),
                .account_token = b.account,
                .amount = b.amount.unpack() orelse unreachable,
                .amount_currency = b.amount_currency,
                .tolerance = b.tolerance.unpack(),
            } },
            .price => |pd| .{ .price = .{
                .data = v.data,
                .currency = pd.currency,
                .amount = pd.amount_number.unpack() orelse unreachable,
                .amount_currency = pd.amount_currency,
            } },
            .event => |e| .{ .event = e },
            .query => |q| .{ .query = q },
            .note => |n| .{ .note = n },
            .document => |d| .{ .document = d },
        };
    }

    pub fn tagslinks(v: EntryView) TagLinkIterator {
        const r = v.data.entries.items(.tagslinks)[v.idx];
        return .{ .data = v.data, .file = v.file(), .i = r.start, .end = r.end };
    }

    pub fn metaKVs(v: EntryView) MetaIterator {
        const r = v.data.entries.items(.meta)[v.idx];
        return .{ .data = v.data, .file = v.file(), .i = r.start, .end = r.end };
    }

    /// Posting iterator. Empty unless the entry is a transaction.
    pub fn postings(v: EntryView) PostingIterator {
        const p = v.data.entries.items(.payload)[v.idx];
        return switch (p) {
            .transaction => |tx| .{ .data = v.data, .file = v.file(), .i = tx.postings.start, .end = tx.postings.end },
            else => .{ .data = v.data, .file = v.file(), .i = 0, .end = 0 },
        };
    }

    /// Convenience: resolve a token from this entry's owning file.
    pub fn token(v: EntryView, idx: Ast.TokenIndex) Lexer.Token {
        return v.data.files.items[v.file()].token(idx);
    }

    pub fn tokenSlice(v: EntryView, idx: Ast.TokenIndex) []const u8 {
        return v.data.files.items[v.file()].tokenSlice(idx);
    }

    /// Position-stable hash suitable for tagging DOM ids in HTML output.
    /// Mirrors the pre-refactor behaviour (date + payee/narration / account text).
    pub fn hash(v: EntryView) u64 {
        var wy = std.hash.Wyhash.init(0);
        const d = v.date();
        wy.update(std.mem.asBytes(&d));
        const fdata = &v.data.files.items[v.file()];
        switch (v.data.entries.items(.payload)[v.idx]) {
            .transaction => |tx| {
                if (fdata.optTokenSlice(tx.payee)) |payee| wy.update(payee);
                if (fdata.optTokenSlice(tx.narration)) |narration| wy.update(narration);
            },
            .open => |open| {
                wy.update(fdata.tokenSlice(open.account));
            },
            else => {},
        }
        return wy.final();
    }
};

/// Decoded payload — same discriminant as `Entry.Tag`. Transaction/Open
/// carry iterators over their children; Balance/PriceDecl have their numeric
/// extras already unpacked.
pub const PayloadView = union(Entry.Tag) {
    transaction: TransactionView,
    open: OpenView,
    close: CloseView,
    commodity: Commodity,
    pad: PadView,
    pnl: Pnl,
    balance: BalanceView,
    price: PriceDeclView,
    event: Event,
    query: Query,
    note: Note,
    document: Document,
};

pub const TransactionView = struct {
    data: *Self,
    file: u8,
    tx: *Transaction,

    pub fn postings(v: TransactionView) PostingIterator {
        return .{ .data = v.data, .file = v.file, .i = v.tx.postings.start, .end = v.tx.postings.end };
    }

    pub fn numPostings(v: TransactionView) usize {
        return v.tx.postings.end - v.tx.postings.start;
    }

    pub fn dirty(v: TransactionView) bool {
        return v.tx.dirty;
    }

    pub fn dirtyPtr(v: TransactionView) *bool {
        return &v.tx.dirty;
    }

    pub fn payeeText(v: TransactionView) ?[]const u8 {
        const i = v.tx.payee.unwrap() orelse return null;
        return v.data.files.items[v.file].tokenSlice(i);
    }

    pub fn narrationText(v: TransactionView) ?[]const u8 {
        const i = v.tx.narration.unwrap() orelse return null;
        return v.data.files.items[v.file].tokenSlice(i);
    }

    pub fn flagSlice(v: TransactionView) []const u8 {
        return v.data.files.items[v.file].tokenSlice(v.tx.flag);
    }

    pub fn addPnlPostings(v: TransactionView, ps: []Posting) !void {
        if (ps.len == 0) return;
        const start = v.data.postings.len;
        for (v.tx.postings.start..v.tx.postings.end) |i| {
            _ = try v.data.appendPosting(v.data.postings.get(i));
        }
        for (ps) |p| {
            _ = try v.data.appendPosting(p);
        }
        v.tx.postings = .{
            .start = @intCast(start),
            .end = @intCast(v.data.postings.len),
        };
    }
};

pub const OpenView = struct {
    data: *const Self,
    file: u8,
    open: Open,

    pub fn currencies(v: OpenView) ?[]const CurrencyIndex {
        if (v.open.currencies.start == v.open.currencies.end) return null;
        return v.data.open_currencies.items[v.open.currencies.start..v.open.currencies.end];
    }

    pub fn bookingMethod(v: OpenView) ?Inventory.BookingMethod {
        return v.open.booking_method;
    }

    pub fn account(v: OpenView) AccountIndex {
        return v.data.files.items[v.file].accountOf(v.open.account);
    }

    pub fn accountTokenIndex(v: OpenView) Ast.TokenIndex {
        return v.open.account;
    }

    pub fn accountLoc(v: OpenView) TokenLoc {
        return .{ .file_id = v.file, .index = v.open.account };
    }

    pub fn accountText(v: OpenView) []const u8 {
        return v.data.files.items[v.file].tokenSlice(v.open.account);
    }
};

pub const CloseView = struct {
    data: *const Self,
    file: u8,
    close: Close,

    pub fn account(v: CloseView) AccountIndex {
        return v.data.files.items[v.file].accountOf(v.close.account);
    }

    pub fn accountTokenIndex(v: CloseView) Ast.TokenIndex {
        return v.close.account;
    }

    pub fn accountLoc(v: CloseView) TokenLoc {
        return .{ .file_id = v.file, .index = v.close.account };
    }

    pub fn accountText(v: CloseView) []const u8 {
        return v.data.files.items[v.file].tokenSlice(v.close.account);
    }
};

pub const PadView = struct {
    data: *Self,
    file: u8,
    pad: *Pad,

    pub fn account(v: PadView) AccountIndex {
        return v.data.files.items[v.file].accountOf(v.pad.account);
    }

    pub fn accountTokenIndex(v: PadView) Ast.TokenIndex {
        return v.pad.account;
    }

    pub fn accountLoc(v: PadView) TokenLoc {
        return .{ .file_id = v.file, .index = v.pad.account };
    }

    pub fn setPadAmount(v: PadView, number: Number, currency: CurrencyIndex) !void {
        const p = try v.newPosting(v.pad.account, number, currency);
        v.pad.pad_posting = p.toOptional();
    }

    pub fn padPosting(v: PadView) ?PostingView {
        const i = v.pad.pad_posting.unwrap() orelse return null;
        return .{ .data = v.data, .file = v.file, .idx = @intFromEnum(i) };
    }

    pub fn padToAccount(v: PadView) AccountIndex {
        return v.data.files.items[v.file].accountOf(v.pad.pad_to);
    }

    pub fn padToAccountTokenIndex(v: PadView) Ast.TokenIndex {
        return v.pad.pad_to;
    }

    pub fn padToAccountLoc(v: PadView) TokenLoc {
        return .{ .file_id = v.file, .index = v.pad.pad_to };
    }

    pub fn setPadToAmount(v: PadView, number: Number, currency: CurrencyIndex) !void {
        const p = try v.newPosting(v.pad.pad_to, number, currency);
        v.pad.pad_to_posting = p.toOptional();
    }

    pub fn padToPosting(v: PadView) ?PostingView {
        const i = v.pad.pad_to_posting.unwrap() orelse return null;
        return .{ .data = v.data, .file = v.file, .idx = @intFromEnum(i) };
    }

    fn newPosting(
        v: PadView,
        acc: Ast.TokenIndex,
        number: Number,
        currency: CurrencyIndex,
    ) !PostingIndex {
        return v.data.appendPosting(Posting.simple(acc, number, currency));
    }
};

pub const BalanceView = struct {
    data: *const Self,
    file: u8,
    account: AccountIndex,
    /// Source token for the account (for error reporting).
    account_token: Ast.TokenIndex,
    amount: Number,
    amount_currency: CurrencyIndex,
    tolerance: ?Number,

    pub fn accountText(v: BalanceView) []const u8 {
        return v.data.files.items[v.file].tokenSlice(v.account_token);
    }

    pub fn accountLoc(v: BalanceView) TokenLoc {
        return .{ .file_id = v.file, .index = v.account_token };
    }

    pub fn amountCurrencyText(v: BalanceView) ?[]const u8 {
        return v.data.currencyTextOpt(v.amount_currency);
    }
};

pub const PriceDeclView = struct {
    data: *const Self,
    currency: CurrencyIndex,
    amount: Number,
    amount_currency: CurrencyIndex,

    pub fn currencyText(v: PriceDeclView) []const u8 {
        return v.data.currencyText(v.currency);
    }

    pub fn amountCurrencyText(v: PriceDeclView) []const u8 {
        return v.data.currencyText(v.amount_currency);
    }
};

/// Resolved lot spec. Carries both the typed index and a `data` pointer so
/// consumers can get text via `*Text()` helpers without re-interning.
pub const LotSpecView = struct {
    data: *const Self,
    file: u8,
    price: ?Number,
    price_currency: OptionalCurrencyIndex,
    date: ?Date,
    label: Ast.OptionalTokenIndex,

    pub fn priceCurrencyText(v: LotSpecView) ?[]const u8 {
        return v.data.currencyTextOpt(v.price_currency);
    }

    pub fn labelText(v: LotSpecView) ?[]const u8 {
        return v.data.files.items[v.file].optTokenSlice(v.label);
    }
};

/// Resolved price annotation.
pub const PriceView = struct {
    data: *const Self,
    amount: ?Number,
    amount_currency: OptionalCurrencyIndex,
    total: bool,

    pub fn amountCurrencyText(v: PriceView) ?[]const u8 {
        return v.data.currencyTextOpt(v.amount_currency);
    }
};

/// Lightweight handle for a posting. Hot fields resolved on demand;
/// `price` and `lot_spec` lazily decoded from `extra`.
pub const PostingView = struct {
    data: *const Self,
    file: u8,
    idx: u32,

    pub fn accountToken(v: PostingView) Ast.TokenIndex {
        return v.data.postings.items(.account)[v.idx];
    }

    pub fn accountLoc(v: PostingView) TokenLoc {
        return .{ .file_id = v.file, .index = v.accountToken() };
    }

    pub fn account(v: PostingView) AccountIndex {
        return v.data.files.items[v.file].accountOf(v.accountToken());
    }

    pub fn accountText(v: PostingView) []const u8 {
        return v.data.files.items[v.file].tokenSlice(v.accountToken());
    }

    pub fn flag(v: PostingView) Ast.OptionalTokenIndex {
        return v.data.postings.items(.flag)[v.idx];
    }

    pub fn amountNumber(v: PostingView) ?Number {
        return v.data.postings.items(.amount_number)[v.idx].unpack();
    }

    pub fn amountCurrency(v: PostingView) OptionalCurrencyIndex {
        return v.data.postings.items(.amount_currency)[v.idx];
    }

    pub fn amountCurrencyText(v: PostingView) ?[]const u8 {
        return v.data.currencyTextOpt(v.amountCurrency());
    }

    pub fn astNode(v: PostingView) Ast.Node.OptionalIndex {
        return v.data.postings.items(.ast_node)[v.idx];
    }

    pub fn price(v: PostingView) ?PriceView {
        const opt = v.data.postings.items(.price)[v.idx];
        const idx = opt.unwrap() orelse return null;
        const p = v.data.prices.items[@intFromEnum(idx)];
        return .{
            .data = v.data,
            .amount = p.amount,
            .amount_currency = p.amount_currency,
            .total = p.total,
        };
    }

    pub fn lotSpec(v: PostingView) ?LotSpecView {
        const opt = v.data.postings.items(.lot_spec)[v.idx];
        const idx = opt.unwrap() orelse return null;
        const ls = v.data.lot_specs.items[@intFromEnum(idx)];
        return .{
            .data = v.data,
            .file = v.file,
            .price = ls.price,
            .price_currency = ls.price_currency,
            .date = ls.date,
            .label = ls.label,
        };
    }

    pub fn metaKVs(v: PostingView) MetaIterator {
        const r = v.data.postings.items(.meta)[v.idx];
        return .{ .data = v.data, .file = v.file, .i = r.start, .end = r.end };
    }
};

pub const TagLinkView = struct {
    data: *const Self,
    file: u8,
    kind: TagLink.Kind,
    token: Ast.TokenIndex,
    explicit: bool,

    pub fn slice(v: TagLinkView) []const u8 {
        return v.data.files.items[v.file].tokenSlice(v.token);
    }
};

pub const KeyValueView = struct {
    key: Ast.TokenIndex,
    value: Ast.TokenIndex,
};

// --- iterators --------------------------------------------------------------

pub const EntryIterator = struct {
    data: *Self,
    i: u32,
    end: u32,

    pub fn next(it: *EntryIterator) ?EntryView {
        if (it.i >= it.end) return null;
        const v = EntryView{ .data = it.data, .idx = it.i };
        it.i += 1;
        return v;
    }
};

pub fn EntriesOfKindIterator(comptime kind: Entry.Tag) type {
    return struct {
        data: *Self,
        i: u32,
        end: u32,

        pub fn next(it: *@This()) ?EntryView {
            const payloads = it.data.entries.items(.payload);
            while (it.i < it.end) {
                if (std.meta.activeTag(payloads[it.i]) == kind) {
                    const v = EntryView{ .data = it.data, .idx = it.i };
                    it.i += 1;
                    return v;
                }
                it.i += 1;
            }
            return null;
        }
    };
}

pub const PostingIterator = struct {
    data: *const Self,
    file: u8,
    i: u32,
    end: u32,

    pub fn next(it: *PostingIterator) ?PostingView {
        if (it.i >= it.end) return null;
        const v = PostingView{ .data = it.data, .file = it.file, .idx = it.i };
        it.i += 1;
        return v;
    }

    pub fn remaining(it: *PostingIterator) usize {
        return it.end - it.i;
    }
};

pub const TagLinkIterator = struct {
    data: *const Self,
    file: u8,
    i: u32,
    end: u32,

    pub fn next(it: *TagLinkIterator) ?TagLinkView {
        if (it.i >= it.end) return null;
        const v = TagLinkView{
            .data = it.data,
            .file = it.file,
            .kind = it.data.tagslinks.items(.kind)[it.i],
            .token = it.data.tagslinks.items(.token)[it.i],
            .explicit = it.data.tagslinks.items(.explicit)[it.i],
        };
        it.i += 1;
        return v;
    }
};

pub const MetaIterator = struct {
    data: *const Self,
    file: u8,
    i: u32,
    end: u32,

    pub fn next(it: *MetaIterator) ?KeyValueView {
        if (it.i >= it.end) return null;
        const v = KeyValueView{
            .key = it.data.meta.items(.key)[it.i],
            .value = it.data.meta.items(.value)[it.i],
        };
        it.i += 1;
        return v;
    }
};

pub fn iterEntries(self: *Self) EntryIterator {
    return .{ .data = self, .i = 0, .end = @intCast(self.entries.len) };
}

pub fn iterEntriesOfKind(self: *Self, comptime kind: Entry.Tag) EntriesOfKindIterator(kind) {
    return .{ .data = self, .i = 0, .end = @intCast(self.entries.len) };
}

pub fn entryAt(self: *Self, idx: u32) EntryView {
    return .{ .data = self, .idx = idx };
}

pub fn postingAt(self: *Self, file_id: u8, idx: u32) PostingView {
    return .{ .data = self, .file = file_id, .idx = idx };
}

// --- file loading -----------------------------------------------------------

/// Add a new file to the project: parse its source, run Sema (which appends
/// entries/postings/etc into the merged arrays), and return its file index
/// alongside the list of `include` directives encountered.
///
/// Takes ownership of `uri` (cloned internally is the caller's responsibility)
/// and of `source`. Caller must check capacity (file_id fits in u8).
pub fn loadFile(
    self: *Self,
    uri: Uri,
    is_root: bool,
    source: [:0]const u8,
) !struct { usize, Imports } {
    const tracy_zone = ztracy.ZoneNC(@src(), "Data.loadFile", 0x00_00_ff_00);
    defer tracy_zone.End();

    var file = try File.loadFromSource(self.alloc, uri, source);
    errdefer file.deinit(self.alloc);

    try self.files.append(self.alloc, file);
    const file_id = self.files.items.len - 1;
    if (file_id >= std.math.maxInt(u8)) return error.TooManyFiles;
    try self.files_by_uri.put(self.files.items[file_id].uri.value, file_id);

    var sem = Sema.init(self.alloc, self, @intCast(file_id), is_root);
    defer sem.deinit();
    const imports = try sem.run();
    return .{ file_id, imports };
}

/// Replace one file's source and rebuild all merged record arrays from
/// scratch by re-running Sema over every file in original order. Takes
/// ownership of `source`.
pub fn updateFile(self: *Self, uri_value: []const u8, source: [:0]const u8) !void {
    const tracy_zone = ztracy.ZoneNC(@src(), "Data.updateFile", 0x00_00_ff_00);
    defer tracy_zone.End();

    const file_id = self.files_by_uri.get(uri_value) orelse return error.FileNotFound;
    const old_uri = self.files.items[file_id].uri;
    const cloned_uri = try old_uri.clone(self.alloc);
    var new_file = File.loadFromSource(self.alloc, cloned_uri, source) catch |err| {
        var u = cloned_uri;
        u.deinit(self.alloc);
        return err;
    };
    errdefer new_file.deinit(self.alloc);

    // Replace file. The hashmap key (uri.value) is the same string contents,
    // but cloning gave us a fresh allocation; rewire the map to the new key
    // so it stays valid after the old file is freed.
    _ = self.files_by_uri.remove(uri_value);
    var old_file = self.files.items[file_id];
    self.files.items[file_id] = new_file;
    old_file.deinit(self.alloc);
    try self.files_by_uri.put(self.files.items[file_id].uri.value, file_id);

    try self.rebuildFromFiles();
}

/// Clear all merged record arrays and re-run Sema over every file in order.
/// Files (their Asts/sources) are kept; only the semantic layer is rebuilt.
fn rebuildFromFiles(self: *Self) !void {
    const tracy_zone = ztracy.ZoneNC(@src(), "Data.rebuildFromFiles", 0x00_00_ff_00);
    defer tracy_zone.End();

    self.clearRecords();
    // Reset per-file token_interned tables (the indices are about to be
    // re-assigned by Sema).
    for (self.files.items) |*f| {
        const n = f.ast.tokens.items.len;
        f.token_interned.clearRetainingCapacity();
        try f.token_interned.appendNTimes(self.alloc, std.math.maxInt(u32), n);
    }

    for (self.files.items, 0..) |_, i| {
        const is_root = i == 0;
        var sem = Sema.init(self.alloc, self, @intCast(i), is_root);
        defer sem.deinit();
        const imports = try sem.run();
        // Imports are tracked from the outer Project on initial load, but on
        // rebuild we don't currently re-walk them; the file set is unchanged.
        self.alloc.free(imports);
    }
}

/// Append a synthetic posting (pad, pnl). Returns the new index.
pub fn appendPosting(self: *Self, p: Posting) !PostingIndex {
    const idx: PostingIndex = @enumFromInt(self.postings.len);
    try self.postings.append(self.alloc, p);
    return idx;
}

/// Intern a (possibly-null) currency text, returning an `OptionalCurrencyIndex`.
pub fn internCurrencyOpt(self: *Self, text: ?[]const u8) !OptionalCurrencyIndex {
    const t = text orelse return .none;
    const idx = try self.currencies.intern(self.alloc, t);
    return idx.toOptional();
}

comptime {
    // Document and guard current sizes. Bump these intentionally if the
    // layout changes; accidental growth should fail here.
    std.debug.assert(@sizeOf(Entry) == 68);
    std.debug.assert(@sizeOf(Entry.Payload) == 36); // sized by Balance (32) + tag byte
    std.debug.assert(@sizeOf(Posting) == 44);
    std.debug.assert(@sizeOf(LotSpec) == 48);
    std.debug.assert(@sizeOf(TagLink) == 8);
    std.debug.assert(@sizeOf(KeyValue) == 8);
}

/// 3-u32 packing of `?Number`. `precision == maxInt(u32)` encodes `null`.
pub const PackedNumber = struct {
    lo: u32,
    hi: u32,
    precision: u32,

    pub const none: PackedNumber = .{ .lo = 0, .hi = 0, .precision = std.math.maxInt(u32) };

    pub fn pack(n: ?Number) PackedNumber {
        const num = n orelse return .none;
        const bits: u64 = @bitCast(num.value);
        return .{
            .lo = @truncate(bits),
            .hi = @truncate(bits >> 32),
            .precision = num.precision,
        };
    }

    pub fn unpack(p: PackedNumber) ?Number {
        if (p.precision == std.math.maxInt(u32)) return null;
        const bits: u64 = (@as(u64, p.hi) << 32) | @as(u64, p.lo);
        return .{ .value = @bitCast(bits), .precision = p.precision };
    }
};

test "PackedNumber round-trips" {
    const cases = [_]?Number{
        null,
        .{ .value = 0, .precision = 0 },
        .{ .value = 12345, .precision = 2 },
        .{ .value = -99999999999, .precision = 4 },
        .{ .value = std.math.maxInt(i64), .precision = 9 },
        .{ .value = std.math.minInt(i64), .precision = 0 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c, PackedNumber.pack(c).unpack());
    }
}
