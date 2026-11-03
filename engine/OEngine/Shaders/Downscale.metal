// OEngine — Spec 4 §10, the preview and multiviewer aux pass: "Aux passes
// downscale the stack textures into small BGRA8 sRGB textures at most 30 times
// a second, backed by IOSurfaces." Spec 4 §10 again for thumbnails, which pass
// through here at 1:1 to land in the same texture kind. A box filter: every
// target pixel is the mean of the block of source pixels it covers, in linear
// light; the sRGB-typed target encodes on write.

#include <metal_stdlib>
using namespace metal;

struct DownscaleUniforms {
    float4 taps;   // taps across, taps down, source texel width, source texel height
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut downscaleVertex(uint id [[vertex_id]]) {
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(positions[id], 0, 1);
    out.uv = float2((positions[id].x + 1) * 0.5, 1 - (positions[id].y + 1) * 0.5);
    return out;
}

fragment float4 downscaleFragment(VertexOut in [[stage_in]],
                                  texture2d<float> source [[texture(0)]],
                                  constant DownscaleUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge, coord::normalized);
    int across = max(1, int(u.taps.x));
    int down = max(1, int(u.taps.y));
    float2 texel = u.taps.zw;
    // The target pixel's centre maps to the centre of its source block; step back to the block's first texel centre.
    float2 origin = in.uv - float2(across - 1, down - 1) * 0.5 * texel;
    float4 sum = float4(0);
    for (int y = 0; y < down; y++) {
        for (int x = 0; x < across; x++) {
            sum += source.sample(s, origin + float2(x, y) * texel);
        }
    }
    return sum / float(across * down);
}
