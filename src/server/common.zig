const std = @import("std");
const Tree = @import("../tree.zig");
const Conversion = @import("DisplaySettings.zig").Conversion;
const Prices = @import("../Prices.zig");
const zts = @import("zts");
const t = @import("templates.zig");

pub fn renderPlotArea(operating_currencies: []const []const u8, out: anytype) !void {
    try zts.writeHeader(t.plot, out);
    try zts.write(t.plot, "settings", out);
    for (operating_currencies) |cur| {
        try zts.print(t.plot, "operating_currency", .{
            .currency = cur,
        }, out);
    }
    try zts.write(t.plot, "end_conversions", out);
    try zts.write(t.plot, "plot", out);
}

pub const TreeRenderer = struct {
    alloc: std.mem.Allocator,
    out: *std.Io.Writer,
    tree: *const Tree,
    operating_currencies: []const []const u8,
    conversion: Conversion,
    prices: *const Prices,

    const MAX_TREE_DEPTH = 10;
    const Self = @This();

    pub fn renderTable(self: *const Self, title: []const u8) !void {
        for (self.tree.nodes.items[0].children.items) |i| {
            if (std.mem.eql(u8, self.tree.nodes.items[i].name, title)) {
                try zts.print(t.tree, "table", .{
                    .fixed_columns = MAX_TREE_DEPTH,
                    .variable_columns = self.operating_currencies.len + 1,
                    .after_name_line = MAX_TREE_DEPTH + 2,
                }, self.out);

                for (self.operating_currencies, 0..) |currency, j| {
                    try zts.print(t.tree, "header_title", .{
                        .title = currency,
                        .from_line = MAX_TREE_DEPTH + 2 + j,
                        .to_line = MAX_TREE_DEPTH + 2 + j + 1,
                    }, self.out);
                }
                try zts.print(t.tree, "header_title", .{
                    .title = "Other",
                    .from_line = MAX_TREE_DEPTH + 2 + self.operating_currencies.len,
                    .to_line = MAX_TREE_DEPTH + 2 + self.operating_currencies.len + 1,
                }, self.out);

                try zts.write(t.tree, "header_title_end", self.out);

                var prefix = std.array_list.Managed(bool).init(self.alloc);
                defer prefix.deinit();

                var name_prefix = std.array_list.Managed(u8).init(self.alloc);
                defer name_prefix.deinit();
                try name_prefix.appendSlice(title);

                try self.renderRec(i, 0, &prefix, &name_prefix, true);

                try zts.write(t.tree, "table_end", self.out);
            }
        }
    }

    fn renderRec(
        self: *const Self,
        node_index: u32,
        depth: u32,
        prefix: *std.array_list.Managed(bool),
        name_prefix: *std.array_list.Managed(u8),
        is_last: bool,
    ) !void {
        const node = self.tree.nodes.items[node_index];
        const has_children = node.children.items.len > 0;

        var unconverted_inv = try node.inventory.toPlain(self.alloc);
        defer unconverted_inv.deinit();

        var inv = switch (self.conversion) {
            .units => try unconverted_inv.clone(self.alloc),
            .currency => |cur| try self.prices.convertInventory(self.alloc, &unconverted_inv, cur),
        };
        defer inv.deinit();

        const name_prefix_len = name_prefix.items.len;
        if (depth > 0) {
            try name_prefix.append(':');
            try name_prefix.appendSlice(node.name);
        }

        try zts.print(t.tree, "account", .{ .full_name = name_prefix.items }, self.out);

        for (prefix.items) |last| {
            try zts.write(t.tree, "tree", self.out);
            if (!last) {
                try zts.write(t.tree, "tree_prefix", self.out);
            }
            try zts.write(t.tree, "tree_end", self.out);
        }

        if (depth > 0) {
            try zts.write(t.tree, "tree", self.out);
            if (is_last) {
                try zts.write(t.tree, "tree_node_last", self.out);
            } else {
                try zts.write(t.tree, "tree_node_middle", self.out);
            }
            try zts.write(t.tree, "tree_end", self.out);
        }

        try zts.print(t.tree, "icon", .{ .full_name = name_prefix.items }, self.out);
        if (has_children) {
            try zts.print(t.tree, "icon_toggle", .{ .full_name = name_prefix.items }, self.out);
        } else {
            if (depth > 0) {
                try zts.write(t.tree, "icon_leaf", self.out);
            } else {
                try zts.write(t.tree, "icon_leaf_root", self.out);
            }
        }
        try zts.write(t.tree, "icon_end", self.out);

        try zts.print(t.tree, "name", .{
            .name = node.name,
            .full_name = name_prefix.items,
            .from_line = depth + 2,
            .to_line = MAX_TREE_DEPTH + 2,
        }, self.out);

        for (self.operating_currencies, 0..) |currency, j| {
            try zts.print(t.tree, "balances", .{
                .from_line = MAX_TREE_DEPTH + 2 + j,
                .to_line = MAX_TREE_DEPTH + 2 + j + 1,
            }, self.out);
            if (inv.by_currency.get(currency)) |balance| {
                if (!balance.is_zero()) {
                    try zts.print(t.tree, "balance", .{
                        .units = balance.withPrecision(2),
                        .cur = "",
                    }, self.out);
                }
            }
            try zts.write(t.tree, "balances_end", self.out);
        }

        try zts.print(t.tree, "balances", .{
            .from_line = MAX_TREE_DEPTH + 2 + self.operating_currencies.len,
            .to_line = MAX_TREE_DEPTH + 2 + self.operating_currencies.len + 1,
        }, self.out);
        var iter = inv.by_currency.iterator();
        currency: while (iter.next()) |kv| {
            for (self.operating_currencies) |cur| {
                if (std.mem.eql(u8, cur, kv.key_ptr.*)) {
                    continue :currency;
                }
            }
            const units = kv.value_ptr.*;
            if (!units.is_zero()) {
                try zts.print(t.tree, "balance", .{
                    .units = units.withPrecision(2),
                    .cur = kv.key_ptr.*,
                }, self.out);
            }
        }
        try zts.write(t.tree, "balances_end", self.out);

        try zts.write(t.tree, "account_end", self.out);

        // Render children with updated prefix
        if (has_children) {
            // Sort children by name
            const sorted_children = try self.alloc.dupe(u32, node.children.items);
            defer self.alloc.free(sorted_children);

            std.mem.sort(u32, sorted_children, self.tree, struct {
                fn lessThan(tr: *const Tree, a: u32, b: u32) bool {
                    const name_a = tr.nodes.items[a].name;
                    const name_b = tr.nodes.items[b].name;
                    return std.mem.order(u8, name_a, name_b) == .lt;
                }
            }.lessThan);

            // Add current node's continuation state to prefix for children (if not root level)
            if (depth > 0) {
                try prefix.append(is_last);
            }

            for (sorted_children, 0..) |child, i| {
                const child_is_last = i == sorted_children.len - 1;
                try self.renderRec(
                    child,
                    depth + 1,
                    prefix,
                    name_prefix,
                    child_is_last,
                );
            }

            // Remove the continuation state we added
            if (depth > 0) {
                _ = prefix.pop();
            }
        }

        name_prefix.shrinkRetainingCapacity(name_prefix_len);
    }
};
