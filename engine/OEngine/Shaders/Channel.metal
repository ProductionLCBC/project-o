// OEngine — Spec 4 §7, the channel pass: "One pass per channel with pixel
// content, producing the channel texture: the content converted to linear
// light, graded, and mixed with the outgoing content if a transition is
// running." One shader, specialised with function constants for the source
// layouts and the transition type (Spec 4 §7, "Shader variants").

#include <metal_stdlib>
using namespace metal;

// Spec 4 §7 — source layouts: 0 none, 1 NV12, 2 P010, 3 4:2:2 10-bit,
// 4 RGBA16 straight alpha, 5 linear RGBA16 premultiplied (a converted still),
// 6 BGRA8 sRGB premultiplied (poster, text), 7 finished channel pixels.
constant int kIncomingLayout [[function_constant(0)]];
constant int kOutgoingLayout [[function_constant(1)]];
// Spec 4 §7 — transition type: 0 cut, 1 dissolve, 2 fadeThroughColor.
constant int kTransition [[function_constant(2)]];
// Spec 4 §7 stage 2 — skipped entirely for an identity grade.
constant bool kHasGrade [[function_constant(3)]];

// Layouts 1, 2 and 3 (NV12, P010, 4:2:2 10-bit) share the YCbCr path below.
constant int kLayoutNone = 0;
constant int kLayoutRGBA16 = 4;
constant int kLayoutLinearRGBA16 = 5;
constant int kLayoutBGRA8sRGB = 6;
constant int kLayoutFinished = 7;

struct ChannelUniforms {
    float4 incomingRect;      // x, y, width, height of the letterboxed content in the target, normalized
    float4 outgoingRect;
    float4 incomingRange;     // yScale, yOffset, cScale, cOffset
    float4 outgoingRange;
    float4 codeScales;        // incoming, outgoing, unused, unused
    float4 transition;        // eased progress, unused...
    float4 color;             // fade-through colour, opaque premultiplied linear
    float4 gradeA;            // saturation, brightness, contrast, opacity
    float4 tint;              // rgba
    float3x3 incomingMatrix;  // Y'CbCr to R'G'B'
    float3x3 outgoingMatrix;
    float3x3 incomingPrimaries;
    float3x3 outgoingPrimaries;
    float3x3 hue;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

/// A full-screen triangle; uv runs 0...1 across the target, y down.
vertex VertexOut channelVertex(uint id [[vertex_id]]) {
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(positions[id], 0, 1);
    out.uv = float2((positions[id].x + 1) * 0.5, 1 - (positions[id].y + 1) * 0.5);
    return out;
}

/// Spec 4 §7 — "every Rec.709 or sRGB-tagged source ... is linearized with the sRGB piecewise curve".
static inline float3 srgbDecode(float3 v) {
    float3 x = saturate(v);
    float3 low = x / 12.92;
    float3 high = pow((x + 0.055) / 1.055, 2.4);
    return select(high, low, x <= 0.04045);
}

/// Spec 4 §7 stage 1 — one source's sample at `uv` within its content, as premultiplied linear RGBA.
static inline float4 stage1(int layout, texture2d<float> plane0, texture2d<float> plane1, float2 uv,
                            float codeScale, float4 range, float3x3 matrix, float3x3 primaries) {
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
    if (layout == kLayoutLinearRGBA16 || layout == kLayoutFinished) {
        return plane0.sample(s, uv);
    }
    if (layout == kLayoutBGRA8sRGB) {
        // The sRGB-typed texture linearizes on sample; the pixels are premultiplied already.
        return plane0.sample(s, uv);
    }
    if (layout == kLayoutRGBA16) {
        float4 c = plane0.sample(s, uv);
        return float4(srgbDecode(c.rgb) * c.a, c.a);   // straight alpha in the file: premultiply after linearizing
    }
    float y = plane0.sample(s, uv).r * codeScale;
    float2 cbcr = plane1.sample(s, uv).rg * codeScale;
    float yp = y * range.x + range.y;
    float2 c = cbcr * range.z + float2(range.w);
    float3 rgb = matrix * float3(yp, c.x, c.y);
    float3 lin = primaries * srgbDecode(rgb);
    return float4(lin, 1);
}

/// Spec 4 §7 stage 2 — the grade "in linear RGB", on premultiplied values.
static inline float4 grade(float4 p, constant ChannelUniforms &u) {
    float3 rgb = u.hue * p.rgb;
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(luma), rgb, u.gradeA.x);
    rgb *= (1 + u.gradeA.y);
    rgb *= mix(float3(1), u.tint.rgb, u.tint.a);
    rgb = (rgb - 0.18 * p.a) * u.gradeA.z + 0.18 * p.a;
    rgb *= u.gradeA.w;
    return float4(rgb, p.a * u.gradeA.w);
}

/// A source letterboxed into its rect; transparent outside it.
static inline float4 sampleSource(int layout, texture2d<float> plane0, texture2d<float> plane1, float2 uv, float4 rect,
                                  float codeScale, float4 range, float3x3 matrix, float3x3 primaries) {
    float2 suv = (uv - rect.xy) / rect.zw;
    if (any(suv < 0) || any(suv > 1)) return float4(0);
    return stage1(layout, plane0, plane1, suv, codeScale, range, matrix, primaries);
}

fragment float4 channelFragment(VertexOut in [[stage_in]],
                                texture2d<float> incoming0 [[texture(0)]],
                                texture2d<float> incoming1 [[texture(1)]],
                                texture2d<float> outgoing0 [[texture(2)]],
                                texture2d<float> outgoing1 [[texture(3)]],
                                constant ChannelUniforms &u [[buffer(0)]]) {
    float4 inc = float4(0);
    if (kIncomingLayout != kLayoutNone) {
        inc = sampleSource(kIncomingLayout, incoming0, incoming1, in.uv, u.incomingRect, u.codeScales.x, u.incomingRange,
                           u.incomingMatrix, u.incomingPrimaries);
        if (kHasGrade && kIncomingLayout != kLayoutFinished) inc = grade(inc, u);
    }
    if (kTransition == 0) return inc;

    float4 outg = float4(0);
    if (kOutgoingLayout != kLayoutNone) {
        outg = sampleSource(kOutgoingLayout, outgoing0, outgoing1, in.uv, u.outgoingRect, u.codeScales.y, u.outgoingRange,
                            u.outgoingMatrix, u.outgoingPrimaries);
        if (kHasGrade && kOutgoingLayout != kLayoutFinished) outg = grade(outg, u);
    }
    float t = u.transition.x;
    // Spec 4 §7 stage 3 — "dissolve: lerp(outgoing, incoming, t)".
    if (kTransition == 1) return mix(outg, inc, t);
    // "fadeThroughColor: t < 0.5: lerp(outgoing, colour, 2t); else lerp(colour, incoming, 2t - 1), colour opaque and premultiplied".
    return t < 0.5 ? mix(outg, u.color, 2 * t) : mix(u.color, inc, 2 * t - 1);
}
