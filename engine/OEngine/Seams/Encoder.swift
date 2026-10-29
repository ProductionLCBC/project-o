// OEngine — Spec 4 §14, the `Encoder` seam; Spec 4 §10, the encode pass.

import Foundation
import OCore

/// Spec 4 §10 — "Every sink shares one encode pass: mix the stack texture
/// with a second texture when an output transition is running ..., apply the
/// output's transfer function, and write the output's pixel format."
/// Spec 4 §14 — `Encoder`: "10-bit display, v210 with weave" in v1; "BGRA and
/// PA16 for NDI, 8-bit with dither for previews" later.
public enum EncodeKind: String, Codable, Sendable {
    /// Spec 4 §10 — the display sink: `bgr10a2Unorm`, sRGB transfer, full range.
    case display10Bit
    /// Spec 4 §10 — the DeckLink sink: v210, Rec.709 transfer, limited range.
    case v210
    /// Spec 4 §14 — the harness's capturing sink: linear RGBA16Float, no encode.
    case capture
}

/// Spec 4 §14 — a sink encoder: the output's transfer function and pixel
/// format, as a shader variant and the CPU reference the colour tests check
/// it against (Spec 4 §16, "Colour").
public protocol SinkEncoder: Sendable {
    var kind: EncodeKind { get }
    /// The code values one linear premultiplied pixel encodes to, per channel,
    /// on the CPU: the reference for the shader's output.
    func encode(_ pixel: LinearPixel) -> EncodedPixel
}

/// Integer code values of one encoded pixel: RGB (or Y, Cb, Cr) and alpha.
public struct EncodedPixel: Equatable, Sendable {
    public var c0: Int
    public var c1: Int
    public var c2: Int
    public var alpha: Int

    public init(c0: Int, c1: Int, c2: Int, alpha: Int) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
        self.alpha = alpha
    }
}
