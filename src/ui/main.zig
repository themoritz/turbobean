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

/// Convert a point size to framebuffer pixels at the current DPI. Layout and the
/// renderer both go through this so a widget's measured and drawn text agree.
pub fn ptToPx(pt: f32) u32 {
    return @intFromFloat(@round(pt * sapp.dpiScale()));
}

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
    border_color: [4]f32 = @splat(0), // ring color when border_thickness > 0
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
    desc.layout.attrs[shd.ATTR_quad_i_border_color] = .{ .format = .FLOAT4, .buffer_index = 0 };
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

    state.ui = Ui.init(gpa, &state.atlas);
}

export fn frame() void {
    state.time += sapp.frameDuration();

    const vs_params = shd.VsParams{
        .resolution = .{ sapp.widthf(), sapp.heightf() },
    };

    state.ui.current_frame = sapp.frameCount();
    buildUi(&state.ui, gpa);
    try state.ui.layout(.{ sapp.widthf(), sapp.heightf() });

    const count = state.ui.render(&instance_buf);
    state.ui.prune(gpa);
    state.ui.reset_stacks();

    // Upload any newly-rasterized glyphs, then the instance data (both must be
    // outside the render pass).
    state.atlas.flush();
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

fn buildUi(ui: *Ui, arena: std.mem.Allocator) void {
    _ = arena;
    ui.push(.{ .height = .{ .kind = .children_sum } });
    defer ui.pop(.height);
    ui.push(.{ .width = .{ .kind = .percent_of_parent, .value = 0.5 } });
    defer ui.pop(.width);

    ui.pushFlags(.{ .clickable = true });
    ui.addFlagsNext(.{ .draw_border = true });

    ui.pushNext(.{ .border_thickness = 1 });
    ui.pushNext(.{ .border_color = .{ 1, 0, 0, 1 } });
    ui.pushNext(.{ .corner_radii = @splat(10) });
    const root = ui.mkWidget("root", {});

    {
        ui.push(.{ .parent = root });
        defer ui.pop(.parent);

        ui.pushNext(.{ .width = .{ .kind = .text_content, .value = 10 } });
        ui.pushNext(.{ .height = .{ .kind = .text_content, .value = 5 } });
        ui.pushNext(.{ .bg_color = .{ 1, 1, 1, 0.3 } });
        _ = ui.mkWidget("Apple", {});

        ui.pushNext(.{ .bg_color = .{ 1, 0, 1, 0.5 } });
        ui.pushNext(.{ .height = .{ .kind = .pixels, .value = 100 } });
        const b = ui.mkWidget("B", {});

        {
            ui.push(.{ .parent = b });
            defer ui.pop(.parent);

            ui.push(.{ .width = .{ .kind = .percent_of_parent, .value = 0.5 } });
            ui.pushNext(.{ .height = .{ .kind = .text_content, .value = 40 } });
            ui.pushNext(.{ .font_size = 25 });
            ui.pushNext(.{ .bg_color = .{ 1, 1, 0, 0.9 } });
            _ = ui.mkWidget("C", 1);
        }
    }
}
