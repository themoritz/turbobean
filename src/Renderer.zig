const std = @import("std");
const Self = @This();
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const Lexer = @import("lexer.zig").Lexer;

alloc: std.mem.Allocator,
ast: *Ast,
w: *std.Io.Writer,
/// Index of the next token to process in the gap scanner.
last_tok: usize,

pub fn render(alloc: std.mem.Allocator, w: *std.Io.Writer, ast: *Ast) !void {
    std.debug.assert(ast.errors.items.len == 0);

    var self = Self{
        .alloc = alloc,
        .ast = ast,
        .w = w,
        .last_tok = 0,
    };

    try self.renderRoot();
    try self.w.flush();
}

fn renderRoot(self: *Self) !void {
    const decls = self.ast.root();
    for (decls) |decl| {
        const first_tok = self.ast.firstToken(decl);
        try self.renderInterDeclComments(first_tok);
        try self.renderDeclaration(decl);
    }
}

/// Scan tokens from `last_tok` up to (but not including) `up_to` and output
/// any standalone comment lines and blank lines found in the gap.
/// Ensures at most one blank line between items. Org-mode headings get one
/// blank line around them.
fn renderInterDeclComments(self: *Self, up_to: usize) !void {
    const tokens = self.ast.tokens.items;
    var i = self.last_tok;

    // Count consecutive blank lines; we collapse them to at most 1.
    var pending_blank_lines: usize = 0;

    while (i < up_to) : (i += 1) {
        switch (tokens[i].tag) {
            .eol => {
                pending_blank_lines += 1;
            },
            .comment => {
                const slice = tokens[i].slice;
                const is_org = slice.len > 0 and slice[0] == '*';
                // Output at most one blank line before (but not at very start of file)
                if (pending_blank_lines > 0 or (is_org and i > 0)) {
                    try self.rawNewline();
                    pending_blank_lines = 0;
                }
                try self.w.writeAll(slice);
                // Skip the eol that terminates this comment line
                if (i + 1 < up_to and tokens[i + 1].tag == .eol) {
                    i += 1;
                }
                try self.rawNewline();
                if (is_org) {
                    // Force a blank line after org heading
                    pending_blank_lines = 1;
                }
            },
            .indent => {
                if (i + 1 < up_to and tokens[i + 1].tag == .comment) {
                    if (pending_blank_lines > 0) {
                        try self.rawNewline();
                        pending_blank_lines = 0;
                    }
                    i += 1;
                    try self.w.writeAll(tokens[i - 1].slice); // indent
                    try self.w.writeAll(tokens[i].slice); // comment
                    // Skip the eol that terminates this comment line
                    if (i + 1 < up_to and tokens[i + 1].tag == .eol) {
                        i += 1;
                    }
                    try self.rawNewline();
                }
                // Skip indent+eol (blank indented lines) - they contribute to pending
            },
            else => break,
        }
    }
    // Output at most one pending blank line before the next decl
    if (pending_blank_lines > 0) {
        try self.rawNewline();
    }
    self.last_tok = up_to;
}

/// Scan tokens between postings and meta lines for indented comments.
/// Normalizes indentation to `indent_level * 2` spaces.
fn renderIndentedComments(self: *Self, up_to: usize, indent_level: usize) !void {
    const tokens = self.ast.tokens.items;
    var i = self.last_tok;

    // Skip past eol from previous line
    if (i < tokens.len and tokens[i].tag == .eol) {
        i += 1;
    }

    while (i < up_to) : (i += 1) {
        switch (tokens[i].tag) {
            .eol => {
                // blank line between postings - skip or output
            },
            .indent => {
                if (i + 1 < up_to and tokens[i + 1].tag == .comment) {
                    i += 1;
                    try self.writeIndent(indent_level);
                    try self.w.writeAll(tokens[i].slice); // comment
                    if (i + 1 < up_to and tokens[i + 1].tag == .eol) {
                        i += 1;
                    }
                    try self.rawNewline();
                } else if (i + 1 < up_to and tokens[i + 1].tag == .eol) {
                    i += 1; // blank indented line
                }
            },
            else => break,
        }
    }
    self.last_tok = up_to;
}

fn rawNewline(self: *Self) !void {
    try self.w.writeByte('\n');
}

fn renderDeclaration(self: *Self, idx: Node.Index) !void {
    switch (self.ast.node(idx)) {
        .entry => |extra| {
            try self.renderEntry(self.ast.getExtra(extra, Node.Entry));
        },
        .include => |tok| {
            try self.renderToken(prevToken(tok));
            try self.space();
            try self.renderToken(tok);
            try self.newline();
        },
        .option => |o| {
            try self.renderToken(prevToken(o.key));
            try self.space();
            try self.renderToken(o.key);
            try self.space();
            try self.renderToken(o.value);
            try self.newline();
        },
        .plugin => |tok| {
            try self.renderToken(prevToken(tok));
            try self.space();
            try self.renderToken(tok);
            try self.newline();
        },
        .pushtag => |tok| {
            try self.renderToken(prevToken(tok));
            try self.space();
            try self.renderToken(tok);
            try self.newline();
        },
        .poptag => |tok| {
            try self.renderToken(prevToken(tok));
            try self.space();
            try self.renderToken(tok);
            try self.newline();
        },
        .pushmeta => |kv| {
            try self.renderToken(prevToken(kv.key));
            try self.space();
            try self.renderToken(kv.key);
            try self.w.writeAll(": ");
            try self.renderToken(kv.value);
            try self.newline();
        },
        .popmeta => |kv| {
            try self.renderToken(prevToken(kv.key));
            try self.space();
            try self.renderToken(kv.key);
            try self.w.writeAll(": ");
            try self.renderToken(kv.value);
            try self.newline();
        },
        else => @panic("unexpected node, expected declaration"),
    }
}

fn prevToken(tok: Ast.TokenIndex) Ast.TokenIndex {
    return @enumFromInt(@intFromEnum(tok) - 1);
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
            const postings = self.ast.list(tx.postings);
            const columns = self.measurePostings(postings);
            for (postings, 0..) |p, i| {
                // Render indented comments between postings
                const posting_first = self.ast.firstToken(p);
                if (i > 0 or self.last_tok < posting_first) {
                    try self.renderIndentedComments(posting_first, 1);
                }
                try self.renderPosting(p, columns);
            }
        },
        .open => |extra| {
            const open = self.ast.getExtra(extra, Node.Open);
            try self.renderToken(prevToken(open.account));
            try self.space();
            try self.renderToken(open.account);
            const currencies = self.ast.tokenList(open.currencies);
            for (currencies, 0..) |cur_tok, i| {
                if (i == 0) try self.space();
                if (i > 0) try self.w.writeAll(",");
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
            try self.renderToken(prevToken(account));
            try self.space();
            try self.renderToken(account);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .commodity => |currency| {
            try self.renderToken(prevToken(currency));
            try self.space();
            try self.renderToken(currency);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .pad => |p| {
            try self.renderToken(prevToken(p.account));
            try self.space();
            try self.renderToken(p.account);
            try self.space();
            try self.renderToken(p.pad_to);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .pnl => |p| {
            try self.renderToken(prevToken(p.account));
            try self.space();
            try self.renderToken(p.account);
            try self.space();
            try self.renderToken(p.income_account);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .balance => |extra| {
            const bal = self.ast.getExtra(extra, Node.Balance);
            try self.renderToken(prevToken(bal.account));
            try self.space();
            try self.renderToken(bal.account);
            try self.space();
            const amount_node = self.ast.node(bal.amount);
            switch (amount_node) {
                .amount => |a| {
                    if (a.number.unwrap()) |n| {
                        try self.renderNumberWithSign(n);
                    }
                    if (bal.tolerance.unwrap()) |tol| {
                        try self.w.writeAll(" ~ ");
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
            try self.renderToken(prevToken(p.currency));
            try self.space();
            try self.renderToken(p.currency);
            try self.space();
            try self.renderAmount(p.amount);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .event => |kv| {
            try self.renderToken(prevToken(kv.key));
            try self.space();
            try self.renderToken(kv.key);
            try self.space();
            try self.renderToken(kv.value);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .query => |kv| {
            try self.renderToken(prevToken(kv.key));
            try self.space();
            try self.renderToken(kv.key);
            try self.space();
            try self.renderToken(kv.value);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .note => |kv| {
            try self.renderToken(prevToken(kv.key));
            try self.space();
            try self.renderToken(kv.key);
            try self.space();
            try self.renderToken(kv.value);
            try self.renderTagsLinks(entry.tagslinks);
            try self.newline();
            try self.renderMeta(entry.meta, 1);
        },
        .document => |kv| {
            try self.renderToken(prevToken(kv.key));
            try self.space();
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

fn renderPosting(self: *Self, idx: Node.Index, columns: Columns) !void {
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
    const has_amount = switch (amount_node) {
        .amount => |a| a.number.unwrap() != null or a.currency.unwrap() != null,
        else => false,
    };
    const has_lot_spec = posting.lot_spec.unwrap() != null;
    const has_price = posting.price.unwrap() != null;

    if (has_amount or has_lot_spec or has_price) {
        // Pad account to alignment column
        const account_width = self.accountWidth(posting);
        try self.writeSpaces(columns.account + 2 - account_width);

        switch (amount_node) {
            .amount => |a| {
                if (a.number.unwrap()) |n| {
                    const nw = self.numberWidths(n);
                    try self.writeSpaces(columns.amount.int - nw.int);
                    try self.renderNumberWithSign(n);
                    try self.writeSpaces(columns.amount.frac - nw.frac);
                } else {
                    try self.writeSpaces(columns.amount.int + columns.amount.frac);
                }
                if (a.currency.unwrap()) |c| {
                    try self.space();
                    try self.renderToken(c);
                    const cw = self.tokenSlice(c).len;
                    if (has_lot_spec or has_price) {
                        try self.writeSpaces(columns.currency - cw);
                    }
                } else if (columns.currency > 0) {
                    // No currency on this posting but others have one
                    if (has_lot_spec or has_price) {
                        try self.writeSpaces(1 + columns.currency);
                    }
                }
            },
            else => {
                // No amount node at all, pad through number + currency columns
                if (has_lot_spec or has_price) {
                    try self.writeSpaces(columns.amount.int + columns.amount.frac + 1 + columns.currency);
                }
            },
        }
    }

    // Lot spec
    if (posting.lot_spec.unwrap()) |ls_idx| {
        try self.space();
        const ls_width = try self.renderLotSpec(ls_idx);
        if (has_price) {
            try self.writeSpaces(columns.lot_spec - ls_width);
        }
    } else if (columns.lot_spec > 0 and has_price) {
        try self.writeSpaces(1 + columns.lot_spec);
    }

    // Price annotation
    if (posting.price.unwrap()) |price_idx| {
        try self.space();
        try self.renderPriceAnnotation(price_idx, columns);
    }

    try self.newline();

    // Posting meta
    try self.renderMeta(posting.meta, 2);
}

const Columns = struct {
    account: usize,
    amount: NumberCols,
    currency: usize,
    lot_spec: usize,
    at: usize,
    price_amount: NumberCols,
    price_currency: usize,
};

const NumberCols = struct {
    int: usize,
    frac: usize,
};

fn measurePostings(self: *Self, postings: []const Node.Index) Columns {
    var result = Columns{
        .account = 0,
        .amount = NumberCols{ .int = 0, .frac = 0 },
        .currency = 0,
        .lot_spec = 0,
        .at = 0,
        .price_amount = NumberCols{ .int = 0, .frac = 0 },
        .price_currency = 0,
    };

    for (postings) |idx| {
        const posting = self.ast.getExtra(
            switch (self.ast.node(idx)) {
                .posting => |e| e,
                else => @panic("expected posting node"),
            },
            Node.Posting,
        );

        const amount_node = self.ast.node(posting.amount);
        const has_amount = switch (amount_node) {
            .amount => |a| a.number.unwrap() != null or a.currency.unwrap() != null,
            else => false,
        };
        const has_content = has_amount or posting.lot_spec.unwrap() != null or posting.price.unwrap() != null;

        if (has_content) {
            const aw = self.accountWidth(posting);
            result.account = @max(result.account, aw);
        }

        switch (amount_node) {
            .amount => |a| {
                if (a.number.unwrap()) |n| {
                    const nw = self.numberWidths(n);
                    result.amount.int = @max(result.amount.int, nw.int);
                    result.amount.frac = @max(result.amount.frac, nw.frac);
                }
                if (a.currency.unwrap()) |c| {
                    result.currency = @max(result.currency, self.tokenSlice(c).len);
                }
            },
            else => {},
        }

        if (posting.lot_spec.unwrap()) |ls_idx| {
            result.lot_spec = @max(result.lot_spec, self.measureLotSpec(ls_idx));
        }

        if (posting.price.unwrap()) |price_idx| {
            const pa = switch (self.ast.node(price_idx)) {
                .price_annotation => |p| p,
                else => @panic("expected price_annotation node"),
            };
            result.at = @max(result.at, self.tokenSlice(pa.total).len);
            const price_amount = self.ast.node(pa.amount);
            switch (price_amount) {
                .amount => |a| {
                    if (a.number.unwrap()) |n| {
                        const nw = self.numberWidths(n);
                        result.price_amount.int = @max(result.price_amount.int, nw.int);
                        result.price_amount.frac = @max(result.price_amount.frac, nw.frac);
                    }
                    if (a.currency.unwrap()) |c| {
                        result.price_currency = @max(result.price_currency, self.tokenSlice(c).len);
                    }
                },
                else => {},
            }
        }
    }

    // Ensure the space after the number block is at least at column 40 (from after indent).
    const min_col: usize = 40;
    const natural = result.account + 2 + result.amount.int + result.amount.frac;
    if (natural < min_col) {
        result.account = min_col - 2 - result.amount.int - result.amount.frac;
    }

    return result;
}

fn accountWidth(self: *Self, posting: Node.Posting) usize {
    var width: usize = 0;
    if (posting.flag.unwrap()) |f| {
        width += self.tokenSlice(f).len + 1; // flag + space
    }
    width += self.tokenSlice(posting.account).len;
    return width;
}

fn numberWidths(self: *Self, token: Ast.TokenIndex) NumberCols {
    const idx = @intFromEnum(token);
    var int_width: usize = 0;
    // Check for minus sign
    if (idx > 0) {
        const prev = self.ast.tokens.items[idx - 1];
        if (prev.tag == .minus) {
            int_width = 1;
        }
    }
    const slice = self.ast.tokens.items[idx].slice;
    if (std.mem.indexOf(u8, slice, ".")) |dot_pos| {
        int_width += dot_pos;
        return .{ .int = int_width, .frac = slice.len - dot_pos };
    }
    int_width += slice.len;
    return .{ .int = int_width, .frac = 0 };
}

fn tokenSlice(self: *Self, token: Ast.TokenIndex) []const u8 {
    return self.ast.tokens.items[@intFromEnum(token)].slice;
}

fn measureLotSpec(self: *Self, idx: Node.Index) usize {
    const ls = self.ast.getExtra(
        switch (self.ast.node(idx)) {
            .lot_spec => |e| e,
            else => @panic("expected lot_spec node"),
        },
        Node.LotSpec,
    );

    var width: usize = 0;
    width += self.tokenSlice(ls.lcurl).len; // { or {{

    if (ls.price.unwrap()) |price_idx| {
        width += self.measureAmount(price_idx);
    }
    if (ls.date.unwrap()) |d| {
        if (ls.price.unwrap() != null) width += 2; // ", "
        width += self.tokenSlice(d).len;
    }
    if (ls.label.unwrap()) |l| {
        if (ls.price.unwrap() != null or ls.date.unwrap() != null) width += 2; // ", "
        width += self.tokenSlice(l).len;
    }
    width += self.tokenSlice(ls.rcurl).len; // } or }}
    return width;
}

fn measureAmount(self: *Self, idx: Node.Index) usize {
    const n = self.ast.node(idx);
    switch (n) {
        .amount => |a| {
            var width: usize = 0;
            if (a.number.unwrap()) |num| {
                const nw = self.numberWidths(num);
                width += nw.int + nw.frac;
            }
            if (a.number.unwrap() != null and a.currency.unwrap() != null) {
                width += 1; // space
            }
            if (a.currency.unwrap()) |c| {
                width += self.tokenSlice(c).len;
            }
            return width;
        },
        else => return 0,
    }
}

/// Render lot spec and return its rendered width.
fn renderLotSpec(self: *Self, idx: Node.Index) !usize {
    const ls = self.ast.getExtra(
        switch (self.ast.node(idx)) {
            .lot_spec => |e| e,
            else => @panic("expected lot_spec node"),
        },
        Node.LotSpec,
    );

    var width: usize = 0;

    const lcurl = self.tokenSlice(ls.lcurl);
    try self.w.writeAll(lcurl);
    self.last_tok = @intFromEnum(ls.lcurl) + 1;
    width += lcurl.len;

    var first = true;
    if (ls.price.unwrap()) |price_idx| {
        const aw = try self.renderAmountInline(price_idx);
        width += aw;
        first = false;
    }
    if (ls.date.unwrap()) |d| {
        if (!first) {
            try self.w.writeAll(", ");
            width += 2;
        }
        const s = self.tokenSlice(d);
        try self.w.writeAll(s);
        self.last_tok = @intFromEnum(d) + 1;
        width += s.len;
        first = false;
    }
    if (ls.label.unwrap()) |l| {
        if (!first) {
            try self.w.writeAll(", ");
            width += 2;
        }
        const s = self.tokenSlice(l);
        try self.w.writeAll(s);
        self.last_tok = @intFromEnum(l) + 1;
        width += s.len;
    }

    const rcurl = self.tokenSlice(ls.rcurl);
    try self.w.writeAll(rcurl);
    self.last_tok = @intFromEnum(ls.rcurl) + 1;
    width += rcurl.len;

    return width;
}

/// Render amount inline (for use inside lot specs), return rendered width.
fn renderAmountInline(self: *Self, idx: Node.Index) !usize {
    const n = self.ast.node(idx);
    switch (n) {
        .amount => |a| {
            var width: usize = 0;
            if (a.number.unwrap()) |num| {
                const nw = self.numberWidths(num);
                try self.renderNumberWithSign(num);
                width += nw.int + nw.frac;
            }
            if (a.number.unwrap() != null and a.currency.unwrap() != null) {
                try self.space();
                width += 1;
            }
            if (a.currency.unwrap()) |c| {
                const s = self.tokenSlice(c);
                try self.w.writeAll(s);
                self.last_tok = @intFromEnum(c) + 1;
                width += s.len;
            }
            return width;
        },
        else => return 0,
    }
}

fn renderPriceAnnotation(self: *Self, idx: Node.Index, columns: Columns) !void {
    const pa = switch (self.ast.node(idx)) {
        .price_annotation => |p| p,
        else => @panic("expected price_annotation node"),
    };

    const at_slice = self.tokenSlice(pa.total);
    try self.w.writeAll(at_slice);
    self.last_tok = @intFromEnum(pa.total) + 1;
    try self.writeSpaces(columns.at - at_slice.len);

    const price_amount = self.ast.node(pa.amount);
    switch (price_amount) {
        .amount => |a| {
            if (a.number.unwrap()) |n| {
                try self.space();
                const nw = self.numberWidths(n);
                try self.writeSpaces(columns.price_amount.int - nw.int);
                try self.renderNumberWithSign(n);
                try self.writeSpaces(columns.price_amount.frac - nw.frac);
            }
            if (a.currency.unwrap()) |c| {
                try self.space();
                try self.renderToken(c);
            }
        },
        else => {},
    }
}

fn writeSpaces(self: *Self, n: usize) !void {
    for (0..n) |_| try self.w.writeByte(' ');
}

fn renderTagsLinks(self: *Self, range: Node.Range) !void {
    for (self.ast.tokenList(range)) |tok| {
        try self.space();
        try self.renderToken(tok);
    }
}

fn renderMeta(self: *Self, range: Node.Range, indent_level: usize) !void {
    const meta_items = self.ast.list(range);
    for (meta_items) |idx| {
        const meta_first = self.ast.firstToken(idx);
        try self.renderIndentedComments(meta_first, indent_level);

        const n = self.ast.node(idx);
        switch (n) {
            .key_value => |kv| {
                try self.writeIndent(indent_level);
                try self.renderToken(kv.key);
                try self.w.writeAll(": ");
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
            try self.w.writeAll(prev.slice);
        }
    }
    const slice = self.ast.tokens.items[idx].slice;
    try self.w.writeAll(slice);
    self.last_tok = idx + 1;
}

fn renderToken(self: *Self, token: Ast.TokenIndex) !void {
    const idx = @intFromEnum(token);
    const slice = self.ast.tokens.items[idx].slice;
    try self.w.writeAll(slice);
    self.last_tok = idx + 1;
}

/// Check for EOL comment at the current position in the token stream, output it,
/// then write a newline.
fn newline(self: *Self) !void {
    const tokens = self.ast.tokens.items;
    var i = self.last_tok;
    // last_tok points to the token after the last rendered one.
    // Check if there's a comment before the eol.
    if (i < tokens.len and tokens[i].tag == .comment) {
        try self.w.writeAll(" ");
        try self.w.writeAll(tokens[i].slice);
        i += 1;
    }
    // Advance past the eol token
    if (i < tokens.len and tokens[i].tag == .eol) {
        i += 1;
    }
    self.last_tok = i;
    try self.w.writeByte('\n');
}

fn space(self: *Self) !void {
    try self.w.writeByte(' ');
}

fn indent(self: *Self) !void {
    try self.w.writeAll("  ");
}

fn writeIndent(self: *Self, level: usize) !void {
    for (0..level) |_| try self.indent();
}
