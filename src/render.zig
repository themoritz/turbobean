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
        try r.render_entry(entry);
        if (i < r.data.entries.len) {
            try r.newline();
            try r.newline();
        }
    }
}

fn render_entry(r: *Render, entry: Data.Entry) !void {
    switch (entry) {
        .transaction => |tx| {
            try r.format("{}", .{tx.date});
            try r.space();
            try r.buffer.appendSlice(tx.flag.loc);
            try r.space();
            try r.buffer.appendSlice(tx.message);
            const num_postings = tx.postings.end - tx.postings.start;
            if (num_postings > 0) {
                try r.newline();
            }
            for (tx.postings.start..tx.postings.end) |i| {
                try r.renderPosting(i);
                if (i < tx.postings.end - 1) try r.newline();
            }
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
}

fn renderAmount(r: *Render, amount: Data.Amount) !void {
    try r.format("{}", .{amount.number});
    try r.space();
    try r.buffer.appendSlice(amount.currency);
}
