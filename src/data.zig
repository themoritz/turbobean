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
tagslinks: TagsLinks.Slice,

pub const Entries = std.ArrayList(Entry);
pub const Postings = std.MultiArrayList(Posting);
pub const TagsLinks = std.MultiArrayList(TagLink);

pub const Posting = struct {
    account: []const u8,
    amount: Amount,
};

pub const Entry = union(enum) {
    transaction: struct {
        date: Date,
        flag: Lexer.Token,
        payee: ?[]const u8,
        narration: ?[]const u8,
        tagslinks: ?Range,
        postings: ?Range,
    },
    open: struct {
        date: Date,
        account: []const u8,
    },
    close: struct {
        date: Date,
        account: []const u8,
    },
    pushtag: []const u8,
    poptag: []const u8,
};

pub const Range = struct {
    start: usize,
    end: usize, // exclusive
};

pub const TagLink = struct {
    kind: Kind,
    slice: []const u8,

    pub const Kind = enum {
        tag,
        link,
    };
};

pub const Amount = struct {
    number: Number,
    currency: []const u8,
};

pub fn parse(alloc: Allocator, source: [:0]const u8) !Self {
    var lexer = Lexer.init(source);
    const first_token = lexer.next();
    var parser: Parser = .{
        .gpa = alloc,
        .postings = .{},
        .tagslinks = .{},
        .entries = Entries.init(alloc),
        .lexer = &lexer,
        .current_token = first_token,
        .err = null,
    };
    defer parser.postings.deinit(alloc);
    defer parser.tagslinks.deinit(alloc);
    defer parser.entries.deinit();

    parser.parse() catch |err| switch (err) {
        error.ParseError => {
            std.debug.print("{any}\n", .{parser.err});
            return err;
        },
        else => return err,
    };

    return Self{
        .entries = try parser.entries.toOwnedSlice(),
        .postings = parser.postings.toOwnedSlice(),
        .tagslinks = parser.tagslinks.toOwnedSlice(),
        .source = source,
    };
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    alloc.free(self.entries);
    self.postings.deinit(alloc);
}
