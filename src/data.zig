const std = @import("std");
const Allocator = std.mem.Allocator;
const Date = @import("date.zig").Date;
const Parser = @import("parser.zig");
const Number = @import("number.zig").Number;
const Lexer = @import("lexer.zig").Lexer;

const Self = @This();

source: [:0]const u8,
directives: Directives.Slice,
legs: Legs.Slice,

pub const Directives = std.ArrayList(Directive);
pub const Legs = std.MultiArrayList(Leg);

pub const Leg = struct {
    account: []const u8,
    amount: Number,
    currency: []const u8,
};

pub const Directive = union(enum) {
    transaction: struct {
        date: Date,
        flag: Flag,
        message: []const u8,
        legs: struct {
            start: usize,
            end: usize, // exclusive
        },
    },
    open: struct {
        date: Date,
        account: []const u8,
    },
    close: struct {
        date: Date,
        account: []const u8,
    },
};

pub const Flag = enum {
    star,
    bang,
};

pub fn parse(alloc: Allocator, source: [:0]const u8) !Self {
    var lexer = Lexer.init(source);
    const first_token = lexer.next();
    var parser: Parser = .{
        .gpa = alloc,
        .legs = .{},
        .directives = Directives.init(alloc),
        .lexer = &lexer,
        .current_token = first_token,
        .err = null,
    };
    defer parser.legs.deinit(alloc);
    defer parser.directives.deinit();

    try parser.parse();

    return Self{
        .directives = try parser.directives.toOwnedSlice(),
        .legs = parser.legs.toOwnedSlice(),
        .source = source,
    };
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    alloc.free(self.directives);
    self.legs.deinit(alloc);
}
