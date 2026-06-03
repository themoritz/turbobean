//------------------------------------------------------------------------------
//  quad.glsl
//
//  A fullscreen "shadertoy-style" playground shader, compiled by sokol-shdc.
//
//  The vertex shader emits a single triangle that covers the whole screen
//  using only gl_VertexIndex, so no vertex buffer is needed. The fragment
//  shader gets the framebuffer resolution and elapsed time as a uniform block,
//  which is where you'll do all the fun stuff (SDFs, rounded rects, ...).
//------------------------------------------------------------------------------

@vs vs
void main() {
    // Fullscreen triangle: vertices (0,0) (2,0) (0,2) in [0..2] space,
    // mapped to clip-space [-1..3]. The bits of gl_VertexIndex pick the corner.
    vec2 p = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
@end

@fs fs
layout(binding=0) uniform fs_params {
    vec2 resolution;
    float time;
};

out vec4 frag_color;

void main() {
    // Normalized coordinates in [0..1].
    vec2 uv = gl_FragCoord.xy / resolution;
    // Simple animated gradient so we can see it's alive.
    vec3 col = vec3(uv, 0.5 + 0.5 * sin(time));
    frag_color = vec4(col, 1.0);
}
@end

@program quad vs fs
