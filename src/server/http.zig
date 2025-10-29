const std = @import("std");

/// Decode URL-encoded bytes.
pub fn decode_url_alloc(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var list = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len);
    defer list.deinit(allocator);

    var input_index: usize = 0;
    while (input_index < input.len) {
        defer input_index += 1;
        const byte = input[input_index];
        switch (byte) {
            '%' => {
                if (input_index + 2 >= input.len) return error.InvalidEncoding;
                list.appendAssumeCapacity(
                    try std.fmt.parseInt(u8, input[input_index + 1 .. input_index + 3], 16),
                );
                input_index += 2;
            },
            '+' => list.appendAssumeCapacity(' '),
            else => list.appendAssumeCapacity(byte),
        }
    }

    return list.toOwnedSlice(allocator);
}

test "decode_url" {
    try test_decode_url("abc", "abc");
    try test_decode_url("abc%20def", "abc def");
    try test_decode_url("abc%2Bdef", "abc+def");
    try test_decode_url("abc+def", "abc def");
    try test_decode_url(
        "%5C%C3%B6%2F%20%C3%A4%C3%B6%C3%9F%20~~.adas-https%3A%2F%2Fcanvas%3A123%2F%23ads%26%26sad",
        "\\ö/ äöß ~~.adas-https://canvas:123/#ads&&sad",
    );

    try test_decode_url_error("%", error.InvalidEncoding);
    try test_decode_url_error("%a", error.InvalidEncoding);
    try test_decode_url_error("%1", error.InvalidEncoding);
    try test_decode_url_error("123%45%6", error.InvalidEncoding);
    try test_decode_url_error("%zzzz", error.InvalidCharacter);
    try test_decode_url_error("%0\xff", error.InvalidCharacter);
}

fn test_decode_url(input: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const actual = try decode_url_alloc(alloc, input);
    defer alloc.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn test_decode_url_error(input: []const u8, err: anyerror) !void {
    const alloc = std.testing.allocator;
    const actual = decode_url_alloc(alloc, input);
    try std.testing.expectError(err, actual);
}

fn parse_from(allocator: std.mem.Allocator, comptime T: type, comptime name: []const u8, value: []const u8) !T {
    return switch (@typeInfo(T)) {
        .int => |info| switch (info.signedness) {
            .unsigned => try std.fmt.parseUnsigned(T, value, 10),
            .signed => try std.fmt.parseInt(T, value, 10),
        },
        .float => try std.fmt.parseFloat(T, value),
        .optional => |info| @as(T, try parse_from(allocator, info.child, name, value)),
        .@"enum" => std.meta.stringToEnum(T, value) orelse return error.InvalidEnumValue,
        .bool => std.mem.eql(u8, value, "true"),
        else => switch (T) {
            []const u8 => try allocator.dupe(u8, value),
            [:0]const u8 => try allocator.dupeZ(u8, value),
            else => {
                if (@hasDecl(T, "from_url_param")) {
                    return try T.from_url_param(value);
                } else {
                    std.debug.panic("Unsupported field type \"{s}\"", .{@typeName(T)});
                }
            },
        },
    };
}

fn parse_struct(allocator: std.mem.Allocator, comptime T: type, map: *const QueryPararms) !T {
    var ret: T = undefined;
    std.debug.assert(@typeInfo(T) == .@"struct");
    const struct_info = @typeInfo(T).@"struct";
    inline for (struct_info.fields) |field| {
        const entry = map.getEntry(field.name);

        if (entry) |e| {
            @field(ret, field.name) = try parse_from(allocator, field.type, field.name, e.value_ptr.*);
        } else if (field.defaultValue()) |default| {
            @field(ret, field.name) = default;
        } else if (@typeInfo(field.type) == .optional) {
            @field(ret, field.name) = null;
        } else return error.FieldEmpty;
    }

    return ret;
}

pub fn Query(comptime T: type) type {
    return struct {
        /// Returnes owned data
        pub fn parse(allocator: std.mem.Allocator, map: *const QueryPararms) !T {
            return parse_struct(allocator, T, map);
        }
    };
}

test Query {
    const alloc = std.testing.allocator;

    const T = struct {
        a: u8,
        b: ?bool,
        c: [:0]const u8,
    };
    const input = "/?a=1&b=true&c=abc";
    const expected = T{ .a = 1, .b = true, .c = "abc" };
    var request = try ParsedRequest.parse(alloc, input);
    defer request.deinit(alloc);
    const actual = try Query(T).parse(alloc, &request.params);
    defer alloc.free(actual.c);
    try std.testing.expectEqual(expected.a, actual.a);
    try std.testing.expectEqual(expected.b.?, actual.b.?);
    try std.testing.expectEqualStrings(expected.c, actual.c);

    // Missing value => null
    const input2 = "/?a=1&c=abc";
    var request2 = try ParsedRequest.parse(alloc, input2);
    defer request2.deinit(alloc);
    const actual2 = try Query(T).parse(alloc, &request2.params);
    defer alloc.free(actual2.c);
    try std.testing.expectEqual(null, actual2.b);
}

const QueryPararms = std.StringHashMap([]const u8);

pub const ParsedRequest = struct {
    path: []const u8,
    params: QueryPararms,

    /// Returns owned data
    pub fn parse(alloc: std.mem.Allocator, target: []const u8) !ParsedRequest {
        var pieces = std.mem.splitScalar(u8, target, '?');

        const path = if (pieces.next()) |piece|
            try alloc.dupe(u8, piece)
        else
            return error.MissingPath;
        errdefer alloc.free(path);

        var params = QueryPararms.init(alloc);
        errdefer params.deinit();

        if (pieces.next()) |query| {
            var pairs = std.mem.splitScalar(u8, query, '&');

            while (pairs.next()) |pair| {
                const field_idx = std.mem.indexOfScalar(u8, pair, '=') orelse return error.MissingSeperator;
                if (pair.len < field_idx + 2) return error.MissingValue;

                const key = pair[0..field_idx];
                const value = pair[(field_idx + 1)..];

                if (std.mem.indexOfScalar(u8, value, '=') != null) return error.MalformedPair;

                const decoded_key = try decode_url_alloc(alloc, key);
                errdefer alloc.free(decoded_key);

                const decoded_value = try decode_url_alloc(alloc, value);
                errdefer alloc.free(decoded_value);

                // Allow for duplicates (like with the URL params),
                // The last one just takes precedent.
                const entry = try params.getOrPut(decoded_key);
                if (entry.found_existing) {
                    alloc.free(decoded_key);
                    alloc.free(entry.value_ptr.*);
                }
                entry.value_ptr.* = decoded_value;
            }
        }

        return .{
            .path = path,
            .params = params,
        };
    }

    pub fn deinit(self: *ParsedRequest, alloc: std.mem.Allocator) void {
        var it = self.params.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.params.deinit();
        alloc.free(self.path);
    }
};

test "parse" {
    const input = "/?foo=bar";
    var req = try ParsedRequest.parse(std.testing.allocator, input);
    defer req.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(req.path, "/");
    try std.testing.expectEqualStrings(req.params.get("foo").?, "bar");
}

test "duplicates" {
    const input = "/?foo=bar&foo=baz";
    var req = try ParsedRequest.parse(std.testing.allocator, input);
    defer req.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(req.params.get("foo").?, "baz");
}

test "missing" {
    const input = "/foo?id=";
    const result = ParsedRequest.parse(std.testing.allocator, input);
    try std.testing.expectError(error.MissingValue, result);
}

test "missing sep" {
    const input = "/foo?id";
    const result = ParsedRequest.parse(std.testing.allocator, input);
    try std.testing.expectError(error.MissingSeperator, result);
}

test "malformed pair" {
    const input = "/foo?id=bar=baz";
    const result = ParsedRequest.parse(std.testing.allocator, input);
    try std.testing.expectError(error.MalformedPair, result);
}
