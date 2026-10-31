// OEngine — Spec 4 §6, stills; Spec 4 §5, posters.

import Foundation
import CoreGraphics
import ImageIO
import Metal
import OCore
import Synchronization

public enum StillError: Error {
    case cannotDecode(String)
    case cannotAllocate
}

/// Spec 4 §6 — "Stills. Decoded once with ImageIO off the render thread,
/// downsampled to the channel render size, converted to RGBA16Float linear
/// with mips, and kept for as long as the instance (and any outgoing
/// transition) needs it. A still is simply a source whose texture never
/// changes." The conversion happens in Core Graphics: the image is drawn into
/// a half-float, linear-sRGB, premultiplied bitmap at the fitted size, which
/// is exactly the texture the channel pass wants.
public final class StillSource: ContentSource, @unchecked Sendable {
    public let url: URL
    public let layout: SourceLayout = .linearRGBA16
    public private(set) var size = PixelSize(width: 0, height: 0)
    public private(set) var handle: TextureHandle = .none
    private let ready = Atomic<Bool>(false)
    private let releasedFlag = Atomic<Bool>(false)
    private let backend: MetalBackend
    private let fitWithin: PixelSize
    private var texture: MTLTexture?

    public init(url: URL, fitWithin: PixelSize, backend: MetalBackend) {
        self.url = url
        self.fitWithin = fitWithin
        self.backend = backend
    }

    public var isReady: Bool { ready.load(ordering: .acquiring) }
    public var queueDepth: Int { isReady ? 1 : 0 }
    public var isReleased: Bool { releasedFlag.load(ordering: .acquiring) }

    public func pick(mediaTimeMs: Double, into frame: inout PickedFrame) -> PickResult {
        guard isReady, let texture else { return .nothing }
        frame.plane0 = texture
        frame.plane1 = nil
        frame.layout = .linearRGBA16
        frame.presentationMs = 0
        return .frame
    }

    public func release() {
        releasedFlag.store(true, ordering: .releasing)
        backend.resources.release(handle, afterTick: Int64.max)
    }

    /// Decode and convert, on the calling (decode) thread.
    public func load() throws {
        let frame = try StillSource.decode(url: url, fitWithin: fitWithin)
        size = PixelSize(width: frame.width, height: frame.height)
        let handle = backend.makeStill(frame, label: "still " + url.lastPathComponent)
        guard !handle.isNone, let texture = backend.resources.object(handle) as? MTLTexture else { throw StillError.cannotAllocate }
        self.handle = handle
        self.texture = texture
        ready.store(true, ordering: .releasing)
    }

    /// The image as premultiplied linear pixels, fitted within `fitWithin`.
    public static func decode(url: URL, fitWithin: PixelSize) throws -> CapturedFrame {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw StillError.cannotDecode(url.lastPathComponent)
        }
        return try convert(image, fitWithin: fitWithin)
    }

    public static func convert(_ image: CGImage, fitWithin: PixelSize) throws -> CapturedFrame {
        let scale = min(1, min(Double(fitWithin.width) / Double(max(1, image.width)), Double(fitWithin.height) / Double(max(1, image.height))))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.linearSRGB) else { throw StillError.cannotDecode("no linear colour space") }
        var halves = [Float16](repeating: 0, count: width * height * 4)
        let drawn = halves.withUnsafeMutableBytes { raw -> Bool in
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                                          space: space, bitmapInfo: info.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw StillError.cannotDecode("cannot draw \(width)x\(height)") }
        var frame = CapturedFrame(width: width, height: height)
        for i in 0..<(width * height) {
            frame.pixels[i] = LinearPixel(r: Float(halves[i * 4]), g: Float(halves[i * 4 + 1]), b: Float(halves[i * 4 + 2]), a: Float(halves[i * 4 + 3]))
        }
        return frame
    }
}

/// Spec 4 §5 — "Poster frame: BGRA8Unorm sRGB ... 1 per pool item, loaded on
/// demand. For offset slots and thumbnails." Loaded with ImageIO into a
/// premultiplied sRGB bitmap and uploaded as an sRGB-typed texture.
public final class ImagePosterProvider: PosterProvider, @unchecked Sendable {
    private let backend: MetalBackend
    private let mediaRoot: URL
    private let log: EngineLog?
    private let lock = NSLock()
    private var handles: [String: TextureHandle] = [:]

    public init(backend: MetalBackend, mediaRoot: URL, log: EngineLog? = nil) {
        self.backend = backend
        self.mediaRoot = mediaRoot
        self.log = log
    }

    public func poster(for entry: MediaEntry) -> TextureHandle {
        guard let path = entry.poster else { return .none }
        lock.lock()
        defer { lock.unlock() }
        if let handle = handles[entry.id] { return handle }
        let handle = load(mediaRoot.appendingPathComponent(path), label: "poster " + entry.id.prefix(15))
        handles[entry.id] = handle
        return handle
    }

    func load(_ url: URL, label: String) -> TextureHandle {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            log?.warning("poster not readable: \(url.lastPathComponent)")
            return .none
        }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return .none }
        let handle = backend.makeTexture(TextureDescriptor(role: .poster, size: PixelSize(width: width, height: height), label: label))
        backend.upload(bgra8: Data(bytes), bytesPerRow: width * 4, into: handle)
        return handle
    }
}
