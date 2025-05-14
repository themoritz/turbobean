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
    for (r.data.entries, 1..) |entry, i| {
        try r.renderEntry(entry);
        if (i < r.data.entries.len) {
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
            if (tx.meta) |meta| {
                for (meta.start..meta.end) |i| {
                    try r.indent();
                    try r.renderKeyValue(i);
                    try r.newline();
                }
            }
            if (tx.postings) |postings| {
                for (postings.start..postings.end) |i| {
                    try r.renderPosting(i);
                }
            }
        },
        .open => {},
        .close => {},
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

    if (r.data.postings.items(.price)[posting]) |price| {
        if (price.total) try r.slice(" @@ ") else try r.slice(" @ ");
        try r.renderAmount(price.amount);
    }

    try r.newline();

    if (r.data.postings.items(.meta)[posting]) |meta| {
        for (meta.start..meta.end) |i| {
            try r.indent();
            try r.indent();
            try r.renderKeyValue(i);
            try r.newline();
        }
    }
}

fn renderKeyValue(r: *Render, i: usize) !void {
    try r.slice(r.data.meta.items(.key)[i]);
    try r.slice(": ");
    try r.slice(r.data.meta.items(.value)[i]);
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
