const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const slog = sokol.log;
const shd = @import("shaders");
const Atlas = @import("atlas.zig");
const Ui = @import("ui.zig");

const font_path: [:0]const u8 = "/Users/moritz/code/Iosevka-main/dist/iosevka-custom/ttf-unhinted/iosevka-custom-regular.ttf";

const State = struct {
    pip: sg.Pipeline = .{},
    instances: sg.Buffer = .{},
    // Instance capacity of `instances`; grown geometrically when a frame
    // emits more.
    gpu_capacity: usize = 0,
    bind: sg.Bindings = .{},
    pass_action: sg.PassAction = .{},
    atlas: Atlas = undefined,
    ui: Ui = undefined,
    app: App = .{ .index = 0 },
    time: f64 = 0,
};
var state: State = .{};

// Allocator stashed for the C-ABI init callback (which takes no args).
var gpa: std.mem.Allocator = undefined;

const initial_gpu_instances = 4096;

pub const Rect = extern struct {
    rect: [4]f32, // x, y, w, h (pixels)
    clip: [4]f32,
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
    desc.layout.attrs[shd.ATTR_quad_i_clip] = .{ .format = .FLOAT4, .buffer_index = 0 };
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

    state.gpu_capacity = initial_gpu_instances;
    state.instances = sg.makeBuffer(.{
        .usage = .{ .stream_update = true },
        .size = state.gpu_capacity * @sizeOf(Rect),
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
    const window: [2]f32 = .{ sapp.widthf(), sapp.heightf() };

    // Future: Collect input and apply commands

    // Build UI
    state.ui.current_frame = sapp.frameCount();
    state.app.buildUi(&state.ui);

    // Layout
    try state.ui.layout(window);

    // Interact
    state.ui.updateInteractions(@floatCast(sapp.frameDuration()));

    // Render
    const instances = state.ui.render(window);

    // Cleanup
    state.ui.prune(gpa);
    state.ui.reset_stacks();

    // GPU pipeline:

    // Upload any newly-rasterized glyphs, then the instance data (both must be
    // outside the render pass).
    state.atlas.flush();
    if (instances.len > state.gpu_capacity) {
        sg.destroyBuffer(state.instances);
        state.gpu_capacity = std.math.ceilPowerOfTwoAssert(usize, instances.len);
        state.instances = sg.makeBuffer(.{
            .usage = .{ .stream_update = true },
            .size = state.gpu_capacity * @sizeOf(Rect),
        });
        state.bind.vertex_buffers[0] = state.instances;
    }
    if (instances.len > 0) {
        sg.updateBuffer(state.instances, sg.asRange(instances));
    }

    const vs_params = shd.VsParams{
        .resolution = .{ sapp.widthf(), sapp.heightf() },
    };

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sg.applyPipeline(state.pip);
    sg.applyBindings(state.bind);
    sg.applyUniforms(shd.UB_vs_params, sg.asRange(&vs_params));
    sg.draw(0, 4, @intCast(instances.len));
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

const App = struct {
    index: usize,

    fn buildUi(app: *App, ui: *Ui) void {
        ui.pushNext(.{ .height = .{ .kind = .percent_of_parent, .value = 0.5 } });
        ui.pushNext(.{ .width = .{ .kind = .percent_of_parent, .value = 1 } });
        ui.pushFlagsNext(.{ .clip = true });
        ui.startVertical();
        defer ui.endVertical();

        _ = ui.mkWidget(std.fmt.allocPrint(ui.alloc, "{d}", .{app.index}) catch @panic("OOM"), {});

        for (0..30) |i| {
            if (ui.button(std.fmt.allocPrint(ui.alloc, "Click me {d}!", .{i}) catch @panic("OOM")).clicked) {
                app.index = i;
            }
        }
    }
};
