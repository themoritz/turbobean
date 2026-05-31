const std = @import("std");
const Allocator = std.mem.Allocator;
const Inventory = @import("inventory.zig").Inventory;
const BookingMethod = @import("inventory.zig").BookingMethod;
const Lot = @import("inventory.zig").Lot;
const Summary = @import("inventory.zig").Summary;
const Number = @import("number.zig").Number;
const Data = @import("data.zig");
const Date = @import("date.zig").Date;
const string_pool = @import("string_pool.zig");
const AccountPool = string_pool.AccountPool;
const CurrencyPool = string_pool.CurrencyPool;
const AccountMap = @import("pool_maps.zig").AccountMap;
const AccountIndex = Data.AccountIndex;
const CurrencyIndex = Data.CurrencyIndex;
const Self = @This();
const Stack = @import("StackStack.zig").Stack(usize, 64);

alloc: Allocator,
/// Borrowed project intern pools — used for account/currency lookups and
/// when rendering text.
accounts_pool: *const AccountPool,
currencies_pool: *const CurrencyPool,
/// Dense lookup: `AccountIndex` → node index. Entries are `null` when the
/// account hasn't been opened in this tree (or isn't a leaf directly).
nodes_by_account: AccountMap(u32),
nodes: std.ArrayList(Node),

pub const Node = struct {
    name: []const u8,
    inventory: Inventory,
    parent: ?u32,
    children: std.ArrayList(u32),

    pub fn init(name: []const u8, parent: ?u32, inv: Inventory) Node {
        return Node{
            .name = name,
            .inventory = inv,
            .parent = parent,
            .children = .empty,
        };
    }
};

pub fn init(alloc: Allocator, accounts_pool: *const AccountPool, currencies_pool: *const CurrencyPool) !Self {
    var nodes = std.ArrayList(Node).empty;
    try nodes.append(alloc, Node.init(
        "",
        null,
        try Inventory.init(alloc, null, null),
    ));
    return Self{
        .alloc = alloc,
        .accounts_pool = accounts_pool,
        .currencies_pool = currencies_pool,
        .nodes_by_account = .{},
        .nodes = nodes,
    };
}

/// Returns null if the account is already open.
pub fn open(
    self: *Self,
    account: AccountIndex,
    currencies: ?[]const CurrencyIndex,
    booking_method: ?BookingMethod,
) !?u32 {
    if (self.nodes_by_account.contains(account)) return null;

    const name = self.accounts_pool.get(account);

    var current_index: u32 = 0; // Start from root
    var iter = std.mem.splitScalar(u8, name, ':');
    parts: while (iter.next()) |part| {
        for (self.nodes.items[current_index].children.items) |child| {
            if (std.mem.eql(u8, self.nodes.items[child].name, part)) {
                current_index = child;
                continue :parts;
            }
        }

        const new_index: u32 = @intCast(self.nodes.items.len);
        const new_node = Node.init(
            part,
            current_index,
            try Inventory.init(self.alloc, booking_method, currencies),
        );
        try self.nodes.append(self.alloc, new_node);
        try self.nodes.items[current_index].children.append(self.alloc, new_index);
        current_index = new_index;
    }

    try self.nodes_by_account.put(self.alloc, account, current_index);
    return current_index;
}

pub fn close(self: *Self, account: AccountIndex) !void {
    if (!self.nodes_by_account.contains(account)) return error.AccountNotOpen;
    self.nodes_by_account.remove(account);
}

pub fn accountOpen(self: *const Self, account: AccountIndex) bool {
    return self.nodes_by_account.contains(account);
}

pub fn nodeOf(self: *const Self, account: AccountIndex) ?u32 {
    return self.nodes_by_account.get(account);
}

pub fn isPlainAccount(self: *const Self, account: AccountIndex) !bool {
    const node = self.nodeOf(account) orelse return error.AccountNotOpen;
    return switch (self.nodes.items[node].inventory) {
        .lots => false,
        .plain => true,
    };
}

pub fn isDescendant(self: *const Self, parent: AccountIndex, child: AccountIndex) !bool {
    const parent_index = self.nodeOf(parent) orelse return error.AccountNotOpen;
    const child_index = self.nodeOf(child) orelse return error.AccountNotOpen;

    if (parent_index == child_index) return true;

    var n = child_index;
    while (self.nodes.items[n].parent) |p| {
        if (p == parent_index) return true;
        n = p;
    }

    return false;
}

pub fn addPosition(self: *Self, account: AccountIndex, currency: CurrencyIndex, number: Number) !void {
    const node = self.nodeOf(account) orelse return error.AccountNotOpen;
    try self.nodes.items[node].inventory.add(currency, number);
}

pub fn bookPosition(
    self: *Self,
    account: AccountIndex,
    currency: CurrencyIndex,
    lot: Lot,
    lot_spec: ?Data.LotSpecView,
) !?Number {
    const node = self.nodeOf(account) orelse return error.AccountNotOpen;
    return try self.nodes.items[node].inventory.book(currency, lot, lot_spec);
}

pub const PostResult = struct {
    cost_weight: Number,
    cost_currency: CurrencyIndex,
};

pub fn postInventory(self: *Self, date: Date, posting: Data.PostingView) !?PostResult {
    const account_idx = posting.account();
    const amount_currency_idx = posting.amountCurrency().unwrap().?;
    const amount_number = posting.amountNumber().?;

    if (posting.price()) |price| {
        const cost_currency_idx = price.amount_currency.unwrap().?;
        const cost_weight = try self.bookPosition(
            account_idx,
            amount_currency_idx,
            .{
                .units = amount_number,
                .cost = .{
                    .price = price.amount.?,
                    .currency = cost_currency_idx,
                    .date = date,
                    .label = null,
                },
            },
            posting.lotSpec(),
        ) orelse return null;
        return PostResult{
            .cost_weight = cost_weight,
            .cost_currency = cost_currency_idx,
        };
    } else {
        try self.addPosition(account_idx, amount_currency_idx, amount_number);
        return null;
    }
}

pub fn clearEarnings(self: *Self, to_account: AccountIndex) !void {
    const to_index = self.nodeOf(to_account) orelse (try self.open(to_account, null, null)).?;

    var it = self.nodes_by_account.valueIterator();
    while (it.next()) |from_index_ptr| {
        const from_index = from_index_ptr.*;
        const relevant = blk: {
            var cur = from_index;
            while (self.nodes.items[cur].parent) |p| {
                if (p == 0) break;
                cur = p;
            }
            const root_name = self.nodes.items[cur].name;
            break :blk std.mem.eql(u8, root_name, "Income") or std.mem.eql(u8, root_name, "Expenses");
        };

        if (from_index != to_index and relevant) {
            const from_inv = &self.nodes.items[from_index].inventory;
            const to_inv = &self.nodes.items[to_index].inventory;

            var summary = try from_inv.summary(self.alloc);

            var cur_iter = summary.by_currency.iterator();
            while (cur_iter.next()) |cur_kv| {
                try to_inv.add(cur_kv.key, cur_kv.value_ptr.total_units());
            }

            from_inv.clear();
        }
    }
}

/// Caller doesn't own returned inventory.
pub fn inventory(self: *Self, account: AccountIndex) !*Inventory {
    const node = self.nodeOf(account) orelse return error.AccountNotOpen;
    return &self.nodes.items[node].inventory;
}

/// Find a node by *exact* display name. Linear scan, for render paths only.
pub fn findNodeByName(self: *const Self, name: []const u8) ?u32 {
    for (self.nodes.items, 0..) |node, index| {
        if (std.mem.eql(u8, node.name, name)) return @intCast(index);
    }
    return null;
}

pub fn balanceAggregatedByAccount(
    self: *const Self,
    account: AccountIndex,
    currency: CurrencyIndex,
) !Number {
    const node = self.nodeOf(account) orelse return error.AccountNotOpen;
    return self.balanceAggregatedByNode(node, currency);
}

pub fn balanceAggregatedByNode(self: *const Self, node: u32, currency: CurrencyIndex) !Number {
    var result = Number.zero();
    var stack: Stack = .{};
    var catch_error = false;

    try stack.push(node);
    while (stack.len > 0) {
        const index = stack.pop();
        var n = self.nodes.items[index];

        const balance = n.inventory.balance(currency) catch |err| if (catch_error)
            switch (err) {
                error.DoesNotHoldCurrency => Number.zero(),
            }
        else
            return err;

        result = result.add(balance);
        for (n.children.items) |child| {
            try stack.push(child);
        }

        catch_error = true;
    }
    return result;
}

/// Caller owns returned inventory.
pub fn inventoryAggregatedByAccount(self: *const Self, alloc: Allocator, account: AccountIndex) !Summary {
    const node = self.nodeOf(account) orelse return error.AccountNotOpen;
    return self.inventoryAggregatedByNode(alloc, node);
}

/// Caller owns returned inventory.
pub fn inventoryAggregatedByNode(self: *const Self, alloc: Allocator, node: u32) !Summary {
    var summary = Summary.init(alloc);

    var stack = std.ArrayList(usize).empty;

    try stack.append(self.alloc, node);
    while (stack.items.len > 0) {
        const index = stack.pop().?;
        var n = self.nodes.items[index];
        const n_summary = try n.inventory.summary(alloc);
        try summary.combine(n_summary);
        for (n.children.items) |child| {
            try stack.append(self.alloc, child);
        }
    }
    return summary;
}

pub fn render(self: *Self) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(self.alloc);

    const max_width = try self.maxWidth();

    var prefix: std.ArrayList(bool) = .empty;

    for (self.nodes.items[0].children.items, 0..) |child, i| {
        const is_last = i == self.nodes.items[0].children.items.len - 1;
        try self.renderRec(&buf.writer, child, max_width, 0, &prefix, is_last);
    }

    return buf.toOwnedSlice();
}

pub fn print(self: *Self) !void {
    const s = try self.render();
    std.debug.print("{s}", .{s});
}

fn renderRec(
    self: *Self,
    w: *std.Io.Writer,
    node_index: u32,
    max_width: u32,
    depth: u32,
    prefix: *std.ArrayList(bool),
    is_last: bool,
) !void {
    const node = self.nodes.items[node_index];

    var prefix_width: u32 = 0;
    for (prefix.items) |last| {
        if (last) {
            try w.writeAll("  ");
        } else {
            try w.writeAll("│ ");
        }
        prefix_width += 2;
    }

    if (depth > 0) {
        if (is_last) {
            try w.writeAll("└ ");
        } else {
            try w.writeAll("├ ");
        }
        prefix_width += 2;
    }

    try w.writeAll(node.name);
    var summary = try self.inventoryAggregatedByNode(self.alloc, node_index);
    if (!summary.isEmpty()) {
        const name_width: u32 = try unicodeLen(self.nodes.items[node_index].name);
        const width: u32 = prefix_width + name_width;
        if (width <= max_width + 3) {
            try w.splatByteAll(' ', max_width + 3 - width);
        } else {
            try w.writeByte(' ');
        }
        try summary.treeDisplay(self.currencies_pool, max_width + 3, w);
    }
    try w.writeByte('\n');

    if (node.children.items.len > 0) {
        if (depth > 0) {
            try prefix.append(self.alloc, is_last);
        }

        for (node.children.items, 0..) |child, i| {
            const child_is_last = i == node.children.items.len - 1;
            try self.renderRec(w, child, max_width, depth + 1, prefix, child_is_last);
        }

        if (depth > 0) {
            _ = prefix.pop();
        }
    }
}

fn maxWidth(self: *Self) !u32 {
    return @max(try self.maxWidthRec(0, 0), 2) - 2;
}

fn maxWidthRec(self: *Self, node_index: u32, depth: u32) !u32 {
    const name_width: u32 = try unicodeLen(self.nodes.items[node_index].name);
    var width: u32 = depth * 2 + name_width;
    for (self.nodes.items[node_index].children.items) |child| {
        width = @max(width, try self.maxWidthRec(child, depth + 1));
    }
    return width;
}

fn unicodeLen(name: []const u8) !u32 {
    return @intCast(try std.unicode.utf8CountCodepoints(name));
}

// --- tests ------------------------------------------------------------------

const TestFixture = struct {
    accounts: AccountPool,
    currencies: CurrencyPool,
    tree: Self,

    fn init(alloc: Allocator) !*TestFixture {
        const self = try alloc.create(TestFixture);
        self.accounts = try AccountPool.init(alloc);
        self.currencies = try CurrencyPool.init(alloc);
        self.tree = try Self.init(alloc, &self.accounts, &self.currencies);
        return self;
    }

    fn account(self: *TestFixture, name: []const u8) !AccountIndex {
        return try self.accounts.intern(self.tree.alloc, name);
    }

    fn currency(self: *TestFixture, name: []const u8) !CurrencyIndex {
        return try self.currencies.intern(self.tree.alloc, name);
    }
};

test "tree" {
    const alloc = std.heap.smp_allocator;
    var fx = try TestFixture.init(alloc);

    _ = try fx.tree.open(try fx.account("Assets:Currency:Chase"), null, null);
    _ = try fx.tree.open(try fx.account("Assets:Currency:BoA"), null, null);
    _ = try fx.tree.open(try fx.account("Income:Dividends"), null, null);
    _ = try fx.tree.open(try fx.account("Assets:Stocks"), null, null);

    const rendered = try fx.tree.render();

    const expected =
        \\Assets
        \\├ Currency
        \\│ ├ Chase
        \\│ └ BoA
        \\└ Stocks
        \\Income
        \\└ Dividends
        \\
    ;

    try std.testing.expectEqualStrings(expected, rendered);
}

test "render empty tree" {
    const alloc = std.heap.smp_allocator;
    var fx = try TestFixture.init(alloc);

    const rendered = try fx.tree.render();

    try std.testing.expectEqualStrings("", rendered);
}

test "aggregated" {
    const alloc = std.heap.smp_allocator;
    var fx = try TestFixture.init(alloc);

    const acc_chas = try fx.account("Assets:Currency:Chas𝄞");
    const acc_boa = try fx.account("Assets:Currency:BoA");
    const acc_div = try fx.account("Income:Dividends");

    _ = try fx.tree.open(acc_chas, null, null);
    _ = try fx.tree.open(acc_boa, null, null);
    _ = try fx.tree.open(acc_div, null, null);

    const eur = try fx.currency("EUR");
    const usd = try fx.currency("USD");

    try fx.tree.addPosition(acc_chas, usd, Number.fromInt(1));
    try fx.tree.addPosition(acc_boa, eur, Number.fromInt(1));
    try fx.tree.addPosition(acc_boa, usd, Number.fromInt(1));
    try fx.tree.addPosition(acc_div, usd, Number.fromInt(1));

    const rendered = try fx.tree.render();

    const expected =
        \\Assets        1 EUR
        \\              2 USD
        \\└ Currency    1 EUR
        \\              2 USD
        \\  ├ Chas𝄞     1 USD
        \\  └ BoA       1 EUR
        \\              1 USD
        \\Income        1 USD
        \\└ Dividends   1 USD
        \\
    ;

    try std.testing.expectEqualStrings(expected, rendered);
}

test "isDescendant" {
    const alloc = std.heap.smp_allocator;
    var fx = try TestFixture.init(alloc);

    const a = try fx.account("Assets");
    const chase = try fx.account("Assets:Currency:Chase");
    const boa = try fx.account("Assets:Currency:BoA");
    const div = try fx.account("Income:Dividends");
    const stocks = try fx.account("Assets:Stocks");

    _ = try fx.tree.open(a, null, null);
    _ = try fx.tree.open(chase, null, null);
    _ = try fx.tree.open(boa, null, null);
    _ = try fx.tree.open(div, null, null);
    _ = try fx.tree.open(stocks, null, null);

    try std.testing.expect(try fx.tree.isDescendant(chase, chase));
    try std.testing.expect(try fx.tree.isDescendant(a, chase));
    try std.testing.expect(!try fx.tree.isDescendant(div, chase));
}

test "balanceAggregatedByAccount" {
    const alloc = std.heap.smp_allocator;
    var fx = try TestFixture.init(alloc);

    const foo = try fx.account("Assets:Foo");
    const foo_bar = try fx.account("Assets:Foo:Bar");
    const baz = try fx.account("Assets:Baz");
    const nzd = try fx.currency("NZD");
    const eur = try fx.currency("EUR");
    const usd = try fx.currency("USD");

    _ = try fx.tree.open(foo, &.{nzd}, null);
    _ = try fx.tree.open(foo_bar, &.{eur}, null);
    _ = try fx.tree.open(baz, null, null);

    try fx.tree.addPosition(foo, nzd, Number.fromInt(1));
    try fx.tree.addPosition(foo_bar, eur, Number.fromInt(2));
    try fx.tree.addPosition(baz, usd, Number.fromInt(3));

    try std.testing.expectEqual(Number.fromFloat(2), try fx.tree.balanceAggregatedByAccount(foo_bar, eur));
    try std.testing.expectError(error.DoesNotHoldCurrency, fx.tree.balanceAggregatedByAccount(foo_bar, usd));

    try std.testing.expectEqual(Number.fromFloat(1), try fx.tree.balanceAggregatedByAccount(foo, nzd));
    try std.testing.expectError(error.DoesNotHoldCurrency, fx.tree.balanceAggregatedByAccount(foo, usd));

    try std.testing.expectEqual(Number.fromFloat(3), try fx.tree.balanceAggregatedByAccount(baz, usd));
    try std.testing.expectEqual(Number.fromFloat(0), try fx.tree.balanceAggregatedByAccount(baz, eur));

    const assets = try fx.account("Assets");
    try std.testing.expectError(error.AccountNotOpen, fx.tree.balanceAggregatedByAccount(assets, usd));
}
