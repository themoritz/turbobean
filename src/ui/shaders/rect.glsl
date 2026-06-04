@vs vs
layout(binding=0) uniform vs_params {
    vec2 resolution;
};

in vec4 i_rect;
in vec4 i_color;

out vec4 color;

void main() {
    // 0->(0,0) 1->(1,0) 2->(0,1) 3->(1,1)
    vec2 corner = vec2(float(gl_VertexIndex & 1), float((gl_VertexIndex >> 1) & 1));

    vec2 px  = i_rect.xy + corner * i_rect.zw;   // pixel-space position of this corner
    vec2 ndc = (px / resolution) * 2.0 - 1.0;    // pixels -> normalized device coords
    ndc.y = -ndc.y;                              // flip: pixels go top-down, NDC bottom-up

    gl_Position = vec4(ndc, 0.0, 1.0);
    color = i_color;
}
@end

@fs fs
in vec4 color;
out vec4 frag_color;

void main() {
  frag_color = color;
}
@end

@program quad vs fs
