// OEngine — Spec 4 §10, the encode pass every sink shares: "mix the stack
// texture with a second texture when an output transition is running (the
// previous stack for a switch, black for blackout ...), apply the output's
// transfer function, and write the output's pixel format."

#include <metal_stdlib>
using namespace metal;

// true: the display sink writes 10-bit encoded values; false: the capture sink keeps linear light.
constant bool kToDisplay [[function_constant(0)]];

struct EncodeUniforms {
    float4 mix;    // amount of the second texture, hasSecond, secondIsBlack, unused
    float4 size;   // width, height
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut encodeVertex(uint id [[vertex_id]]) {
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(positions[id], 0, 1);
    out.uv = float2((positions[id].x + 1) * 0.5, 1 - (positions[id].y + 1) * 0.5);
    return out;
}

static inline float3 srgbEncode(float3 v) {
    float3 x = saturate(v);
    float3 low = x * 12.92;
    float3 high = 1.055 * pow(x, 1 / 2.4) - 0.055;
    return select(high, low, x <= 0.0031308);
}

/// The mixed linear pixel at uv.
static inline float4 mixed(float2 uv, texture2d<float> stack, texture2d<float> second, constant EncodeUniforms &u) {
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
    float4 a = stack.sample(s, uv);
    if (u.mix.y < 0.5 || u.mix.x <= 0) return a;
    float4 b = u.mix.z > 0.5 ? float4(0, 0, 0, 1) : second.sample(s, uv);
    return mix(a, b, u.mix.x);
}

fragment float4 encodeFragment(VertexOut in [[stage_in]],
                               texture2d<float> stack [[texture(0)]],
                               texture2d<float> second [[texture(1)]],
                               constant EncodeUniforms &u [[buffer(0)]]) {
    float4 c = mixed(in.uv, stack, second, u);
    if (kToDisplay) {
        // Spec 4 §10 — "pixel format bgr10a2Unorm (10-bit) ... colour space sRGB/Rec.709".
        return float4(srgbEncode(c.rgb), c.a);
    }
    return c;
}

/// Spec 4 §10 — "The encode pass is a compute shader that writes v210 directly
/// into an MTLBuffer with shared storage": six pixels of Rec.709 limited-range
/// 10-bit 4:2:2 per four 32-bit words, chroma from the mean of each pair.
kernel void encodeV210(texture2d<float> stack [[texture(0)]],
                       texture2d<float> second [[texture(1)]],
                       device uint *out [[buffer(0)]],
                       constant EncodeUniforms &u [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    uint width = uint(u.size.x);
    uint height = uint(u.size.y);
    uint groups = (width + 5) / 6;
    if (gid.x >= groups || gid.y >= height) return;
    uint rowWords = ((width + 47) / 48) * 32;   // rows are padded to a multiple of 128 bytes
    float y[6];
    float cb[6];
    float cr[6];
    for (uint i = 0; i < 6; i++) {
        uint x = min(width - 1, gid.x * 6 + i);
        float2 uv = (float2(x, gid.y) + 0.5) / float2(width, height);
        float4 c = mixed(uv, stack, second, u);
        float3 e = srgbEncode(c.rgb);
        float luma = 0.2126 * e.r + 0.7152 * e.g + 0.0722 * e.b;
        y[i] = luma;
        cb[i] = (e.b - luma) / 1.8556;
        cr[i] = (e.r - luma) / 1.5748;
    }
    uint yc[6];
    uint cbc[3];
    uint crc[3];
    for (uint i = 0; i < 6; i++) yc[i] = uint(round(64 + 876 * saturate(y[i])));
    for (uint p = 0; p < 3; p++) {
        cbc[p] = uint(round(512 + 896 * clamp((cb[p * 2] + cb[p * 2 + 1]) * 0.5, -0.5, 0.5)));
        crc[p] = uint(round(512 + 896 * clamp((cr[p * 2] + cr[p * 2 + 1]) * 0.5, -0.5, 0.5)));
    }
    uint base = gid.y * rowWords + gid.x * 4;
    out[base + 0] = cbc[0] | (yc[0] << 10) | (crc[0] << 20);
    out[base + 1] = yc[1] | (cbc[1] << 10) | (yc[2] << 20);
    out[base + 2] = crc[1] | (yc[3] << 10) | (cbc[2] << 20);
    out[base + 3] = yc[4] | (crc[2] << 10) | (yc[5] << 20);
}
