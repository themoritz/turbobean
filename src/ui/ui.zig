const std = @import("std");
const Allocator = std.mem.Allocator;
const Self = @This();
const sapp = @import("sokol").app;
const geom = @import("geom.zig");
const Rect = geom.Rect;
const Point = geom.Point;
const main = @import("main.zig");

alloc: Allocator,

widget_pool: std.heap.MemoryPool(Widget),
widget_cache: std.AutoHashMap(Key, *Widget),

stack_parent: Stack(?*Widget) = .init(null),
stack_pref_width: Stack(Size) = .init(.{}),
stack_pref_height: Stack(Size) = .init(.{}),
stack_pref_axis: Stack(u1) = .init(1),
stack_bg_color: Stack([4]f32) = .init(.{ 1, 1, 1, 0 }),
stack_border_thickness: Stack(f32) = .init(0),

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
    first: ?*Widget = null,
    last: ?*Widget = null,
    next: ?*Widget = null,
    prev: ?*Widget = null,
    parent: ?*Widget = null,

    // Provided by builders
    flags: Flags = .{},
    string: []const u8 = "",
    semantic_size: [2]Size = @splat(.{}),
    semantic_child_layout_axis: u1 = 1,
    bg_color: [4]f32 = @splat(1),
    border_thickness: f32 = 0,

    // Computed by layout algo
    computed_position: [2]f32 = @splat(0),
    computed_size: [2]f32 = @splat(0),

    // Generation info
    last_frame_touched: u64 = 0,

    // Persistent data
    hot_t: f32 = 0,
    active_t: f32 = 0,

    const Flags = struct {
        clickable: bool = false,
        floating: bool = false,
    };

    pub fn appendChild(self: *Widget, child: *Widget) void {
        if (self.last) |last| {
            self.last = child;
            last.next = child;
            child.prev = last;
            child.next = null;
        } else {
            self.last = child;
            self.first = child;
            child.prev = null;
            child.next = null;
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

        pub fn init(default: T) @This() {
            return .{ .default = default };
        }

        pub fn push(self: *@This(), alloc: std.mem.Allocator, t: T) !void {
            try self.values.append(alloc, .{ .value = t, .auto_pop = false });
        }

        pub fn pushNext(self: *@This(), alloc: std.mem.Allocator, t: T) !void {
            try self.values.append(alloc, .{ .value = t, .auto_pop = true });
        }

        pub fn pop(self: *@This()) void {
            _ = self.values.pop();
        }

        pub fn top(self: *@This()) T {
            const last = self.values.getLastOrNull() orelse return self.default;
            if (last.auto_pop) self.pop();
            return last.value;
        }

        pub fn clear(self: *@This()) void {
            self.values.clearRetainingCapacity();
        }
    };
}

pub fn init(alloc: Allocator) Self {
    return .{
        .alloc = alloc,
        .widget_cache = .init(alloc),
        .widget_pool = .empty,
        .current_frame = 0,
    };
}

pub fn reset_stacks(self: *Self) void {
    self.stack_parent.clear();
    self.stack_pref_width.clear();
    self.stack_pref_height.clear();
    self.stack_pref_axis.clear();
    self.stack_bg_color.clear();
    self.stack_border_thickness.clear();
}

pub fn getWidget(self: *Self, key: Key, alloc: Allocator) !*Widget {
    const entry = try self.widget_cache.getOrPut(key);
    if (!entry.found_existing) {
        const new_w = try self.widget_pool.create(alloc);
        new_w.* = .{};
        entry.value_ptr.* = new_w;
    }
    const w = entry.value_ptr.*;
    w.last_frame_touched = self.current_frame;
    return w;
}

pub fn mkWidget(self: *Self, key: Key, str: []const u8) !*Widget {
    const w = try self.getWidget(key, self.alloc);

    w.parent = self.stack_parent.top();
    if (w.parent) |parent| parent.appendChild(w);

    w.semantic_size = .{ self.stack_pref_width.top(), self.stack_pref_height.top() };
    w.semantic_child_layout_axis = self.stack_pref_axis.top();
    w.bg_color = self.stack_bg_color.top();
    w.border_thickness = self.stack_border_thickness.top();
    w.string = str;

    return w;
}

pub fn prune(self: *Self, arena: Allocator) !void {
    // Collect stale widgets
    var stale = std.ArrayList(Key).empty;
    var it = self.widget_cache.iterator();

    while (it.next()) |kv| {
        var w = kv.value_ptr.*;

        if (w.last_frame_touched < self.current_frame) {
            self.widget_pool.destroy(w);
            try stale.append(arena, kv.key_ptr.*);
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

pub fn layout(self: *Self, window: [2]f32) !void {
    // Find root
    if (self.widget_cache.count() == 0) return;
    var it = self.widget_cache.valueIterator();
    var root = it.next().?.*;
    while (root.parent) |p| root = p;

    for (0..2) |ax| {
        const axis: u1 = @intCast(ax);
        layoutStandalone(root, axis);
        layoutUpwardDependent(root, axis, window[axis]);
        layoutDownwardDependent(root, axis);
        root.computed_position[axis] = 0;
        layoutComputePositions(root, axis);
    }
}

fn layoutStandalone(w: *Widget, axis: u1) void {
    // Self
    switch (w.semantic_size[axis].kind) {
        .pixels => {
            w.computed_size[axis] = w.semantic_size[axis].value;
        },
        else => {},
    }

    // Children
    var current = w.first;
    while (current) |c| {
        layoutStandalone(c, axis);
        current = c.next;
    }
}

fn layoutUpwardDependent(w: *Widget, axis: u1, available: f32) void {
    // Self
    var size = available;
    switch (w.semantic_size[axis].kind) {
        .percent_of_parent => {
            size = available * w.semantic_size[axis].value;
            w.computed_size[axis] = size;
        },
        .pixels => {
            size = w.computed_size[axis];
        },
        else => {},
    }

    // Children
    var current = w.first;
    while (current) |c| {
        layoutUpwardDependent(c, axis, size);
        current = c.next;
    }
}

fn layoutDownwardDependent(w: *Widget, axis: u1) void {
    // Children
    var sum: f32 = 0;
    var current = w.first;
    while (current) |c| {
        layoutDownwardDependent(c, axis);
        current = c.next;
        if (!c.flags.floating) {
            if (w.semantic_child_layout_axis == axis) {
                sum += c.computed_size[axis];
            } else {
                sum = @max(sum, c.computed_size[axis]);
            }
        }
    }

    // Self
    switch (w.semantic_size[axis].kind) {
        .children_sum => {
            w.computed_size[axis] = sum;
        },
        else => {},
    }
}

fn layoutComputePositions(w: *Widget, axis: u1) void {
    // Self
    var position: f32 = 0;
    var current = w.first;
    while (current) |c| {
        c.computed_position[axis] = w.computed_position[axis] + position;
        if (!c.flags.floating) {
            if (w.semantic_child_layout_axis == axis) {
                position += c.computed_size[axis];
            }
        }
        current = c.next;
    }

    // Children
    var current_rec = w.first;
    while (current_rec) |c| {
        layoutComputePositions(c, axis);
        current_rec = c.next;
    }
}

// Returns how many instances emitted
pub fn render(self: *const Self, instance_buf: []main.Rect) usize {
    const max = instance_buf.len;
    var i: usize = 0;
    var it = self.widget_cache.valueIterator();
    while (it.next()) |v| : (i += 1) {
        if (i == max) break;
        const w = v.*;
        instance_buf[i] = main.Rect{
            .rect = .{
                @floor(w.computed_position[0]),
                @floor(w.computed_position[1]),
                @floor(w.computed_size[0]),
                @floor(w.computed_size[1]),
            },
            .color = w.bg_color,
            .border_thickness = w.border_thickness,
        };
    }
    return i;
}
