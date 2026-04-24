const std = @import("std");
const Allocator = std.mem.Allocator;

const Data = @import("data.zig");

fn GenericMap(K: type, V: type) type {
    return struct {
        const Self = @This();

        array: std.ArrayList(?V) = .{},

        pub fn initWithCapacity(capacity: usize) Self {
            const self = .{};
            try self.ensure(capacity);
            return self;
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.array.deinit(alloc);
        }

        pub fn get(self: *const Self, k: K) ?V {
            const i: usize = @intFromEnum(k);
            return if (i < self.array.items.len) self.array.items[i] else null;
        }

        pub fn getPtr(self: *const Self, k: K) ?*V {
            const i: usize = @intFromEnum(k);
            if (i >= self.array.items.len) return null;
            if (self.array.items[i] == null) return null;
            return &self.array.items[i].?;
        }

        pub fn put(self: *Self, alloc: Allocator, k: K, v: V) !void {
            const i: usize = @intFromEnum(k);
            try self.ensure(alloc, i);
            self.array.items[i] = v;
        }

        pub fn remove(self: *Self, k: K) void {
            const i: usize = @intFromEnum(k);
            if (i < self.array.items.len) self.array.items[i] = null;
        }

        /// Keeps capacity
        pub fn clear(self: *Self) void {
            @memset(self.array.items, null);
        }

        pub fn contains(self: *const Self, k: K) bool {
            return self.get(k) != null;
        }

        /// Linear scan — dense arrays keep no tally.
        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (self.array.items) |slot| if (slot != null) {
                n += 1;
            };
            return n;
        }

        /// Shallow copy. Caller is responsible for deep-copying values if V
        /// owns external memory.
        pub fn clone(self: *const Self, alloc: Allocator) !Self {
            return .{ .array = try self.array.clone(alloc) };
        }

        pub const Entry = struct {
            key: K,
            value_ptr: *V,
        };

        pub const Iterator = struct {
            parent: *const Self,
            index: usize = 0,

            pub fn next(it: *Iterator) ?Entry {
                const items = it.parent.array.items;
                while (it.index < items.len) : (it.index += 1) {
                    if (items[it.index] != null) {
                        const key: K = @enumFromInt(it.index);
                        const value_ptr = &items[it.index].?;
                        it.index += 1;
                        return .{ .key = key, .value_ptr = value_ptr };
                    }
                }
                return null;
            }
        };

        pub const ValueIterator = struct {
            parent: *const Self,
            index: usize = 0,

            pub fn next(it: *ValueIterator) ?*V {
                const items = it.parent.array.items;
                while (it.index < items.len) : (it.index += 1) {
                    if (items[it.index] != null) {
                        const value_ptr = &items[it.index].?;
                        it.index += 1;
                        return value_ptr;
                    }
                }
                return null;
            }
        };

        /// Yields keys by value (dense keys are derived from the slot index,
        /// so there is nothing to take a pointer to).
        pub const KeyIterator = struct {
            parent: *const Self,
            index: usize = 0,

            pub fn next(it: *KeyIterator) ?K {
                const items = it.parent.array.items;
                while (it.index < items.len) : (it.index += 1) {
                    if (items[it.index] != null) {
                        const key: K = @enumFromInt(it.index);
                        it.index += 1;
                        return key;
                    }
                }
                return null;
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{ .parent = self };
        }

        pub fn valueIterator(self: *const Self) ValueIterator {
            return .{ .parent = self };
        }

        pub fn keyIterator(self: *const Self) KeyIterator {
            return .{ .parent = self };
        }

        fn ensure(self: *Self, alloc: Allocator, i: usize) !void {
            if (i >= self.array.items.len)
                try self.array.ensureTotalCapacity(alloc, i + 1);
            while (i >= self.array.items.len) {
                self.array.appendAssumeCapacity(null);
            }
        }
    };
}

pub fn CurrencyMap(V: type) type {
    return GenericMap(Data.CurrencyIndex, V);
}

pub fn AccountMap(V: type) type {
    return GenericMap(Data.AccountIndex, V);
}

test {
    const alloc = std.testing.allocator;
    var map = CurrencyMap(usize){};
    defer map.deinit(alloc);

    const a: Data.CurrencyIndex = @enumFromInt(3);
    const b: Data.CurrencyIndex = @enumFromInt(6);
    const c: Data.CurrencyIndex = @enumFromInt(1);
    const d: Data.CurrencyIndex = @enumFromInt(9);

    try map.put(alloc, a, 4);
    try map.put(alloc, b, 7);
    try std.testing.expect(map.contains(a));
    try std.testing.expectEqual(map.get(a), 4);
    try std.testing.expectEqual(map.get(b), 7);
    try std.testing.expectEqual(map.get(c), null);
    try std.testing.expectEqual(map.get(d), null);

    try std.testing.expectEqual(map.count(), 2);

    map.clear();
    try std.testing.expectEqual(map.get(a), null);
    try std.testing.expectEqual(map.get(b), null);
    try std.testing.expectEqual(map.count(), 0);
}
