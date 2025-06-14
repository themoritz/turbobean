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

    while (true) {
        const json_message = try transport.readJsonMessage(gpa);
        defer gpa.free(json_message);

        const parsed_message: std.json.Parsed(Message) = try Message.parseFromSlice(
            gpa,
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
                    _ = params.capabilities;
                    try transport.any().writeResponse(
                        gpa,
                        request.id,
                        lsp.types.InitializeResult,
                        .{
                            .serverInfo = .{
                                .name = "zigcount language server",
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
                    _ = params;
                },
                .@"textDocument/didChange" => @panic("TODO: implement textDocument/didChange"),
                .@"textDocument/didClose" => |params| {
                    _ = params;
                },
                .other => {},
            },
            .response => @panic("Haven't sent any requests to the client"),
        }
    }
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
    @"textDocument/didOpen": lsp.types.DidOpenTextDocumentParams,
    @"textDocument/didChange": lsp.types.DidChangeTextDocumentParams,
    @"textDocument/didClose": lsp.types.DidCloseTextDocumentParams,
    other: lsp.MethodWithParams,
};
