const std = @import("std");

/// A stack that lives on the stack
pub fn Stack(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined, // all on the stack
        len: usize = 0,

        const Self = @This();

        /// Push an item (returns error if full)
        pub fn push(self: *Self, item: T) error{Overflow}!void {
            if (self.len >= capacity) return error.Overflow;
            self.items[self.len] = item;
            self.len += 1;
        }

        /// Pop an item (panics if empty, use peek + drop for safety)
        pub fn pop(self: *Self) T {
            if (self.len == 0) @panic("pop on empty stack");
            self.len -= 1;
            return self.items[self.len];
        }
    };
}
