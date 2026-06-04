const std = @import("std");
const ft = @import("freetype");
const sg = @import("sokol").gfx;

const atlas_w: i32 = 1024;
const atlas_h: i32 = 1024;
const pad: i32 = 1; // 1px gutter so linear sampling can't bleed between glyphs

pub const Glyph = struct {
    // Atlas UVs (normalized 0..1).
    u0: f32 = 0,
    v0: f32 = 0,
    u1: f32 = 0,
    v1: f32 = 0,
    // Placement, in pixels.
    w: f32 = 0,
    h: f32 = 0,
    bearing_x: f32 = 0, // left side bearing
    bearing_y: f32 = 0, // baseline -> top of bitmap (up positive)
    advance: f32 = 0, // pen advance
};

pub const LineMetrics = struct {
    ascent: f32,
    line_height: f32,
};

const Key = struct { cp: u21, px: u32 };

alloc: std.mem.Allocator,
lib: ft.Library,
face: ft.Face,
cur_px: u32 = 0, // pixel size currently set on the face (0 = none)

pixels: []u8, // CPU atlas, atlas_w * atlas_h, R8
dirty: bool = false, // CPU atlas changed since last GPU upload

// Shelf packer cursor (persists across insertions).
pen_x: i32 = pad,
pen_y: i32 = pad,
shelf_h: i32 = 0,

glyphs: std.AutoHashMapUnmanaged(Key, Glyph) = .{},

image: sg.Image = .{},
view: sg.View = .{},
sampler: sg.Sampler = .{},

const Atlas = @This();

pub fn init(alloc: std.mem.Allocator, font_path: [:0]const u8) !Atlas {
    const lib = try ft.Library.init();
    errdefer lib.deinit();
    const face = try lib.initFace(font_path, 0);
    errdefer face.deinit();

    const pixels = try alloc.alloc(u8, @intCast(atlas_w * atlas_h));
    @memset(pixels, 0);

    const image = sg.makeImage(.{
        .width = atlas_w,
        .height = atlas_h,
        .pixel_format = .R8,
        .usage = .{ .dynamic_update = true },
    });

    return .{
        .alloc = alloc,
        .lib = lib,
        .face = face,
        .pixels = pixels,
        .image = image,
        .view = sg.makeView(.{ .texture = .{ .image = image } }),
        .sampler = sg.makeSampler(.{ .min_filter = .LINEAR, .mag_filter = .LINEAR }),
    };
}

pub fn deinit(self: *Atlas) void {
    self.glyphs.deinit(self.alloc);
    self.alloc.free(self.pixels);
    self.face.deinit();
    self.lib.deinit();
}

fn setSize(self: *Atlas, px: u32) void {
    if (self.cur_px == px) return;
    _ = ft.c.FT_Set_Pixel_Sizes(self.face.handle, 0, px);
    self.cur_px = px;
}

/// Font vertical metrics at a given pixel size.
pub fn lineMetrics(self: *Atlas, px: u32) LineMetrics {
    self.setSize(px);
    const m = self.face.handle.*.size.*.metrics;
    return .{
        .ascent = @floatFromInt(m.ascender >> 6),
        .line_height = @floatFromInt(m.height >> 6),
    };
}

/// Look up a glyph, rasterizing + packing it on first use. Returns null only
/// if the codepoint has no glyph or the atlas is full.
pub fn glyph(self: *Atlas, cp: u21, px: u32) ?Glyph {
    const key = Key{ .cp = cp, .px = px };
    if (self.glyphs.get(key)) |g| return g;
    const g = self.rasterize(cp, px) catch return null;
    self.glyphs.put(self.alloc, key, g) catch return null;
    return g;
}

/// Upload the CPU atlas to the GPU if it changed. Call once per frame, outside
/// a render pass, before drawing.
pub fn flush(self: *Atlas) void {
    if (!self.dirty) return;
    var data: sg.ImageData = .{};
    data.mip_levels[0] = sg.asRange(self.pixels);
    sg.updateImage(self.image, data);
    self.dirty = false;
}

fn rasterize(self: *Atlas, cp: u21, px: u32) !Glyph {
    self.setSize(px);

    const gindex = ft.c.FT_Get_Char_Index(self.face.handle, cp);
    if (gindex == 0) return error.NoGlyph;
    if (ft.c.FT_Load_Glyph(self.face.handle, gindex, ft.c.FT_LOAD_DEFAULT) != 0) return error.Load;
    if (ft.c.FT_Render_Glyph(self.face.handle.*.glyph, ft.c.FT_RENDER_MODE_NORMAL) != 0) return error.Render;

    const slot = self.face.handle.*.glyph;
    const bmp = slot.*.bitmap;
    const bw: i32 = @intCast(bmp.width);
    const bh: i32 = @intCast(bmp.rows);

    var g = Glyph{
        .w = @floatFromInt(bw),
        .h = @floatFromInt(bh),
        .bearing_x = @floatFromInt(slot.*.bitmap_left),
        .bearing_y = @floatFromInt(slot.*.bitmap_top),
        .advance = @floatFromInt(slot.*.advance.x >> 6), // 26.6 fixed -> px
    };
    if (bw == 0 or bh == 0) return g; // empty glyph (e.g. space): advance only

    // Advance to the next shelf if it won't fit on the current one.
    if (self.pen_x + bw + pad > atlas_w) {
        self.pen_x = pad;
        self.pen_y += self.shelf_h + pad;
        self.shelf_h = 0;
    }
    if (self.pen_y + bh + pad > atlas_h) return error.AtlasFull;

    // Blit the glyph bitmap into the CPU atlas (handle bottom-up pitch).
    const pitch: i32 = bmp.pitch;
    var row: i32 = 0;
    while (row < bh) : (row += 1) {
        const src_row: i32 = if (pitch >= 0) row else bh - 1 - row;
        const abs_pitch: i32 = if (pitch >= 0) pitch else -pitch;
        const src_off: usize = @intCast(src_row * abs_pitch);
        const dst_off: usize = @intCast((self.pen_y + row) * atlas_w + self.pen_x);
        const len: usize = @intCast(bw);
        @memcpy(self.pixels[dst_off .. dst_off + len], bmp.buffer[src_off .. src_off + len]);
    }

    const aw: f32 = @floatFromInt(atlas_w);
    const ah: f32 = @floatFromInt(atlas_h);
    const fx: f32 = @floatFromInt(self.pen_x);
    const fy: f32 = @floatFromInt(self.pen_y);
    g.u0 = fx / aw;
    g.v0 = fy / ah;
    g.u1 = (fx + g.w) / aw;
    g.v1 = (fy + g.h) / ah;

    self.pen_x += bw + pad;
    self.shelf_h = @max(self.shelf_h, bh);
    self.dirty = true;
    return g;
}
