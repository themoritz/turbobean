const std = @import("std");

const lex = @import("lexer.zig");
const render = @import("render.zig");
const number = @import("number.zig");
const Data = @import("data.zig");
const parser = @import("parser.zig");
const Project = @import("project.zig");

const lsp = @import("lsp.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);
    if (args.len < 2) return error.MissingArgument;
    const filename = args[1];

    if (std.mem.eql(u8, filename, "--lsp")) {
        try lsp.loop();
        return;
    }

    var project = try Project.load(allocator, filename);
    defer project.deinit();

    try project.balanceTransactions();
    if (!try project.printErrors()) {
        try project.sortEntries();
        try project.printTree();
    }
}

test {
    _ = lex.Lexer;
    _ = render;
    _ = number;
    _ = Data;
    _ = parser;
    _ = Project;
}
