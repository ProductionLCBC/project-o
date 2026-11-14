// OEngine — Spec 4 §6 and §8, what the control thread asks other threads for.

import Foundation
import OCore

/// Spec 4 §6 — what opening a video or still source needs: the file, its
/// index entry, the trim and loop of the instance, and the handle the render
/// thread will pick it through.
public struct SourceRequest: Equatable, Sendable {
    public var url: URL
    public var entry: MediaEntry
    public var inMs: Double
    public var outMs: Double?
    public var loop: Bool
    public var handle: InstanceHandle

    public init(url: URL, entry: MediaEntry, inMs: Double, outMs: Double?, loop: Bool, handle: InstanceHandle) {
        self.url = url
        self.entry = entry
        self.inMs = inMs
        self.outMs = outMs
        self.loop = loop
        self.handle = handle
    }

    /// Spec 4 §6 — a prefetch matches a write by media and in-point.
    public var prefetchKey: String { entry.id + "@" + String(inMs) }
}

/// Spec 4 §6 — "Sessions are created on the decode thread when a write is
/// prefetched or lands, never on the render thread." The factory opens
/// sources for the control thread and keeps prefetched ones until a write
/// adopts them.
public protocol SourceFactory: AnyObject, Sendable {
    /// Open a source for an instance; it becomes ready when its first frame
    /// is published (Spec 4 §6, "Trims and the first frame").
    func open(_ request: SourceRequest) -> any ContentSource
    /// Spec 4 §6 — "the control thread prefetches the media of the next cue".
    func prefetch(_ request: SourceRequest)
    /// A prefetched source for the same media and in-point, if one is waiting.
    func adoptPrefetched(_ request: SourceRequest) -> (any ContentSource)?
}

/// Spec 8 §9 — which poster: "The poster loader reads at the entry's
/// location and caches by the poster's path ... reads an image as its own
/// poster". A video's poster is the PNG its entry names, "relative to the
/// same folder as its `path`" (Spec 8 §5); an image's is the image, at the
/// location it resolves to, with its id, since another item's file can take
/// that path.
public struct PosterKey: Hashable, Sendable {
    public var location: MediaLocation
    public var id: String

    public init(location: MediaLocation, id: String) {
        self.location = location
        self.id = id
    }

    /// The poster of an entry from the tier that holds it, at its resolved
    /// location; nil for audio, slides, a video with no poster yet and an
    /// image with no location.
    public static func of(_ entry: MediaEntry, tier: MediaTier, location: MediaLocation?) -> PosterKey? {
        switch entry.kind {
        case .video:
            guard let path = entry.poster, let poster = MediaLocation(MediaPosters.folder(of: tier), path) else { return nil }
            return PosterKey(location: poster, id: entry.id)
        case .image:
            return location.map { PosterKey(location: $0, id: entry.id) }
        case .audio, .audioSet, .slide, .template:
            return nil
        }
    }

    /// The poster of what a resolution reached.
    public static func of(_ resolution: MediaResolution?) -> PosterKey? {
        resolution.flatMap { of($0.entry, tier: $0.tier, location: $0.location) }
    }
}

/// Spec 4 §5 — "Poster frame: BGRA8Unorm sRGB, Half the channel render
/// size, 1 per pool item, loaded on demand. For offset boxes and thumbnails."
/// `.none` while a poster isn't loaded, and when there is none.
public protocol PosterProvider: AnyObject, Sendable {
    /// Spec 4 §5 — the poster's texture if it is loaded; otherwise it is
    /// asked for and `.none` comes back at once. The control thread's call:
    /// it never waits on a file or a decoder (Spec 4 §3).
    func poster(_ key: PosterKey) -> TextureHandle
    /// Spec 4 §10 — the poster's texture, loaded now on the calling thread if
    /// it must be: the thumbnail job's call, on its background queue, so a
    /// thumbnail never draws without a poster that is there.
    func load(_ key: PosterKey) -> TextureHandle
    /// Spec 8 §5 — "The poster loader doesn't remember a poster it couldn't
    /// find, and a change under `.posters/` makes it look again": what it
    /// couldn't find is forgotten.
    func postersChanged()
}

public extension PosterProvider {
    func load(_ key: PosterKey) -> TextureHandle { poster(key) }
    func postersChanged() {}
}

/// Spec 4 §8 — one cache entry as the plan builder sees it: the line textures
/// with their frames relative to the box origin.
public struct TextEntry: Equatable, Sendable {
    public var lines: [TextLine]
    public var bytes: Int

    public init(lines: [TextLine], bytes: Int) {
        self.lines = lines
        self.bytes = bytes
    }
}

/// Spec 4 §8 — the cache the plan builder consults and the raster queue fills.
/// "Lookahead pre-rasterizes the next cue's text for every due stack so a fire
/// never waits on text; a cache miss on a fire draws nothing for that box on
/// the first tick and the texture from the second".
public protocol TextProvider: AnyObject, Sendable {
    /// The entry for a job, if it is in the cache.
    func entry(for job: TextJob) -> TextEntry?
    /// Ask for a rasterization; returns at once.
    func request(_ job: TextJob)
    /// Spec 4 §8 — "the result replaces the cache entry": a raster that will not
    /// be asked for again goes, its textures freed after `afterTick`.
    func release(_ key: TextKey, afterTick: Int64)
    /// Spec 4 §3 — the render thread consumed this tick; what was released
    /// earlier may be freed.
    func sweep(consumedTick: Int64)
}

public extension TextProvider {
    func release(_ key: TextKey, afterTick: Int64) {}
    func sweep(consumedTick: Int64) {}
}

extension TextKey {
    /// Spec 4 §8 — "Keyed by a hash of (field text, text style value, box pixel
    /// width, box pixel height, fit policy, output scale, tabular digits)."
    /// FNV-1a over a canonical rendering, so the key is stable across runs and
    /// saved plans. Spec 6 §4 — "the text cache's key includes it".
    public static func make(text: String, style: BoxTextStyle, box: PixelSize, fit: TextFit, outputHeight: Int, tabular: Bool = false) -> TextKey {
        var canonical = text
        canonical += "\u{1}"
        canonical += TextKey.canonical(style.values)
        canonical += "\u{1}\(box.width)x\(box.height)\u{1}\(fit.policy.rawValue)/\(fit.maxLines)/\(fit.minSize)\u{1}\(outputHeight)"
        if tabular { canonical += "\u{1}tnum" }
        return TextKey(hash: fnv1a(canonical))
    }

    static func canonical(_ v: TextStyleValues) -> String {
        let variations = v.variations.keys.sorted().map { "\($0)=\(v.variations[$0] ?? 0)" }.joined(separator: ",")
        return "\(v.font)|\(v.size.value)\(v.size.unit.rawValue)|\(v.weight)|\(v.color.r),\(v.color.g),\(v.color.b),\(v.color.a)|\(v.alignment.rawValue)|\(v.verticalAlignment.rawValue)|\(v.lineSpacing)|\(v.letterSpacing)|\(v.outline.width),\(v.outline.color.r),\(v.outline.color.g),\(v.outline.color.b),\(v.outline.color.a)|\(v.shadow.x),\(v.shadow.y),\(v.shadow.blur),\(v.shadow.color.r),\(v.shadow.color.g),\(v.shadow.color.b),\(v.shadow.color.a)|\(v.allCaps)|\(variations)"
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

extension BoxFit {
    public var pixelFit: PixelFit? {
        if case .pixels(let fit) = self { return fit }
        return nil
    }

    public var textFit: TextFit? {
        if case .text(let fit) = self { return fit }
        return nil
    }
}

extension TextSize {
    /// Spec 1 §2 — "pt is points on a 1080-line canvas scaled with output
    /// height, the default; percent is a percentage of output height."
    public func pixels(outputHeight: Int) -> Double {
        switch unit {
        case .pt: return value * Double(outputHeight) / 1080
        case .percent: return value / 100 * Double(outputHeight)
        }
    }
}
