// OEngine — Spec 4 §9, the stack pass: "The pass is a sequence of textured
// quads, each a box, drawn with premultiplied over-blending in linear light."
// Variants: the per-box grade (Spec 4 §9, "a second instance of the channel
// pass's stage 2") and the gamma-blend switch; the mask slot is reserved
// (texture 1) and bound to white until v1.5.

#include <metal_stdlib>
using namespace metal;

constant bool kHasGrade [[function_constant(0)]];
constant bool kGammaBlend [[function_constant(1)]];

struct StackUniforms {
    float4 frame;     // x, y, width, height in clip space
    float4 uv;        // u, v, width, height
    float4 opacity;   // opacity
    float4 gradeA;    // saturation, brightness, contrast, opacity
    float4 tint;
    float3x3 hue;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut boxVertex(uint id [[vertex_id]], constant StackUniforms &u [[buffer(0)]]) {
    float2 corner = float2(id & 1, (id >> 1) & 1);   // 0,0  1,0  0,1  1,1
    VertexOut out;
    out.position = float4(u.frame.x + corner.x * u.frame.z, u.frame.y + corner.y * u.frame.w, 0, 1);
    // v runs down the texture as y runs down the box: the top of the box is the top of the texture.
    out.uv = float2(u.uv.x + corner.x * u.uv.z, u.uv.y + (1 - corner.y) * u.uv.w);
    return out;
}

static inline float4 grade(float4 p, constant StackUniforms &u) {
    float3 rgb = u.hue * p.rgb;
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(luma), rgb, u.gradeA.x);
    rgb *= (1 + u.gradeA.y);
    rgb *= mix(float3(1), u.tint.rgb, u.tint.a);
    rgb = (rgb - 0.18 * p.a) * u.gradeA.z + 0.18 * p.a;
    rgb *= u.gradeA.w;
    return float4(rgb, p.a * u.gradeA.w);
}

static inline float3 srgbEncode(float3 v) {
    float3 x = saturate(v);
    float3 low = x * 12.92;
    float3 high = 1.055 * pow(x, 1 / 2.4) - 0.055;
    return select(high, low, x <= 0.0031308);
}

fragment float4 boxFragment(VertexOut in [[stage_in]],
                            texture2d<float> source [[texture(0)]],
                            texture2d<float> mask [[texture(1)]],
                            sampler s [[sampler(0)]],
                            constant StackUniforms &u [[buffer(0)]]) {
    float4 c = source.sample(s, in.uv);
    if (kHasGrade) c = grade(c, u);
    if (kGammaBlend) {
        // Spec 4 §9 — "each box shader applies the sRGB OETF to its sampled colour before
        // blending": the straight colour is encoded, then premultiplied again, so opacity
        // and the blend act on encoded values.
        float3 straight = c.a > 0 ? c.rgb / c.a : float3(0);
        c = float4(srgbEncode(straight) * c.a, c.a);
    }
    c *= u.opacity.x;
    constexpr sampler maskSampler(filter::linear, address::clamp_to_edge, coord::normalized);
    c *= mask.sample(maskSampler, in.uv).r;
    return c;
}

/// Spec 4 §9 — after a gamma-blend stack pass, "the final stack pass output is linearized again for the sink".
fragment float4 linearizeFragment(VertexOut in [[stage_in]], texture2d<float> source [[texture(0)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge, coord::normalized);
    float4 c = source.sample(s, in.uv);
    float3 x = saturate(c.rgb);
    float3 low = x / 12.92;
    float3 high = pow((x + 0.055) / 1.055, 2.4);
    return float4(select(high, low, x <= 0.04045), c.a);
}
