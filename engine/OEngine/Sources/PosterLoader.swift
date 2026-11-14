// OEngine — Spec 4 §5 and Spec 8 §5, §9: the poster loader.

import CoreGraphics
import Foundation
import ImageIO
import OCore
import OFormats

/// Spec 4 §5 — "Poster frame: BGRA8Unorm sRGB, Half the channel render size,
/// 1 per pool item, loaded on demand. For offset boxes and thumbnails."
/// Spec 8 §9 — "The poster loader reads at the entry's location and caches
/// by the poster's path, doesn't cache a miss, reads an image as its own
/// poster, and downsizes to half the channel render size (Spec 4 §5)."
///
/// The control thread only looks posters up (`poster`): a poster not yet
/// loaded is asked for on the loader's own queue and the lookup returns
/// `.none` at once, so a build never waits on a file or a decoder (Spec 4
/// §3). The lookahead asks for the next cue's posters ahead of time, beside
/// the text it pre-rasterizes. The thumbnail job loads on its own queue
/// (`load`). What couldn't be read is remembered only until `.posters/` or
/// the media changes (`postersChanged`, Spec 8 §5). Past a byte cap, the
/// posters no build has asked for in two seconds go, least recently asked
/// for first, each texture freed by the resource table two plans after
/// (Spec 4 §3). `synchronous` loads in the lookup itself, for the harness.
public final class ImagePosterProvider: PosterProvider, @unchecked Sendable {
    /// The texture bytes kept before unused posters go.
    public static let defaultCap = 256 << 20
    /// Ticks (two seconds at 60 Hz) a poster must have gone unasked before it may go.
    static let idleTicks: Int64 = 120

    private let backend: MetalBackend
    private let media: MediaFolders
    private let log: EngineLog?
    private let fit: PixelSize
    private let cap: Int
    private let synchronous: Bool
    private let queue = DispatchQueue(label: "o.engine.posters", qos: .utility)
    private let lock = NSLock()

    private struct Slot {
        var handle: TextureHandle
        var bytes: Int
        var lastAsked: Int64
    }
    private var loaded: [PosterKey: Slot] = [:]
    private var loading: Set<PosterKey> = []
    private var missed: Set<PosterKey> = []
    /// Raised by `postersChanged`, so a load that started before the change doesn't record a stale miss.
    private var generation = 0
    private var bytes = 0
    private var loads = 0

    /// Spec 4 §5 — `fit` is half the largest channel render size
    /// (`fit(channels:)`); posters are made no larger than it.
    public init(backend: MetalBackend, media: MediaFolders, fit: PixelSize = PixelSize(width: 960, height: 540),
                cap: Int = ImagePosterProvider.defaultCap, synchronous: Bool = false, log: EngineLog? = nil) {
        self.backend = backend
        self.media = media
        self.fit = fit
        self.cap = cap
        self.synchronous = synchronous
        self.log = log
    }

    /// Spec 4 §5 — "Half the channel render size": half the largest of the
    /// channels', one texture per item whichever channel shows it.
    public static func fit(channels: [PixelSize]) -> PixelSize {
        let width = channels.map(\.width).max() ?? 1920
        let height = channels.map(\.height).max() ?? 1080
        return PixelSize(width: max(1, width / 2), height: max(1, height / 2))
    }

    /// How many posters have been read from disk, for the tests of the cache.
    public var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    /// The texture bytes held.
    public var bytesHeld: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    public func poster(_ key: PosterKey) -> TextureHandle {
        lock.lock()
        let now = backend.resources.lastConsumedTick
        if let slot = loaded[key] {
            loaded[key]?.lastAsked = now
            lock.unlock()
            return slot.handle
        }
        if missed.contains(key) || loading.contains(key) {
            lock.unlock()
            return .none
        }
        loading.insert(key)
        let started = generation
        lock.unlock()
        if synchronous { return finish(key, started: started) }
        queue.async { [self] in _ = finish(key, started: started) }
        return .none
    }

    public func load(_ key: PosterKey) -> TextureHandle {
        lock.lock()
        if let slot = loaded[key] {
            loaded[key]?.lastAsked = backend.resources.lastConsumedTick
            lock.unlock()
            return slot.handle
        }
        if missed.contains(key) {
            lock.unlock()
            return .none
        }
        let wasLoading = loading.contains(key)
        loading.insert(key)
        let started = generation
        lock.unlock()
        // One in flight on the loader's queue: wait for it there.
        if wasLoading {
            queue.sync {}
            lock.lock()
            defer { lock.unlock() }
            return loaded[key]?.handle ?? .none
        }
        return finish(key, started: started)
    }

    public func postersChanged() {
        lock.lock()
        missed.removeAll()
        generation += 1
        lock.unlock()
    }

    /// Reads, fits and uploads one poster, then records what came of it.
    private func finish(_ key: PosterKey, started: Int) -> TextureHandle {
        let handle = read(key)
        lock.lock()
        defer { lock.unlock() }
        loading.remove(key)
        loads += 1
        guard let handle else {
            // Spec 8 §5 — not remembered past the next change under `.posters/` or in the media.
            if generation == started { missed.insert(key) }
            return .none
        }
        let size = backend.resources.descriptor(handle)?.size ?? PixelSize(width: 0, height: 0)
        let slotBytes = size.width * size.height * 4
        loaded[key] = Slot(handle: handle, bytes: slotBytes, lastAsked: backend.resources.lastConsumedTick)
        bytes += slotBytes
        evict(keeping: key)
        return handle
    }

    /// Past the cap, posters unasked for two seconds go, least recently asked first.
    private func evict(keeping key: PosterKey) {
        guard bytes > cap else { return }
        let now = backend.resources.lastConsumedTick
        let idle = loaded.filter { $0.key != key && now - $0.value.lastAsked >= Self.idleTicks }.sorted { $0.value.lastAsked < $1.value.lastAsked }
        for (old, slot) in idle where bytes > cap {
            loaded[old] = nil
            bytes -= slot.bytes
            // Spec 4 §3 — freed once every plan that could name it has been consumed.
            backend.resources.release(slot.handle)
        }
    }

    /// The file fitted within `fit`, as a premultiplied sRGB BGRA texture; nil when it can't be read.
    private func read(_ key: PosterKey) -> TextureHandle? {
        guard let url = media.url(for: key.location),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else {
            return nil
        }
        let scale = min(1, min(Double(fit.width) / Double(w), Double(fit.height) / Double(h)))
        let width = max(1, Int((Double(w) * scale).rounded()))
        let height = max(1, Int((Double(h) * scale).rounded()))
        let decoded: CGImage?
        if scale < 1 {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                                            kCGImageSourceShouldCacheImmediately: true]
            decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image = decoded else {
            log?.warning("poster not readable: \(key.location.folder.rawValue) \(key.location.path)")
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let handle = backend.makeTexture(TextureDescriptor(role: .poster, size: PixelSize(width: width, height: height),
                                                           label: "poster " + key.id.prefix(15)))
        guard !handle.isNone else { return nil }
        backend.upload(bgra8: Data(pixels), bytesPerRow: width * 4, into: handle)
        return handle
    }
}
