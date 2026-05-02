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

const Sema = @import("Sema.zig");
const Solver = @import("solver.zig").Solver;
const Parser = @import("Parser.zig");

const Self = @This();

alloc: Allocator,
source: [:0]const u8,
uri: Uri,
ast: Ast,

/// Project-wide intern pools, borrowed. The `Project` owns them; `Data` just
/// reads/writes through the pointer so indices are comparable across files.
accounts: *AccountPool,
currencies: *CurrencyPool,
/// Parallel to `ast.tokens`; interpretation depends on the token's tag.
token_interned: std.ArrayList(u32),

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
errors: std.ArrayList(ErrorDetails),

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

/// Takes ownership of `ast`. The pools are borrowed — caller (Project) owns
/// them and must outlive this `Data`.
pub fn init(alloc: Allocator, ast: Ast, uri: Uri, accounts: *AccountPool, currencies: *CurrencyPool) !Self {
    var token_interned: std.ArrayList(u32) = .{};
    errdefer token_interned.deinit(alloc);
    try token_interned.appendNTimes(alloc, std.math.maxInt(u32), ast.tokens.items.len);

    const errors = try ast.errors.clone(alloc);

    return .{
        .alloc = alloc,
        .source = ast.source,
        .uri = uri,
        .ast = ast,
        .accounts = accounts,
        .currencies = currencies,
        .token_interned = token_interned,
        .entries = .{},
        .postings = .{},
        .prices = .{},
        .lot_specs = .{},
        .open_currencies = .{},
        .tagslinks = .{},
        .meta = .{},
        .config = Config.init(alloc),
        .errors = errors,
    };
}

pub fn deinit(self: *Self) void {
    self.alloc.free(self.source);
    self.ast.deinit();
    self.token_interned.deinit(self.alloc);
    self.entries.deinit(self.alloc);
    self.postings.deinit(self.alloc);
    self.prices.deinit(self.alloc);
    self.lot_specs.deinit(self.alloc);
    self.open_currencies.deinit(self.alloc);
    self.tagslinks.deinit(self.alloc);
    self.meta.deinit(self.alloc);
    self.config.deinit();
    self.errors.deinit(self.alloc);
}

pub fn token(self: *const Self, index: Ast.TokenIndex) Lexer.Token {
    return self.ast.tokens.items[@intFromEnum(index)];
}

pub fn tokenSlice(self: *const Self, index: Ast.TokenIndex) []const u8 {
    return self.token(index).slice;
}

pub fn optTokenSlice(self: *const Self, index: Ast.OptionalTokenIndex) ?[]const u8 {
    const i = index.unwrap() orelse return null;
    return self.tokenSlice(i);
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

/// Resolve an account token to its interned `AccountIndex` via the side-table.
pub fn accountOf(self: *const Self, tok: Ast.TokenIndex) AccountIndex {
    return @enumFromInt(self.token_interned.items[@intFromEnum(tok)]);
}

/// Resolve a currency token to its interned `CurrencyIndex` via the side-table.
pub fn currencyOf(self: *const Self, tok: Ast.TokenIndex) CurrencyIndex {
    return @enumFromInt(self.token_interned.items[@intFromEnum(tok)]);
}

pub fn addError(self: *Self, tok: Ast.TokenIndex, uri: Uri, tag: ErrorDetails.Tag) !void {
    try self.errors.append(self.alloc, .{
        .tag = tag,
        .token = self.token(tok),
        .uri = uri,
        .source = self.source,
    });
}

pub fn addWarning(self: *Self, tok: Ast.TokenIndex, uri: Uri, tag: ErrorDetails.Tag) !void {
    try self.errors.append(self.alloc, .{
        .tag = tag,
        .severity = .warn,
        .token = self.token(tok),
        .uri = uri,
        .source = self.source,
    });
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

    pub fn tag(v: EntryView) Entry.Tag {
        return std.meta.activeTag(v.data.entries.items(.payload)[v.idx]);
    }

    pub fn payload(v: EntryView) PayloadView {
        return switch (v.data.entries.items(.payload)[v.idx]) {
            .transaction => |*tx| .{ .transaction = .{ .data = v.data, .tx = tx } },
            .open => |o| .{ .open = .{ .data = v.data, .open = o } },
            .close => |c| .{ .close = .{ .data = v.data, .close = c } },
            .commodity => |c| .{ .commodity = c },
            .pad => |*p| .{ .pad = .{ .data = v.data, .pad = p } },
            .pnl => |p2| .{ .pnl = p2 },
            .balance => |b| .{ .balance = .{
                .data = v.data,
                .account = v.data.accountOf(b.account),
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
        return .{ .data = v.data, .i = r.start, .end = r.end };
    }

    pub fn metaKVs(v: EntryView) MetaIterator {
        const r = v.data.entries.items(.meta)[v.idx];
        return .{ .data = v.data, .i = r.start, .end = r.end };
    }

    /// Posting iterator. Empty unless the entry is a transaction.
    pub fn postings(v: EntryView) PostingIterator {
        const p = v.data.entries.items(.payload)[v.idx];
        return switch (p) {
            .transaction => |tx| .{ .data = v.data, .i = tx.postings.start, .end = tx.postings.end },
            else => .{ .data = v.data, .i = 0, .end = 0 },
        };
    }

    /// Position-stable hash suitable for tagging DOM ids in HTML output.
    /// Mirrors the pre-refactor behaviour (date + payee/narration / account text).
    pub fn hash(v: EntryView) u64 {
        var wy = std.hash.Wyhash.init(0);
        const d = v.date();
        wy.update(std.mem.asBytes(&d));
        switch (v.data.entries.items(.payload)[v.idx]) {
            .transaction => |tx| {
                if (v.data.optTokenSlice(tx.payee)) |payee| wy.update(payee);
                if (v.data.optTokenSlice(tx.narration)) |narration| wy.update(narration);
            },
            .open => |open| {
                wy.update(v.data.tokenSlice(open.account));
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
    tx: *Transaction,

    pub fn postings(v: TransactionView) PostingIterator {
        return .{ .data = v.data, .i = v.tx.postings.start, .end = v.tx.postings.end };
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
        return v.data.tokenSlice(i);
    }

    pub fn narrationText(v: TransactionView) ?[]const u8 {
        const i = v.tx.narration.unwrap() orelse return null;
        return v.data.tokenSlice(i);
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
    open: Open,

    pub fn currencies(v: OpenView) ?[]const CurrencyIndex {
        if (v.open.currencies.start == v.open.currencies.end) return null;
        return v.data.open_currencies.items[v.open.currencies.start..v.open.currencies.end];
    }

    pub fn bookingMethod(v: OpenView) ?Inventory.BookingMethod {
        return v.open.booking_method;
    }

    pub fn account(v: OpenView) AccountIndex {
        return v.data.accountOf(v.open.account);
    }

    pub fn accountTokenIndex(v: OpenView) Ast.TokenIndex {
        return v.open.account;
    }

    pub fn accountText(v: OpenView) []const u8 {
        return v.data.tokenSlice(v.open.account);
    }
};

pub const CloseView = struct {
    data: *const Self,
    close: Close,

    pub fn account(v: CloseView) AccountIndex {
        return v.data.accountOf(v.close.account);
    }

    pub fn accountTokenIndex(v: CloseView) Ast.TokenIndex {
        return v.close.account;
    }

    pub fn accountText(v: CloseView) []const u8 {
        return v.data.tokenSlice(v.close.account);
    }
};

pub const PadView = struct {
    data: *Self,
    pad: *Pad,

    pub fn account(v: PadView) AccountIndex {
        return v.data.accountOf(v.pad.account);
    }

    pub fn accountTokenIndex(v: PadView) Ast.TokenIndex {
        return v.pad.account;
    }

    pub fn setPadAmount(v: PadView, number: Number, currency: CurrencyIndex) !void {
        const p = try v.newPosting(v.pad.account, number, currency);
        v.pad.pad_posting = p.toOptional();
    }

    pub fn padPosting(v: PadView) ?PostingView {
        const i = v.pad.pad_posting.unwrap() orelse return null;
        return v.data.postingAt(@intFromEnum(i));
    }

    pub fn padToAccount(v: PadView) AccountIndex {
        return v.data.accountOf(v.pad.pad_to);
    }

    pub fn padToAccountTokenIndex(v: PadView) Ast.TokenIndex {
        return v.pad.pad_to;
    }

    pub fn setPadToAmount(v: PadView, number: Number, currency: CurrencyIndex) !void {
        const p = try v.newPosting(v.pad.pad_to, number, currency);
        v.pad.pad_to_posting = p.toOptional();
    }

    pub fn padToPosting(v: PadView) ?PostingView {
        const i = v.pad.pad_to_posting.unwrap() orelse return null;
        return v.data.postingAt(@intFromEnum(i));
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
    account: AccountIndex,
    /// Source token for the account (for error reporting).
    account_token: Ast.TokenIndex,
    amount: Number,
    amount_currency: CurrencyIndex,
    tolerance: ?Number,

    pub fn accountText(v: BalanceView) []const u8 {
        return v.data.tokenSlice(v.account_token);
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
    price: ?Number,
    price_currency: OptionalCurrencyIndex,
    date: ?Date,
    label: Ast.OptionalTokenIndex,

    pub fn priceCurrencyText(v: LotSpecView) ?[]const u8 {
        return v.data.currencyTextOpt(v.price_currency);
    }

    pub fn labelText(v: LotSpecView) ?[]const u8 {
        return v.data.optTokenSlice(v.label);
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
    idx: u32,

    pub fn accountToken(v: PostingView) Ast.TokenIndex {
        return v.data.postings.items(.account)[v.idx];
    }

    pub fn account(v: PostingView) AccountIndex {
        return v.data.accountOf(v.accountToken());
    }

    pub fn accountText(v: PostingView) []const u8 {
        return v.data.tokenSlice(v.accountToken());
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
            .price = ls.price,
            .price_currency = ls.price_currency,
            .date = ls.date,
            .label = ls.label,
        };
    }

    pub fn metaKVs(v: PostingView) MetaIterator {
        const r = v.data.postings.items(.meta)[v.idx];
        return .{ .data = v.data, .i = r.start, .end = r.end };
    }
};

pub const TagLinkView = struct {
    kind: TagLink.Kind,
    token: Ast.TokenIndex,
    explicit: bool,
};

pub const KeyValueView = struct {
    key: Ast.TokenIndex,
    value: Ast.TokenIndex,
};

// --- iterators --------------------------------------------------------------

pub const EntryIterator = struct {
    data: *const Self,
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
    i: u32,
    end: u32,

    pub fn next(it: *PostingIterator) ?PostingView {
        if (it.i >= it.end) return null;
        const v = PostingView{ .data = it.data, .idx = it.i };
        it.i += 1;
        return v;
    }

    pub fn remaining(it: *PostingIterator) usize {
        return it.end - it.i;
    }
};

pub const TagLinkIterator = struct {
    data: *const Self,
    i: u32,
    end: u32,

    pub fn next(it: *TagLinkIterator) ?TagLinkView {
        if (it.i >= it.end) return null;
        const v = TagLinkView{
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

pub fn iterEntries(self: *const Self) EntryIterator {
    return .{ .data = self, .i = 0, .end = @intCast(self.entries.len) };
}

pub fn iterEntriesOfKind(self: *Self, comptime kind: Entry.Tag) EntriesOfKindIterator(kind) {
    return .{ .data = self, .i = 0, .end = @intCast(self.entries.len) };
}

pub fn entryAt(self: *Self, idx: u32) EntryView {
    return .{ .data = self, .idx = idx };
}

pub fn postingAt(self: *const Self, idx: u32) PostingView {
    return .{ .data = self, .idx = idx };
}

// --- mutators ---------------------------------------------------------------
//
// Views are read-only by convention. The few places that need to mutate
// entry-level state go through these named helpers so the mutation is obvious
// in a reader's grep.

/// Mark a transaction as unbalanced. Asserts the entry is a transaction.
pub fn markDirty(self: *Self, entry_idx: u32) void {
    const payloads = self.entries.items(.payload);
    std.debug.assert(std.meta.activeTag(payloads[entry_idx]) == .transaction);
    payloads[entry_idx].transaction.dirty = true;
}

/// Alias for `currencyTextOpt`, kept for symmetry with callers that already
/// have an `OptionalCurrencyIndex` in hand.
pub fn optCurrencyText(self: *const Self, oi: OptionalCurrencyIndex) ?[]const u8 {
    return self.currencyTextOpt(oi);
}

// --- construction helpers ---------------------------------------------------

/// Parse + run Sema. Takes ownership of `source`. Pools are borrowed from
/// the caller (Project), so indices produced during Sema are comparable
/// across files.
pub fn loadSource(
    alloc: Allocator,
    accounts: *AccountPool,
    currencies: *CurrencyPool,
    uri: Uri,
    source: [:0]const u8,
    is_root: bool,
) !struct { Self, Imports } {
    var ast = try Ast.parse(alloc, uri, source);
    errdefer ast.deinit();

    var data = try init(alloc, ast, uri, accounts, currencies);
    errdefer data.deinit();

    var sem = Sema.init(alloc, &data, is_root);
    defer sem.deinit();

    const imports = try sem.run();
    return .{ data, imports };
}

/// Append a synthetic posting (pad, pnl). Returns the new index.
pub fn appendPosting(self: *Self, p: Posting) !PostingIndex {
    const idx: PostingIndex = @enumFromInt(self.postings.len);
    try self.postings.append(self.alloc, p);
    return idx;
}

/// Run the balancer over every transaction, solving for unknown numbers and
/// currencies. Sets `dirty = true` on transactions that cannot be solved.
pub fn balanceTransactions(self: *Self) !void {
    var solver = Solver.init(self.alloc);
    defer solver.deinit();
    var diagnostics: Solver.CurrencyImbalance = undefined;

    var one: ?Number = Number.fromFloat(1);

    // Stable, reused per-tx staging buffers. We ensureTotalCapacity before
    // filling so that the pointers we hand to the solver stay valid during
    // `solve()`.
    var stage_numbers: std.ArrayList(?Number) = .{};
    defer stage_numbers.deinit(self.alloc);
    var stage_currencies: std.ArrayList(?[]const u8) = .{};
    defer stage_currencies.deinit(self.alloc);
    var stage_prices: std.ArrayList(?Number) = .{};
    defer stage_prices.deinit(self.alloc);
    var stage_price_currencies: std.ArrayList(?[]const u8) = .{};
    defer stage_price_currencies.deinit(self.alloc);

    const payloads = self.entries.items(.payload);
    const main_tokens = self.entries.items(.main_token);

    entries: for (payloads, 0..) |*ep, entry_idx| {
        if (std.meta.activeTag(ep.*) != .transaction) continue;
        const tx = &ep.transaction;
        const postings = tx.postings;
        if (postings.isEmpty()) continue;

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
            stage_numbers.appendAssumeCapacity(self.postings.items(.amount_number)[i].unpack());
            stage_currencies.appendAssumeCapacity(self.optCurrencyText(self.postings.items(.amount_currency)[i]));

            if (self.postings.items(.price)[i].unwrap()) |pidx| {
                const pr = self.prices.items[@intFromEnum(pidx)];
                stage_prices.appendAssumeCapacity(pr.amount);
                stage_price_currencies.appendAssumeCapacity(self.optCurrencyText(pr.amount_currency));
            } else {
                stage_prices.appendAssumeCapacity(null);
                stage_price_currencies.appendAssumeCapacity(null);
            }
        }

        for (postings.start..postings.end, 0..) |i, k| {
            const has_price = self.postings.items(.price)[i].unwrap() != null;
            var price_ptr: *?Number = undefined;
            var currency_ptr: *?[]const u8 = undefined;
            var rounding_currency: ?[]const u8 = null;

            if (has_price) {
                if (stage_currencies.items[k] == null) {
                    try self.addError(self.postings.items(.account)[i], self.uri, .cannot_infer_amount_currency_when_price_set);
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
            try self.addError(main_tokens[entry_idx], self.uri, tag);
            continue;
        };

        // Write solved values back.
        for (postings.start..postings.end, 0..) |i, k| {
            self.postings.items(.amount_number)[i] = PackedNumber.pack(stage_numbers.items[k]);
            self.postings.items(.amount_currency)[i] = try self.internCurrencyOpt(stage_currencies.items[k]);
            if (self.postings.items(.price)[i].unwrap()) |pidx| {
                const p_ptr = &self.prices.items[@intFromEnum(pidx)];
                p_ptr.amount = stage_prices.items[k];
                p_ptr.amount_currency = try self.internCurrencyOpt(stage_price_currencies.items[k]);
            }
        }
    }
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
    std.debug.assert(@sizeOf(Entry) == 64);
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
