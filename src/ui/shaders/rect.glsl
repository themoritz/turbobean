@vs vs

layout(binding=0) uniform vs_params {
    vec2 resolution;
};

in vec4 i_rect;
in vec4 i_color;
in float i_corner_radius;
in float i_edge_softness;

out vec2 dest_pos;
out vec2 dest_center;
out vec2 dest_half_size;
// Passthrough
out vec4 color;
out float corner_radius;
out float edge_softness;

void main() {
    // 0->(0,0) 1->(1,0) 2->(0,1) 3->(1,1)
    vec2 corner = vec2(float(gl_VertexIndex & 1), float((gl_VertexIndex >> 1) & 1));

    vec2 px  = i_rect.xy + corner * i_rect.zw;   // pixel-space position of this corner
    vec2 ndc = (px / resolution) * 2.0 - 1.0;    // pixels -> normalized device coords
    ndc.y = -ndc.y;                              // flip: pixels go top-down, NDC bottom-up

    gl_Position = vec4(ndc, 0.0, 1.0);

    dest_pos = px;
    dest_half_size = 0.5 * i_rect.zw;
    dest_center = i_rect.xy + dest_half_size;

    color = i_color;
    corner_radius = i_corner_radius;
    edge_softness = i_edge_softness;
}

@end

//--------------------------------

@fs fs

in vec2 dest_pos;
in vec2 dest_center;
in vec2 dest_half_size;
in vec4 color;
in float corner_radius;
in float edge_softness;

out vec4 frag_color;

float sdf(vec2 sample_pos, vec2 rect_center, vec2 rect_half_size, float r) {
    vec2 d2 = abs(rect_center - sample_pos) - rect_half_size + vec2(r, r);
    return min(max(d2.x, d2.y), 0.0) + length(max(d2, 0.0)) - r;
}

void main() {
    vec2 softness_padding = vec2(
        max(0.0, edge_softness * 2.0 - 1.0),
        max(0.0, edge_softness * 2.0 - 1.0)
    );
    float dist = sdf(
        dest_pos,
        dest_center,
        dest_half_size - softness_padding,
        corner_radius
    );
    float sdf_factor = 1.0 - smoothstep(0, 2 * edge_softness, dist);
    frag_color = vec4(color.xyz, color.w * sdf_factor);
}

@end

@program quad vs fs
