//! Semantic data derived from a parsed file.
//!
//! Layout
//! ======
//! * `entries`  — MultiArrayList SoA. Tagged union payload is sized by the
//!   largest variant (Transaction, ~24 bytes). Rarely-needed numeric data for
//!   Balance/PriceDecl lives in `extra`.
//! * `postings` — MultiArrayList SoA. Hot fields inline; rare `price` and
//!   `lot_spec` live in `extra` via `OptionalExtraIndex`.
//! * `accounts`, `currencies` — separate StringPools, typed indices.
//! * `token_interned[i]` is the interned id for `ast.tokens[i]`, interpreted
//!   by `ast.tokens[i].tag`:
//!     - `.account`  → `AccountIndex`
//!     - `.currency` → `CurrencyIndex`
//!     - others      → `maxInt(u32)` (unused)
//! * `extra` — flat `u32` pool, Ast-style, decoded via `getExtra`/`addExtra`.

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
extra: std.ArrayList(u32),

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

pub const ExtraIndex = enum(u32) {
    _,

    pub fn toOptional(i: ExtraIndex) OptionalExtraIndex {
        const r: OptionalExtraIndex = @enumFromInt(@intFromEnum(i));
        std.debug.assert(r != .none);
        return r;
    }
};

pub const OptionalExtraIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oi: OptionalExtraIndex) ?ExtraIndex {
        return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
    }

    pub fn fromOptional(oi: ?ExtraIndex) OptionalExtraIndex {
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
    account: AccountIndex,
    booking_method: BookingMethod = .unspecified,
    /// Currency indices range in `extra` (u32s, each an interned `CurrencyIndex`).
    currencies: Range,

    pub const BookingMethod = enum(u8) {
        unspecified,
        fifo,
        lifo,
        strict,

        pub fn fromInventory(m: ?Inventory.BookingMethod) BookingMethod {
            return if (m) |mm| switch (mm) {
                .fifo => .fifo,
                .lifo => .lifo,
                .strict => .strict,
            } else .unspecified;
        }

        pub fn toInventory(b: BookingMethod) ?Inventory.BookingMethod {
            return switch (b) {
                .unspecified => null,
                .fifo => .fifo,
                .lifo => .lifo,
                .strict => .strict,
            };
        }
    };
};

pub const Close = struct {
    account: AccountIndex,
};

pub const Commodity = struct {
    currency: CurrencyIndex,
};

pub const Pad = struct {
    account: AccountIndex,
    pad_to: AccountIndex,
    /// Synthetic posting indices created by the balancer.
    pad_posting: OptionalPostingIndex = .none,
    pad_to_posting: OptionalPostingIndex = .none,
};

pub const Pnl = struct {
    account: AccountIndex,
    income_account: AccountIndex,
};

pub const Balance = struct {
    account: AccountIndex,
    amount_currency: OptionalCurrencyIndex,
    /// Points at a `BalanceExtra` (two successive `PackedNumber`s — 6 u32s).
    extras: ExtraIndex,
};

pub const PriceDecl = struct {
    currency: CurrencyIndex,
    amount_currency: OptionalCurrencyIndex,
    /// Points at a `PackedNumber` (3 u32s) in `extra`.
    amount_number: ExtraIndex,
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
    account: AccountIndex,
    note: Ast.TokenIndex,
};

pub const Document = struct {
    account: AccountIndex,
    filename: Ast.TokenIndex,
};

// --- Posting ----------------------------------------------------------------

pub const Posting = struct {
    account: AccountIndex,
    flag: Ast.OptionalTokenIndex,
    amount_number: ?Number,
    amount_currency: OptionalCurrencyIndex,
    /// Optional `PriceExtra` (5 u32s) in `extra`. `.none` for most postings.
    price: OptionalExtraIndex,
    /// Optional `LotSpecExtra` (6 u32s) in `extra`. `.none` for most postings.
    lot_spec: OptionalExtraIndex,
    /// Meta KV range in `Data.meta`. `isEmpty()` means no metadata.
    meta: Range,
    /// AST posting node for source recovery. `.none` for synthetic postings (pad, pnl).
    ast_node: Ast.Node.OptionalIndex = .none,
};

// --- Extras encoded in `extra` ---------------------------------------------

pub const BalanceExtra = struct {
    amount: PackedNumber,
    tolerance: PackedNumber,
};

pub const PriceExtra = struct {
    amount: PackedNumber,
    amount_currency: OptionalCurrencyIndex,
    flags: u32, // bit 0 = total (@@)
};

pub const LotSpecExtra = struct {
    price: PackedNumber,
    price_currency: OptionalCurrencyIndex,
    date: PackedDate,
    label: Ast.OptionalTokenIndex,
};

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

/// 1-u32 packing of `?Date`. `maxInt(u32)` encodes `null`. Layout: YYYYYYYY YYYYYYYY YYYYMMMM DDDDDDDD... (year << 9 | month << 5 | day).
pub const PackedDate = struct {
    raw: u32,

    pub const none: PackedDate = .{ .raw = std.math.maxInt(u32) };

    pub fn pack(d: ?Date) PackedDate {
        const dd = d orelse return .none;
        const year: u32 = dd.year;
        const month: u32 = dd.month;
        const day: u32 = dd.day;
        return .{ .raw = (year << 9) | (month << 5) | day };
    }

    pub fn unpack(p: PackedDate) ?Date {
        if (p.raw == std.math.maxInt(u32)) return null;
        return .{
            .year = p.raw >> 9,
            .month = @intCast((p.raw >> 5) & 0xF),
            .day = @intCast(p.raw & 0x1F),
        };
    }
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

// --- extra encoding helpers -------------------------------------------------

/// Append a struct value as its u32 fields to `extra` and return the start offset.
/// Accepts fields of type `u32`, `enum(u32)`, or nested structs whose fields are themselves supported.
pub fn addExtra(self: *Self, value: anytype) !ExtraIndex {
    const start: u32 = @intCast(self.extra.items.len);
    try appendExtraFields(self, value);
    return @enumFromInt(start);
}

fn appendExtraFields(self: *Self, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            inline for (s.fields) |f| try appendExtraFields(self, @field(value, f.name));
        },
        .@"enum" => try self.extra.append(self.alloc, @intFromEnum(value)),
        .int => try self.extra.append(self.alloc, @as(u32, value)),
        else => @compileError("unsupported extra field type: " ++ @typeName(T)),
    }
}

/// Decode a struct starting at `index` in `extra`.
pub fn getExtra(self: *const Self, index: ExtraIndex, comptime T: type) T {
    var cursor: u32 = @intFromEnum(index);
    return readExtra(self, &cursor, T);
}

fn readExtra(self: *const Self, cursor: *u32, comptime T: type) T {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            var result: T = undefined;
            inline for (s.fields) |f| {
                @field(result, f.name) = readExtra(self, cursor, f.type);
            }
            return result;
        },
        .@"enum" => {
            const raw = self.extra.items[cursor.*];
            cursor.* += 1;
            return @enumFromInt(raw);
        },
        .int => {
            const raw = self.extra.items[cursor.*];
            cursor.* += 1;
            return @as(T, @intCast(raw));
        },
        else => @compileError("unsupported extra field type: " ++ @typeName(T)),
    }
}

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
        .extra = .{},
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
    self.extra.deinit(self.alloc);
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

// --- size guards ------------------------------------------------------------

comptime {
    // Document and guard current sizes. Bump these intentionally if the
    // layout changes; accidental growth should fail here.
    std.debug.assert(@sizeOf(Entry) == 56);
    std.debug.assert(@sizeOf(Entry.Payload) == 28);
    std.debug.assert(@sizeOf(Posting) == 56);
    std.debug.assert(@sizeOf(TagLink) == 8);
    std.debug.assert(@sizeOf(KeyValue) == 8);
}

// --- round-trip tests for packing -------------------------------------------

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

test "PackedDate round-trips" {
    const cases = [_]?Date{
        null,
        .{ .year = 1970, .month = 1, .day = 1 },
        .{ .year = 2026, .month = 4, .day = 20 },
        .{ .year = 9999, .month = 12, .day = 31 },
    };
    for (cases) |c| {
        const packed_d = PackedDate.pack(c);
        const unpacked = packed_d.unpack();
        try std.testing.expectEqual(c, unpacked);
    }
}

