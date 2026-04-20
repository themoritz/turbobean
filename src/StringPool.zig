//! Interning pool for deduplicated strings.
//! Strings are concatenated into a single byte arena and addressed by `Index`.
//! Lookup uses an adapter-based hashmap so `intern` doesn't copy on a hit.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();

pub const Index = enum(u32) {
    _,

    pub fn toOptional(i: Index) OptionalIndex {
        const result: OptionalIndex = @enumFromInt(@intFromEnum(i));
        std.debug.assert(result != .none);
        return result;
    }
};

pub const OptionalIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oi: OptionalIndex) ?Index {
        return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
    }

    pub fn fromOptional(oi: ?Index) OptionalIndex {
        return if (oi) |i| i.toOptional() else .none;
    }
};

bytes: std.ArrayList(u8),
/// `starts.items.len == num_strings + 1`. `starts[i]` is the offset of string `i`;
/// `starts[num_strings]` is the byte-arena length (sentinel).
starts: std.ArrayList(u32),
map: std.HashMapUnmanaged(Index, void, IndexContext, std.hash_map.default_max_load_percentage),

pub fn init(alloc: Allocator) !Self {
    var starts: std.ArrayList(u32) = .{};
    try starts.append(alloc, 0);
    return .{
        .bytes = .{},
        .starts = starts,
        .map = .{},
    };
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    self.bytes.deinit(alloc);
    self.starts.deinit(alloc);
    self.map.deinit(alloc);
}

pub fn count(self: *const Self) u32 {
    return @intCast(self.starts.items.len - 1);
}

pub fn get(self: *const Self, idx: Index) []const u8 {
    const i = @intFromEnum(idx);
    const start = self.starts.items[i];
    const end = self.starts.items[i + 1];
    return self.bytes.items[start..end];
}

pub fn getOptional(self: *const Self, oi: OptionalIndex) ?[]const u8 {
    const i = oi.unwrap() orelse return null;
    return self.get(i);
}

pub fn intern(self: *Self, alloc: Allocator, s: []const u8) !Index {
    const gop = try self.map.getOrPutContextAdapted(
        alloc,
        s,
        SliceAdapter{ .pool = self },
        IndexContext{ .pool = self },
    );
    if (!gop.found_existing) {
        // Reserve the new Index now; must match the order we append to bytes/starts.
        const new_idx: Index = @enumFromInt(self.count());
        try self.bytes.appendSlice(alloc, s);
        try self.starts.append(alloc, @intCast(self.bytes.items.len));
        gop.key_ptr.* = new_idx;
    }
    return gop.key_ptr.*;
}

const IndexContext = struct {
    pool: *const Self,

    pub fn hash(ctx: IndexContext, idx: Index) u64 {
        return std.hash.Wyhash.hash(0, ctx.pool.get(idx));
    }

    pub fn eql(_: IndexContext, a: Index, b: Index) bool {
        return a == b;
    }
};

const SliceAdapter = struct {
    pool: *const Self,

    pub fn hash(_: SliceAdapter, s: []const u8) u64 {
        return std.hash.Wyhash.hash(0, s);
    }

    pub fn eql(ctx: SliceAdapter, s: []const u8, idx: Index) bool {
        return std.mem.eql(u8, s, ctx.pool.get(idx));
    }
};

test "intern deduplicates and preserves identity" {
    const alloc = std.testing.allocator;
    var pool = try Self.init(alloc);
    defer pool.deinit(alloc);

    const a1 = try pool.intern(alloc, "USD");
    const a2 = try pool.intern(alloc, "EUR");
    const a3 = try pool.intern(alloc, "USD");
    try std.testing.expectEqual(a1, a3);
    try std.testing.expect(a1 != a2);
    try std.testing.expectEqualStrings("USD", pool.get(a1));
    try std.testing.expectEqualStrings("EUR", pool.get(a2));
    try std.testing.expectEqual(@as(u32, 2), pool.count());
}

test "intern handles empty string and many inserts" {
    const alloc = std.testing.allocator;
    var pool = try Self.init(alloc);
    defer pool.deinit(alloc);

    const empty = try pool.intern(alloc, "");
    try std.testing.expectEqualStrings("", pool.get(empty));

    var buf: [8]u8 = undefined;
    for (0..100) |i| {
        const s = try std.fmt.bufPrint(&buf, "s{d}", .{i});
        _ = try pool.intern(alloc, s);
    }
    try std.testing.expectEqual(@as(u32, 101), pool.count());
    // re-intern should not grow.
    _ = try pool.intern(alloc, "s42");
    try std.testing.expectEqual(@as(u32, 101), pool.count());
}
