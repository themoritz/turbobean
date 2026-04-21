const std = @import("std");
const Allocator = std.mem.Allocator;
const Date = @import("date.zig").Date;
const Ast = @import("Ast.zig");
const Number = @import("number.zig").Number;
const Inventory = @import("inventory.zig");
const ErrorDetails = @import("ErrorDetails.zig");
const Uri = @import("Uri.zig");
const Lexer = @import("lexer.zig").Lexer;
const StringPool = @import("StringPool.zig");

const Self = @This();

alloc: Allocator,
source: [:0]const u8,
uri: Uri,
ast: Ast,

accounts: StringPool,
currencies: StringPool,
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
    token: Ast.TokenIndex,
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
    pub fn compare(ctx: void, self: Entry, other: Entry) bool {
        _ = ctx;
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
};

pub const Price = struct {
    amount: Number,
    amount_currency: CurrencyIndex,
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

/// Takes ownership of `ast`.
pub fn init(alloc: Allocator, ast: Ast, uri: Uri) !Self {
    var accounts = try StringPool.init(alloc);
    errdefer accounts.deinit(alloc);

    var currencies = try StringPool.init(alloc);
    errdefer currencies.deinit(alloc);

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
    self.accounts.deinit(self.alloc);
    self.currencies.deinit(self.alloc);
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

pub fn accountText(self: *const Self, i: AccountIndex) []const u8 {
    return self.accounts.get(i);
}

pub fn currencyText(self: *const Self, i: CurrencyIndex) []const u8 {
    return self.currencies.get(i);
}

pub fn accountTextOpt(self: *const Self, oi: OptionalAccountIndex) ?[]const u8 {
    const i = oi.unwrap() orelse return null;
    return self.accounts.get(i);
}

pub fn currencyTextOpt(self: *const Self, oi: OptionalCurrencyIndex) ?[]const u8 {
    const i = oi.unwrap() orelse return null;
    return self.currencies.get(i);
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
    data: *const Self,
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
            .transaction => |tx| .{ .transaction = .{ .data = v.data, .tx = tx } },
            .open => |o| .{ .open = .{ .data = v.data, .open = o } },
            .close => |c| .{ .close = c },
            .commodity => |c| .{ .commodity = c },
            .pad => |p2| .{ .pad = p2 },
            .pnl => |p2| .{ .pnl = p2 },
            .balance => |b| .{ .balance = .{
                .account = v.data.accountOf(b.account),
                .account_token = b.account,
                .amount = b.amount.unpack() orelse unreachable,
                .amount_currency = b.amount_currency,
                .tolerance = b.tolerance.unpack(),
            } },
            .price => |pd| .{ .price = .{
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
};

/// Decoded payload — same discriminant as `Entry.Tag`. Transaction/Open
/// carry iterators over their children; Balance/PriceDecl have their numeric
/// extras already unpacked.
pub const PayloadView = union(Entry.Tag) {
    transaction: TransactionView,
    open: OpenView,
    close: Close,
    commodity: Commodity,
    pad: Pad,
    pnl: Pnl,
    balance: BalanceView,
    price: PriceDeclView,
    event: Event,
    query: Query,
    note: Note,
    document: Document,
};

pub const TransactionView = struct {
    data: *const Self,
    tx: Transaction,

    pub fn postings(v: TransactionView) PostingIterator {
        return .{ .data = v.data, .i = v.tx.postings.start, .end = v.tx.postings.end };
    }

    pub fn payeeText(v: TransactionView) ?[]const u8 {
        const i = v.tx.payee.unwrap() orelse return null;
        return v.data.tokenSlice(i);
    }

    pub fn narrationText(v: TransactionView) ?[]const u8 {
        const i = v.tx.narration.unwrap() orelse return null;
        return v.data.tokenSlice(i);
    }
};

pub const OpenView = struct {
    data: *const Self,
    open: Open,

    pub fn currencies(v: OpenView) CurrencySliceIterator {
        return .{ .data = v.data, .i = v.open.currencies.start, .end = v.open.currencies.end };
    }

    pub fn account(v: OpenView) AccountIndex {
        return v.data.accountOf(v.open.account);
    }

    pub fn accountText(v: OpenView) []const u8 {
        return v.data.tokenSlice(v.open.account);
    }
};

pub const BalanceView = struct {
    account: AccountIndex,
    /// Source token for the account (for error reporting).
    account_token: Ast.TokenIndex,
    amount: Number,
    amount_currency: CurrencyIndex,
    tolerance: ?Number,
};

pub const PriceDeclView = struct {
    currency: CurrencyIndex,
    amount: Number,
    amount_currency: CurrencyIndex,
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
        const c = v.amountCurrency().unwrap() orelse return null;
        return v.data.currencies.get(c);
    }

    pub fn astNode(v: PostingView) Ast.Node.OptionalIndex {
        return v.data.postings.items(.ast_node)[v.idx];
    }

    pub fn price(v: PostingView) ?Price {
        const opt = v.data.postings.items(.price)[v.idx];
        const idx = opt.unwrap() orelse return null;
        return v.data.prices.items[@intFromEnum(idx)];
    }

    pub fn lotSpec(v: PostingView) ?LotSpec {
        const opt = v.data.postings.items(.lot_spec)[v.idx];
        const idx = opt.unwrap() orelse return null;
        return v.data.lot_specs.items[@intFromEnum(idx)];
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
        data: *const Self,
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

/// Iterates a `Range` into `Data.open_currencies`.
pub const CurrencySliceIterator = struct {
    data: *const Self,
    i: u32,
    end: u32,

    pub fn next(it: *CurrencySliceIterator) ?CurrencyIndex {
        if (it.i >= it.end) return null;
        const v = it.data.open_currencies.items[it.i];
        it.i += 1;
        return v;
    }
};

pub fn iterEntries(self: *const Self) EntryIterator {
    return .{ .data = self, .i = 0, .end = @intCast(self.entries.len) };
}

pub fn iterEntriesOfKind(self: *const Self, comptime kind: Entry.Tag) EntriesOfKindIterator(kind) {
    return .{ .data = self, .i = 0, .end = @intCast(self.entries.len) };
}

pub fn entryAt(self: *const Self, idx: u32) EntryView {
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

comptime {
    // Document and guard current sizes. Bump these intentionally if the
    // layout changes; accidental growth should fail here.
    std.debug.assert(@sizeOf(Entry) == 64);
    std.debug.assert(@sizeOf(Entry.Payload) == 36); // sized by Balance (32) + tag byte
    std.debug.assert(@sizeOf(Posting) == 44);
    std.debug.assert(@sizeOf(Price) == 24);
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
