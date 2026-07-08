#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position;
    float2 texCoord;
    float  alpha;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float  alpha;
};

vertex VertexOut vertex_quad(uint vid [[vertex_id]],
                             constant VertexIn *verts [[buffer(0)]]) {
    VertexIn in = verts[vid];
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    out.alpha = in.alpha;
    return out;
}

fragment half4 fragment_texture(VertexOut in [[stage_in]],
                                texture2d<half> tex [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    half4 color = tex.sample(s, in.texCoord);
    color.a *= in.alpha;
    return color;
}
