// OEngine — Spec 8 §5, poster frames and pool tiles: the frame at the in-point, fitted, and written as PNG.

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import OCore

/// A CGImage handed between the loading task and the thread waiting on it.
public struct MediaImage: @unchecked Sendable {
    public let image: CGImage

    public init(_ image: CGImage) {
        self.image = image
    }
}

/// Spec 8 §5 — "The poster (M2) is the frame at the video's default
/// in-point (`defaults.trimInMs`, or 0), taken exactly". A seam, so the walk
/// and import tests run without AVFoundation (Spec 8 §11).
public protocol MediaFrames: Sendable {
    /// The frame of the video at `url` that playback shows first for a write
    /// with this in-point, with its alpha when `alpha` is set; nil when it
    /// can't be decoded.
    func frame(of url: URL, atMs inMs: Int, alpha: Bool) -> MediaImage?
}

/// Spec 8 §5 — the engine's own: "taken exactly, because that's the frame
/// the engine stands it in for when a write lands before its first decoded
/// frame (Spec 4 §6)". Playback pre-rolls to the in-point and publishes the
/// first frame whose time is at or after it (`VideoFileSource`); so does
/// this, decoding with AVAssetReader from playback's pre-roll point to that
/// frame. Behind a bounded wait, as the probe is (Spec 4 §12).
public struct AVMediaFrames: MediaFrames {
    public var timeout: Double

    public init(timeout: Double = 20) {
        self.timeout = timeout
    }

    final class Found: @unchecked Sendable {
        var image: MediaImage?
    }

    public func frame(of url: URL, atMs inMs: Int, alpha: Bool) -> MediaImage? {
        let found = Found()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            found.image = await Self.extract(url, inMs: inMs, alpha: alpha)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return found.image
    }

    static func extract(_ url: URL, inMs: Int, alpha: Bool) async -> MediaImage? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        // As playback reads (`AVAssetReaderDemuxer`): from its pre-roll before the in-point, so every frame
        // near the in-point keeps its own time (the reader stamps the first frame of a range with the range's start).
        let start = max(0, Double(inMs) - AVAssetReaderDemuxer.prerollMs)
        reader.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue(start), timescale: 1000), duration: .positiveInfinity)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        var chosen: CVPixelBuffer?
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            chosen = buffer
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            // The first frame at or after the in-point, as `VideoFileSource` publishes it.
            if time.isNumeric, time.seconds * 1000 >= Double(inMs) - 0.001 { break }
        }
        return chosen.flatMap { image(of: $0, alpha: alpha) }.map(MediaImage.init)
    }

    /// A decoded BGRA frame as a CGImage that owns its bytes: straight or
    /// premultiplied alpha as the decoder marks it, or none.
    static func image(of buffer: CVPixelBuffer, alpha: Bool) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, let provider = CGDataProvider(data: Data(bytes: base, count: rowBytes * height) as CFData) else { return nil }
        let mode = CVBufferCopyAttachment(buffer, kCVImageBufferAlphaChannelModeKey, nil) as? String
        let straight = mode == (kCVImageBufferAlphaChannelMode_StraightAlpha as String)
        let alphaInfo: CGImageAlphaInfo = alpha ? (straight ? .first : .premultipliedFirst) : .noneSkipFirst
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: MediaImages.sRGB, bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Spec 8 §5 — fitting, tiles and PNG files, with Core Graphics and ImageIO.
public enum MediaImages {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Whether an image carries alpha worth keeping.
    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// The image drawn at `width` × `height`, premultiplied BGRA, with its
    /// alpha when it has some.
    static func draw(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let alpha = hasAlpha(image)
        let info = CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.premultipliedFirst : .noneSkipFirst).rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: sRGB, bitmapInfo: info.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Spec 8 §5 — "a PNG fitted within 1920 × 1080": made smaller to fit,
    /// never larger.
    public static func fitted(_ image: CGImage, within bounds: (width: Int, height: Int) = MediaPosters.posterBounds) -> CGImage? {
        let scale = min(1, min(Double(bounds.width) / Double(max(1, image.width)), Double(bounds.height) / Double(max(1, image.height))))
        guard scale < 1 else { return image }
        return draw(image, width: max(1, Int((Double(image.width) * scale).rounded())), height: max(1, Int((Double(image.height) * scale).rounded())))
    }

    /// Spec 8 §5 — "Pool tiles (M3) are 480 px wide PNGs ..., made from the
    /// poster for video and from the image for an image": the image's first
    /// frame (a GIF's too), drawn 480 px wide at its own aspect.
    public static func tile(from url: URL, width: Int = MediaPosters.tileWidth) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        let height = max(1, Int((Double(width) * Double(h) / Double(w)).rounded()))
        // A large image is decoded at about the size it's drawn, never smaller.
        let needed = Int((Double(width) * Double(max(w, h)) / Double(w)).rounded(.up))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: needed,
                                        kCGImageSourceShouldCacheImmediately: true]
        let decoded = max(w, h) > needed ? CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                                         : CGImageSourceCreateImageAtIndex(source, 0, nil)
        return decoded.flatMap { draw($0, width: width, height: height) }
    }

    /// A PNG written under a hidden name and renamed into place, so nothing
    /// reads half of it; false when it couldn't be written.
    public static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).writing-\(UInt32.random(in: .min ... .max))")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        return true
    }
}
