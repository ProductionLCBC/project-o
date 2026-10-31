// OEngine — Spec 4 §15, "A fixture list of public-domain hymn lyrics over
// ProRes and HEVC backgrounds with trims and one loop" and "a clapper fixture":
// the synthetic media the spike library's index names.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The clips and the still behind `tests/fixtures/spike/library/media-index.json`.
/// They are generated, not committed (the folder is ignored by git): the index
/// carries fixed ids, so `make-fixtures` can run on any machine and the lists
/// still resolve.
public enum SpikeFixtures {
    public struct Item: Equatable, Sendable {
        public var path: String
        public var clip: FixtureMedia.Clip?

        public var isStill: Bool { clip == nil }
    }

    /// The media, at full length; `scale` shortens every clip (and moves the
    /// clapper's click and flash with it) for a quick test.
    public static func items(scale: Double = 1) -> [Item] {
        let s = max(0.05, scale)
        func clip(_ name: String, _ codec: FixtureMedia.Codec, seconds: Double, audio: FixtureMedia.Audio? = nil, flashFrame: Int? = nil) -> FixtureMedia.Clip {
            var scaledAudio = audio
            if case .click(let atMs)? = audio { scaledAudio = .click(atMs: atMs * s) }
            return FixtureMedia.Clip(name: name, codec: codec, width: 640, height: 360, fps: 30, seconds: seconds * s, audio: scaledAudio,
                                     flashFrame: flashFrame.map { Int((Double($0) * s).rounded()) })
        }
        return [
            Item(path: "backgrounds/field-prores.mov", clip: clip("field", .proRes422Proxy, seconds: 12)),
            Item(path: "backgrounds/sky-hevc.mov", clip: clip("sky", .hevc, seconds: 12, audio: .tone(hz: 220, gain: 0.1))),
            Item(path: "backgrounds/river-hevc10.mov", clip: clip("river", .hevc10, seconds: 12, audio: .tone(hz: 330, gain: 0.1))),
            Item(path: "backgrounds/light-prores4444.mov", clip: clip("light", .proRes4444, seconds: 6)),
            Item(path: "clapper/clapper.mov", clip: clip("clapper", .h264, seconds: 3, audio: .click(atMs: 1000), flashFrame: 30)),
            Item(path: "stills/cross.png", clip: nil),
        ]
    }

    /// Writes every item under `mediaFolder`, making the folders; returns what it wrote.
    @discardableResult
    public static func write(into mediaFolder: URL, scale: Double = 1) throws -> [URL] {
        var written: [URL] = []
        for item in items(scale: scale) {
            let url = mediaFolder.appendingPathComponent(item.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let clip = item.clip {
                try FixtureMedia.write(clip, to: url)
            } else {
                try FixtureMedia.writeStill(to: url, width: 640, height: 360)
            }
            written.append(url)
        }
        return written
    }

    /// True when every item exists under `mediaFolder`.
    public static func exist(in mediaFolder: URL) -> Bool {
        items().allSatisfy { FileManager.default.fileExists(atPath: mediaFolder.appendingPathComponent($0.path).path) }
    }
}

extension FixtureMedia {
    /// A synthetic still: a vertical wash with a white cross, sRGB PNG without
    /// alpha, so the still source and poster paths have a real file.
    public static func writeStill(to url: URL, width: Int, height: Int) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw WriteError.cannotMakeBuffer
        }
        let colors = [CGColor(srgbRed: 0.05, green: 0.10, blue: 0.30, alpha: 1), CGColor(srgbRed: 0.55, green: 0.35, blue: 0.15, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: context.colorSpace, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: 0, y: 0), options: [])
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        let w = CGFloat(width), h = CGFloat(height)
        context.fill(CGRect(x: w * 0.47, y: h * 0.2, width: w * 0.06, height: h * 0.6))
        context.fill(CGRect(x: w * 0.35, y: h * 0.58, width: w * 0.3, height: h * 0.06))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw WriteError.failed("png destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WriteError.failed("png write") }
    }
}
