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
                _ = try self.w.write(slice);
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
                    _ = try self.w.write(tokens[i - 1].slice); // indent
                    _ = try self.w.write(tokens[i].slice); // comment
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
                    _ = try self.w.write(tokens[i].slice); // comment
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
            _ = try self.w.write(": ");
            try self.renderToken(kv.value);
            try self.newline();
        },
        .popmeta => |kv| {
            try self.renderToken(prevToken(kv.key));
            try self.space();
            try self.renderToken(kv.key);
            _ = try self.w.write(": ");
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
            for (postings, 0..) |p, i| {
                // Render indented comments between postings
                const posting_first = self.ast.firstToken(p);
                if (i > 0 or self.last_tok < posting_first) {
                    try self.renderIndentedComments(posting_first, 1);
                }
                try self.renderPosting(p);
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

    try self.space();
    try self.renderToken(ls.lcurl);
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
    try self.renderToken(ls.rcurl);
}

fn renderPriceAnnotation(self: *Self, idx: Node.Index) !void {
    const pa = switch (self.ast.node(idx)) {
        .price_annotation => |p| p,
        else => @panic("expected price_annotation node"),
    };

    try self.space();
    try self.renderToken(pa.total);
    try self.space();
    try self.renderAmount(pa.amount);
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
    const slice = self.ast.tokens.items[idx].slice;
    _ = try self.w.write(slice);
    self.last_tok = idx + 1;
}

fn renderToken(self: *Self, token: Ast.TokenIndex) !void {
    const idx = @intFromEnum(token);
    const slice = self.ast.tokens.items[idx].slice;
    _ = try self.w.write(slice);
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
        _ = try self.w.write(" ");
        _ = try self.w.write(tokens[i].slice);
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
    _ = try self.w.write("  ");
}

fn writeIndent(self: *Self, level: usize) !void {
    for (0..level) |_| try self.indent();
}
