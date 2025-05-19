const std = @import("std");
const Allocator = std.mem.Allocator;
const Data = @import("data.zig");
const Render = @This();
const Lexer = @import("lexer.zig");

buffer: std.ArrayList(u8),
data: *Data,

pub fn init(alloc: Allocator, data: *Data) !Render {
    return .{
        .buffer = std.ArrayList(u8).init(alloc),
        .data = data,
    };
}

pub fn deinit(r: *Render) void {
    r.buffer.deinit();
}

pub fn dump(alloc: Allocator, data: *Data) ![]const u8 {
    var self = try init(alloc, data);
    defer self.deinit();
    try self.render();
    return self.buffer.toOwnedSlice();
}

pub fn print(alloc: Allocator, data: *Data) !void {
    var self = try init(alloc, data);
    defer self.deinit();
    try self.render();
    std.debug.print("{s}", .{self.buffer.items});
}

fn format(r: *Render, comptime fmt: []const u8, args: anytype) !void {
    try std.fmt.format(r.buffer.writer(), fmt, args);
}

fn slice(r: *Render, str: []const u8) !void {
    try r.buffer.appendSlice(str);
}

inline fn space(r: *Render) !void {
    try r.buffer.append(' ');
}

inline fn newline(r: *Render) !void {
    try r.buffer.append('\n');
}

inline fn indent(r: *Render) !void {
    try r.slice("  ");
}

fn render(r: *Render) !void {
    for (r.data.entries.items, 1..) |entry, i| {
        try r.renderEntry(entry);
        if (i < r.data.entries.items.len) {
            try r.newline();
        }
    }
}

fn renderEntry(r: *Render, entry: Data.Entry) !void {
    switch (entry) {
        .transaction => |tx| {
            try r.format("{}", .{tx.date});
            try r.space();
            try r.slice(tx.flag.loc);
            if (tx.payee) |payee| {
                try r.space();
                try r.slice(payee);
            }
            if (tx.narration) |narration| {
                try r.space();
                try r.slice(narration);
            }
            if (tx.tagslinks) |tagslinks| {
                for (tagslinks.start..tagslinks.end) |i| {
                    try r.space();
                    try r.slice(r.data.tagslinks.items(.slice)[i]);
                }
            }
            try r.newline();
            if (tx.meta) |meta| try r.renderMeta(meta, 1);
            if (tx.postings) |postings| {
                for (postings.start..postings.end) |i| {
                    try r.renderPosting(i);
                }
            }
        },
        .open => |open| {
            try r.format("{}", .{open.date});
            try r.slice(" open ");
            try r.slice(open.account);
            if (open.currencies) |currencies| {
                try r.space();
                for (currencies.start..currencies.end, 0..) |i, j| {
                    if (j > 0) try r.slice(",");
                    try r.slice(r.data.currencies.items[i]);
                }
            }
            if (open.booking) |booking| {
                try r.space();
                try r.slice(booking);
            }
            try r.newline();
            if (open.meta) |meta| try r.renderMeta(meta, 1);
        },
        .close => |close| {
            try r.format("{}", .{close.date});
            try r.slice(" close ");
            try r.slice(close.account);
            try r.newline();
            if (close.meta) |meta| try r.renderMeta(meta, 1);
        },
        .commodity => |commodity| {
            try r.format("{}", .{commodity.date});
            try r.slice(" commodity ");
            try r.slice(commodity.currency);
            try r.newline();
            if (commodity.meta) |meta| try r.renderMeta(meta, 1);
        },
        .pad => |pad| {
            try r.format("{}", .{pad.date});
            try r.slice(" pad ");
            try r.slice(pad.account);
            try r.space();
            try r.slice(pad.pad_to);
            try r.newline();
            if (pad.meta) |meta| try r.renderMeta(meta, 1);
        },
        .balance => |balance| {
            try r.format("{}", .{balance.date});
            try r.slice(" balance ");
            try r.slice(balance.account);
            try r.space();
            if (balance.tolerance) |tolerance| {
                try r.format("{}", .{balance.amount.number.?});
                try r.slice(" ~ ");
                try r.format("{}", .{tolerance});
                try r.space();
                try r.slice(balance.amount.currency.?);
            } else {
                try r.renderAmount(balance.amount);
            }
            try r.newline();
            if (balance.meta) |meta| try r.renderMeta(meta, 1);
        },
        .price => |price| {
            try r.format("{}", .{price.date});
            try r.slice(" price ");
            try r.slice(price.currency);
            try r.space();
            try r.renderAmount(price.amount);
            try r.newline();
            if (price.meta) |meta| try r.renderMeta(meta, 1);
        },
        .event => |event| {
            try r.format("{}", .{event.date});
            try r.slice(" event ");
            try r.slice(event.variable);
            try r.space();
            try r.slice(event.value);
            try r.newline();
            if (event.meta) |meta| try r.renderMeta(meta, 1);
        },
        .query => |query| {
            try r.format("{}", .{query.date});
            try r.slice(" query ");
            try r.slice(query.name);
            try r.space();
            try r.slice(query.sql);
            try r.newline();
            if (query.meta) |meta| try r.renderMeta(meta, 1);
        },
        .note => |note| {
            try r.format("{}", .{note.date});
            try r.slice(" note ");
            try r.slice(note.account);
            try r.space();
            try r.slice(note.note);
            try r.newline();
            if (note.meta) |meta| try r.renderMeta(meta, 1);
        },
        .document => |document| {
            try r.format("{}", .{document.date});
            try r.slice(" document ");
            try r.slice(document.account);
            try r.space();
            try r.slice(document.filename);
            if (document.tagslinks) |tagslinks| {
                for (tagslinks.start..tagslinks.end) |i| {
                    try r.space();
                    try r.slice(r.data.tagslinks.items(.slice)[i]);
                }
            }
            try r.newline();
            if (document.meta) |meta| try r.renderMeta(meta, 1);
        },
        .pushtag => |tag| {
            try r.slice("pushtag ");
            try r.slice(tag);
            try r.newline();
        },
        .poptag => |tag| {
            try r.slice("poptag ");
            try r.slice(tag);
            try r.newline();
        },
        .pushmeta => |meta| {
            try r.slice("pushmeta ");
            try r.renderKeyValue(meta);
            try r.newline();
        },
        .popmeta => |meta| {
            try r.slice("popmeta ");
            try r.renderKeyValue(meta);
            try r.newline();
        },
        .option => |option| {
            try r.slice("option ");
            try r.slice(option.key);
            try r.space();
            try r.slice(option.value);
            try r.newline();
        },
        .include => |file| {
            try r.slice("include ");
            try r.slice(file);
            try r.newline();
        },
        .plugin => |plugin| {
            try r.slice("plugin ");
            try r.slice(plugin);
            try r.newline();
        },
    }
}

fn renderPosting(r: *Render, posting: usize) !void {
    try r.indent();

    if (r.data.postings.items(.flag)[posting]) |flag| {
        try r.slice(flag.loc);
        try r.space();
    }

    try r.slice(r.data.postings.items(.account)[posting]);

    const amount = r.data.postings.items(.amount)[posting];
    if (amount.exists()) try r.space();
    try r.renderAmount(amount);

    if (r.data.postings.items(.cost)[posting]) |cost| {
        if (cost.total) try r.slice(" {{") else try r.slice(" {");
        if (cost.comps) |comps| {
            for (comps.start..comps.end, 0..) |i, j| {
                if (j > 0) try r.slice(", ");
                const comp = r.data.costcomps.items[i];
                switch (comp) {
                    .amount => |am| try r.renderAmount(am),
                    .date => |date| try r.format("{}", .{date}),
                    .label => |label| try r.slice(label),
                }
            }
        }
        if (cost.total) try r.slice("}}") else try r.slice("}");
    }

    if (r.data.postings.items(.price)[posting]) |price| {
        if (price.total) try r.slice(" @@ ") else try r.slice(" @ ");
        try r.renderAmount(price.amount);
    }

    try r.newline();

    if (r.data.postings.items(.meta)[posting]) |meta| try r.renderMeta(meta, 2);
}

fn renderKeyValue(r: *Render, i: usize) !void {
    try r.slice(r.data.meta.items(.key)[i]);
    try r.slice(": ");
    try r.slice(r.data.meta.items(.value)[i]);
}

fn renderMeta(r: *Render, range: Data.Range, num_indent: usize) !void {
    for (range.start..range.end) |i| {
        for (0..num_indent) |_| {
            try r.indent();
        }
        try r.renderKeyValue(i);
        try r.newline();
    }
}

fn renderAmount(r: *Render, amount: Data.Amount) !void {
    if (amount.number) |number| {
        try r.format("{}", .{number});
    }
    if (amount.is_complete()) {
        try r.space();
    }
    if (amount.currency) |c| {
        try r.slice(c);
    }
}
