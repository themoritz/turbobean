const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const lsp = @import("lsp");
const Project = @import("project.zig");
const Config = @import("Config.zig");
const ErrorDetails = @import("ErrorDetails.zig");
const Token = @import("lexer.zig").Lexer.Token;
const completion = @import("lsp/completion.zig");
const Date = @import("date.zig").Date;

const LspState = struct {
    project: Project = undefined,
    initialized: bool = false,
    clientCapabilities: ClientCapabilities = .{},

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
            try transport.writeNotification(
                alloc,
                "textDocument/publishDiagnostics",
                lsp.types.PublishDiagnosticsParams,
                .{ .uri = kv.key_ptr.*, .diagnostics = diagnostics.items },
                .{},
            );
        }
    }

    pub fn findAccount(self: *const LspState, uri: []const u8, position: lsp.types.Position) ?Token {
        var iter = self.project.accountIterator(uri);
        return while (iter.next()) |next| {
            const same_line = next.token.line == position.line;
            const within_token = next.token.start_col <= position.character and next.token.end_col >= position.character;
            if (same_line and within_token) break next.token;
        } else null;
    }
};

const ClientCapabilities = struct {
    utf16_position_encoding: bool = false,
};

pub fn loop(alloc: std.mem.Allocator) !void {
    var transport: lsp.TransportOverStdio = .init(std.io.getStdIn(), std.io.getStdOut());
    var timer = try std.time.Timer.start();
    var state: LspState = .{};
    defer state.deinit();

    loop: while (true) : ({
        const elapsed_ns = timer.read();
        const elapsed_ms = @divFloor(elapsed_ns, std.time.ns_per_ms);
        std.log.debug("Completed in {d} ms\n", .{elapsed_ms});
    }) {
        const json_message = try transport.readJsonMessage(alloc);
        defer alloc.free(json_message);

        const parsed_message: std.json.Parsed(Message) = try Message.parseFromSlice(
            alloc,
            json_message,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed_message.deinit();

        switch (parsed_message.value) {
            .request => |request| std.log.debug("Received '{s}' request", .{@tagName(request.params)}),
            .notification => |notification| std.log.debug("Received '{s}' notification", .{@tagName(notification.params)}),
            .response => std.log.debug("Received response from client", .{}),
        }
        timer.reset();

        switch (parsed_message.value) {
            .request => |request| switch (request.params) {
                .initialize => |params| {
                    if (params.workDoneToken) |token| {
                        var map = std.json.ObjectMap.init(alloc);
                        defer map.deinit();
                        try map.put("kind", .{ .string = "begin" });
                        try map.put("title", .{ .string = "Initializing" });
                        try transport.any().writeNotification(
                            alloc,
                            "$/progress",
                            lsp.types.ProgressParams,
                            .{ .token = token, .value = std.json.Value{ .object = map } },
                            .{},
                        );
                    }
                    const init_result = try initialize(alloc, params, &state);
                    defer init_result.deinit(alloc);
                    switch (init_result) {
                        .fail_message => |message| {
                            std.log.err("Failed to initialize: {s}", .{message});
                            try transport.any().writeErrorResponse(
                                alloc,
                                request.id,
                                .{ .code = .internal_error, .message = message },
                                .{},
                            );
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
                                    .capabilities = .{
                                        .positionEncoding = .@"utf-16",
                                        .renameProvider = .{
                                            .RenameOptions = .{ .prepareProvider = true },
                                        },
                                        .documentHighlightProvider = .{ .bool = true },
                                        .definitionProvider = .{ .bool = true },
                                        .hoverProvider = .{ .bool = true },
                                        .completionProvider = .{
                                            .resolveProvider = false,
                                            .triggerCharacters = &.{ "#", "^", "2", "\"" },
                                        },
                                        .textDocumentSync = .{ .TextDocumentSyncOptions = .{
                                            .openClose = false,
                                            .change = lsp.types.TextDocumentSyncKind.Full,
                                        } },
                                    },
                                },
                                .{
                                    // VSCode doesn't understand that null means no capability.
                                    .emit_null_optional_fields = false,
                                },
                            );
                            if (params.workDoneToken) |token| {
                                var map = std.json.ObjectMap.init(alloc);
                                defer map.deinit();
                                try map.put("kind", .{ .string = "end" });
                                try transport.any().writeNotification(
                                    alloc,
                                    "$/progress",
                                    lsp.types.ProgressParams,
                                    .{ .token = token, .value = std.json.Value{ .object = map } },
                                    .{},
                                );
                            }
                        },
                    }
                },
                .shutdown => try transport.any().writeResponse(alloc, request.id, void, {}, .{}),
                .@"textDocument/hover" => |params| {
                    const uri = params.textDocument.uri;
                    const position = params.position;
                    var iter = state.project.accountIterator(uri);
                    const account = while (iter.next()) |next| {
                        const same_line = next.token.line == position.line;
                        const within_token = next.token.start_col <= position.character and next.token.end_col >= position.character;
                        if (same_line and within_token and next.kind == .posting) break next.token;
                    } else {
                        try transport.any().writeResponse(alloc, request.id, void, {}, .{});
                        continue :loop;
                    };

                    if (try state.project.accountInventoryUntilLine(account.slice, uri, position.line)) |inv| {
                        defer {
                            var before = inv.before;
                            var after = inv.after;
                            before.deinit();
                            after.deinit();
                        }
                        var value = std.ArrayList(u8).init(alloc);
                        defer value.deinit();
                        const writer = value.writer();
                        {
                            try writer.writeAll("Before:\n");
                            var currency_iter = inv.before.by_currency.iterator();
                            while (currency_iter.next()) |kv| {
                                try writer.print("• {d} {s}\n", .{ kv.value_ptr.*, kv.key_ptr.* });
                            }
                        }
                        {
                            try writer.writeAll("\nAfter:\n");
                            var currency_iter = inv.after.by_currency.iterator();
                            while (currency_iter.next()) |kv| {
                                try writer.print("• {d} {s}\n", .{ kv.value_ptr.*, kv.key_ptr.* });
                            }
                        }

                        const result = lsp.types.Hover{
                            .contents = .{
                                .MarkupContent = lsp.types.MarkupContent{
                                    .kind = lsp.types.MarkupKind.plaintext,
                                    .value = value.items,
                                },
                            },
                            .range = .{
                                .start = .{
                                    .line = account.line,
                                    .character = account.start_col,
                                },
                                .end = .{
                                    .line = account.line,
                                    .character = account.end_col,
                                },
                            },
                        };
                        try transport.any().writeResponse(alloc, request.id, lsp.types.Hover, result, .{});
                    } else {
                        try transport.any().writeResponse(alloc, request.id, void, {}, .{});
                        continue :loop;
                    }
                },
                .@"textDocument/completion" => |params| {
                    var arena = std.heap.ArenaAllocator.init(alloc);
                    defer arena.deinit();
                    const arena_alloc = arena.allocator();

                    const Completion = struct { []const u8, lsp.types.CompletionItemKind };
                    var completions = std.ArrayList(Completion).init(arena_alloc);

                    var start: u32 = params.position.character;
                    var end: u32 = params.position.character;

                    blk: {
                        const file = state.project.files_by_uri.get(params.textDocument.uri) orelse break :blk;
                        const src = state.project.files.items[file].source;
                        const line = completion.getLine(src, params.position.line) orelse break :blk;
                        const before = completion.getTextBefore(line, params.position.character);

                        // No completion inside comments
                        if (completion.countOccurrences(before, ";") > 0) break :blk;

                        const triggerChar = if (params.context) |context|
                            if (context.triggerKind == .TriggerCharacter)
                                if (context.triggerCharacter) |char|
                                    char[0]
                                else
                                    null
                            else
                                null
                        else
                            break :blk;

                        if (triggerChar) |t| {
                            switch (t) {
                                '#' => {
                                    var iter = state.project.tags.keyIterator();
                                    while (iter.next()) |k| try completions.append(.{ k.*, .Variable });
                                    start = start - 1;
                                },
                                '^' => {
                                    var iter = state.project.links.keyIterator();
                                    while (iter.next()) |k| try completions.append(.{ k.*, .Reference });
                                    start = start - 1;
                                },
                                '2' => {
                                    const today = Date.today();
                                    const item = try std.fmt.allocPrint(arena_alloc, "{any}", .{today});
                                    try completions.append(.{ item, .Event });
                                    start = start - 1;
                                },
                                '"' => {
                                    // TODO: Payee/narration
                                },
                                else => try transport.any().writeErrorResponse(
                                    alloc,
                                    request.id,
                                    .{ .code = .invalid_params, .message = "Unknown trigger character" },
                                    .{},
                                ),
                            }
                        } else {
                            const numQuotes =
                                completion.countOccurrences(before, "\"") -
                                completion.countOccurrences(before, "\\\"");
                            if (numQuotes % 2 == 0) {
                                var iter = state.project.accounts.keyIterator();
                                while (iter.next()) |k| try completions.append(.{ k.*, .EnumMember });
                                const word_start, const word_end = completion.getWordAround(line, params.position.character) orelse break :blk;
                                start = word_start;
                                end = word_end;
                            }
                        }
                    }

                    if (completions.items.len > 0) {
                        var completionItems = std.ArrayList(lsp.types.CompletionItem).init(alloc);
                        defer completionItems.deinit();

                        for (completions.items) |item| {
                            try completionItems.append(lsp.types.CompletionItem{
                                .label = item.@"0",
                                .kind = item.@"1",
                                .textEdit = .{ .TextEdit = .{ .range = .{
                                    .start = .{
                                        .line = params.position.line,
                                        .character = @max(start, 0),
                                    },
                                    .end = .{
                                        .line = params.position.line,
                                        .character = @max(end, 0),
                                    },
                                }, .newText = item.@"0" } },
                            });
                        }

                        try transport.any().writeResponse(
                            alloc,
                            request.id,
                            lsp.types.CompletionList,
                            .{ .isIncomplete = false, .items = completionItems.items },
                            .{},
                        );
                    } else {
                        try transport.any().writeResponse(alloc, request.id, void, {}, .{});
                    }
                },
                .@"textDocument/definition" => |params| {
                    const account = state.findAccount(params.textDocument.uri, params.position) orelse {
                        try transport.any().writeResponse(alloc, request.id, void, {}, .{});
                        continue :loop;
                    };
                    const result_uri, const result_line = state.project.get_account_open_pos(account.slice) orelse {
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
                    const account = state.findAccount(uri, params.position) orelse {
                        try transport.any().writeResponse(alloc, request.id, void, {}, .{});
                        continue :loop;
                    };
                    var highlights = std.ArrayList(lsp.types.DocumentHighlight).init(alloc);
                    defer highlights.deinit();
                    var iter = state.project.accountIterator(uri);
                    while (iter.next()) |next| {
                        if (std.mem.eql(u8, next.token.slice, account.slice)) {
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
                .@"textDocument/prepareRename" => |params| {
                    const account = state.findAccount(params.textDocument.uri, params.position) orelse {
                        try transport.any().writeResponse(alloc, request.id, void, {}, .{});
                        continue :loop;
                    };
                    try transport.any().writeResponse(alloc, request.id, lsp.types.PrepareRenameResult, .{
                        .literal_1 = .{
                            .range = .{
                                .start = .{
                                    .line = @intCast(account.line),
                                    .character = @intCast(account.start_col),
                                },
                                .end = .{
                                    .line = @intCast(account.line),
                                    .character = @intCast(account.end_col),
                                },
                            },
                            .placeholder = account.slice,
                        },
                    }, .{});
                },
                .@"textDocument/rename" => |params| {
                    const uri = params.textDocument.uri;
                    const account = state.findAccount(uri, params.position) orelse {
                        try transport.any().writeResponse(alloc, request.id, void, {}, .{});
                        continue :loop;
                    };

                    var map = std.AutoHashMap(u32, std.ArrayList(lsp.types.TextEdit)).init(alloc);
                    defer {
                        var iter = map.valueIterator();
                        while (iter.next()) |v| v.deinit();
                        map.deinit();
                    }

                    var iter = state.project.accountIterator(null);
                    while (iter.next()) |next| {
                        const token = next.token;
                        if (std.mem.eql(u8, token.slice, account.slice)) {
                            const entry = try map.getOrPut(next.file);
                            if (!entry.found_existing) entry.value_ptr.* = std.ArrayList(lsp.types.TextEdit).init(alloc);
                            try entry.value_ptr.append(.{
                                .range = .{
                                    .start = .{
                                        .line = @intCast(token.line),
                                        .character = @intCast(token.start_col),
                                    },
                                    .end = .{
                                        .line = @intCast(token.line),
                                        .character = @intCast(token.end_col),
                                    },
                                },
                                .newText = params.newName,
                            });
                        }
                    }

                    var changes = lsp.parser.Map([]const u8, []const lsp.types.TextEdit){};
                    defer changes.deinit(alloc);

                    var map_iter = map.iterator();
                    while (map_iter.next()) |kv| {
                        const file_uri = state.project.uris.items[kv.key_ptr.*];
                        try changes.map.put(alloc, file_uri.value, kv.value_ptr.items);
                    }

                    try transport.any().writeResponse(alloc, request.id, lsp.types.WorkspaceEdit, .{ .changes = changes }, .{});
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
    }
}

fn mkDiagnostic(err: ErrorDetails, alloc: Allocator) !lsp.types.Diagnostic {
    return .{
        .severity = switch (err.severity) {
            .err => .Error,
            .warn => .Warning,
        },
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
    // Check and store client capabilities
    if (params.capabilities.general) |general| {
        if (general.positionEncodings) |encodings| {
            for (encodings) |encoding| {
                if (encoding == .@"utf-16") state.clientCapabilities.utf16_position_encoding = true;
            }
        }
        if (!state.clientCapabilities.utf16_position_encoding) return .{
            .fail_message = try alloc.dupe(u8, "Client doesn't support utf-16 position encoding"),
        };
    } else return .{
        .fail_message = try alloc.dupe(u8, "Client doesn't have general capabilities defined"),
    };

    // Load config
    if (params.workspaceFolders == null) return .{
        .fail_message = try alloc.dupe(u8, "No workspace folder"),
    };
    const workspace_folders = params.workspaceFolders.?;
    if (workspace_folders.len != 1) return .{
        .fail_message = try alloc.dupe(u8, "Expected one workspace folder"),
    };
    var root = workspace_folders[0].name;
    std.log.debug("Workspace root: {s}", .{root});

    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);
    std.log.debug("Current working dir: {s}", .{cwd});

    if (!std.fs.path.isAbsolute(root)) {
        root = cwd;
    }

    std.log.debug("Looking for config in {s}", .{root});

    const config = Config.load_from_dir(alloc, root) catch |err| switch (err) {
        error.FileNotFound => return .{
            .fail_message = try alloc.dupe(u8, "No config found. Make sure to put a `zigcount.config` file in the workspace folder"),
        },
        error.InvalidConfig => return .{
            .fail_message = try alloc.dupe(u8, "Invalid config. The config should contain a line like `root = file.bean` where file.bean is relative to the workspace root"),
        },
        else => return .{
            .fail_message = try std.fmt.allocPrint(alloc, "Error: {s}", .{@errorName(err)}),
        },
    };
    defer config.deinit(alloc);

    std.log.debug("Loaded config: {any}", .{config});
    state.initialize(alloc, config.root) catch |err| switch (err) {
        error.FileNotFound => return .{
            .fail_message = try std.fmt.allocPrint(alloc, "Could not open `{s}` defined in your `zigcount.config` file", .{config.root}),
        },
        else => return .{
            .fail_message = try std.fmt.allocPrint(alloc, "Error: {s}", .{@errorName(err)}),
        },
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
    @"textDocument/prepareRename": lsp.types.PrepareRenameParams,
    @"textDocument/rename": lsp.types.RenameParams,
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
