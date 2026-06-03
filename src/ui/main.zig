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
    pass_action: sg.PassAction = .{},
    time: f64 = 0,
};
var state: State = .{};

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

    // No vertex buffer: the vertex shader generates a fullscreen triangle from
    // gl_VertexIndex, so the pipeline needs no vertex layout and no bindings.
    state.pip = sg.makePipeline(.{
        .shader = sg.makeShader(shd.quadShaderDesc(sg.queryBackend())),
    });

    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };
}

export fn frame() void {
    state.time += sapp.frameDuration();

    const fs_params = shd.FsParams{
        .resolution = .{ sapp.widthf(), sapp.heightf() },
        .time = @floatCast(state.time),
    };

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sg.applyPipeline(state.pip);
    sg.applyUniforms(shd.UB_fs_params, sg.asRange(&fs_params));
    sg.draw(0, 3, 1);
    sg.endPass();
    sg.commit();
}

export fn cleanup() void {
    sg.shutdown();
}
