const std = @import("std");
const builtin = @import("builtin");
const lsp = @import("lsp");

pub const std_options: std.Options = .{
    .log_level = std.log.default_level,
};

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn loop() !void {
    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var transport: lsp.TransportOverStdio = .init(std.io.getStdIn(), std.io.getStdOut());

    // keep track of opened documents
    var documents: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer {
        for (documents.keys()) |uri| gpa.free(uri);
        for (documents.values()) |source| gpa.free(source);
        documents.deinit(gpa);
    }

    while (true) {
        // read the unparsed JSON-RPC message
        const json_message = try transport.readJsonMessage(gpa);
        defer gpa.free(json_message);
        // std.log.debug("received message from client: {s}", .{json_message});

        // parse the message
        const parsed_message: std.json.Parsed(Message) = try Message.parseFromSlice(
            gpa,
            json_message,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed_message.deinit();

        // For the sake of simplicity, we will skip over some of the requirements for document synchronization and lifecycle messages:
        //
        // - https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_synchronization
        // - https://microsoft.github.io/language-server-protocol/specifications/specification-current/#lifeCycleMessages
        //
        // An actual LSP server implementation should try to comply with these requirements.

        switch (parsed_message.value) {
            .request => |request| std.log.debug("received '{s}' request from client", .{@tagName(request.params)}),
            .notification => |notification| std.log.debug("received '{s}' notification from client", .{@tagName(notification.params)}),
            .response => std.log.debug("received response from client", .{}),
        }

        // The order of exchanged messages will look similar to this:
        //
        // 1. receive `initialize` request and send response
        // 2. receive `initialized` notification
        // 3. receive various requests like `textDocument/formatting`
        // 4. receive `shutdown` request and send response
        // 5. receive `exit` notification

        switch (parsed_message.value) {
            // requests must send a response back to the client
            .request => |request| switch (request.params) {
                .initialize => |params| {
                    _ = params.capabilities; // the client capabilities tell the server what "features" the client supports
                    try transport.any().writeResponse(
                        gpa,
                        request.id,
                        lsp.types.InitializeResult,
                        .{
                            // the server capabilities tell the client what "features" the server supports
                            .serverInfo = .{
                                .name = "hello-server",
                            },
                            .capabilities = .{
                                .hoverProvider = .{ .bool = true },
                            },
                        },
                        .{ .emit_null_optional_fields = false },
                    );
                },
                .shutdown => try transport.any().writeResponse(gpa, request.id, void, {}, .{}),
                .@"textDocument/hover" => |params| {
                    _ = params;
                    const result = lsp.types.Hover{ .contents = .{ .MarkupContent = lsp.types.MarkupContent{
                        .kind = lsp.types.MarkupKind.plaintext,
                        .value = "Hello, world!",
                    } } };
                    try transport.any().writeResponse(gpa, request.id, lsp.types.Hover, result, .{});
                },
                .other => try transport.any().writeResponse(gpa, request.id, void, {}, .{}),
            },
            .notification => |notification| switch (notification.params) {
                .initialized => {},
                .exit => return,
                .@"textDocument/didOpen" => |params| {
                    // The client has given us a document. We must use it over what is actually located on the file system.

                    const duped_uri = try gpa.dupe(u8, params.textDocument.uri);
                    errdefer gpa.free(duped_uri);
                    const duped_text = try gpa.dupe(u8, params.textDocument.text);
                    errdefer gpa.free(duped_text);

                    const gop = try documents.getOrPutValue(gpa, duped_uri, duped_text);
                    if (gop.found_existing) @panic("document opened twice");
                },
                .@"textDocument/didChange" => @panic("TODO: implement textDocument/didChange"),
                .@"textDocument/didClose" => |params| {
                    const old_entry = documents.fetchOrderedRemove(params.textDocument.uri) orelse continue;
                    gpa.free(old_entry.key);
                    gpa.free(old_entry.value);
                },
                .other => {},
            },
            // We haven't sent any requests to the client.
            .response => @panic("TODO: implement response handler"),
        }
    }
}

const Message = lsp.Message(RequestMethods, NotificationMethods, .{});

const RequestMethods = union(enum) {
    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#initialize
    initialize: lsp.types.InitializeParams,
    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#shutdown
    shutdown,
    /// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocument_hover
    @"textDocument/hover": lsp.types.HoverParams,
    other: lsp.MethodWithParams,
};

const NotificationMethods = union(enum) {
    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#initialized
    initialized: lsp.types.InitializedParams,
    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#exit
    exit,
    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didOpen
    @"textDocument/didOpen": lsp.types.DidOpenTextDocumentParams,
    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didChange
    @"textDocument/didChange": lsp.types.DidChangeTextDocumentParams,
    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didClose
    @"textDocument/didClose": lsp.types.DidCloseTextDocumentParams,
    other: lsp.MethodWithParams,
};
