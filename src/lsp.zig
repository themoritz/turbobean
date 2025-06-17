const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const lsp = @import("lsp");
const Project = @import("project.zig");
const Config = @import("Config.zig");
const ErrorDetails = @import("ErrorDetails.zig");

const LspState = struct {
    project: Project = undefined,
    initialized: bool = false,

    pub fn initialize(self: *LspState, alloc: Allocator, root: []const u8) !void {
        self.project = try Project.load(alloc, root);
        self.initialized = true;
    }

    pub fn deinit(self: *LspState) void {
        if (self.initialized) {
            self.project.deinit();
        }
    }
};

pub fn loop(alloc: std.mem.Allocator) !void {
    var transport: lsp.TransportOverStdio = .init(std.io.getStdIn(), std.io.getStdOut());
    var state: LspState = .{};
    defer state.deinit();

    while (true) {
        const json_message = try transport.readJsonMessage(alloc);
        defer alloc.free(json_message);

        const parsed_message: std.json.Parsed(Message) = try Message.parseFromSlice(
            alloc,
            json_message,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed_message.deinit();

        switch (parsed_message.value) {
            .request => |request| std.log.debug("received '{s}' request from client", .{@tagName(request.params)}),
            .notification => |notification| std.log.debug("received '{s}' notification from client", .{@tagName(notification.params)}),
            .response => std.log.debug("received response from client", .{}),
        }

        switch (parsed_message.value) {
            .request => |request| switch (request.params) {
                .initialize => |params| {
                    const init_result = try initialize(alloc, params, &state);
                    defer init_result.deinit(alloc);
                    switch (init_result) {
                        .fail_message => |message| {
                            std.log.err("Failed to initialize: {s}", .{message});
                            try transport.any().writeErrorResponse(alloc, request.id, .{ .code = .internal_error, .message = message }, .{});
                            try transport.any().writeNotification(alloc, "exit", void, {}, .{});
                            std.process.exit(1);
                        },
                        .success => {
                            try transport.any().writeResponse(
                                alloc,
                                request.id,
                                lsp.types.InitializeResult,
                                .{
                                    .serverInfo = .{
                                        .name = "zigcount language server",
                                    },
                                    .capabilities = .{ .hoverProvider = .{ .bool = true }, .textDocumentSync = .{ .TextDocumentSyncOptions = .{
                                        .openClose = false,
                                        .change = lsp.types.TextDocumentSyncKind.Full,
                                    } } },
                                },
                                .{},
                            );
                        },
                    }
                },
                .shutdown => try transport.any().writeResponse(alloc, request.id, void, {}, .{}),
                .@"textDocument/hover" => |params| {
                    _ = params;
                    const result = lsp.types.Hover{ .contents = .{ .MarkupContent = lsp.types.MarkupContent{
                        .kind = lsp.types.MarkupKind.plaintext,
                        .value = "Hello, world!",
                    } } };
                    try transport.any().writeResponse(alloc, request.id, lsp.types.Hover, result, .{});
                },
                .other => try transport.any().writeResponse(alloc, request.id, void, {}, .{}),
            },
            .notification => |notification| switch (notification.params) {
                .initialized => {},
                .exit => return,
                .@"textDocument/didChange" => |params| {
                    const uri = params.textDocument.uri;
                    std.debug.assert(params.contentChanges.len == 1);
                    const text = switch (params.contentChanges[0]) {
                        .literal_1 => |lit| lit.text,
                        else => @panic("Expected full text change"),
                    };
                    // Make a null-terminated copy of text
                    const null_terminated = try alloc.dupeZ(u8, text);
                    try state.project.update_file(uri, null_terminated);
                    std.log.debug("Updated file {s}", .{uri});

                    var errors = try state.project.collectErrors(alloc);
                    defer {
                        var iter = errors.iterator();
                        while (iter.next()) |kv| {
                            kv.value_ptr.deinit();
                        }
                    }
                    var iter = errors.iterator();
                    while (iter.next()) |kv| {
                        var diagnostics = std.ArrayList(lsp.types.Diagnostic).init(alloc);
                        defer diagnostics.deinit();
                        for (kv.value_ptr.items) |err| {
                            try diagnostics.append(try mkDiagnostic(err, alloc));
                        }
                        try transport.any().writeNotification(alloc, "textDocument/publishDiagnostics", lsp.types.PublishDiagnosticsParams, .{ .uri = kv.key_ptr.*, .diagnostics = diagnostics.items }, .{});
                    }
                },
                .other => {},
            },
            .response => @panic("Haven't sent any requests to the client"),
        }
    }
}

fn mkDiagnostic(err: ErrorDetails, alloc: Allocator) !lsp.types.Diagnostic {
    return .{
        .severity = .Error,
        .range = .{
            .start = .{ .line = err.token.line, .character = err.token.start_col },
            .end = .{ .line = err.token.line, .character = err.token.end_col },
        },
        .message = try err.message(alloc),
    };
}

const InitResult = union(enum) {
    success: void,
    fail_message: []const u8,

    pub fn deinit(self: InitResult, alloc: Allocator) void {
        if (self == .fail_message) {
            alloc.free(self.fail_message);
        }
    }
};

fn initialize(alloc: std.mem.Allocator, params: lsp.types.InitializeParams, state: *LspState) !InitResult {
    if (params.workspaceFolders == null) return .{ .fail_message = try alloc.dupe(u8, "No workspace folder") };
    const workspace_folders = params.workspaceFolders.?;
    if (workspace_folders.len != 1) return .{ .fail_message = try alloc.dupe(u8, "Expected one workspace folder") };
    const root = workspace_folders[0].name;

    const config = Config.load_from_dir(alloc, root) catch |err| switch (err) {
        error.FileNotFound => return .{ .fail_message = try alloc.dupe(u8, "No config found. Make sure to put a `zigcount.config` file in the workspace folder") },
        error.InvalidConfig => return .{ .fail_message = try alloc.dupe(u8, "Invalid config. The config should contain a line like `root = file.bean` where file.bean is relative to the workspace root") },
        else => return .{ .fail_message = try std.fmt.allocPrint(alloc, "Error: {s}", .{@errorName(err)}) },
    };
    defer config.deinit(alloc);

    std.log.debug("Loaded config: {any}", .{config});
    state.initialize(alloc, config.root) catch |err| switch (err) {
        error.FileNotFound => return .{ .fail_message = try std.fmt.allocPrint(alloc, "Could not open `{s}` defined in your `zigcount.config` file", .{config.root}) },
        else => return .{ .fail_message = try std.fmt.allocPrint(alloc, "Error: {s}", .{@errorName(err)}) },
    };

    return .{ .success = {} };
}

const Message = lsp.Message(RequestMethods, NotificationMethods, .{});

const RequestMethods = union(enum) {
    initialize: lsp.types.InitializeParams,
    shutdown,
    @"textDocument/hover": lsp.types.HoverParams,
    other: lsp.MethodWithParams,
};

const NotificationMethods = union(enum) {
    initialized: lsp.types.InitializedParams,
    exit,
    // @"textDocument/didOpen": lsp.types.DidOpenTextDocumentParams,
    @"textDocument/didChange": lsp.types.DidChangeTextDocumentParams,
    // @"textDocument/didClose": lsp.types.DidCloseTextDocumentParams,
    other: lsp.MethodWithParams,
};
