const std = @import("std");
const Allocator = std.mem.Allocator;
const Inventory = @import("inventory.zig").Inventory;
const Number = @import("number.zig").Number;
const Self = @This();

alloc: Allocator,
node_by_name: std.StringHashMap(u32),
nodes: std.ArrayList(Node),

pub const Node = struct {
    name: []const u8,
    inventory: Inventory,
    parent: ?u32,
    children: std.ArrayList(u32),

    pub fn init(alloc: Allocator, name: []const u8, parent: ?u32) Node {
        return Node{
            .name = name,
            .inventory = Inventory.init(alloc),
            .parent = parent,
            .children = std.ArrayList(u32).init(alloc),
        };
    }

    pub fn deinit(self: *Node) void {
        self.children.deinit();
        self.inventory.deinit();
    }
};

pub fn init(alloc: Allocator) !Self {
    var nodes = std.ArrayList(Node).init(alloc);
    try nodes.append(Node.init(alloc, "", null));
    return Self{
        .alloc = alloc,
        .node_by_name = std.StringHashMap(u32).init(alloc),
        .nodes = nodes,
    };
}

pub fn deinit(self: *Self) void {
    self.node_by_name.deinit();
    for (self.nodes.items) |*node| {
        node.deinit();
    }
    self.nodes.deinit();
}

pub fn open(self: *Self, name: []const u8) !u32 {
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
        const new_node = Node.init(self.alloc, part, current_index);
        try self.nodes.append(new_node);
        try self.nodes.items[current_index].children.append(new_index);
        current_index = new_index;
    }

    try self.node_by_name.put(name, current_index);

    return current_index;
}

pub fn add_position(self: *Self, account: []const u8, number: Number, currency: []const u8) !void {
    const index = self.node_by_name.get(account) orelse return error.AccountNotOpen;
    try self.nodes.items[index].inventory.add(number, currency);
}

/// Caller doesn't own returned inventory.
pub fn inventory(self: *Self, account: []const u8) !*Inventory {
    const index = self.node_by_name.get(account) orelse return error.AccountNotOpen;
    return &self.nodes.items[index].inventory;
}

pub fn find_node(self: *Self, account: []const u8) ?u32 {
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
pub fn inventory_aggregated(self: *Self, alloc: Allocator, account: []const u8) !Inventory {
    const start = self.node_by_name.get(account) orelse self.find_node(account) orelse return error.AccountDoesNotExist;
    var inv = Inventory.init(alloc);
    errdefer inv.deinit();

    var stack = std.ArrayList(u32).init(alloc);
    defer stack.deinit();

    try stack.append(start);
    while (stack.items.len > 0) {
        const index = stack.pop();
        var node = self.nodes.items[index];
        try inv.combine(&node.inventory);
        for (node.children.items) |child| {
            try stack.append(child);
        }
    }
    return inv;
}

pub fn render(self: *Self) ![]const u8 {
    var buf = std.ArrayList(u8).init(self.alloc);
    defer buf.deinit();

    for (self.nodes.items[0].children.items) |child| {
        try self.renderRec(&buf, child, 0);
    }

    return buf.toOwnedSlice();
}

fn renderRec(self: *Self, buf: *std.ArrayList(u8), node_index: u32, depth: u32) !void {
    const node = self.nodes.items[node_index];
    try buf.appendNTimes(' ', 2 * depth);
    try buf.appendSlice(node.name);
    try buf.append('\n');
    for (node.children.items) |child| {
        try self.renderRec(buf, child, depth + 1);
    }
}

test "tree" {
    var tree = try Self.init(std.testing.allocator);
    defer tree.deinit();
    _ = try tree.open("Assets:Currency:Chase");
    _ = try tree.open("Assets:Currency:BoA");
    _ = try tree.open("Income:Dividends");
    _ = try tree.open("Assets:Stocks");

    const rendered = try tree.render();
    defer std.testing.allocator.free(rendered);

    const expected =
        \\Assets
        \\  Currency
        \\    Chase
        \\    BoA
        \\  Stocks
        \\Income
        \\  Dividends
        \\
    ;

    try std.testing.expectEqualStrings(expected, rendered);
}

test "aggregated" {
    var tree = try Self.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.open("Assets:Currency:Chase");
    _ = try tree.open("Assets:Currency:BoA");
    _ = try tree.open("Income:Dividends");

    try tree.add_position("Assets:Currency:Chase", Number.fromInt(1000), "USD");
    try tree.add_position("Assets:Currency:BoA", Number.fromInt(1000), "USD");
    try tree.add_position("Income:Dividends", Number.fromInt(1000), "USD");

    var inv = try tree.inventory_aggregated(std.testing.allocator, "Assets");
    defer inv.deinit();

    try std.testing.expectEqual(Number.fromInt(2000), inv.balance("USD"));
}
