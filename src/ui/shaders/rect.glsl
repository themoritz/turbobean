@vs vs

layout(binding=0) uniform vs_params {
    vec2 resolution;
};

in vec4 i_rect;
in vec4 i_color;
in vec4 i_corner_radii;     // per corner: x=TL, y=TR, z=BR, w=BL (screen y down)
in float i_edge_softness;
in float i_border_thickness; // 0 = filled, >0 = outline of this width (px)

out vec2 dest_pos;
out vec2 dest_center;
out vec2 dest_half_size;
// Passthrough
out vec4 color;
out vec4 corner_radii;
out float edge_softness;
out float border_thickness;

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
    corner_radii = i_corner_radii;
    edge_softness = i_edge_softness;
    border_thickness = i_border_thickness;
}

@end

//--------------------------------

@fs fs

in vec2 dest_pos;
in vec2 dest_center;
in vec2 dest_half_size;
in vec4 color;
in vec4 corner_radii;
in float edge_softness;
in float border_thickness;

out vec4 frag_color;

// Signed distance to a rounded box. `p` is relative to the center, `b` is the
// half-size, `radii` holds one radius per corner (x=TL, y=TR, z=BR, w=BL).
// Each pixel lives in exactly one quadrant, so we just pick that corner's radius.
float sdf(vec2 p, vec2 b, vec4 radii) {
    float r;
    if (p.x >= 0.0) {
        r = (p.y >= 0.0) ? radii.z : radii.y; // right: bottom-right : top-right
    } else {
        r = (p.y >= 0.0) ? radii.w : radii.x; // left:  bottom-left  : top-left
    }
    vec2 q = abs(p) - b + vec2(r, r);
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
    vec2 softness_padding = vec2(max(0.0, edge_softness * 2.0 - 1.0));
    vec2 p = dest_pos - dest_center;
    vec2 half_size = dest_half_size - softness_padding;

    float dist = sdf(p, half_size, corner_radii);

    // Outer edge coverage (anti-aliased).
    float outer = 1.0 - smoothstep(0.0, 2.0 * edge_softness, dist);

    float coverage;
    if (border_thickness > 0.0) {
        // Inner shape is the rect shrunk by the border width; subtracting its
        // coverage leaves a ring `border_thickness` px wide.
        float inner = 1.0 - smoothstep(0.0, 2.0 * edge_softness, dist + border_thickness);
        coverage = outer - inner;
    } else {
        coverage = outer;
    }

    frag_color = vec4(color.xyz, color.w * coverage);
}

@end

@program quad vs fs
