const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const builtin = @import("builtin");
const lsp = @import("lsp");
const Project = @import("project.zig");
const Config = @import("Config.zig");
const ErrorDetails = @import("ErrorDetails.zig");
const Token = @import("lexer.zig").Lexer.Token;
const completion = @import("lsp/completion.zig");
const semantic_tokens = @import("lsp/semantic_tokens.zig");
const Date = @import("date.zig").Date;
const Uri = @import("Uri.zig");
const Number = @import("number.zig").Number;

const Data = @import("data.zig");
const Ast = @import("Ast.zig");
const Renderer = @import("Renderer.zig");

const ArenaProject = struct {
    project: Project,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *ArenaProject) void {
        self.arena.deinit();
    }
};

const LspState = struct {
    alloc: Allocator,
    io: Io,
    arena_projects: std.ArrayList(ArenaProject),
    clientCapabilities: ClientCapabilities,

    pub fn init(alloc: Allocator, io: Io) LspState {
        return .{
            .alloc = alloc,
            .io = io,
            .arena_projects = .empty,
            .clientCapabilities = .{},
        };
    }

    pub fn deinit(self: *LspState) void {
        for (self.arena_projects.items) |*ap| ap.deinit();
    }

    fn initialize(self: *LspState, params: lsp.types.InitializeParams) !InitResult {
        // Check and store client capabilities
        if (params.capabilities.general) |general| {
            if (general.positionEncodings) |encodings| {
                for (encodings) |encoding| {
                    if (encoding == .@"utf-16") self.clientCapabilities.utf16_position_encoding = true;
                }
            }
            if (!self.clientCapabilities.utf16_position_encoding) return .{
                .fail_message = "Client doesn't support utf-16 position encoding",
            };
        } else return .{
            .fail_message = "Client doesn't have general capabilities defined",
        };

        if (params.workspaceFolders) |workspace_folders| {
            for (workspace_folders) |folder| {
                self.addWorkspaceFolder(folder) catch |err| {
                    std.log.err("Failed to load project for workspace folder '{s}': {s}", .{ folder.name, @errorName(err) });
                    continue;
                };
            }
        }

        self.logOpenProjects();
        return .{ .success = {} };
    }

    pub fn sendDiagnostics(self: *const LspState, alloc: Allocator, io: Io, transport: *lsp.Transport) !void {
        for (self.arena_projects.items) |ap| {
            var errors = try ap.project.collectErrors(alloc);
            var iter = errors.iterator();
            while (iter.next()) |kv| {
                var diagnostics = std.ArrayList(lsp.types.Diagnostic).empty;
                for (kv.value_ptr.items) |err| {
                    try diagnostics.append(alloc, try mkDiagnostic(err, alloc));
                }
                try transport.writeNotification(
                    io,
                    alloc,
                    "textDocument/publishDiagnostics",
                    lsp.types.publish_diagnostics.Params,
                    .{ .uri = kv.key_ptr.*, .diagnostics = diagnostics.items },
                    .{},
                );
            }
        }
    }

    pub fn findAccount(self: *const LspState, uri: []const u8, position: lsp.types.Position) ?Token {
        const project = self.getProjectForUri(uri) orelse return null;
        var iter = project.accountIterator(uri);
        return while (iter.next()) |next| {
            const same_line = next.token.start_line == position.line;
            const within_token = next.token.start_col <= position.character and next.token.end_col >= position.character;
            if (same_line and within_token) break next.token;
        } else null;
    }

    pub fn findTagOrLink(self: *const LspState, uri: []const u8, position: lsp.types.Position) ?Token {
        const project = self.getProjectForUri(uri) orelse return null;
        var iter = project.tagLinkIterator(uri);
        return while (iter.next()) |next| {
            const same_line = next.token.start_line == position.line;
            const within_token = next.token.start_col <= position.character and next.token.end_col >= position.character;
            if (same_line and within_token) break next.token;
        } else null;
    }

    pub fn getProjectForUri(self: *const LspState, uri: []const u8) ?*Project {
        for (self.arena_projects.items) |*ap| {
            if (ap.project.ownsFile(uri)) return &ap.project;
        }
        return null;
    }

    pub fn addWorkspaceFolder(self: *LspState, folder: lsp.types.workspace.Folder) !void {
        const root_file = self.getWorkspaceRootFile(folder) catch |err| {
            std.log.err("Failed to load project for workspace folder '{s}': {s}", .{ folder.name, @errorName(err) });
            return;
        };

        const uri = try Uri.from_absolute(self.alloc, root_file);

        try self.openProjectByRootUri(uri, null);
    }

    pub fn removeWorkspaceFolder(self: *LspState, folder: lsp.types.workspace.Folder) void {
        const root_file = self.getWorkspaceRootFile(folder) catch |err| {
            std.log.err("Failed to load config for workspace folder '{s}': {s}", .{ folder.name, @errorName(err) });
            return;
        };

        closeProjectByRootUri(self, root_file);
    }

    fn getWorkspaceRootFile(self: *LspState, folder: lsp.types.workspace.Folder) ![]const u8 {
        var uri = try Uri.from_raw(self.alloc, folder.uri);
        const config = try Config.load_from_dir(self.alloc, self.io, uri);

        return std.fs.path.join(self.alloc, &.{ uri.absolute(), config.root });
    }

    pub fn openProjectByRootUri(self: *LspState, uri: Uri, source: ?[:0]const u8) !void {
        var arena = try self.alloc.create(std.heap.ArenaAllocator);
        arena.* = .init(std.heap.page_allocator);
        errdefer arena.deinit();
        const project = try Project.load(arena.allocator(), self.io, uri, source);

        try self.arena_projects.append(self.alloc, .{ .arena = arena, .project = project });

        // Remove all projects that have a dependency of this project as their root
        const files = project.data.files.items;
        for (files[1..]) |dependency| {
            self.closeProjectByRootUri(dependency.uri.value);
        }
    }

    pub fn closeProjectByRootUri(self: *LspState, uri: []const u8) void {
        for (self.arena_projects.items, 0..) |*ap, i| {
            if (ap.project.hasRoot(uri)) {
                ap.deinit();
                _ = self.arena_projects.orderedRemove(i);
                std.log.debug("Closed project for: {s}", .{uri});
                return;
            }
        }
    }

    pub fn logOpenProjects(self: *const LspState) void {
        std.log.debug("Currently open projects:", .{});
        for (self.arena_projects.items) |ap| {
            const files = ap.project.data.files.items;
            std.log.debug("- {s}", .{files[0].uri.value});
            for (files[1..]) |f| {
                std.log.debug("  > {s}", .{f.uri.value});
            }
        }
    }
};

const ClientCapabilities = struct {
    utf16_position_encoding: bool = false,
};

pub fn loop(alloc: std.mem.Allocator, io: Io) !void {
    var read_buffer: [256]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, Io.File.stdin(), Io.File.stdout());
    const transport = &stdio_transport.transport;
    var timer = Io.Clock.Timestamp.now(io, .awake);
    var state = LspState.init(alloc, io);
    defer state.deinit();

    var arena_alloc = std.heap.ArenaAllocator.init(alloc);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    loop: while (true) : ({
        const elapsed = timer.untilNow(io).raw.toMilliseconds();
        std.log.info("Completed in {d} ms\n", .{elapsed});
        _ = arena_alloc.reset(.retain_capacity);
    }) {
        const json_message = try transport.readJsonMessage(io, arena);

        const parsed_message: std.json.Parsed(Message) = try Message.parseFromSlice(
            arena,
            json_message,
            .{ .ignore_unknown_fields = true },
        );

        switch (parsed_message.value) {
            .request => |request| std.log.info("Received '{s}' request", .{@tagName(request.params)}),
            .notification => |notification| std.log.info("Received '{s}' notification", .{@tagName(notification.params)}),
            .response => std.log.info("Received response from client", .{}),
        }
        timer = Io.Clock.Timestamp.now(io, .awake);

        switch (parsed_message.value) {
            .request => |request| switch (request.params) {
                .initialize => |params| {
                    if (params.workDoneToken) |token| {
                        var map: std.json.ObjectMap = .empty;
                        try map.put(arena, "kind", .{ .string = "begin" });
                        try map.put(arena, "title", .{ .string = "Initializing" });
                        try transport.writeNotification(
                            io,
                            arena,
                            "$/progress",
                            lsp.types.ProgressParams,
                            .{ .token = token, .value = std.json.Value{ .object = map } },
                            .{},
                        );
                    }
                    const init_result = try state.initialize(params);
                    switch (init_result) {
                        .fail_message => |message| {
                            std.log.err("Failed to initialize: {s}", .{message});
                            try transport.writeErrorResponse(
                                io,
                                arena,
                                request.id,
                                .{ .code = .internal_error, .message = message },
                                .{},
                            );
                            try transport.writeNotification(io, arena, "exit", void, {}, .{});
                            std.process.exit(1);
                        },
                        .success => {
                            try transport.writeResponse(
                                io,
                                arena,
                                request.id,
                                lsp.types.InitializeResult,
                                .{
                                    .serverInfo = .{
                                        .name = "turbobean language server",
                                    },
                                    .capabilities = .{
                                        .positionEncoding = .@"utf-16",
                                        .renameProvider = .{
                                            .rename_options = .{ .prepareProvider = true },
                                        },
                                        .documentHighlightProvider = .{ .bool = true },
                                        .definitionProvider = .{ .bool = true },
                                        .hoverProvider = .{ .bool = true },
                                        .completionProvider = .{
                                            .resolveProvider = false,
                                            .triggerCharacters = &.{ "#", "^", "2", "\"" },
                                        },
                                        .textDocumentSync = .{ .text_document_sync_options = .{
                                            .openClose = true,
                                            .change = lsp.types.TextDocument.SyncKind.Full,
                                        } },
                                        .semanticTokensProvider = .{ .semantic_tokens_options = .{
                                            .legend = .{
                                                .tokenTypes = std.meta.fieldNames(semantic_tokens.TokenType),
                                                .tokenModifiers = &.{},
                                            },
                                            .full = .{ .bool = true },
                                        } },
                                        .inlayHintProvider = .{ .inlay_hint_options = .{} },
                                        .workspace = .{ .workspaceFolders = .{
                                            .supported = true,
                                            .changeNotifications = .{ .bool = true },
                                        } },
                                    },
                                },
                                .{
                                    // VSCode doesn't understand that null means no capability.
                                    .emit_null_optional_fields = false,
                                },
                            );
                            if (params.workDoneToken) |token| {
                                var map: std.json.ObjectMap = .empty;
                                try map.put(arena, "kind", .{ .string = "end" });
                                try transport.writeNotification(
                                    io,
                                    arena,
                                    "$/progress",
                                    lsp.types.ProgressParams,
                                    .{ .token = token, .value = std.json.Value{ .object = map } },
                                    .{},
                                );
                            }
                        },
                    }
                },
                .shutdown => try transport.writeResponse(io, arena, request.id, void, {}, .{}),
                .@"textDocument/hover" => |params| {
                    const uri = params.textDocument.uri;
                    const position = params.position;
                    const project = state.getProjectForUri(uri) orelse {
                        std.log.warn("No project found for file {s}", .{uri});
                        try transport.writeResponse(io, arena, request.id, void, {}, .{});
                        continue :loop;
                    };
                    var iter = project.accountIterator(uri);
                    const account = while (iter.next()) |next| {
                        const same_line = next.token.start_line == position.line;
                        const within_token = next.token.start_col <= position.character and next.token.end_col >= position.character;
                        if (same_line and within_token and (next.kind == .posting or next.kind == .pad or next.kind == .pad_to)) break next.token;
                    } else {
                        std.log.warn("No account found for file {s} at line {d}", .{ uri, position.line });
                        try transport.writeResponse(io, arena, request.id, void, {}, .{});
                        continue :loop;
                    };

                    if (try project.accountInventoryUntilLine(arena, account.slice, uri, position.line)) |inv| {
                        var value = std.Io.Writer.Allocating.init(arena);
                        const writer = &value.writer;
                        {
                            try writer.writeAll("Before:\n");
                            try inv.before.hoverDisplay(&project.data.currencies, writer);
                        }
                        {
                            try writer.writeAll("\nAfter:\n");
                            try inv.after.hoverDisplay(&project.data.currencies, writer);
                        }

                        const result = lsp.types.Hover{
                            .contents = .{
                                .markup_content = lsp.types.MarkupContent{
                                    .kind = lsp.types.MarkupKind.plaintext,
                                    .value = value.written(),
                                },
                            },
                            .range = tokenRange(account),
                        };
                        try transport.writeResponse(io, arena, request.id, lsp.types.Hover, result, .{});
                    } else {
                        std.log.warn("No inventory found for file {s} at line {d}", .{ uri, position.line });
                        try transport.writeResponse(io, arena, request.id, void, {}, .{});
                        continue :loop;
                    }
                },
                .@"textDocument/completion" => |params| {
                    const project = state.getProjectForUri(params.textDocument.uri) orelse {
                        try transport.writeResponse(io, arena, request.id, void, {}, .{});
                        continue :loop;
                    };

                    const Completion = struct { []const u8, lsp.types.completion.Item.Kind };
                    var completions = std.ArrayList(Completion).empty;

                    var start: u32 = params.position.character;
                    var end: u32 = params.position.character;

                    blk: {
                        const file = project.data.files_by_uri.get(params.textDocument.uri) orelse break :blk;
                        const src = project.data.files.items[file].source.items;
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
                                    var iter = project.tags.keyIterator();
                                    while (iter.next()) |k| try completions.append(arena, .{ k.*, .Variable });
                                    start = start - 1;
                                },
                                '^' => {
                                    var iter = project.links.keyIterator();
                                    while (iter.next()) |k| try completions.append(arena, .{ k.*, .Reference });
                                    start = start - 1;
                                },
                                '2' => {
                                    const today = Date.today(io);
                                    const item = try std.fmt.allocPrint(arena, "{f}", .{today});
                                    try completions.append(arena, .{ item, .Event });
                                    start = start - 1;
                                },
                                '"' => {
                                    // TODO: Payee/narration
                                },
                                else => try transport.writeErrorResponse(
                                    io,
                                    arena,
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
                                var iter = project.accountsIterator();
                                while (iter.next()) |k| try completions.append(arena, .{ k, .EnumMember });
                                const word_start, const word_end = completion.getWordAround(line, params.position.character) orelse break :blk;
                                start = word_start;
                                end = word_end;
                            }
                        }
                    }

                    if (completions.items.len > 0) {
                        var completionItems = std.ArrayList(lsp.types.completion.Item).empty;

                        for (completions.items) |item| {
                            try completionItems.append(arena, lsp.types.completion.Item{
                                .label = item.@"0",
                                .kind = item.@"1",
                                .textEdit = .{ .text_edit = .{ .range = .{
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

                        try transport.writeResponse(
                            io,
                            arena,
                            request.id,
                            lsp.types.completion.List,
                            .{ .isIncomplete = false, .items = completionItems.items },
                            .{},
                        );
                    } else {
                        try transport.writeResponse(io, arena, request.id, void, {}, .{});
                    }
                },
                .@"textDocument/definition" => |params| {
                    const uri = params.textDocument.uri;
                    const project = state.getProjectForUri(uri) orelse {
                        try transport.writeResponse(io, arena, request.id, void, {}, .{});
                        continue :loop;
                    };
                    const account = state.findAccount(uri, params.position) orelse {
                        try transport.writeResponse(io, arena, request.id, void, {}, .{});
                        continue :loop;
                    };
                    const result_uri, const result_line = project.get_account_open_pos(account.slice) orelse {
                        try transport.writeResponse(io, arena, request.id, void, {}, .{});
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
                    try transport.writeResponse(io, arena, request.id, lsp.types.Location, result, .{});
                },
                .@"textDocument/documentHighlight" => |params| {
                    const uri = params.textDocument.uri;
                    const project = state.getProjectForUri(uri) orelse {
                        try transport.writeResponse(io, arena, request.id, void, {}, .{});
                        continue :loop;
                    };

                    var highlights = std.ArrayList(lsp.types.DocumentHighlight).empty;

                    // Try to find an account at the cursor position
                    if (state.findAccount(uri, params.position)) |account| {
                        var iter = project.accountIterator(uri);
                        while (iter.next()) |next| {
                            if (std.mem.eql(u8, next.token.slice, account.slice)) {
                                try highlights.append(arena, .{
                                    .range = tokenRange(next.token),
                                    .kind = .Text,
                                });
                            }
                        }
                    }
                    // Try to find a tag or link at the cursor position
                    else if (state.findTagOrLink(uri, params.position)) |taglink| {
                        var iter = project.tagLinkIterator(uri);
                        while (iter.next()) |next| {
                            if (std.mem.eql(u8, next.token.slice, taglink.slice)) {
                                try highlights.append(arena, .{
                                    .range = tokenRange(next.token),
                                    .kind = .Text,
                                });
                            }
                        }
                    }

                    try transport.writeResponse(io, arena, request.id, []lsp.types.DocumentHighlight, highlights.items, .{});
                },
                .@"textDocument/prepareRename" => |params| {
                    const range: lsp.types.Range, const placeholder: []const u8 =
                        if (state.findAccount(params.textDocument.uri, params.position)) |acc|
                            .{ tokenRange(acc), acc.slice }
                        else if (state.findTagOrLink(params.textDocument.uri, params.position)) |tl|
                            .{ tokenRangeSkipPrefix(tl), tl.slice[1..] }
                        else {
                            try transport.writeResponse(io, arena, request.id, void, {}, .{});
                            continue :loop;
                        };
                    try transport.writeResponse(io, arena, request.id, lsp.types.prepare_rename.Result, .{
                        .prepare_rename_placeholder = .{
                            .range = range,
                            .placeholder = placeholder,
                        },
                    }, .{});
                },
                .@"textDocument/rename" => |params| {
                    const uri = params.textDocument.uri;
                    const project = state.getProjectForUri(uri) orelse {
                        try transport.writeResponse(io, arena, request.id, void, {}, .{});
                        continue :loop;
                    };

                    const RenameKind = enum { account, taglink };
                    const target_kind: RenameKind, const target_slice: []const u8 =
                        if (state.findAccount(uri, params.position)) |acc|
                            .{ .account, acc.slice }
                        else if (state.findTagOrLink(uri, params.position)) |tl|
                            .{ .taglink, tl.slice }
                        else {
                            try transport.writeResponse(io, arena, request.id, void, {}, .{});
                            continue :loop;
                        };

                    var map = std.AutoHashMap(u32, std.ArrayList(lsp.types.TextEdit)).init(arena);

                    switch (target_kind) {
                        .account => {
                            var iter = project.accountIterator(null);
                            while (iter.next()) |next| {
                                const token = next.token;
                                if (std.mem.eql(u8, token.slice, target_slice)) {
                                    const entry = try map.getOrPut(next.file);
                                    if (!entry.found_existing) entry.value_ptr.* = std.ArrayList(lsp.types.TextEdit).empty;
                                    try entry.value_ptr.append(arena, .{
                                        .range = tokenRange(token),
                                        .newText = params.newName,
                                    });
                                }
                            }
                        },
                        .taglink => {
                            var iter = project.tagLinkIterator(null);
                            while (iter.next()) |next| {
                                const token = next.token;
                                if (std.mem.eql(u8, token.slice, target_slice)) {
                                    const entry = try map.getOrPut(next.file);
                                    if (!entry.found_existing) entry.value_ptr.* = std.ArrayList(lsp.types.TextEdit).empty;
                                    try entry.value_ptr.append(arena, .{
                                        .range = tokenRangeSkipPrefix(token),
                                        .newText = params.newName,
                                    });
                                }
                            }
                        },
                    }

                    var changes = lsp.parser.Map([]const u8, []const lsp.types.TextEdit){};

                    var map_iter = map.iterator();
                    while (map_iter.next()) |kv| {
                        const file_uri = project.data.files.items[kv.key_ptr.*].uri;
                        try changes.map.put(arena, file_uri.value, kv.value_ptr.items);
                    }

                    try transport.writeResponse(io, arena, request.id, lsp.types.WorkspaceEdit, .{ .changes = changes }, .{});
                },
                .@"textDocument/semanticTokens/full" => |params| {
                    const uri = params.textDocument.uri;
                    const project = state.getProjectForUri(uri) orelse {
                        try transport.writeResponse(io, arena, request.id, void, {}, .{});
                        continue :loop;
                    };
                    const file = project.data.files_by_uri.get(uri) orelse {
                        try transport.writeResponse(io, arena, request.id, void, {}, .{});
                        continue :loop;
                    };
                    const tokens = project.data.files.items[file].ast.tokens;
                    const data = try semantic_tokens.tokensToData(arena, tokens.items);
                    try transport.writeResponse(io, arena, request.id, lsp.types.semantic_tokens.Result, .{ .data = data.items }, .{});
                },
                .@"textDocument/inlayHint" => |params| {
                    const uri = params.textDocument.uri;
                    const project = state.getProjectForUri(uri) orelse {
                        try transport.writeResponse(io, arena, request.id, void, {}, .{});
                        continue :loop;
                    };
                    const file_idx = project.data.files_by_uri.get(uri) orelse {
                        try transport.writeResponse(io, arena, request.id, void, {}, .{});
                        continue :loop;
                    };
                    const file_data = &project.data.files.items[file_idx];

                    var hints = std.ArrayList(lsp.types.InlayHint).empty;

                    var entry_iter = project.data.iterEntriesOfKind(.transaction);
                    while (entry_iter.next()) |entry| {
                        if (entry.file() != file_idx) continue;
                        const tx = entry.payload().transaction;
                        if (tx.dirty()) continue;
                        var postings = tx.postings();

                        // Measure source dot-column for alignment and max frac
                        // width across source and inferred numbers. Also count
                        // plain vs number-inferred postings so we can suppress
                        // the lone hint when the user can trivially mirror a
                        // single plain posting.
                        var amount_dot_col: ?u32 = null;
                        var frac_width: usize = 0;
                        var plain_count: u32 = 0;
                        var num_inferred_count: u32 = 0;
                        while (postings.next()) |posting| {
                            const ast_node_idx = posting.astNode().unwrap() orelse continue;
                            const ap = file_data.ast.getExtra(
                                file_data.ast.node(ast_node_idx).posting,
                                Ast.Node.Posting,
                            );
                            const has_extras = ap.price.unwrap() != null or ap.lot_spec.unwrap() != null;
                            switch (file_data.ast.node(ap.amount)) {
                                .amount => |a| {
                                    if (a.number.unwrap()) |n| {
                                        const tok = file_data.ast.tokens.items[@intFromEnum(n)];
                                        const nw = Renderer.sliceNumberWidths(tok.slice);
                                        amount_dot_col = @max(amount_dot_col orelse 0, tok.start_col + @as(u32, @intCast(nw.int)));
                                        frac_width = @max(frac_width, nw.frac);
                                        if (!has_extras) plain_count += 1;
                                    } else if (posting.amountNumber()) |num| {
                                        var num_buf: [64]u8 = undefined;
                                        const formatted = try std.fmt.bufPrint(&num_buf, "{f}", .{num});
                                        frac_width = @max(frac_width, Renderer.sliceNumberWidths(formatted).frac);
                                        if (!has_extras) num_inferred_count += 1;
                                    }
                                },
                                else => {},
                            }
                        }
                        const skip_lone_inferred = tx.numPostings() == 2 and
                            plain_count == 1 and num_inferred_count == 1;

                        var postings2 = tx.postings();
                        while (postings2.next()) |posting| {
                            const account_tok = file_data.token(posting.accountToken());
                            if (account_tok.start_line < params.range.start.line or
                                account_tok.start_line > params.range.end.line) continue;

                            const ast_node_idx = posting.astNode().unwrap() orelse continue;
                            const ap = file_data.ast.getExtra(
                                file_data.ast.node(ast_node_idx).posting,
                                Ast.Node.Posting,
                            );

                            const resolved_number = posting.amountNumber();
                            const skip_this_amount = skip_lone_inferred and switch (file_data.ast.node(ap.amount)) {
                                .amount => |a| a.number.unwrap() == null and resolved_number != null,
                                else => false,
                            };
                            if (!skip_this_amount) try emitAmountHint(
                                arena,
                                &hints,
                                &file_data.ast,
                                file_data.ast.node(ap.amount),
                                resolved_number,
                                posting.amountCurrencyText(),
                                account_tok.start_line,
                                account_tok.end_col,
                                .{
                                    .target_col = amount_dot_col orelse account_tok.end_col + 2,
                                    .frac_width = frac_width,
                                },
                            );

                            if (ap.price.unwrap()) |price_node_idx| {
                                const price = posting.price() orelse continue;
                                const pa = file_data.ast.node(price_node_idx).price_annotation;
                                const at_token = file_data.ast.tokens.items[@intFromEnum(pa.total)];
                                try emitAmountHint(
                                    arena,
                                    &hints,
                                    &file_data.ast,
                                    file_data.ast.node(pa.amount),
                                    price.amount,
                                    price.amountCurrencyText(),
                                    at_token.end_line,
                                    at_token.end_col,
                                    null,
                                );
                            }
                        }
                    }

                    try transport.writeResponse(io, arena, request.id, []const lsp.types.InlayHint, hints.items, .{
                        .emit_null_optional_fields = false,
                    });
                },
                .other => try transport.writeResponse(io, arena, request.id, void, {}, .{}),
            },
            .notification => |notification| switch (notification.params) {
                .initialized => {
                    try state.sendDiagnostics(arena, io, transport);
                },
                .exit => return,
                .@"workspace/didChangeWorkspaceFolders" => |params| {
                    for (params.event.added) |folder| {
                        state.addWorkspaceFolder(folder) catch |err| {
                            std.log.err("Failed to add workspace folder '{s}': {s}", .{ folder.name, @errorName(err) });
                        };
                    }
                    for (params.event.removed) |folder| {
                        state.removeWorkspaceFolder(folder);
                    }
                    state.logOpenProjects();
                    try state.sendDiagnostics(arena, io, transport);
                },
                .@"textDocument/didOpen" => |params| {
                    const uri = params.textDocument.uri;

                    if (state.getProjectForUri(uri) == null) {
                        const owned_uri = try Uri.from_raw(arena, uri);
                        // Make null-terminated copy
                        const source = try arena.dupeZ(u8, params.textDocument.text);
                        try state.openProjectByRootUri(owned_uri, source);
                        state.logOpenProjects();
                        try state.sendDiagnostics(arena, io, transport);
                    }
                },
                .@"textDocument/didChange" => |params| {
                    const uri = params.textDocument.uri;
                    var project = state.getProjectForUri(uri) orelse {
                        std.log.warn("No project found for file {s}", .{uri});
                        continue :loop;
                    };

                    std.debug.assert(params.contentChanges.len == 1);
                    const text = switch (params.contentChanges[0]) {
                        .text_document_content_change_whole_document => |lit| lit.text,
                        else => @panic("Expected full text change"),
                    };
                    // Make a null-terminated copy
                    const null_terminated = try arena.dupeZ(u8, text);
                    try project.update_file(uri, null_terminated);
                    std.log.debug("Updated file {s}", .{uri});

                    try state.sendDiagnostics(arena, io, transport);
                },
                .@"textDocument/didClose" => |params| {
                    state.closeProjectByRootUri(params.textDocument.uri);
                    state.logOpenProjects();
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
        .range = tokenRange(err.token),
        .message = try err.message(alloc),
    };
}

const InitResult = union(enum) {
    success: void,
    fail_message: []const u8,
};

const Message = lsp.Message(RequestMethods, NotificationMethods, .{});

const RequestMethods = union(enum) {
    initialize: lsp.types.InitializeParams,
    shutdown,
    @"textDocument/hover": lsp.types.Hover.Params,
    @"textDocument/completion": lsp.types.completion.Params,
    @"textDocument/definition": lsp.types.Definition.Params,
    @"textDocument/documentHighlight": lsp.types.DocumentHighlight.Params,
    @"textDocument/prepareRename": lsp.types.prepare_rename.Params,
    @"textDocument/rename": lsp.types.rename.Params,
    @"textDocument/semanticTokens/full": lsp.types.semantic_tokens.Params,
    @"textDocument/inlayHint": lsp.types.InlayHint.Params,
    other: lsp.MethodWithParams,
};

const NotificationMethods = union(enum) {
    initialized: lsp.types.InitializedParams,
    exit,
    @"workspace/didChangeWorkspaceFolders": lsp.types.workspace.folders.DidChangeParams,
    @"textDocument/didOpen": lsp.types.TextDocument.DidOpenParams,
    @"textDocument/didChange": lsp.types.TextDocument.DidChangeParams,
    @"textDocument/didClose": lsp.types.TextDocument.DidCloseParams,
    other: lsp.MethodWithParams,
};

fn tokenRange(token: Token) lsp.types.Range {
    return .{
        .start = .{ .line = token.start_line, .character = token.start_col },
        .end = .{ .line = token.end_line, .character = token.end_col },
    };
}

/// Like tokenRange, but skips the first character of the token (e.g. the
/// leading `#` of a tag or `^` of a link).
fn tokenRangeSkipPrefix(token: Token) lsp.types.Range {
    return .{
        .start = .{ .line = token.start_line, .character = token.start_col + 1 },
        .end = .{ .line = token.end_line, .character = token.end_col },
    };
}

const Alignment = struct {
    target_col: u32,
    frac_width: usize,
};

/// Emit an inlay hint for an inferred amount (number and/or currency).
/// With alignment, positions the hint for column-aligned posting amounts.
/// Without alignment, positions after the last existing token (for price annotations).
fn emitAmountHint(
    alloc: Allocator,
    hints: *std.ArrayList(lsp.types.InlayHint),
    ast: *Ast,
    ast_node: Ast.Node,
    amount_number: ?Number,
    amount_currency: ?[]const u8,
    after_line: u32,
    after_col: u32,
    alignment: ?Alignment,
) !void {
    const ast_amount = switch (ast_node) {
        .amount => |a| a,
        else => return,
    };

    const num_inferred = ast_amount.number.unwrap() == null and amount_number != null;
    const cur_inferred = ast_amount.currency.unwrap() == null and amount_currency != null;
    if (!num_inferred and !cur_inferred) return;

    if (num_inferred) {
        const num = amount_number.?;
        var num_buf: [64]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&num_buf, "{f}", .{num});

        var label_buf = std.Io.Writer.Allocating.init(alloc);
        defer label_buf.deinit();
        const w = &label_buf.writer;

        if (cur_inferred) {
            // Both number and currency inferred
            if (alignment) |a| {
                const nw = Renderer.sliceNumberWidths(formatted);
                if (a.target_col > after_col + nw.int) {
                    try writeSpaces(w, a.target_col - after_col - nw.int);
                } else {
                    try writeSpaces(w, 2);
                }
                try w.writeAll(formatted);
                if (a.frac_width > nw.frac) try writeSpaces(w, a.frac_width - nw.frac);
            } else {
                try w.writeAll(formatted);
            }
            try w.writeByte(' ');
            try w.writeAll(amount_currency orelse "");

            try hints.append(alloc, .{
                .position = .{ .line = after_line, .character = after_col },
                .label = .{ .string = try label_buf.toOwnedSlice() },
                .paddingLeft = alignment == null,
            });
        } else if (alignment != null) {
            // Number inferred, currency in source (aligned): place before currency
            const cur_tok_idx = ast_amount.currency.unwrap() orelse return;
            const cur_tok = ast.tokens.items[@intFromEnum(cur_tok_idx)];
            try w.writeAll(formatted);
            try hints.append(alloc, .{
                .position = .{ .line = cur_tok.start_line, .character = cur_tok.start_col },
                .label = .{ .string = try label_buf.toOwnedSlice() },
                .paddingRight = true,
            });
        } else {
            // Number inferred (unaligned, e.g. price annotation): place at fallback
            try w.writeAll(formatted);
            try hints.append(alloc, .{
                .position = .{ .line = after_line, .character = after_col },
                .label = .{ .string = try label_buf.toOwnedSlice() },
                .paddingLeft = true,
            });
        }
    } else {
        // Only currency inferred: position after number token or at fallback
        var pos_line = after_line;
        var pos_col = after_col;
        if (ast_amount.number.unwrap()) |n| {
            const tok = ast.tokens.items[@intFromEnum(n)];
            pos_line = tok.end_line;
            pos_col = tok.end_col;
        }
        try hints.append(alloc, .{
            .position = .{ .line = pos_line, .character = pos_col },
            .label = .{ .string = try alloc.dupe(u8, amount_currency.?) },
            .paddingLeft = true,
        });
    }
}

fn writeSpaces(w: *std.Io.Writer, n: usize) !void {
    for (0..n) |_| try w.writeByte(' ');
}
