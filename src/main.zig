const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const lex = @import("lexer.zig");
const number = @import("number.zig");
const Data = @import("data.zig");
const Project = @import("project.zig");
const Uri = @import("Uri.zig");
const Ast = @import("Ast.zig");
const Renderer = @import("Renderer.zig");
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
    comptime scope: @EnumLiteral(),
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
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    nosuspend stderr.file_writer.interface.print(prefix ++ format ++ "\n", args) catch return;
}

pub fn main(init: std.process.Init) !void {
    var arena_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_alloc.allocator();
    const io = init.io;

    var iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer iter.deinit();
    _ = iter.next();

    if (iter.next()) |command| {
        if (std.mem.eql(u8, command, "lsp")) {
            try lsp.loop(arena, io);
            return;
        }
        if (std.mem.eql(u8, command, "serve")) {
            if (iter.next()) |file| {
                const uri = try Uri.from_relative_to_cwd(arena, io, file);

                var project = try Project.load(arena, io, uri, null);

                if (project.hasErrors()) try project.printErrors(arena);

                try server.loop(arena, io, &project);
                return;
            } else {
                cli.printMissingFileArgument();
                return;
            }
        }
        if (std.mem.eql(u8, command, "tree")) {
            if (iter.next()) |file| {
                const uri = try Uri.from_relative_to_cwd(arena, io, file);
                var project = try Project.load(arena, io, uri, null);

                if (project.hasErrors()) try project.printErrors(arena);
                try project.printTree(arena);
                return;
            } else {
                cli.printMissingFileArgument();
                return;
            }
        }
        if (std.mem.eql(u8, command, "fmt")) {
            var in_place = false;
            var file_arg: ?[]const u8 = null;
            while (iter.next()) |arg| {
                if (std.mem.eql(u8, arg, "-i")) {
                    in_place = true;
                } else {
                    file_arg = arg;
                    break;
                }
            }

            if (in_place and file_arg == null) {
                std.debug.print("-i requires a file argument\n", .{});
                std.process.exit(1);
            }

            const source = if (file_arg) |file| blk: {
                var f = try Io.Dir.cwd().openFile(io, file, .{});
                defer f.close(io);
                var rbuf: [4096]u8 = undefined;
                var r = f.reader(io, &rbuf);
                break :blk try r.interface.allocRemainingAlignedSentinel(arena, .unlimited, .@"1", 0);
            } else blk: {
                const stdin = Io.File.stdin();
                var rbuf: [4096]u8 = undefined;
                var r = stdin.reader(io, &rbuf);
                break :blk try r.interface.allocRemainingAlignedSentinel(arena, .unlimited, .@"1", 0);
            };

            const uri = Uri{ .value = file_arg orelse "<stdin>" };
            var ast = Ast.empty;
            try ast.parse(arena, uri, source);

            if (ast.errors.items.len > 0) {
                var stderr_buf: [4096]u8 = undefined;
                var stderr_w = Io.File.stderr().writer(io, &stderr_buf);
                for (ast.errors.items) |err| {
                    try err.format(&stderr_w.interface, arena, io, true);
                }
                try stderr_w.interface.flush();
                std.process.exit(1);
            }

            if (in_place) {
                var atomic = try Io.Dir.cwd().createFileAtomic(io, file_arg.?, .{ .replace = true });
                defer atomic.deinit(io);
                var write_buf: [4096]u8 = undefined;
                var fw = atomic.file.writer(io, &write_buf);
                try Renderer.render(arena, &fw.interface, &ast);
                try fw.interface.flush();
                try atomic.replace(io);
            } else {
                var stdout_buf: [4096]u8 = undefined;
                var stdout_w = Io.File.stdout().writer(io, &stdout_buf);
                try Renderer.render(arena, &stdout_w.interface, &ast);
                try stdout_w.interface.flush();
            }
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
    _ = @import("Parser.zig");
    _ = Project;
    _ = @import("tree.zig");
    _ = @import("ErrorDetails.zig");
    _ = @import("Uri.zig");
    _ = Ast;
    _ = Renderer;
    _ = @import("solver.zig");
    _ = @import("server/DisplaySettings.zig");
    _ = semantic_tokens;
}
