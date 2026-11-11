// OEngine — the harness's media probe: Spec 8 §11, the walk and import tested without AVFoundation.

import Foundation
import OCore

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
