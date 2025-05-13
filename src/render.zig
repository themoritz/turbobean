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

inline fn space(r: *Render) !void {
    try r.buffer.append(' ');
}

inline fn newline(r: *Render) !void {
    try r.buffer.append('\n');
}

inline fn indent(r: *Render) !void {
    try r.buffer.appendSlice("  ");
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
            try r.buffer.appendSlice(tx.flag.loc);
            try r.space();
            if (tx.payee) |payee| {
                try r.buffer.appendSlice(payee);
            }
            if (tx.narration) |narration| {
                try r.buffer.appendSlice(narration);
            }
            try r.newline();
            if (tx.meta) |meta| {
                for (meta.start..meta.end) |i| {
                    try r.indent();
                    try r.buffer.appendSlice(r.data.meta.items(.key)[i]);
                    try r.format(": ", .{});
                    try r.buffer.appendSlice(r.data.meta.items(.value)[i]);
                    try r.newline();
                }
            }
            if (tx.postings) |postings| {
                for (postings.start..postings.end) |i| {
                    try r.renderPosting(i);
                }
            }
        },
        .pushtag => |tag| {
            try r.format("pushtag ", .{});
            try r.buffer.appendSlice(tag);
            try r.newline();
        },
        .poptag => |tag| {
            try r.format("poptag ", .{});
            try r.buffer.appendSlice(tag);
            try r.newline();
        },
        .open => {},
        .close => {},
    }
}

fn renderPosting(r: *Render, posting: usize) !void {
    try r.indent();
    try r.buffer.appendSlice(r.data.postings.items(.account)[posting]);
    try r.space();
    try r.renderAmount(r.data.postings.items(.amount)[posting]);
    try r.newline();
    if (r.data.postings.items(.meta)[posting]) |meta| {
        for (meta.start..meta.end) |i| {
            try r.indent();
            try r.indent();
            try r.buffer.appendSlice(r.data.meta.items(.key)[i]);
            try r.format(": ", .{});
            try r.buffer.appendSlice(r.data.meta.items(.value)[i]);
            try r.newline();
        }
    }
}

fn renderAmount(r: *Render, amount: Data.Amount) !void {
    try r.format("{}", .{amount.number});
    try r.space();
    try r.buffer.appendSlice(amount.currency);
}
