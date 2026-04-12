const std = @import("std");
const builtin = @import("builtin");

const lex = @import("lexer.zig");
const number = @import("number.zig");
const Data = @import("data.zig");
const Project = @import("project.zig");
const Uri = @import("Uri.zig");
const Ast = @import("Ast.zig");
const AstRender = @import("AstRender.zig");
const ErrorDetails = @import("ErrorDetails.zig");

const lsp = @import("lsp.zig");
const server = @import("server.zig");
const semantic_tokens = @import("lsp/semantic_tokens.zig");
const cli = @import("cli.zig");

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
    const stderr = std.fs.File.stderr().deprecatedWriter();
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

    var iter = try std.process.ArgIterator.initWithAllocator(alloc);
    defer iter.deinit();
    _ = iter.next();

    if (iter.next()) |command| {
        if (std.mem.eql(u8, command, "lsp")) {
            try lsp.loop(alloc);
            return;
        }
        if (std.mem.eql(u8, command, "serve")) {
            if (iter.next()) |file| {
                var uri = try Uri.from_relative_to_cwd(alloc, file);
                defer uri.deinit(alloc);

                var project = try Project.load(alloc, uri, null);
                defer project.deinit();

                if (project.hasErrors()) try project.printErrors();

                try server.loop(alloc, &project);
                return;
            } else {
                cli.printMissingFileArgument();
                return;
            }
        }
        if (std.mem.eql(u8, command, "tree")) {
            if (iter.next()) |file| {
                var uri = try Uri.from_relative_to_cwd(alloc, file);
                defer uri.deinit(alloc);

                var project = try Project.load(alloc, uri, null);
                defer project.deinit();

                if (project.hasErrors()) try project.printErrors();
                try project.printTree();
                return;
            } else {
                cli.printMissingFileArgument();
                return;
            }
        }
        if (std.mem.eql(u8, command, "fmt")) {
            const file_arg = iter.next();
            const source = if (file_arg) |file| blk: {
                const f = try std.fs.cwd().openFile(file, .{});
                defer f.close();
                break :blk try f.readToEndAllocOptions(alloc, std.math.maxInt(usize), null, .@"1", 0);
            } else blk: {
                break :blk try std.fs.File.stdin().readToEndAllocOptions(alloc, std.math.maxInt(usize), null, .@"1", 0);
            };
            defer alloc.free(source);

            const uri = Uri{ .value = file_arg orelse "<stdin>" };
            var ast = try Ast.parse(alloc, uri, source);
            defer ast.deinit();

            if (ast.errors.items.len > 0) {
                var stderr_buf: [4096]u8 = undefined;
                var stderr_w = std.fs.File.stderr().writer(&stderr_buf);
                for (ast.errors.items) |err| {
                    try err.format(&stderr_w.interface, alloc, true);
                }
                try stderr_w.interface.flush();
                std.process.exit(1);
            }

            var stdout_buf: [4096]u8 = undefined;
            var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
            try AstRender.render(alloc, &stdout_w.interface, &ast);
            return;
        }
        if (std.mem.eql(u8, command, "-h")) {
            cli.printHelp();
            return;
        }
        cli.printUnknownCommand();
    } else {
        cli.printHelp();
        return;
    }
}

test {
    _ = lex.Lexer;
    _ = number;
    _ = Data;
    _ = @import("AstParser.zig");
    _ = Project;
    _ = @import("tree.zig");
    _ = @import("ErrorDetails.zig");
    _ = @import("Uri.zig");
    _ = Ast;
    _ = AstRender;
    _ = @import("solver.zig");
    _ = @import("server/DisplaySettings.zig");
    _ = semantic_tokens;
}
