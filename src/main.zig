const std = @import("std");
const builtin = @import("builtin");

const lex = @import("lexer.zig");
const render = @import("render.zig");
const number = @import("number.zig");
const Data = @import("data.zig");
const parser = @import("parser.zig");
const Project = @import("project.zig");

const lsp = @import("lsp.zig");
const server = @import("server.zig");
const semantic_tokens = @import("lsp/semantic_tokens.zig");

pub const std_options: std.Options = .{
    .log_level = std.log.default_level,
};

var debug_allocator: std.heap.DebugAllocator(.{
    .stack_trace_frames = 24,
}) = .init;

pub fn main() !void {
    const alloc, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 2) return error.MissingArgument;
    const filename = args[1];

    if (std.mem.eql(u8, filename, "--lsp")) {
        try lsp.loop(alloc);
        return;
    } else if (std.mem.eql(u8, filename, "--server")) {
        try server.run(alloc);
        return;
    }

    var project = try Project.load(alloc, filename);
    defer project.deinit();

    if (project.hasSevereErrors()) {
        try project.printErrors();
        std.process.exit(1);
    } else {
        if (project.hasErrors()) {
            try project.printErrors();
        }
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
    _ = semantic_tokens;
}
