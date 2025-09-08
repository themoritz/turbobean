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
    .logFn = myLogFn,
};

pub fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = switch (scope) {
        .default => "",
        .watcher => if (@intFromEnum(level) <= @intFromEnum(std.log.Level.warn))
            " (" ++ @tagName(scope) ++ ")"
        else
            return,
        else => " (" ++ @tagName(scope) ++ ")",
    };

    const prefix = "[" ++ comptime level.asText() ++ "]" ++ scope_prefix ++ ": ";

    // Print the message to stderr, silently ignoring any errors
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr().writer();
    nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
}

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
    const first_arg = args[1];

    if (std.mem.eql(u8, first_arg, "--lsp")) {
        try lsp.loop(alloc);
        return;
    }

    var project = try Project.load(alloc, first_arg);
    defer project.deinit();

    if (project.hasSevereErrors()) {
        try project.printErrors();
        std.process.exit(1);
    }

    if (args.len < 3) {
        if (project.hasErrors()) {
            try project.printErrors();
        }
        try project.printTree();
        return;
    }

    if (std.mem.eql(u8, args[2], "--server")) {
        try server.loop(alloc, &project);
        return;
    }

    return error.SecondArgumentNeedsToBeServer;
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
