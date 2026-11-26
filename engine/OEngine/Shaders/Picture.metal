// OEngine — Spec 4 §10 and Spec 10 §2 (choice U-3), the channel picture: "Another
// aux pass, at most 30 times a second like the previews, makes a live picture of
// each channel with pixel content for the operator app's channel strip: its
// channel texture fit into 256 by 144 over black, filtered in one pass so it
// doesn't alias". "Without a mip chain": every picture pixel is the mean of the
// block of channel pixels it covers, taken in this one pass, in linear light; the
// sRGB-typed target encodes on write. The channel texture is premultiplied, so
// over black its color is the picture's color and the picture is opaque.

#include <metal_stdlib>
using namespace metal;

struct PictureUniforms {
    float4 fit;    // the part of the picture the source fills: left, top, width, height, of the target
    float4 taps;   // taps across, taps down, source texel width, source texel height
};

struct PictureVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex PictureVertexOut pictureVertex(uint id [[vertex_id]]) {
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    PictureVertexOut out;
    out.position = float4(positions[id], 0, 1);
    out.uv = float2((positions[id].x + 1) * 0.5, 1 - (positions[id].y + 1) * 0.5);
    return out;
}

fragment float4 pictureFragment(PictureVertexOut in [[stage_in]],
                                texture2d<float> source [[texture(0)]],
                                constant PictureUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge, coord::normalized);
    // Where this picture pixel falls in the channel's texture; outside the fitted picture it is black.
    float2 local = (in.uv - u.fit.xy) / u.fit.zw;
    if (local.x < 0 || local.y < 0 || local.x > 1 || local.y > 1) {
        return float4(0, 0, 0, 1);
    }
    int across = max(1, int(u.taps.x));
    int down = max(1, int(u.taps.y));
    float2 texel = u.taps.zw;
    // The picture pixel's center maps to the center of its source block; step back to the block's first texel center.
    float2 origin = local - float2(across - 1, down - 1) * 0.5 * texel;
    float4 sum = float4(0);
    for (int y = 0; y < down; y++) {
        for (int x = 0; x < across; x++) {
            sum += source.sample(s, origin + float2(x, y) * texel);
        }
    }
    float4 mean = sum / float(across * down);
    return float4(mean.rgb, 1);
}
