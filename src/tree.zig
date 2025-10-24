const std = @import("std");
const Allocator = std.mem.Allocator;
const Inventory = @import("inventory.zig").Inventory;
const BookingMethod = @import("inventory.zig").BookingMethod;
const Lot = @import("inventory.zig").Lot;
const Summary = @import("inventory.zig").Summary;
const Number = @import("number.zig").Number;
const Data = @import("data.zig");
const Date = @import("date.zig").Date;
const Self = @This();

alloc: Allocator,
node_by_name: std.StringHashMap(u32),
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
            .children = .{},
        };
    }

    pub fn deinit(self: *Node, alloc: Allocator) void {
        self.children.deinit(alloc);
        self.inventory.deinit();
    }
};

pub fn init(alloc: Allocator) !Self {
    var nodes = std.ArrayList(Node){};
    try nodes.append(alloc, Node.init(
        "",
        null,
        try Inventory.init(alloc, null, null),
    ));
    return Self{
        .alloc = alloc,
        .node_by_name = std.StringHashMap(u32).init(alloc),
        .nodes = nodes,
    };
}

pub fn deinit(self: *Self) void {
    self.node_by_name.deinit();
    for (self.nodes.items) |*node| {
        node.deinit(self.alloc);
    }
    self.nodes.deinit(self.alloc);
}

pub fn open(
    self: *Self,
    name: []const u8,
    currencies: ?[][]const u8,
    booking_method: ?BookingMethod,
) !u32 {
    if (self.node_by_name.contains(name)) {
        return error.AccountExists;
    }

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

    try self.node_by_name.put(name, current_index);

    return current_index;
}

pub fn close(self: *Self, name: []const u8) !void {
    const removed = self.node_by_name.remove(name);
    if (!removed) return error.AccountNotOpen;
}

pub fn accountOpen(self: *Self, name: []const u8) bool {
    return self.node_by_name.contains(name);
}

pub fn addPosition(self: *Self, account: []const u8, currency: []const u8, number: Number) !void {
    const index = self.node_by_name.get(account) orelse return error.AccountNotOpen;
    try self.nodes.items[index].inventory.add(currency, number);
}

pub fn bookPosition(
    self: *Self,
    account: []const u8,
    currency: []const u8,
    lot: Lot,
    lot_spec: ?Data.LotSpec,
) !void {
    const index = self.node_by_name.get(account) orelse return error.AccountNotOpen;
    _ = try self.nodes.items[index].inventory.book(currency, lot, lot_spec);
}

pub fn postInventory(self: *Self, date: Date, posting: Data.Posting) !void {
    if (posting.price) |price| {
        try self.bookPosition(
            posting.account.slice,
            posting.amount.currency.?,
            .{
                .units = posting.amount.number.?,
                .cost = .{
                    .price = price.amount.number.?,
                    .currency = price.amount.currency.?,
                    .date = date,
                    .label = null,
                },
            },
            posting.lot_spec,
        );
    } else {
        try self.addPosition(
            posting.account.slice,
            posting.amount.currency.?,
            posting.amount.number.?,
        );
    }
}

pub fn clearEarnings(self: *Self, to_account: []const u8) !void {
    const to_index = self.node_by_name.get(to_account) orelse try self.open(to_account, null, null);

    var iter = self.node_by_name.iterator();
    while (iter.next()) |kv| {
        const from_index = kv.value_ptr.*;
        const relevant = std.mem.startsWith(u8, kv.key_ptr.*, "Income") or std.mem.startsWith(u8, kv.key_ptr.*, "Expenses");

        if (from_index != to_index and relevant) {
            const from_inv = &self.nodes.items[from_index].inventory;
            const to_inv = &self.nodes.items[to_index].inventory;

            var summary = try from_inv.summary(self.alloc);
            defer summary.deinit();

            var cur_iter = summary.by_currency.iterator();
            while (cur_iter.next()) |cur_kv| {
                try to_inv.add(cur_kv.key_ptr.*, cur_kv.value_ptr.total_units());
            }

            from_inv.clear();
        }
    }
}

/// Caller doesn't own returned inventory.
pub fn inventory(self: *Self, account: []const u8) !*Inventory {
    const index = self.node_by_name.get(account) orelse return error.AccountNotOpen;
    return &self.nodes.items[index].inventory;
}

pub fn findNode(self: *const Self, account: []const u8) ?u32 {
    var result: ?u32 = null;
    for (self.nodes.items, 0..) |node, index| {
        if (std.mem.eql(u8, node.name, account)) {
            result = @intCast(index);
            break;
        }
    }
    return result;
}

/// Caller owns returned inventory.
pub fn inventoryAggregatedByAccount(self: *const Self, alloc: Allocator, account: []const u8) !Summary {
    const node = self.node_by_name.get(account) orelse self.findNode(account) orelse return error.AccountDoesNotExist;
    return self.inventoryAggregatedByNode(alloc, node);
}

/// Caller owns returned inventory.
pub fn inventoryAggregatedByNode(self: *const Self, alloc: Allocator, node: u32) !Summary {
    var summary = Summary.init(alloc);
    errdefer summary.deinit();

    var stack = std.ArrayList(usize){};
    defer stack.deinit(self.alloc);

    try stack.append(self.alloc, node);
    while (stack.items.len > 0) {
        const index = stack.pop().?;
        var n = self.nodes.items[index];
        var n_summary = try n.inventory.summary(alloc);
        defer n_summary.deinit();
        try summary.combine(n_summary);
        for (n.children.items) |child| {
            try stack.append(self.alloc, child);
        }
    }
    return summary;
}

pub fn render(self: *Self) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(self.alloc);
    defer buf.deinit();

    const max_width = try self.maxWidth();

    var prefix = std.array_list.Managed(bool).init(self.alloc);
    defer prefix.deinit();

    for (self.nodes.items[0].children.items, 0..) |child, i| {
        const is_last = i == self.nodes.items[0].children.items.len - 1;
        try self.renderRec(&buf, child, max_width, 0, &prefix, is_last);
    }

    return buf.toOwnedSlice();
}

pub fn print(self: *Self) !void {
    const s = try self.render();
    defer self.alloc.free(s);
    std.debug.print("{s}", .{s});
}

fn renderRec(
    self: *Self,
    buf: *std.array_list.Managed(u8),
    node_index: u32,
    max_width: u32,
    depth: u32,
    prefix: *std.array_list.Managed(bool),
    is_last: bool,
) !void {
    const node = self.nodes.items[node_index];

    // Draw the prefix (tree structure) based on ancestors
    var prefix_width: u32 = 0;
    for (prefix.items) |last| {
        if (last) {
            try buf.appendSlice("  ");
        } else {
            try buf.appendSlice("│ ");
        }
        prefix_width += 2;
    }

    // Draw the branch connector for current node (if not at root level)
    if (depth > 0) {
        if (is_last) {
            try buf.appendSlice("└ ");
        } else {
            try buf.appendSlice("├ ");
        }
        prefix_width += 2;
    }

    try buf.appendSlice(node.name);
    var summary = try self.inventoryAggregatedByNode(self.alloc, node_index);
    defer summary.deinit();
    if (!summary.isEmpty()) {
        const name_width: u32 = try unicodeLen(self.nodes.items[node_index].name);
        const width: u32 = prefix_width + name_width;
        if (width <= max_width + 3) {
            try buf.appendNTimes(' ', max_width + 3 - width);
        } else {
            try buf.append(' ');
        }
        try summary.treeDisplay(max_width + 3, buf.writer().any());
    }
    try buf.append('\n');

    // Render children with updated prefix
    if (node.children.items.len > 0) {
        // Add current node's continuation state to prefix for children (if not root level)
        if (depth > 0) {
            try prefix.append(is_last);
        }

        for (node.children.items, 0..) |child, i| {
            const child_is_last = i == node.children.items.len - 1;
            try self.renderRec(buf, child, max_width, depth + 1, prefix, child_is_last);
        }

        // Remove the continuation state we added
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
    // Each level adds 2 characters for tree drawing
    var width: u32 = depth * 2 + name_width;
    for (self.nodes.items[node_index].children.items) |child| {
        width = @max(width, try self.maxWidthRec(child, depth + 1));
    }
    return width;
}

fn unicodeLen(name: []const u8) !u32 {
    return @intCast(try std.unicode.utf8CountCodepoints(name));
}

test "tree" {
    var tree = try Self.init(std.testing.allocator);
    defer tree.deinit();
    _ = try tree.open("Assets:Currency:Chase", null, null);
    _ = try tree.open("Assets:Currency:BoA", null, null);
    _ = try tree.open("Income:Dividends", null, null);
    _ = try tree.open("Assets:Stocks", null, null);

    const rendered = try tree.render();
    defer std.testing.allocator.free(rendered);

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
    var tree = try Self.init(std.testing.allocator);
    defer tree.deinit();

    const rendered = try tree.render();
    defer std.testing.allocator.free(rendered);

    const expected = "";

    try std.testing.expectEqualStrings(expected, rendered);
}

test "aggregated" {
    var tree = try Self.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.open("Assets:Currency:Chas𝄞", null, null);
    _ = try tree.open("Assets:Currency:BoA", null, null);
    _ = try tree.open("Income:Dividends", null, null);

    try tree.addPosition("Assets:Currency:Chas𝄞", "USD", Number.fromInt(1));
    try tree.addPosition("Assets:Currency:BoA", "EUR", Number.fromInt(1));
    try tree.addPosition("Assets:Currency:BoA", "USD", Number.fromInt(1));
    try tree.addPosition("Income:Dividends", "USD", Number.fromInt(1));

    const rendered = try tree.render();
    defer std.testing.allocator.free(rendered);

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
