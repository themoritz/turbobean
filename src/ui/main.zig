const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const slog = sokol.log;
const shd = @import("shaders");
const Atlas = @import("atlas.zig");
const Ui = @import("ui.zig");

// Default font + base size for the text demo. The atlas is rasterized at
// base_pt * dpi_scale so it stays crisp on high-DPI displays.
const font_path: [:0]const u8 = "/Users/moritz/code/Iosevka-main/dist/iosevka-custom/ttf-unhinted/iosevka-custom-regular.ttf";

// Current font size in points. Adjustable at runtime with Cmd -/= (Cmd+0 resets).
var font_pt: f32 = 18;
const min_pt: f32 = 6;
const max_pt: f32 = 96;

const max_instances = 4096;

const State = struct {
    pip: sg.Pipeline = .{},
    instances: sg.Buffer = .{},
    bind: sg.Bindings = .{},
    pass_action: sg.PassAction = .{},
    atlas: Atlas = undefined,
    ui: Ui = undefined,
    time: f64 = 0,
};
var state: State = .{};

// Allocator stashed for the C-ABI init callback (which takes no args).
var gpa: std.mem.Allocator = undefined;

// CPU-side instance scratch, uploaded each frame.
var instance_buf: [max_instances]Rect = undefined;

pub const Rect = extern struct {
    rect: [4]f32, // x, y, w, h (pixels)
    color: [4]f32, // rgba
    corner_radii: [4]f32 = @splat(0), // TL, TR, BR, BL (pixels)
    edge_softness: f32 = 0,
    border_thickness: f32 = 0, // 0 = filled, >0 = outline width (pixels)
    uv: [4]f32 = @splat(0), // glyph atlas source rect (u0,v0,u1,v1)
    use_texture: f32 = 0, // 0 = SDF rect, 1 = sample glyph atlas
};

pub fn run(alloc: std.mem.Allocator, io: std.Io) !void {
    _ = io;
    gpa = alloc;
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .event_cb = event,
        .cleanup_cb = cleanup,
        .width = 800,
        .height = 600,
        .high_dpi = true,
        .window_title = "turbobean ui",
        .logger = .{ .func = slog.func },
    });
}

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    var desc = sg.PipelineDesc{
        .shader = sg.makeShader(shd.quadShaderDesc(sg.queryBackend())),
        .primitive_type = .TRIANGLE_STRIP,
    };
    desc.layout.buffers[0].step_func = .PER_INSTANCE;
    desc.layout.attrs[shd.ATTR_quad_i_rect] = .{ .format = .FLOAT4, .buffer_index = 0 };
    desc.layout.attrs[shd.ATTR_quad_i_color] = .{ .format = .FLOAT4, .buffer_index = 0 };
    desc.layout.attrs[shd.ATTR_quad_i_corner_radii] = .{ .format = .FLOAT4, .buffer_index = 0 };
    desc.layout.attrs[shd.ATTR_quad_i_edge_softness] = .{ .format = .FLOAT, .buffer_index = 0 };
    desc.layout.attrs[shd.ATTR_quad_i_border_thickness] = .{ .format = .FLOAT, .buffer_index = 0 };
    desc.layout.attrs[shd.ATTR_quad_i_uv] = .{ .format = .FLOAT4, .buffer_index = 0 };
    desc.layout.attrs[shd.ATTR_quad_i_use_texture] = .{ .format = .FLOAT, .buffer_index = 0 };
    desc.colors[0].blend = .{
        .enabled = true,
        .src_factor_rgb = .SRC_ALPHA,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        .src_factor_alpha = .ONE,
        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
    };
    state.pip = sg.makePipeline(desc);

    state.instances = sg.makeBuffer(.{
        .usage = .{ .stream_update = true },
        .size = max_instances * @sizeOf(Rect),
    });
    state.bind.vertex_buffers[0] = state.instances;

    // Lazy glyph atlas; glyphs are rasterized on first use at the requested px.
    state.atlas = Atlas.init(gpa, font_path) catch |err| {
        std.log.err("failed to init glyph atlas: {t}", .{err});
        @panic("atlas init failed");
    };
    state.bind.views[shd.VIEW_atlas] = state.atlas.view;
    state.bind.samplers[shd.SMP_smp] = state.atlas.sampler;

    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };

    state.ui = Ui.init(gpa);
}

/// Append one textured quad per glyph of `text` to `out`, returning the count.
/// Positions are pixel-snapped (integer) for maximum crispness.
fn pushText(out: []Rect, atlas: *Atlas, text: []const u8, x: f32, y: f32, px: u32, color: [4]f32) usize {
    var n: usize = 0;
    var pen_x: f32 = @round(x);
    const baseline: f32 = @round(y);
    for (text) |ch| {
        const g = atlas.glyph(@intCast(ch), px) orelse continue;
        if (g.w > 0 and g.h > 0 and n < out.len) {
            out[n] = .{
                .rect = .{
                    @round(pen_x + g.bearing_x),
                    @round(baseline - g.bearing_y),
                    g.w,
                    g.h,
                },
                .color = color,
                .uv = .{ g.u0, g.v0, g.u1, g.v1 },
                .use_texture = 1,
            };
            n += 1;
        }
        pen_x += g.advance;
    }
    return n;
}

export fn frame() void {
    state.time += sapp.frameDuration();

    const vs_params = shd.VsParams{
        .resolution = .{ sapp.widthf(), sapp.heightf() },
    };

    buildUi(&state.ui, gpa) catch @panic("OOM");
    try state.ui.layout(.{ sapp.widthf(), sapp.heightf() });

    var count = state.ui.render(&instance_buf);

    // A couple of UI rects (SDF path).
    instance_buf[count] = .{
        .color = .{ 1, 0, 0, 1 },
        .rect = .{ 100, 100, 160, 90 },
        .corner_radii = .{ 12, 12, 0, 0 },
        .edge_softness = 1,
    };
    count += 1;
    instance_buf[count] = .{
        .color = .{ 0, 1, 0, 1 },
        .rect = .{ 300, 120, 120, 120 },
        .corner_radii = @splat(20),
        .edge_softness = 1,
        .border_thickness = 1,
    };
    count += 1;

    // Text (atlas path), rasterized at the current framebuffer-DPI px size.
    const px: u32 = @intFromFloat(@round(font_pt * sapp.dpiScale()));
    const a = &state.atlas;
    const lm = a.lineMetrics(px);
    const top = 40 + lm.ascent;
    count += pushText(
        instance_buf[count..],
        a,
        "Hello, Iosevka!",
        100,
        top,
        px,
        .{ 1, 1, 1, 1 },
    );

    // Upload any newly-rasterized glyphs, then the instance data (both must be
    // outside the render pass).
    a.flush();
    sg.updateBuffer(state.instances, sg.asRange(instance_buf[0..count]));

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sg.applyPipeline(state.pip);
    sg.applyBindings(state.bind);
    sg.applyUniforms(shd.UB_vs_params, sg.asRange(&vs_params));
    sg.draw(0, 4, @intCast(count));
    sg.endPass();
    sg.commit();
}

export fn event(ev: [*c]const sapp.Event) void {
    const e = ev.*;
    state.ui.handle_event(e);
}

export fn cleanup() void {
    state.atlas.deinit();
    sg.shutdown();
}

fn buildUi(ui: *Ui, arena: std.mem.Allocator) !void {
    const root = try ui.mkWidget(.{ .key = 0 }, "");

    try ui.stack_parent.push(arena, root);
    defer ui.stack_parent.pop();

    _ = try ui.mkWidget(.{ .key = 1 }, "A");
}
