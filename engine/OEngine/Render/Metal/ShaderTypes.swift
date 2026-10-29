// OEngine — the uniform blocks the shaders read, laid out as the .metal files
// declare them (float4 and float3x3 members only, so Swift and Metal agree on
// every offset).

import Foundation
import simd

/// `ChannelUniforms` in Channel.metal.
struct ChannelUniforms {
    var incomingRect: SIMD4<Float> = SIMD4(0, 0, 1, 1)
    var outgoingRect: SIMD4<Float> = SIMD4(0, 0, 1, 1)
    var incomingRange: SIMD4<Float> = SIMD4(1, 0, 1, 0)
    var outgoingRange: SIMD4<Float> = SIMD4(1, 0, 1, 0)
    var codeScales: SIMD4<Float> = SIMD4(1, 1, 0, 0)
    var transition: SIMD4<Float> = SIMD4(0, 0, 0, 0)
    var color: SIMD4<Float> = SIMD4(0, 0, 0, 1)
    var gradeA: SIMD4<Float> = SIMD4(1, 0, 1, 1)
    var tint: SIMD4<Float> = SIMD4(0, 0, 0, 0)
    var incomingMatrix: simd_float3x3 = matrix_identity_float3x3
    var outgoingMatrix: simd_float3x3 = matrix_identity_float3x3
    var incomingPrimaries: simd_float3x3 = matrix_identity_float3x3
    var outgoingPrimaries: simd_float3x3 = matrix_identity_float3x3
    var hue: simd_float3x3 = matrix_identity_float3x3

    mutating func setGrade(_ g: GradeParameters) {
        gradeA = SIMD4(g.saturation, g.brightness, g.contrast, g.opacity)
        tint = SIMD4(g.tint.r, g.tint.g, g.tint.b, g.tint.a)
        hue = ColorMath.hueRotation(degrees: g.hue)
    }
}

/// `BlurUniforms` in Blur.metal.
struct BlurUniforms {
    var params: SIMD4<Float>
}

/// `StackUniforms` in Stack.metal.
struct StackUniforms {
    var frame: SIMD4<Float>      // x, y, width, height in clip space units (-1...1)
    var uv: SIMD4<Float>         // u, v, width, height
    var opacity: SIMD4<Float>    // opacity, unused...
    var gradeA: SIMD4<Float>
    var tint: SIMD4<Float>
    var hue: simd_float3x3

    mutating func setGrade(_ g: GradeParameters) {
        gradeA = SIMD4(g.saturation, g.brightness, g.contrast, g.opacity)
        tint = SIMD4(g.tint.r, g.tint.g, g.tint.b, g.tint.a)
        hue = ColorMath.hueRotation(degrees: g.hue)
    }
}

/// `EncodeUniforms` in Encode.metal.
struct EncodeUniforms {
    var mix: SIMD4<Float>        // amount of the second texture, hasSecond (0/1), secondIsBlack (0/1), unused
    var size: SIMD4<Float>       // width, height, unused, unused
}
