// OEngine — Spec 4 §10, the thumbnail cache: "Results are written as PNG into
// a disk cache keyed by (cue uuid, stack, library version) so thumbnails
// survive a relaunch; the UI reads them through the same IOSurface path or as
// files."

import Foundation
import CoreGraphics

/// Spec 4 §10 — "(cue uuid, stack, library version)".
public struct ThumbnailKey: Hashable, Sendable {
    public var cue: UUID
    public var stack: Int
    public var version: String

    public init(cue: UUID, stack: Int, version: String) {
        self.cue = cue
        self.stack = stack
        self.version = version
    }
}

public enum ThumbnailCacheError: Error {
    case pngEncodingFailed
}

/// Spec 4 §10 — the PNGs on disk, one folder per stack, one file per cue at
/// its library version (`<cue uuid>-<version>.png`), with a bounded memory
/// of recent PNG bytes in front so the app's repeat reads cost no file. Spec
/// 4 §12 — memory pressure shrinks the memory part; the disk is the store.
/// Area 5 reading, approved 2026-11-03: the folder is `thumbnails/` in the
/// machine root, beside `logs/` and `snapshots/`, and a stale version of a
/// cue's thumbnail goes when the new one is written.
public final class ThumbnailCache: @unchecked Sendable {
    public let folder: URL
    public let maximumBytes: Int
    private let lock = NSLock()
    private var memory: [ThumbnailKey: Data] = [:]
    private var recency: [ThumbnailKey] = []
    private var bytes = 0
    private var ceiling: Int

    public init(folder: URL, maximumBytes: Int = 32 * 1024 * 1024) {
        self.folder = folder
        self.maximumBytes = max(1, maximumBytes)
        ceiling = self.maximumBytes
    }

    // MARK: - Keys and files

    public func fileURL(for key: ThumbnailKey) -> URL {
        folder.appendingPathComponent(String(key.stack)).appendingPathComponent("\(key.cue.uuidString.lowercased())-\(key.version).png")
    }

    /// Where a cached thumbnail is, if anywhere.
    public enum Hit: Equatable, Sendable { case memory, disk }

    /// The thumbnail's file, when it exists; whether the memory has its bytes
    /// too. A file another process or service removed is forgotten.
    public func lookup(_ key: ThumbnailKey) -> (url: URL, hit: Hit)? {
        let url = fileURL(for: key)
        let onDisk = FileManager.default.fileExists(atPath: url.path)
        lock.lock()
        defer { lock.unlock() }
        if memory[key] != nil {
            if onDisk {
                touch(key)
                return (url, .memory)
            }
            if let data = memory.removeValue(forKey: key) { bytes -= data.count }
            recency.removeAll { $0 == key }
            return nil
        }
        return onDisk ? (url, .disk) : nil
    }

    /// The PNG bytes, from memory or from disk (which refills the memory).
    public func data(for key: ThumbnailKey) -> Data? {
        lock.lock()
        if let data = memory[key] {
            touch(key)
            lock.unlock()
            return data
        }
        lock.unlock()
        guard let data = FileManager.default.contents(atPath: fileURL(for: key).path) else { return nil }
        remember(data, for: key)
        return data
    }

    /// Spec 4 §10 — write the PNG for a key: the file (atomically), the stale
    /// versions of the same cue on the same stack removed, and the memory
    /// updated. Returns the file's URL.
    @discardableResult
    public func store(_ png: Data, for key: ThumbnailKey) throws -> URL {
        let url = fileURL(for: key)
        let stackFolder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: stackFolder, withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
        let prefix = key.cue.uuidString.lowercased() + "-"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: stackFolder.path) {
            for name in names where name.hasPrefix(prefix) && name.hasSuffix(".png") && name != url.lastPathComponent {
                try? FileManager.default.removeItem(at: stackFolder.appendingPathComponent(name))
            }
        }
        remember(png, for: key)
        return url
    }

    // MARK: - Memory (Spec 4 §12)

    private func remember(_ data: Data, for key: ThumbnailKey) {
        lock.lock()
        defer { lock.unlock() }
        if let old = memory.removeValue(forKey: key) { bytes -= old.count }
        memory[key] = data
        bytes += data.count
        touch(key)
        evictLocked()
    }

    private func touch(_ key: ThumbnailKey) {
        if let index = recency.firstIndex(of: key) { recency.remove(at: index) }
        recency.append(key)
    }

    private func evictLocked() {
        while bytes > ceiling, let oldest = recency.first {
            recency.removeFirst()
            if let data = memory.removeValue(forKey: oldest) { bytes -= data.count }
        }
    }

    public var memoryBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    /// Spec 4 §12 — hold the memory to a ceiling; nil is the cap again.
    public func setPressureCeiling(_ newCeiling: Int?) {
        lock.lock()
        defer { lock.unlock() }
        ceiling = min(maximumBytes, max(0, newCeiling ?? maximumBytes))
        evictLocked()
    }

    // MARK: - PNG

    /// A premultiplied BGRA8 sRGB bitmap, top row first, as a PNG.
    public static func png(bgra8 bytes: Data, width: Int, height: Int) throws -> Data {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        do {
            return try GoldenImage.encodePNG(bytes: [UInt8](bytes), width: width, height: height, bitsPerPixel: 32, bytesPerPixel: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
        } catch {
            throw ThumbnailCacheError.pngEncodingFailed
        }
    }
}
