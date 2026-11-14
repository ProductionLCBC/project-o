// OEngine — the harness's media probe: Spec 8 §11, the walk and import tested without AVFoundation.

import CoreGraphics
import Foundation
import OCore

/// Spec 8 §11 — the frame a poster is made from, without AVFoundation: a
/// frame of `size`, grey and opaque, or half transparent when alpha is
/// asked for, unless the file's bytes start `NO FRAME`, which can't be
/// decoded. It records each frame asked for, with its in-point.
public final class FakeMediaFrames: MediaFrames, @unchecked Sendable {
    public struct Ask: Equatable, Sendable {
        public var file: String
        public var inMs: Int
        public var alpha: Bool
    }

    private let lock = NSLock()
    private var asks: [Ask] = []
    private var frameSize: (width: Int, height: Int)

    public init(width: Int = 64, height: Int = 36) {
        frameSize = (width, height)
    }

    /// The frames asked for, in order, by file name.
    public var asked: [Ask] {
        lock.lock()
        defer { lock.unlock() }
        return asks
    }

    public var size: (width: Int, height: Int) {
        get { lock.lock(); defer { lock.unlock() }; return frameSize }
        set { lock.lock(); frameSize = newValue; lock.unlock() }
    }

    public func frame(of url: URL, atMs inMs: Int, alpha: Bool) -> MediaImage? {
        lock.lock()
        asks.append(Ask(file: url.lastPathComponent, inMs: inMs, alpha: alpha))
        let (width, height) = frameSize
        lock.unlock()
        let head = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 8)
        } ?? Data()
        if String(decoding: head, as: UTF8.self).hasPrefix("NO FRAME") { return nil }
        let info = CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.premultipliedFirst : .noneSkipFirst).rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.5, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map(MediaImage.init)
    }
}

/// Spec 8 §11 — "Free space, the watcher's events, the Trash and the clock
/// are seams, so the tests run without real volumes or waits"; the probe
/// is one too. It takes a file's kind from its extension, except that a file
/// whose bytes start with `NOT YET` doesn't open yet (a video still being
/// exported, Spec 8 §4) and one starting `UNSUPPORTED` is a codec v1 can't
/// play. Slides and templates are read for their uuid, as the engine's probe
/// reads them.
public struct FakeMediaProbe: MediaProbe {
    public init() {}

    public static let video = MediaMetadata(kind: .video, durationMs: 10_000, fps: FrameRate(num: 30), width: 64, height: 36, codec: "avc1")
    public static let image = MediaMetadata(kind: .image, width: 64, height: 36, codec: "png")
    public static let audio = MediaMetadata(kind: .audio, durationMs: 5_000, hasAudio: true, codec: "aac ")

    public func read(_ url: URL) -> MediaRead? {
        if MediaID.isSlideFile(url.lastPathComponent) { return AVMediaProbe().read(url) }
        let head = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 16)
        } ?? Data()
        let text = String(decoding: head, as: UTF8.self)
        if text.hasPrefix("NOT YET") { return nil }
        if text.hasPrefix("UNSUPPORTED") { return .unsupported("jpeg video") }
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v": return .media(Self.video)
        case "png", "jpg", "jpeg", "heic", "tif", "tiff", "gif": return .media(Self.image)
        case "wav", "aif", "aiff", "m4a", "mp3": return .media(Self.audio)
        case "txt": return .unsupported("plain text")
        default: return .unsupported("a .\(url.pathExtension) file of a kind v1 doesn't take")
        }
    }
}
