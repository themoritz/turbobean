const std = @import("std");
const Allocator = std.mem.Allocator;
const Self = @This();
const sapp = @import("sokol").app;
const geom = @import("geom.zig");
const Rect = geom.Rect;
const Point = geom.Point;
const main = @import("main.zig");

widget_pool: std.heap.MemoryPool(Widget),
widget_cache: std.AutoHashMap(Key, *Widget),

stack_parent: Stack(?*Widget) = .init(null),
stack_pref_width: Stack(Size) = .init(.{}),
stack_pref_height: Stack(Size) = .init(.{}),
stack_bg_color: Stack([4]f32) = .init(.{ 1, 1, 1, 0 }),

current_frame: u64,
input: Input = .{},

const Input = struct {
    mouse_pos: ?Point = null,
    mouse_down: bool = false,
    mouse_clicked: bool = false,
};

pub fn handle_event(self: *Self, event: sapp.Event) void {
    self.input.mouse_clicked = false;

    switch (event.type) {
        .MOUSE_MOVE => {
            self.input.mouse_pos = .{ .x = event.mouse_x, .y = event.mouse_y };
        },
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
        const hover = self.rect.contains(ui.input.mouse_down);
        return .{
            .widget = self,
            .hover = hover,
            .clicked = hover and ui.input.mouse_clicked,
            .mouse_down = hover and ui.input.mouse_down,
        };
    }
};

const Interaction = struct {
    widget: *Widget,
    hover: bool,
    clicked: bool,
    mouse_down: bool,
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

pub fn layout(self: *Self, window: Rect) !void {
    // Find root
    if (self.widget_cache.count() == 0) return;
    var root = self.widget_cache.valueIterator().next().?.*;
    while (root.parent) |p| root = p;

    // Calculate standalone sizes (pre-order)
    layoutStandalone(root);

    // Calculate upwards dependent sizes
    layoutUpwardDependent(root, 0, window.w);
    layoutUpwardDependent(root, 1, window.h);
}

fn layoutStandalone(w: *Widget) void {
    // Self
    for (0..1) |axis| {
        const size = w.semantic_size[axis];
        switch (size.kind) {
            .pixels => {
                if (axis == 0) w.rect.w = size.value;
                if (axis == 1) w.rect.h = size.value;
            },
            else => {
                // "not yet specified"
                w.rect.w = std.math.floatMax(f32);
                w.rect.h = std.math.floatMax(f32);
            },
        }
    }

    // Children
    var current = w.first;
    while (current) |c| {
        layoutStandalone(c);
        current = c.next;
    }
}

fn layoutUpwardDependent(w: *Widget, axis: u1, available: ?f32) void {
    // Self
    const size = w.semantic_size[axis];
    if (available) |av| {
        switch (size.kind) {
            .percent_of_parent => {
                if (axis == 0) w.rect.w = av * size.value;
                if (axis == 1) w.rect.h = av * size.value;
            },
            else => {},
        }
    }

    // Children
    var current = w.first;
    while (current) |c| {
        const av = switch (axis) {
            0 => if (w.rect.w == std.math.floatMax(f32)) null else w.rect.w,
            1 => if (w.rect.h == std.math.floatMax(f32)) null else w.rect.h,
        };
        layoutUpwardDependent(c, av);
        current = c.next;
    }
}

pub fn render(self: *const Self, instance_buf: []main.Rect) void {
    const max = instance_buf.len;
    var i = 0;
    var it = self.widget_cache.valueIterator();
    while (it.next()) |v| : (i += 1) {
        if (i == max) break;
        const w = v.*;
        instance_buf[i] = main.Rect{
            .rect = .{ w.rect.x, w.rect.y, w.rect.w, w.rect.h },
            .color = w.bg_color,
        };
    }
}
