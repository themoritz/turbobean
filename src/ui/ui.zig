const std = @import("std");
const Allocator = std.mem.Allocator;
const Self = @This();
const sapp = @import("sokol").app;
const geom = @import("geom.zig");
const Rect = geom.Rect;
const Point = geom.Point;
const main = @import("main.zig");
const Atlas = @import("atlas.zig");

alloc: Allocator,

widget_pool: std.heap.MemoryPool(Widget),
widget_cache: std.AutoHashMap(Key, *Widget),
atlas: *Atlas,

stacks: AttributeStacks = .{},

current_frame: u64,
input: Input = .{},

const Input = struct {
    mouse_pos: ?Point = null,
    mouse_down: bool = false,
    mouse_clicked: bool = false,
};

/// Single source of truth for every attribute:
/// - field name is the attribute name used in `push`/`pop`
/// - field type is what gets stacked
/// - field default is the value `top()` returns when the stack is empty
pub const BuildAttributes = struct {
    parent: ?*Widget = null,
    width: Size = .{},
    height: Size = .{},
    axis: u1 = 1,
    bg_color: [4]f32 = .{ 1, 1, 1, 0 },
    border_thickness: f32 = 0,
    flags: Widget.Flags = .{},

    /// Semantic size on the given layout axis (0 = width, 1 = height).
    pub fn size(self: BuildAttributes, axis: u1) Size {
        return switch (axis) {
            0 => self.width,
            1 => self.height,
        };
    }
};

/// Used for `push`
pub const Attribute = blk: {
    const style_fields = @typeInfo(BuildAttributes).@"struct".fields;
    const n = style_fields.len;
    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    var values: [n]usize = undefined;
    for (style_fields, 0..) |sf, i| {
        names[i] = sf.name;
        types[i] = sf.type;
        values[i] = i;
    }
    const Tag = @Enum(usize, .exhaustive, &names, &values);
    break :blk @Union(.auto, Tag, &names, &types, &@splat(.{}));
};

/// Used for `pop`
pub const AttributeTag = std.meta.Tag(Attribute);

/// A struct with one `Stack(FieldType)` per `BuildAtrribute` field
const AttributeStacks = blk: {
    const style_fields = @typeInfo(BuildAttributes).@"struct".fields;
    var names: [style_fields.len][]const u8 = undefined;
    var types: [style_fields.len]type = undefined;
    var attrs: [style_fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (style_fields, 0..) |sf, i| {
        const S = Stack(sf.type);
        names[i] = sf.name;
        types[i] = S;
        // Seed each stack with the matching Style field's default.
        attrs[i] = .{ .default_value_ptr = @ptrCast(&@as(S, .{ .default = sf.defaultValue().? })) };
    }
    break :blk @Struct(.auto, null, &names, &types, &attrs);
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
        // `value` is padding in this case
        text_content,
        percent_of_parent,
        children_sum,
    };
};

const Key = struct {
    key: u64,

    pub const zero = Key{ .key = 0 };

    // Seed from parent. Add str to the hash and optionally hash_arg
    pub fn fromString(seed: Key, str: []const u8, hash_arg: anytype) Key {
        var state = std.hash.Wyhash.init(seed.key);
        state.update(str);
        const type_info = @typeInfo(@TypeOf(hash_arg));
        switch (type_info) {
            .int,
            => {
                const bytes: []const u8 = std.mem.asBytes(&hash_arg);
                state.update(bytes);
            },
            .comptime_int => {
                const bytes: []const u8 = std.mem.asBytes(&@as(u32, hash_arg));
                state.update(bytes);
            },
            .void => {},
            else => {
                @compileLog(hash_arg);
                @compileError("Can't handle type of hash_arg");
            },
        }
        return .{ .key = state.final() };
    }
};

const Widget = struct {
    // Widget tree
    first: ?*Widget = null,
    last: ?*Widget = null,
    next: ?*Widget = null,
    prev: ?*Widget = null,

    // Provided by builders
    string: []const u8 = "",
    attrs: BuildAttributes = .{},

    // Computed by layout algo
    computed_position: [2]f32 = @splat(0),
    computed_size: [2]f32 = @splat(0),

    // Generation info
    key: Key,
    last_frame_touched: u64 = 0,

    // Persistent data
    hot_t: f32 = 0,
    active_t: f32 = 0,

    const Flags = packed struct {
        clickable: bool = false,
        floating: bool = false,
        draw_border: bool = false,

        pub fn merge(a: Flags, b: Flags) Flags {
            return @bitCast(@as(u3, @bitCast(a)) | @as(u3, @bitCast(b)));
        }

        pub fn without(a: Flags, b: Flags) Flags {
            return @bitCast(@as(u3, @bitCast(a)) & ~@as(u3, @bitCast(b)));
        }
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

        pub fn peek_top(self: *@This()) T {
            const last = self.values.getLastOrNull() orelse return self.default;
            return last.value;
        }

        pub fn clear(self: *@This()) void {
            self.values.clearRetainingCapacity();
        }
    };
}

pub fn init(alloc: Allocator, atlas: *Atlas) Self {
    return .{
        .alloc = alloc,
        .widget_cache = .init(alloc),
        .widget_pool = .empty,
        .atlas = atlas,
        .current_frame = 0,
    };
}

pub fn reset_stacks(self: *Self) void {
    inline for (@typeInfo(AttributeStacks).@"struct".fields) |f| {
        @field(self.stacks, f.name).clear();
    }
}

/// Snapshot the current top of every attribute stack into a `BuildAttributes`.
/// Reads each stack via `top()`, which auto-pops any `pushNext` entries.
fn stacks_top(self: *Self) BuildAttributes {
    var attrs: BuildAttributes = .{};
    inline for (@typeInfo(BuildAttributes).@"struct".fields) |f| {
        @field(attrs, f.name) = @field(self.stacks, f.name).top();
    }
    return attrs;
}

/// Push one style attribute, e.g. `ui.push(.{ .height = .{ .kind = .children_sum } })`.
/// The arg is an anonymous struct with exactly one field naming the attribute.
pub fn push(self: *Self, attr: Attribute) void {
    switch (attr) {
        inline else => |value, tag| {
            @field(self.stacks, @tagName(tag)).push(self.alloc, value) catch @panic("OOM");
        },
    }
}

/// Like `push`, but the value is auto-popped after the next `mkWidget` reads it.
pub fn pushNext(self: *Self, attr: Attribute) void {
    switch (attr) {
        inline else => |value, tag| {
            @field(self.stacks, @tagName(tag)).pushNext(self.alloc, value) catch @panic("OOM");
        },
    }
}

/// Pop one style attribute, e.g. `ui.pop(.height)`.
pub fn pop(self: *Self, comptime tag: AttributeTag) void {
    @field(self.stacks, @tagName(tag)).pop();
}

pub fn pushFlags(self: *Self, flags: Widget.Flags) void {
    self.push(.{ .flags = flags });
}

pub fn pushFlagsNext(self: *Self, flags: Widget.Flags) void {
    self.pushNext(.{ .flags = flags });
}

pub fn addFlags(self: *Self, flags: Widget.Flags) void {
    const current = self.stacks.flags.peek_top();
    self.pushFlags(current.merge(flags));
}

pub fn addFlagsNext(self: *Self, flags: Widget.Flags) void {
    const current = self.stacks.flags.peek_top();
    self.pushFlagsNext(current.merge(flags));
}

pub fn popFlags(self: *Self) void {
    self.pop(.flags);
}

pub fn getWidget(self: *Self, key: Key, alloc: Allocator) !*Widget {
    const entry = try self.widget_cache.getOrPut(key);
    if (!entry.found_existing) {
        const new_w = try self.widget_pool.create(alloc);
        new_w.* = .{ .key = key };
        entry.value_ptr.* = new_w;
    }
    const w = entry.value_ptr.*;
    w.last_frame_touched = self.current_frame;
    return w;
}

pub fn mkWidget(self: *Self, str: []const u8, hash_arg: anytype) *Widget {
    const attrs = self.stacks_top();
    const parent = attrs.parent;

    const seed = if (parent) |p| p.key else Key.zero;
    const key = Key.fromString(seed, str, hash_arg);
    const w = self.getWidget(key, self.alloc) catch @panic("OOM");

    w.attrs = attrs;
    if (parent) |p| p.appendChild(w);
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
            stale.append(arena, kv.key_ptr.*) catch @panic("OOM");
        } else {
            // Delete tree structure for what's left
            w.attrs.parent = null;
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
    while (root.attrs.parent) |p| root = p;

    for (0..2) |ax| {
        const axis: u1 = @intCast(ax);
        self.layoutStandalone(root, axis);
        layoutUpwardDependent(root, axis, window[axis]);
        layoutDownwardDependent(root, axis);
        root.computed_position[axis] = 0;
        layoutComputePositions(root, axis);
    }
}

fn layoutStandalone(self: *Self, w: *Widget, axis: u1) void {
    // Self
    switch (w.attrs.size(axis).kind) {
        .pixels => {
            w.computed_size[axis] = w.attrs.size(axis).value;
        },
        .text_content => {
            const px = main.textPx();
            switch (axis) {
                0 => {
                    // Sum glyph advances across the string for the text width.
                    var width: f32 = 0;
                    for (w.string) |ch| {
                        const g = self.atlas.glyph(@intCast(ch), px) orelse continue;
                        width += g.advance;
                    }
                    w.computed_size[axis] = width + 2 * w.attrs.size(axis).value;
                },
                1 => {
                    // A single line of text is one line height tall.
                    const lm = self.atlas.lineMetrics(px);
                    w.computed_size[axis] = lm.line_height + 2 * w.attrs.size(axis).value;
                },
            }
        },
        else => {},
    }

    // Children
    var current = w.first;
    while (current) |c| {
        self.layoutStandalone(c, axis);
        current = c.next;
    }
}

fn layoutUpwardDependent(w: *Widget, axis: u1, available: f32) void {
    // Self
    var size = available;
    switch (w.attrs.size(axis).kind) {
        .percent_of_parent => {
            size = available * w.attrs.size(axis).value;
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
        if (!c.attrs.flags.floating) {
            if (w.attrs.axis == axis) {
                sum += c.computed_size[axis];
            } else {
                sum = @max(sum, c.computed_size[axis]);
            }
        }
    }

    // Self
    switch (w.attrs.size(axis).kind) {
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
        if (!c.attrs.flags.floating) {
            if (w.attrs.axis == axis) {
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
    while (it.next()) |v| {
        if (i == max) break;
        const w = v.*;

        // Background / border quad for the widget itself.
        instance_buf[i] = main.Rect{
            .rect = .{
                @floor(w.computed_position[0]),
                @floor(w.computed_position[1]),
                @floor(w.computed_size[0]),
                @floor(w.computed_size[1]),
            },
            .color = w.attrs.bg_color,
            .border_thickness = w.attrs.border_thickness,
        };
        i += 1;

        // Text glyph quads for widgets sized to their text content.
        if (w.string.len != 0 and
            (w.attrs.width.kind == .text_content or w.attrs.height.kind == .text_content))
        {
            i += self.renderText(w, instance_buf[i..]);
        }
    }
    return i;
}

/// Emit one textured quad per glyph of `w.string`, baseline-aligned within the
/// widget's box. Returns how many instances were written (bounded by `out.len`).
fn renderText(self: *const Self, w: *Widget, out: []main.Rect) usize {
    const px = main.textPx();
    const lm = self.atlas.lineMetrics(px);

    // Honor `value` padding stored on the text_content axes (see Size.Kind).
    const pad_x = w.attrs.width.value;
    const pad_y = w.attrs.height.value;

    var pen_x: f32 = @round(w.computed_position[0] + pad_x);
    const baseline: f32 = @round(w.computed_position[1] + pad_y + lm.ascent);

    var n: usize = 0;
    for (w.string) |ch| {
        if (n == out.len) break;
        const g = self.atlas.glyph(@intCast(ch), px) orelse continue;
        if (g.w > 0 and g.h > 0) {
            out[n] = .{
                .rect = .{
                    @round(pen_x + g.bearing_x),
                    @round(baseline - g.bearing_y),
                    g.w,
                    g.h,
                },
                .color = .{ 1, 1, 1, 1 },
                .uv = .{ g.u0, g.v0, g.u1, g.v1 },
                .use_texture = 1,
            };
            n += 1;
        }
        pen_x += g.advance;
    }
    return n;
}
