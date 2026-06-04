//! Minimal GPU rendering loop: open a window and draw a fullscreen fragment
//! shader. This is the "shader code -> something visible" starting point.
//!
//! Backend is sokol_gfx (Metal on macOS). The shader lives in
//! `shaders/quad.glsl` and is compiled to the `shaders` module by sokol-shdc
//! at build time.

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const slog = sokol.log;
const shd = @import("shaders");

const State = struct {
    pip: sg.Pipeline = .{},
    instances: sg.Buffer = .{},
    bind: sg.Bindings = .{},
    pass_action: sg.PassAction = .{},
    time: f64 = 0,
};
var state: State = .{};

const Rect = extern struct {
    rect: [4]f32,
    color: [4]f32,
    corner_radius: f32,
    edge_softness: f32,
};

pub fn run(alloc: std.mem.Allocator, io: std.Io) !void {
    _ = alloc;
    _ = io;
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
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
    desc.layout.attrs[shd.ATTR_quad_i_corner_radius] = .{ .format = .FLOAT, .buffer_index = 0 };
    desc.layout.attrs[shd.ATTR_quad_i_edge_softness] = .{ .format = .FLOAT, .buffer_index = 0 };
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
        .size = 2 * @sizeOf(Rect),
    });

    state.bind.vertex_buffers[0] = state.instances;

    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };
}

export fn frame() void {
    state.time += sapp.frameDuration();

    const vs_params = shd.VsParams{
        .resolution = .{ sapp.widthf(), sapp.heightf() },
    };

    const n = 2;
    const rects: [2]Rect = .{
        Rect{
            .color = .{ 1, 0, 0, 1 },
            .rect = .{ 100, 100, 130, 20 },
            .corner_radius = 10,
            .edge_softness = 1,
        },
        Rect{
            .color = .{ 0, 1, 0, 0.5 },
            .rect = .{ 200, 100, 50, 50 },
            .corner_radius = 0,
            .edge_softness = 4,
        },
    };

    sg.updateBuffer(state.instances, sg.asRange(&rects));

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sg.applyPipeline(state.pip);
    sg.applyBindings(state.bind);
    sg.applyUniforms(shd.UB_vs_params, sg.asRange(&vs_params));
    sg.draw(0, 4, n);
    sg.endPass();
    sg.commit();
}

export fn cleanup() void {
    sg.shutdown();
}
