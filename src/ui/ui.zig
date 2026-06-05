const std = @import("std");
const Allocator = std.mem.Allocator;
const Self = @This();
const sapp = @import("sokol").app;

widget_pool: std.heap.MemoryPool(Widget),
widget_cache: std.AutoHashMap(Key, *Widget),

stack_parent: Stack(?*Widget) = .init(null),
stack_pref_width: Stack(Size) = .init(.{}),
stack_pref_height: Stack(Size) = .init(.{}),
stack_bg_color: Stack([4]f32) = .init(.{ 1, 1, 1, 0 }),

current_frame: u64,
input: Input = .{},

const Input = struct {
    mouse_pos: ?[2]f32 = null,
    mouse_down: bool = false,
    mouse_clicked: bool = false,
};

pub fn handle_event(self: *Self, event: sapp.Event) void {
    self.input.mouse_clicked = false;

    switch (event.type) {
        .MOUSE_MOVE => self.input.mouse_pos = .{ event.mouse_x, event.mouse_y },
        .MOUSE_DOWN => {
            self.input.mouse_down = true;
            self.input.mouse_clicked = true;
        },
        .MOUSE_UP => {
            self.input.mouse_down = false;
        },
        else => {},
    }
}

const Size = struct {
    kind: Kind = .null,
    value: f32 = 0,
    strictness: f32 = 0,

    const Kind = enum {
        null,
        pixels,
        percent_of_parent,
        children_sum,
    };
};

const Key = struct {
    key: u64,

    pub fn fromString(str: []const u8) Key {
        _ = str;
    }
};

const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

const Widget = struct {
    // Widget tree
    first: ?*Widget,
    last: ?*Widget,
    next: ?*Widget,
    prev: ?*Widget,
    parent: ?*Widget,

    // Provided by builders
    flags: Flags,
    string: []const u8,
    semantic_size: [2]Size,
    bg_color: [4]f32,

    // Computed by layout algo
    computed_rel_position: [2]f32,
    computed_size: [2]f32,
    rect: Rect,

    // Generation info
    last_frame_touched: u64 = 0,

    // Persistent data
    hot_t: f32 = 0,
    active_t: f32 = 0,

    const Flags = struct {
        clickable: bool = false,
    };

    pub fn appendChild(self: *Widget, child: *Widget) void {
        if (self.last) |last| {
            self.last = child;
            last.next = child;
            child.prev = last;
        } else {
            self.last = child;
            self.first = child;
        }
    }

    pub fn interact(self: *Widget, ui: *Self) Interaction {
        _ = ui;
        return .{
            .widget = self,
            // TODO:
            .clicked = false,
        };
    }
};

const Interaction = struct {
    widget: *Widget,
    clicked: bool,
};

pub fn Stack(comptime T: type) type {
    return struct {
        values: std.ArrayList(Node) = .empty,
        default: T,

        const Node = struct { value: T, auto_pop: bool };

        pub fn init(default: T) Stack(T) {
            return .{ .default = default };
        }

        pub fn push(self: *Stack, alloc: std.mem.Allocator, t: T) !void {
            try self.values.append(alloc, .{ .value = t, .auto_pop = false });
        }

        pub fn pushNext(self: *Stack, alloc: std.mem.Allocator, t: T) !void {
            try self.values.append(alloc, .{ .value = t, .auto_pop = true });
        }

        pub fn pop(self: *Stack) void {
            _ = self.values.pop();
        }

        pub fn top(self: *Stack) T {
            const last = self.values.getLastOrNull() orelse return self.default;
            if (last.auto_pop) self.pop();
            return last.value;
        }

        pub fn clear(self: *Stack) void {
            self.values.clearRetainingCapacity();
        }
    };
}

pub fn init(alloc: Allocator) Self {
    return .{
        .widget_cache = .init(alloc),
        .widget_pool = .empty,
        .current_frame = 0,
    };
}

pub fn getWidget(self: *Self, key: Key, alloc: Allocator) !*Widget {
    const entry = try self.widget_cache.getOrPut(key);
    if (!entry.found_existing) {
        const w = self.widget_pool.create(alloc);
        entry.value_ptr.* = w;
    }
    const w = entry.value_ptr.*;
    w.last_frame_touched = self.current_frame;
    return w;
}

pub fn mkWidget(self: *Self, key: Key, str: []const u8) !*Widget {
    const w = try self.getWidget(key);

    w.parent = self.stack_parent.top();
    if (w.parent) |parent| parent.appendChild(w);

    w.semantic_size = .{ self.stack_pref_width.top(), self.stack_pref_height.top() };
    w.bg_color = self.stack_bg_color.top();
    w.string = str;

    return w;
}

pub fn prune(self: *Self, arena: Allocator) void {
    // Collect stale widgets
    var stale = std.ArrayList(Key).empty;
    var it = self.widget_cache.iterator();

    while (it.next()) |kv| {
        var w = kv.value_ptr.*;

        if (w.last_frame_touched < self.current_frame) {
            self.widget_pool.destroy(w);
            stale.append(arena, kv.key_ptr.*);
        } else {
            // Delete tree structure for what's left
            w.parent = null;
            w.first = null;
            w.last = null;
            w.prev = null;
            w.next = null;
        }
    }

    // Prune
    for (stale.items) |key| _ = self.widget_cache.remove(key);
}
