// OEngine — Spec 4 §1 guarantee 4 and §7 stage 1 and 2, the colour pipeline
// on the CPU: the reference the shaders are tested against (Spec 4 §16, Colour).

import Foundation
import OCore
import simd

/// Spec 4 §7 — "Decision on the transfer function: every Rec.709 or
/// sRGB-tagged source, video or still, is linearized with the sRGB piecewise
/// curve." Spec 4 §10 — "apply the output's transfer function" is the same
/// curve the other way, so a source passes through unchanged (Area 4 reading;
/// a BT.1886 switch for video can come later, as the spec allows).
public enum ColorMath {
    public static func srgbDecode(_ v: Float) -> Float {
        let x = min(1, max(0, v))
        return x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4)
    }

    public static func srgbEncode(_ v: Float) -> Float {
        let x = min(1, max(0, v))
        return x <= 0.0031308 ? x * 12.92 : 1.055 * powf(x, 1 / 2.4) - 0.055
    }

    /// Spec 4 §7 — "matrix (BT.709 by default, BT.601 for SD-sized sources,
    /// BT.2020 sources converted to 709 primaries)". Y' in 0...1, Cb and Cr
    /// centred on zero, to non-linear R'G'B'.
    public static func ycbcrToRGB(_ matrix: ColorMatrix) -> simd_float3x3 {
        switch matrix {
        case .bt709:
            return simd_float3x3(columns: (SIMD3(1, 1, 1), SIMD3(0, -0.1873, 1.8556), SIMD3(1.5748, -0.4681, 0)))
        case .bt601:
            return simd_float3x3(columns: (SIMD3(1, 1, 1), SIMD3(0, -0.344136, 1.772), SIMD3(1.402, -0.714136, 0)))
        case .bt2020:
            return simd_float3x3(columns: (SIMD3(1, 1, 1), SIMD3(0, -0.16455, 1.8814), SIMD3(1.4746, -0.57135, 0)))
        }
    }

    /// BT.2020 to Rec.709 primaries, applied in linear light.
    public static func primariesToRec709(_ matrix: ColorMatrix) -> simd_float3x3 {
        guard matrix == .bt2020 else { return matrix_identity_float3x3 }
        return simd_float3x3(rows: [SIMD3(1.6605, -0.5876, -0.0728), SIMD3(-0.1246, 1.1329, -0.0083), SIMD3(-0.0182, -0.1006, 1.1187)])
    }

    /// Spec 4 §7 — "range expansion when the source is limited range": the
    /// scale and offset that take a code (normalized to full scale of its bit
    /// depth) to Y' in 0...1 and chroma centred on zero: (yScale, yOffset,
    /// cScale, cOffset).
    public static func rangeExpansion(range: ColorRange, bits: Int) -> SIMD4<Float> {
        let full = Float((1 << bits) - 1)
        switch (range, bits) {
        case (.limited, 8):
            return SIMD4(255.0 / 219.0, -16.0 / 219.0, 255.0 / 224.0, -128.0 / 224.0)
        case (.limited, _):
            return SIMD4(1023.0 / 876.0, -64.0 / 876.0, 1023.0 / 896.0, -512.0 / 896.0)
        case (.full, _):
            let half = Float(1 << (bits - 1)) / full
            return SIMD4(1, 0, 1, -half)
        }
    }

    /// 10-bit codes left-aligned in 16-bit unorm samples (P010, 4:2:2 10-bit)
    /// read as `code << 6 / 65535`; this brings them back to `code / 1023`.
    public static func codeScale(for layout: SourceLayout) -> Float {
        switch layout {
        case .p010, .yuv422p10: return 65535.0 / (64.0 * 1023.0)
        default: return 1
        }
    }

    public static func bits(for layout: SourceLayout) -> Int {
        switch layout {
        case .nv12: return 8
        case .p010, .yuv422p10: return 10
        default: return 16
        }
    }

    /// Spec 4 §7 stage 1 for a YCbCr sample: codes (normalized to the depth's
    /// full scale) to premultiplied linear RGBA.
    public static func stage1YCbCr(y: Float, cb: Float, cr: Float, layout: SourceLayout, matrix: ColorMatrix, range: ColorRange) -> LinearPixel {
        let bits = bits(for: layout)
        let expansion = rangeExpansion(range: range, bits: bits)
        let yp = y * expansion.x + expansion.y
        let cbc = cb * expansion.z + expansion.w
        let crc = cr * expansion.z + expansion.w
        let rgb = ycbcrToRGB(matrix) * SIMD3(yp, cbc, crc)
        let lin = SIMD3(srgbDecode(rgb.x), srgbDecode(rgb.y), srgbDecode(rgb.z))
        let out = primariesToRec709(matrix) * lin
        return LinearPixel(r: out.x, g: out.y, b: out.z, a: 1)
    }

    /// Spec 4 §7 stage 1 for an RGBA source: "the transfer function, then
    /// premultiplication after linearizing, since files store straight alpha."
    public static func stage1RGBA(r: Float, g: Float, b: Float, a: Float) -> LinearPixel {
        LinearPixel(r: srgbDecode(r) * a, g: srgbDecode(g) * a, b: srgbDecode(b) * a, a: a)
    }

    /// Spec 4 §7 stage 2 — the grade in linear light on a premultiplied pixel:
    /// hue rotation, saturation toward luma, brightness and tint multiplies,
    /// contrast around 0.18 (scaled by alpha for premultiplied values),
    /// opacity on all four components.
    public static func grade(_ p: LinearPixel, _ g: GradeParameters) -> LinearPixel {
        var rgb = SIMD3(p.r, p.g, p.b)
        rgb = hueRotation(degrees: g.hue) * rgb
        let luma = simd_dot(rgb, lumaWeights)
        rgb = simd_mix(SIMD3(repeating: luma), rgb, SIMD3(repeating: g.saturation))
        rgb *= (1 + g.brightness)
        let tint = simd_mix(SIMD3(repeating: 1), SIMD3(g.tint.r, g.tint.g, g.tint.b), SIMD3(repeating: g.tint.a))
        rgb *= tint
        rgb = (rgb - 0.18 * p.a) * g.contrast + 0.18 * p.a
        rgb *= g.opacity
        return LinearPixel(r: rgb.x, g: rgb.y, b: rgb.z, a: p.a * g.opacity)
    }

    /// Rec.709 luma weights in linear light.
    public static let lumaWeights = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    /// A hue rotation about the luma axis, as a matrix the shader multiplies by.
    public static func hueRotation(degrees: Float) -> simd_float3x3 {
        guard degrees != 0 else { return matrix_identity_float3x3 }
        let angle = degrees * .pi / 180
        let c = cosf(angle)
        let s = sinf(angle)
        let axis = simd_normalize(SIMD3<Float>(1, 1, 1))
        let x = axis.x
        let y = axis.y
        let z = axis.z
        let t = 1 - c
        return simd_float3x3(rows: [
            SIMD3(t * x * x + c, t * x * y - s * z, t * x * z + s * y),
            SIMD3(t * x * y + s * z, t * y * y + c, t * y * z - s * x),
            SIMD3(t * x * z - s * y, t * y * z + s * x, t * z * z + c),
        ])
    }

    // MARK: - Sink encodes (Spec 4 §10, Spec 4 §16 "back through each sink encode")

    /// Spec 4 §10 — the display sink: 10-bit full range, the sRGB curve.
    public static func encodeDisplay10(_ p: LinearPixel) -> EncodedPixel {
        func code(_ v: Float) -> Int { Int((min(1, max(0, srgbEncode(v))) * 1023).rounded()) }
        return EncodedPixel(c0: code(p.r), c1: code(p.g), c2: code(p.b), alpha: Int((min(1, max(0, p.a)) * 3).rounded()))
    }

    /// Spec 4 §10 — the DeckLink sink: "10-bit YUV (v210) frames, limited
    /// range, Rec.709": Y'CbCr codes for one pixel (chroma of a pair is the
    /// mean of the two pixels' codes in the packer).
    public static func encodeV210(_ p: LinearPixel) -> EncodedPixel {
        let rp = srgbEncode(p.r)
        let gp = srgbEncode(p.g)
        let bp = srgbEncode(p.b)
        let y = 0.2126 * rp + 0.7152 * gp + 0.0722 * bp
        let cb = (bp - y) / 1.8556
        let cr = (rp - y) / 1.5748
        let yCode = Int((64 + 876 * min(1, max(0, y))).rounded())
        let cbCode = Int((512 + 896 * min(0.5, max(-0.5, cb))).rounded())
        let crCode = Int((512 + 896 * min(0.5, max(-0.5, cr))).rounded())
        return EncodedPixel(c0: yCode, c1: cbCode, c2: crCode, alpha: 0)
    }
}

extension SourceLayout {
    /// The function-constant code of the layout in the channel shader.
    public var shaderCode: Int32 {
        switch self {
        case .nv12: return 1
        case .p010: return 2
        case .yuv422p10: return 3
        case .rgba16: return 4
        case .linearRGBA16: return 5
        case .bgra8sRGB: return 6
        case .finished: return 7
        }
    }
}
