// OEngine — Spec 4 §16, golden images: captured frames, PNGs, the compare.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A frame read back from a stack texture: premultiplied linear RGBA, row
/// major, top row first.
public struct CapturedFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [LinearPixel]

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        pixels = Array(repeating: .transparent, count: self.width * self.height)
    }

    public init(width: Int, height: Int, pixels: [LinearPixel]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> LinearPixel {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }
}

/// Spec 4 §16 — "match stored PNGs within a tolerance": the worst and the mean
/// difference in 8-bit encoded code values, and where the worst pixel is.
public struct GoldenDiff: Equatable, Sendable {
    public var sizesMatch: Bool
    public var maxCodeDifference: Int
    public var meanCodeDifference: Double
    public var worstPixel: (x: Int, y: Int)

    public static func == (a: GoldenDiff, b: GoldenDiff) -> Bool {
        a.sizesMatch == b.sizesMatch && a.maxCodeDifference == b.maxCodeDifference
            && a.meanCodeDifference == b.meanCodeDifference && a.worstPixel == b.worstPixel
    }

    public func isWithin(_ tolerance: GoldenTolerance) -> Bool {
        sizesMatch && maxCodeDifference <= tolerance.maxCodeDifference && meanCodeDifference <= tolerance.meanCodeDifference
    }
}

public struct GoldenTolerance: Equatable, Sendable {
    public var maxCodeDifference: Int
    public var meanCodeDifference: Double

    public init(maxCodeDifference: Int, meanCodeDifference: Double) {
        self.maxCodeDifference = maxCodeDifference
        self.meanCodeDifference = meanCodeDifference
    }

    /// Two codes of 255 on any channel of any pixel, half a code on average.
    public static let `default` = GoldenTolerance(maxCodeDifference: 2, meanCodeDifference: 0.5)
    /// Text rasterization differs by font version; edges may move a little.
    public static let text = GoldenTolerance(maxCodeDifference: 64, meanCodeDifference: 1.5)
}

public enum GoldenError: Error {
    case encodeFailed
    case decodeFailed
}

public enum GoldenImage {
    // MARK: - sRGB

    /// The sRGB piecewise curve, which Spec 4 §7 chose for every source.
    public static func srgbEncode(_ v: Float) -> Float {
        let x = min(1, max(0, v))
        return x <= 0.0031308 ? x * 12.92 : 1.055 * powf(x, 1 / 2.4) - 0.055
    }

    public static func srgbDecode(_ v: Float) -> Float {
        let x = min(1, max(0, v))
        return x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4)
    }

    static func code(_ v: Float) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }

    /// The 8-bit encoded codes of one premultiplied linear pixel.
    static func codes(_ p: LinearPixel) -> (Int, Int, Int, Int) {
        (code(srgbEncode(p.r)), code(srgbEncode(p.g)), code(srgbEncode(p.b)), code(p.a))
    }

    // MARK: - PNG

    /// A frame as an 8-bit sRGB PNG with premultiplied alpha.
    public static func png(from frame: CapturedFrame) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
        for i in 0..<frame.pixels.count {
            let c = codes(frame.pixels[i])
            bytes[i * 4] = UInt8(c.0)
            bytes[i * 4 + 1] = UInt8(c.1)
            bytes[i * 4 + 2] = UInt8(c.2)
            bytes[i * 4 + 3] = UInt8(c.3)
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw GoldenError.encodeFailed
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw GoldenError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw GoldenError.encodeFailed }
        return out as Data
    }

    public static func frame(fromPNG data: Data) throws -> CapturedFrame {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw GoldenError.decodeFailed }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw GoldenError.decodeFailed }
        var frame = CapturedFrame(width: width, height: height)
        for i in 0..<(width * height) {
            frame.pixels[i] = LinearPixel(r: srgbDecode(Float(bytes[i * 4]) / 255), g: srgbDecode(Float(bytes[i * 4 + 1]) / 255),
                                          b: srgbDecode(Float(bytes[i * 4 + 2]) / 255), a: Float(bytes[i * 4 + 3]) / 255)
        }
        return frame
    }

    // MARK: - Compare

    public static func compare(_ a: CapturedFrame, _ b: CapturedFrame) -> GoldenDiff {
        guard a.width == b.width, a.height == b.height, a.width > 0, a.height > 0 else {
            return GoldenDiff(sizesMatch: false, maxCodeDifference: 255, meanCodeDifference: 255, worstPixel: (0, 0))
        }
        var worst = 0
        var worstAt = (0, 0)
        var total = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let ca = codes(a[x, y])
                let cb = codes(b[x, y])
                let d = max(abs(ca.0 - cb.0), abs(ca.1 - cb.1), abs(ca.2 - cb.2), abs(ca.3 - cb.3))
                total += d
                if d > worst {
                    worst = d
                    worstAt = (x, y)
                }
            }
        }
        return GoldenDiff(sizesMatch: true, maxCodeDifference: worst, meanCodeDifference: Double(total) / Double(a.width * a.height),
                          worstPixel: worstAt)
    }

    /// A picture of where two frames differ, amplified, for the diff file.
    static func difference(_ a: CapturedFrame, _ b: CapturedFrame) -> CapturedFrame {
        var out = CapturedFrame(width: a.width, height: a.height)
        guard a.width == b.width, a.height == b.height else { return out }
        for i in 0..<a.pixels.count {
            let p = a.pixels[i]
            let q = b.pixels[i]
            out.pixels[i] = LinearPixel(r: min(1, abs(p.r - q.r) * 8), g: min(1, abs(p.g - q.g) * 8), b: min(1, abs(p.b - q.b) * 8), a: 1)
        }
        return out
    }
}

/// The outcome of checking a frame against its golden.
public enum GoldenCheck: Equatable, Sendable {
    case matched
    case written
    case missing
    case mismatch(GoldenDiff, String)
}

/// Spec 4 §16 and CLAUDE.md — `scripts/golden.sh --update` regenerates the
/// goldens after an intended render change; without it a render must match.
public struct GoldenStore: Sendable {
    public let folder: URL
    public let update: Bool
    public let tolerance: GoldenTolerance

    public init(folder: URL, update: Bool, tolerance: GoldenTolerance = .default) {
        self.folder = folder
        self.update = update
        self.tolerance = tolerance
    }

    /// Whether the environment asks for an update (`OENGINE_GOLDEN_UPDATE=1`).
    public static var updateRequested: Bool {
        ProcessInfo.processInfo.environment["OENGINE_GOLDEN_UPDATE"] == "1"
    }

    public func check(_ name: String, _ frame: CapturedFrame, tolerance: GoldenTolerance? = nil) throws -> GoldenCheck {
        let url = folder.appendingPathComponent(name + ".png")
        if update {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try GoldenImage.png(from: frame).write(to: url)
            return .written
        }
        guard let data = FileManager.default.contents(atPath: url.path) else { return .missing }
        let golden = try GoldenImage.frame(fromPNG: data)
        let diff = GoldenImage.compare(golden, frame)
        if diff.isWithin(tolerance ?? self.tolerance) { return .matched }
        let diffURL = folder.appendingPathComponent(name + ".golden-diff.png")
        try? GoldenImage.png(from: GoldenImage.difference(golden, frame)).write(to: diffURL)
        try? GoldenImage.png(from: frame).write(to: folder.appendingPathComponent(name + ".actual.png"))
        return .mismatch(diff, diffURL.path)
    }
}
