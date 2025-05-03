const std = @import("std");
const Allocator = std.mem.Allocator;
const Data = @import("data.zig");
const Render = @This();

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
    for (r.data.directives, 1..) |directive, i| {
        try r.render_directive(directive);
        if (i < r.data.directives.len) {
            try r.newline();
            try r.newline();
        }
    }
}

fn render_directive(r: *Render, directive: Data.Directive) !void {
    switch (directive) {
        .transaction => |tx| {
            try r.format("{}", .{tx.date});
            try r.space();
            try r.renderFlag(tx.flag);
            try r.space();
            try r.buffer.appendSlice(tx.message);
            const num_legs = tx.legs.end - tx.legs.start;
            if (num_legs > 0) {
                try r.newline();
            }
            for (tx.legs.start..tx.legs.end) |i| {
                try r.render_leg(i);
                if (i < tx.legs.end - 1) try r.newline();
            }
        },
        .open => {},
        .close => {},
    }
}

fn renderFlag(r: *Render, flag: Data.Flag) !void {
    const char: u8 = switch (flag) {
        .bang => '!',
        .star => '*',
    };
    try r.buffer.append(char);
}

fn render_leg(r: *Render, leg: usize) !void {
    try r.indent();
    try r.buffer.appendSlice(r.data.legs.items(.account)[leg]);
    try r.space();
    const amount = r.data.legs.items(.amount)[leg];
    try r.format("{}", .{amount});
    try r.space();
    const currency = r.data.legs.items(.currency)[leg];
    try r.buffer.appendSlice(currency);
}
