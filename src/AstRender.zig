const std = @import("std");
const Self = @This();
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const Lexer = @import("lexer.zig").Lexer;

alloc: std.mem.Allocator,
ast: *Ast,
w: *std.Io.Writer,

pub fn render(alloc: std.mem.Allocator, w: *std.Io.Writer, ast: *Ast) !void {
    std.debug.assert(ast.errors.items.len == 0);

    var self = Self{
        .alloc = alloc,
        .ast = ast,
        .w = w,
    };

    try self.renderRoot();
    try self.w.flush();
}

fn renderRoot(self: *Self) !void {
    const decls = self.ast.root();
    for (decls, 0..) |decl, i| {
        try self.renderDeclaration(decl);
        if (i + 1 < decls.len) {
            try self.newline();
        }
    }
}

fn renderDeclaration(self: *Self, idx: Node.Index) !void {
    switch (self.ast.node(idx)) {
        .entry => |extra| {
            try self.renderEntry(self.ast.getExtra(extra, Node.Entry));
        },
        .include => |tok| {
            _ = try self.w.write("include ");
            try self.renderToken(tok);
            try self.newline();
        },
        .option => |o| {
            _ = try self.w.write("option ");
            try self.renderToken(o.key);
            try self.space();
            try self.renderToken(o.value);
            try self.newline();
        },
        .plugin => |tok| {
            _ = try self.w.write("plugin ");
            try self.renderToken(tok);
            try self.newline();
        },
        .pushtag => |tok| {
            _ = try self.w.write("pushtag ");
            try self.renderToken(tok);
            try self.newline();
        },
        .poptag => |tok| {
            _ = try self.w.write("poptag ");
            try self.renderToken(tok);
            try self.newline();
        },
        .pushmeta => |kv| {
            _ = try self.w.write("pushmeta ");
            try self.renderToken(kv.key);
            _ = try self.w.write(": ");
            try self.renderToken(kv.value);
            try self.newline();
        },
        .popmeta => |kv| {
            _ = try self.w.write("popmeta ");
            try self.renderToken(kv.key);
            _ = try self.w.write(": ");
            try self.renderToken(kv.value);
            try self.newline();
        },
        else => @panic("unexpected node, expected declaration"),
    }
}

fn renderEntry(self: *Self, entry: Node.Entry) !void {
    try self.renderToken(entry.date);
    try self.space();
    switch (self.ast.node(entry.payload)) {
        .transaction => |tx_extra| {
            const tx = self.ast.getExtra(tx_extra, Node.Transaction);
            try self.renderToken(tx.flag);
            if (tx.payee.unwrap()) |p| {
                try self.space();
                try self.renderToken(p);
            }
            if (tx.narration.unwrap()) |n| {
                try self.space();
                try self.renderToken(n);
            }
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
            for (self.ast.list(tx.postings)) |p| {
                try self.renderPosting(p);
            }
        },
        .open => |extra| {
            const open = self.ast.getExtra(extra, Node.Open);
            _ = try self.w.write("open ");
            try self.renderToken(open.account);
            const currencies = self.ast.tokenList(open.currencies);
            for (currencies, 0..) |cur_tok, i| {
                if (i == 0) try self.space();
                if (i > 0) _ = try self.w.write(",");
                try self.renderToken(cur_tok);
            }
            if (open.booking_method.unwrap()) |bm| {
                try self.space();
                try self.renderToken(bm);
            }
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .close => |account| {
            _ = try self.w.write("close ");
            try self.renderToken(account);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .commodity => |currency| {
            _ = try self.w.write("commodity ");
            try self.renderToken(currency);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .pad => |p| {
            _ = try self.w.write("pad ");
            try self.renderToken(p.account);
            try self.space();
            try self.renderToken(p.pad_to);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .pnl => |p| {
            _ = try self.w.write("pnl ");
            try self.renderToken(p.account);
            try self.space();
            try self.renderToken(p.income_account);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .balance => |extra| {
            const bal = self.ast.getExtra(extra, Node.Balance);
            _ = try self.w.write("balance ");
            try self.renderToken(bal.account);
            try self.space();
            // Get the amount node to extract number and currency
            const amount_node = self.ast.node(bal.amount);
            switch (amount_node) {
                .amount => |a| {
                    if (a.number.unwrap()) |n| {
                        try self.renderNumberWithSign(n);
                    }
                    if (bal.tolerance.unwrap()) |tol| {
                        _ = try self.w.write(" ~ ");
                        try self.renderNumberWithSign(tol);
                    }
                    if (a.currency.unwrap()) |c| {
                        try self.space();
                        try self.renderToken(c);
                    }
                },
                else => {},
            }
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .price_decl => |p| {
            _ = try self.w.write("price ");
            try self.renderToken(p.currency);
            try self.space();
            try self.renderAmount(p.amount);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .event => |kv| {
            _ = try self.w.write("event ");
            try self.renderToken(kv.key);
            try self.space();
            try self.renderToken(kv.value);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .query => |kv| {
            _ = try self.w.write("query ");
            try self.renderToken(kv.key);
            try self.space();
            try self.renderToken(kv.value);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .note => |kv| {
            _ = try self.w.write("note ");
            try self.renderToken(kv.key);
            try self.space();
            try self.renderToken(kv.value);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .document => |kv| {
            _ = try self.w.write("document ");
            try self.renderToken(kv.key);
            try self.space();
            try self.renderToken(kv.value);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        else => {},
    }
}

fn renderPosting(self: *Self, idx: Node.Index) !void {
    const posting = self.ast.getExtra(
        switch (self.ast.node(idx)) {
            .posting => |e| e,
            else => @panic("expected posting node"),
        },
        Node.Posting,
    );

    try self.indent();

    if (posting.flag.unwrap()) |f| {
        try self.renderToken(f);
        try self.space();
    }

    try self.renderToken(posting.account);

    // Amount
    const amount_node = self.ast.node(posting.amount);
    switch (amount_node) {
        .amount => |a| {
            const has_content = a.number.unwrap() != null or a.currency.unwrap() != null;
            if (has_content) try self.space();
            try self.renderAmountFields(a);
        },
        else => {},
    }

    // Lot spec
    if (posting.lot_spec.unwrap()) |ls_idx| {
        try self.renderLotSpec(ls_idx);
    }

    // Price annotation
    if (posting.price.unwrap()) |price_idx| {
        try self.renderPriceAnnotation(price_idx);
    }

    try self.newline();

    // Posting meta
    try self.renderMeta(posting.meta, 2);
}

fn renderLotSpec(self: *Self, idx: Node.Index) !void {
    const ls = self.ast.getExtra(
        switch (self.ast.node(idx)) {
            .lot_spec => |e| e,
            else => @panic("expected lot_spec node"),
        },
        Node.LotSpec,
    );

    _ = try self.w.write(" {");
    var first = true;

    if (ls.price.unwrap()) |price_idx| {
        try self.renderAmount(price_idx);
        first = false;
    }
    if (ls.date.unwrap()) |d| {
        if (!first) _ = try self.w.write(", ");
        try self.renderToken(d);
        first = false;
    }
    if (ls.label.unwrap()) |l| {
        if (!first) _ = try self.w.write(", ");
        try self.renderToken(l);
    }
    _ = try self.w.write("}");
}

fn renderPriceAnnotation(self: *Self, idx: Node.Index) !void {
    const pa = switch (self.ast.node(idx)) {
        .price_annotation => |p| p,
        else => @panic("expected price_annotation node"),
    };

    // Check if @ or @@
    const tok = self.ast.tokens.items[@intFromEnum(pa.total)];
    if (tok.tag == .atat) {
        _ = try self.w.write(" @@ ");
    } else {
        _ = try self.w.write(" @ ");
    }
    try self.renderAmount(pa.amount);
}

fn renderTagsLinks(self: *Self, range: Node.Range) !void {
    for (self.ast.tokenList(range)) |tok| {
        try self.space();
        try self.renderToken(tok);
    }
}

fn renderMeta(self: *Self, range: Node.Range, num_indent: usize) !void {
    for (self.ast.list(range)) |idx| {
        const n = self.ast.node(idx);
        switch (n) {
            .key_value => |kv| {
                for (0..num_indent) |_| try self.indent();
                try self.renderToken(kv.key);
                _ = try self.w.write(": ");
                try self.renderToken(kv.value);
                try self.newline();
            },
            else => {},
        }
    }
}

fn renderAmount(self: *Self, idx: Node.Index) !void {
    const n = self.ast.node(idx);
    switch (n) {
        .amount => |a| try self.renderAmountFields(a),
        else => {},
    }
}

fn renderAmountFields(self: *Self, a: @TypeOf(@as(Node, .{ .amount = undefined }).amount)) !void {
    if (a.number.unwrap()) |n| {
        try self.renderNumberWithSign(n);
    }
    if (a.number.unwrap() != null and a.currency.unwrap() != null) {
        try self.space();
    }
    if (a.currency.unwrap()) |c| {
        try self.renderToken(c);
    }
}

/// Render a number token, checking if the preceding token is a minus sign.
fn renderNumberWithSign(self: *Self, token: Ast.TokenIndex) !void {
    const idx = @intFromEnum(token);
    if (idx > 0) {
        const prev = self.ast.tokens.items[idx - 1];
        if (prev.tag == .minus) {
            _ = try self.w.write(prev.slice);
        }
    }
    _ = try self.w.write(self.ast.tokens.items[idx].slice);
}

fn renderToken(self: *Self, token: Ast.TokenIndex) !void {
    _ = try self.w.write(self.ast.tokens.items[@intFromEnum(token)].slice);
}

fn space(self: *Self) !void {
    try self.w.writeByte(' ');
}

fn newline(self: *Self) !void {
    try self.w.writeByte('\n');
}

fn indent(self: *Self) !void {
    _ = try self.w.write("  ");
}
