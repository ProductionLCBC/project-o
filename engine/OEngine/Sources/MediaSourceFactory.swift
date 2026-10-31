// OEngine — Spec 4 §6, the v1 `SourceFactory`: video files and stills.

import Foundation
import OCore

/// Spec 4 §6 — "Sessions are created on the decode thread when a write is
/// prefetched or lands, never on the render thread." Video opens its own
/// decode thread; a still decodes on a utility queue; both report ready when
/// their first picture exists.
public final class MediaSourceFactory: SourceFactory, @unchecked Sendable {
    private let backend: MetalBackend
    private let log: EngineLog
    private let lock = NSLock()
    private var prefetched: [String: any ContentSource] = [:]
    private let stillQueue = DispatchQueue(label: "o.engine.stills", qos: .userInitiated)
    public private(set) var openedCount = 0

    public init(backend: MetalBackend, log: EngineLog) {
        self.backend = backend
        self.log = log
    }

    public func open(_ request: SourceRequest) -> any ContentSource {
        lock.lock()
        openedCount += 1
        lock.unlock()
        if request.entry.kind == .image {
            let fit = PixelSize(width: request.entry.width ?? 4096, height: request.entry.height ?? 2160)
            let still = StillSource(url: request.url, fitWithin: fit, backend: backend)
            let log = self.log
            stillQueue.async {
                do { try still.load() } catch { log.error("still \(request.url.lastPathComponent): \(error)") }
            }
            return still
        }
        let source = VideoFileSource(url: request.url, inMs: request.inMs, outMs: request.outMs, loop: request.loop,
                                     device: backend.device, log: log)
        source.start()
        return source
    }

    public func prefetch(_ request: SourceRequest) {
        lock.lock()
        let exists = prefetched[request.prefetchKey] != nil
        lock.unlock()
        guard !exists else { return }
        let source = open(request)
        lock.lock()
        prefetched[request.prefetchKey] = source
        lock.unlock()
    }

    public func adoptPrefetched(_ request: SourceRequest) -> (any ContentSource)? {
        lock.lock()
        defer { lock.unlock() }
        return prefetched.removeValue(forKey: request.prefetchKey)
    }

    /// Prefetched sources nobody adopted: released, so decoders do not pile up.
    public func dropPrefetched(except keep: Set<String>) {
        lock.lock()
        let stale = prefetched.filter { !keep.contains($0.key) }
        for key in stale.keys { prefetched.removeValue(forKey: key) }
        lock.unlock()
        for source in stale.values { source.release() }
    }
}
