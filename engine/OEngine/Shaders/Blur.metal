// OEngine — Spec 4 §7 stage 2: "Blur is the exception: when the radius is
// non-zero, a separable two-pass Gaussian at half resolution runs before this
// stage and is skipped entirely otherwise, so a non-blurring show pays nothing
// for it."

#include <metal_stdlib>
using namespace metal;

// 0 horizontal, 1 vertical.
constant int kDirection [[function_constant(0)]];

struct BlurUniforms {
    float4 params;   // radius in half-resolution pixels, 1/width, 1/height, unused
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut blurVertex(uint id [[vertex_id]]) {
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(positions[id], 0, 1);
    out.uv = float2((positions[id].x + 1) * 0.5, 1 - (positions[id].y + 1) * 0.5);
    return out;
}

/// A Gaussian with sigma = radius / 2, sampled at whole texels up to the radius (capped at 32 taps a side).
fragment float4 blurFragment(VertexOut in [[stage_in]],
                             texture2d<float> source [[texture(0)]],
                             constant BlurUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
    float radius = u.params.x;
    if (radius <= 0) return source.sample(s, in.uv);
    float sigma = max(0.5, radius * 0.5);
    int taps = min(32, int(ceil(radius)));
    float2 step = kDirection == 0 ? float2(u.params.y, 0) : float2(0, u.params.z);
    float4 sum = float4(0);
    float weights = 0;
    for (int i = -taps; i <= taps; i++) {
        float w = exp(-float(i * i) / (2 * sigma * sigma));
        sum += source.sample(s, in.uv + step * float(i)) * w;
        weights += w;
    }
    return sum / weights;
}
