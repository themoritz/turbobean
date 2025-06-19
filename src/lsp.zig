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

    pub fn sendDiagnostics(self: *const LspState, alloc: Allocator, transport: lsp.AnyTransport) !void {
        var errors = try self.project.collectErrors(alloc);
        defer {
            var iter = errors.iterator();
            while (iter.next()) |kv| {
                kv.value_ptr.deinit();
            }
            errors.deinit();
        }
        var iter = errors.iterator();
        while (iter.next()) |kv| {
            var diagnostics = std.ArrayList(lsp.types.Diagnostic).init(alloc);
            defer {
                for (diagnostics.items) |diagnostic| {
                    alloc.free(diagnostic.message);
                }
                diagnostics.deinit();
            }
            for (kv.value_ptr.items) |err| {
                try diagnostics.append(try mkDiagnostic(err, alloc));
            }
            try transport.writeNotification(alloc, "textDocument/publishDiagnostics", lsp.types.PublishDiagnosticsParams, .{ .uri = kv.key_ptr.*, .diagnostics = diagnostics.items }, .{});
        }
    }
};

pub fn loop(alloc: std.mem.Allocator) !void {
    var transport: lsp.TransportOverStdio = .init(std.io.getStdIn(), std.io.getStdOut());
    var timer = try std.time.Timer.start();
    var state: LspState = .{};
    defer state.deinit();

    loop: while (true) {
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
        timer.reset();

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
                                    .capabilities = .{ .documentHighlightProvider = .{ .bool = true }, .definitionProvider = .{ .bool = true }, .hoverProvider = .{ .bool = true }, .completionProvider = .{ .resolveProvider = false, .triggerCharacters = &.{ "#", "^" } }, .textDocumentSync = .{ .TextDocumentSyncOptions = .{
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
                .@"textDocument/completion" => |params| {
                    var completions = std.ArrayList(lsp.types.CompletionItem).init(alloc);
                    defer completions.deinit();

                    if (params.context) |context| {
                        if (context.triggerKind == .TriggerCharacter) {
                            if (context.triggerCharacter) |char| {
                                std.log.debug("trigger char: {s}", .{char});
                                switch (char[0]) {
                                    '#' => {
                                        var iter = state.project.tags.keyIterator();
                                        while (iter.next()) |k| {
                                            try completions.append(lsp.types.CompletionItem{
                                                .label = k.*,
                                                .kind = .Variable,
                                            });
                                        }
                                    },
                                    '^' => {
                                        var iter = state.project.links.keyIterator();
                                        while (iter.next()) |k| {
                                            try completions.append(lsp.types.CompletionItem{
                                                .label = k.*,
                                                .kind = .Variable,
                                            });
                                        }
                                    },
                                    else => try transport.any().writeErrorResponse(alloc, request.id, .{ .code = .invalid_params, .message = "Unknown trigger character" }, .{}),
                                }
                            }
                        } else {
                            var iter = state.project.accounts.keyIterator();
                            while (iter.next()) |k| {
                                try completions.append(lsp.types.CompletionItem{
                                    .label = k.*,
                                    .kind = .Variable,
                                });
                            }
                        }
                    }

                    if (completions.items.len > 0) {
                        try transport.any().writeResponse(alloc, request.id, lsp.types.CompletionList, .{ .isIncomplete = false, .items = completions.items }, .{});
                    }
                },
                .@"textDocument/definition" => |params| {
                    const uri = params.textDocument.uri;
                    var iter = state.project.accountIterator(uri);
                    const account = while (iter.next()) |next| {
                        if (next.token.line == params.position.line and next.token.start_col <= params.position.character and next.token.end_col >= params.position.character) break next.token.slice;
                    } else {
                        try transport.any().writeResponse(alloc, request.id, void, {}, .{});
                        continue :loop;
                    };
                    const result_uri, const result_line = state.project.get_account_open_pos(account) orelse {
                        try transport.any().writeResponse(alloc, request.id, void, {}, .{});
                        continue :loop;
                    };
                    const result = lsp.types.Location{
                        .uri = result_uri.value,
                        .range = .{
                            .start = .{
                                .line = result_line,
                                .character = 0,
                            },
                            .end = .{
                                .line = result_line,
                                .character = 0,
                            },
                        },
                    };
                    try transport.any().writeResponse(alloc, request.id, lsp.types.Location, result, .{});
                },
                .@"textDocument/documentHighlight" => |params| {
                    const uri = params.textDocument.uri;
                    var iter = state.project.accountIterator(uri);
                    const account = while (iter.next()) |next| {
                        if (next.token.line == params.position.line and next.token.start_col <= params.position.character and next.token.end_col >= params.position.character) break next.token.slice;
                    } else {
                        try transport.any().writeResponse(alloc, request.id, void, {}, .{});
                        continue :loop;
                    };
                    var highlights = std.ArrayList(lsp.types.DocumentHighlight).init(alloc);
                    defer highlights.deinit();
                    var iter2 = state.project.accountIterator(uri);
                    while (iter2.next()) |next| {
                        if (std.mem.eql(u8, next.token.slice, account)) {
                            try highlights.append(.{
                                .range = .{
                                    .start = .{
                                        .line = @intCast(next.token.line),
                                        .character = @intCast(next.token.start_col),
                                    },
                                    .end = .{
                                        .line = @intCast(next.token.line),
                                        .character = @intCast(next.token.end_col),
                                    },
                                },
                                .kind = .Text,
                            });
                        }
                    }
                    try transport.any().writeResponse(alloc, request.id, []lsp.types.DocumentHighlight, highlights.items, .{});
                },
                .other => try transport.any().writeResponse(alloc, request.id, void, {}, .{}),
            },
            .notification => |notification| switch (notification.params) {
                .initialized => {
                    try state.sendDiagnostics(alloc, transport.any());
                },
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

                    try state.sendDiagnostics(alloc, transport.any());
                },
                .other => {},
            },
            .response => @panic("Haven't sent any requests to the client"),
        }

        const elapsed_ns = timer.read();
        const elapsed_ms = @divFloor(elapsed_ns, std.time.ns_per_ms);
        std.log.debug("Done processing request in {d} ms\n", .{elapsed_ms});
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
    @"textDocument/completion": lsp.types.CompletionParams,
    @"textDocument/definition": lsp.types.DefinitionParams,
    @"textDocument/documentHighlight": lsp.types.DocumentHighlightParams,
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
