const std = @import("std");
const Allocator = std.mem.Allocator;
const Date = @import("date.zig").Date;
const Parser = @import("parser.zig");
const Number = @import("number.zig").Number;
const Lexer = @import("lexer.zig").Lexer;

const Self = @This();

source: [:0]const u8,
entries: Entries.Slice,
postings: Postings.Slice,

pub const Entries = std.ArrayList(Entry);
pub const Postings = std.MultiArrayList(Posting);

pub const Posting = struct {
    account: []const u8,
    amount: Amount,
};

pub const Entry = union(enum) {
    transaction: struct {
        date: Date,
        flag: Flag,
        message: []const u8,
        postings: struct {
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

pub const Amount = struct {
    number: Number,
    currency: []const u8,
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
        .postings = .{},
        .entries = Entries.init(alloc),
        .lexer = &lexer,
        .current_token = first_token,
        .err = null,
    };
    defer parser.postings.deinit(alloc);
    defer parser.entries.deinit();

    try parser.parse();

    return Self{
        .entries = try parser.entries.toOwnedSlice(),
        .postings = parser.postings.toOwnedSlice(),
        .source = source,
    };
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    alloc.free(self.entries);
    self.postings.deinit(alloc);
}
