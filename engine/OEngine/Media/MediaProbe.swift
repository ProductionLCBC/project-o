// OEngine — Spec 8 §3, the kinds v1 takes, found by opening the file.

import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import OCore

/// Spec 8 §3 — "The kinds v1 takes (M6), found by opening the file, not from
/// its extension". A seam, so the walk and import tests run without
/// AVFoundation (Spec 8 §11).
public protocol MediaProbe: Sendable {
    /// What opening the file found: a kind v1 takes with its metadata, or a
    /// format v1 doesn't take, named; nil when the file doesn't open yet as a
    /// kind v1 takes, "such as a video still being exported" (Spec 8 §4).
    func read(_ url: URL) -> MediaRead?
}

/// Spec 8 §3 — the probe the engine uses: the file's first bytes say what it
/// is; ImageIO reads stills, AVFoundation reads video and audio (behind a
/// bounded wait, Spec 4 §12), and slides and templates are read for their
/// envelope (Spec 1 §7).
///
/// | Kind | Takes |
/// | --- | --- |
/// | Video | ProRes (the 422 family and 4444), HEVC (8- and 10-bit, with or without alpha) and H.264, in `.mov`, `.mp4` or `.m4v` |
/// | Image | PNG, JPEG, HEIC, TIFF; GIF as a still, its first frame |
/// | Audio | WAV, AIFF, M4A (AAC or ALAC), MP3 |
/// | Slide, template | `.oslide`, `.otemplate` |
///
/// "Anything else is refused with `unsupported`, so a `.mov` holding a codec
/// v1 can't play never reaches a cue."
public struct AVMediaProbe: MediaProbe {
    /// Spec 4 §12 — "a media open that never answers is a failure, not a wait".
    public var timeout: Double

    public init(timeout: Double = 10) {
        self.timeout = timeout
    }

    /// The video codecs v1 plays (Spec 4 §6): the ProRes 422 family (Proxy,
    /// LT, 422, HQ), ProRes 4444 and 4444 XQ, HEVC and H.264.
    public static let videoCodecs: Set<String> = ["apco", "apcs", "apcn", "apch", "ap4h", "ap4x", "hvc1", "hev1", "avc1", "avc3"]
    /// The audio v1 plays: AAC and ALAC (in M4A), linear PCM (WAV, AIFF) and MP3.
    public static let audioCodecs: Set<String> = ["aac ", "alac", "lpcm", ".mp3", "sowt", "twos", "in24", "in32", "fl32", "fl64"]

    public func read(_ url: URL) -> MediaRead? {
        if MediaID.isSlideFile(url.lastPathComponent) { return slide(url) }
        guard let head = Self.head(of: url, count: 64) else { return nil }
        switch Self.signature(head) {
        case .image: return image(url)
        case .container: return media(url)
        case .unknown(let name): return .unsupported(name ?? Self.unknownName(url))
        }
    }

    // MARK: - What the first bytes say

    enum Signature: Equatable {
        case image
        case container
        case unknown(String?)
    }

    static func head(of url: URL, count: Int) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: count) else { return nil }
        return [UInt8](data)
    }

    static func signature(_ b: [UInt8]) -> Signature {
        func at(_ offset: Int, _ text: String) -> Bool {
            let bytes = Array(text.utf8)
            return b.count >= offset + bytes.count && Array(b[offset..<offset + bytes.count]) == bytes
        }
        func starts(_ bytes: [UInt8]) -> Bool { b.count >= bytes.count && Array(b[0..<bytes.count]) == bytes }
        if starts([0x89, 0x50, 0x4E, 0x47]) || starts([0xFF, 0xD8, 0xFF]) || at(0, "GIF8") { return .image }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .image }
        if at(4, "ftyp") {
            let brand = b.count >= 12 ? String(decoding: b[8..<12], as: UTF8.self) : ""
            if ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"].contains(brand) { return .image }
            return .container
        }
        // QuickTime movies may start with any of these atoms; RIFF/WAVE, AIFF and MP3 are audio AVFoundation reads.
        for atom in ["moov", "mdat", "wide", "free", "skip", "pnot"] where at(4, atom) { return .container }
        if at(0, "RIFF") && at(8, "WAVE") { return .container }
        if at(0, "FORM") && (at(8, "AIFF") || at(8, "AIFC")) { return .container }
        if at(0, "ID3") || (b.count >= 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) { return .container }
        if at(0, "%PDF") { return .unknown("a PDF document") }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return .unknown("a zip archive") }
        if at(0, "RIFF") { return .unknown("a RIFF file that isn't WAVE audio") }
        return .unknown(nil)
    }

    static func unknownName(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "a file of a kind v1 doesn't take" : "a .\(ext) file of a kind v1 doesn't take"
    }

    // MARK: - Stills (ImageIO)

    func image(_ url: URL) -> MediaRead? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        guard CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        let type = (CGImageSourceGetType(source) as String?) ?? ""
        let codec: String
        switch type {
        case "public.png": codec = "png"
        case "public.jpeg": codec = "jpeg"
        case "com.compuserve.gif": codec = "gif"
        case "public.tiff": codec = "tiff"
        case "public.heic", "public.heif": codec = "heic"
        default: return .unsupported(type.isEmpty ? "an image of a kind v1 doesn't take" : "a \(type) image")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        let alpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        return .media(MediaMetadata(kind: .image, width: width, height: height, hasAlpha: alpha, codec: codec))
    }

    // MARK: - Video and audio (AVFoundation)

    /// Holds what the loading task found for the thread waiting on it.
    final class Found: @unchecked Sendable {
        var read: MediaRead?
    }

    /// AVFoundation's loads are asynchronous; the worker waits on them with a
    /// bound (Spec 4 §12), and a file that doesn't answer in time doesn't open yet.
    func media(_ url: URL) -> MediaRead? {
        let found = Found()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            found.read = await Self.load(url)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return found.read
    }

    static func load(_ url: URL) async -> MediaRead? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks), let duration = try? await asset.load(.duration) else { return nil }
        let video = tracks.filter { $0.mediaType == .video }
        let audio = tracks.filter { $0.mediaType == .audio }
        let durationMs = duration.isNumeric ? Int((duration.seconds * 1000).rounded()) : nil
        if let track = video.first {
            guard let (size, fps, descriptions) = try? await track.load(.naturalSize, .nominalFrameRate, .formatDescriptions),
                  let description = descriptions.first else { return nil }
            let fourCC = fourCC(CMFormatDescriptionGetMediaSubType(description))
            guard videoCodecs.contains(fourCC) else { return .unsupported("\(fourCC.trimmingCharacters(in: .whitespaces)) video") }
            return .media(MediaMetadata(kind: .video, durationMs: durationMs, fps: rate(fps),
                                        width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                                        hasAudio: !audio.isEmpty, hasAlpha: hasAlpha(description, codec: fourCC), codec: fourCC))
        }
        if let track = audio.first {
            guard let descriptions = try? await track.load(.formatDescriptions), let description = descriptions.first else { return nil }
            let fourCC = fourCC(CMFormatDescriptionGetMediaSubType(description))
            guard audioCodecs.contains(fourCC) else { return .unsupported("\(fourCC.trimmingCharacters(in: .whitespaces)) audio") }
            return .media(MediaMetadata(kind: .audio, durationMs: durationMs, hasAudio: true, codec: fourCC))
        }
        return .unsupported("a movie with no video or audio")
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Spec 1 §7 — `hasAlpha`: a ProRes 4444 at 32 bits deep, or a format
    /// that says it carries an alpha channel (HEVC with alpha).
    static func hasAlpha(_ description: CMFormatDescription, codec: String) -> Bool {
        let extensions = CMFormatDescriptionGetExtensions(description) as? [CFString: Any] ?? [:]
        if let contains = extensions[kCMFormatDescriptionExtension_ContainsAlphaChannel] as? Bool { return contains }
        if codec == "ap4h" || codec == "ap4x" { return (extensions[kCMFormatDescriptionExtension_Depth] as? Int) == 32 }
        return false
    }

    /// Spec 1 §5 — "frame rates are `{num, den}` (so 59.94 is `{60000, 1001}`)".
    static func rate(_ fps: Float) -> FrameRate? {
        guard fps > 0 else { return nil }
        let value = Double(fps)
        for base in [24.0, 30.0, 60.0, 120.0] where abs(value - base * 1000 / 1001) < 0.005 {
            return FrameRate(num: Int(base * 1000), den: 1001)
        }
        let rounded = value.rounded()
        if abs(value - rounded) < 0.01 { return FrameRate(num: Int(rounded), den: 1) }
        return FrameRate(num: Int((value * 1000).rounded()), den: 1000)
    }

    // MARK: - Slides and templates (Spec 1 §7)

    /// "Designed slides and templates are JSON files in the media root with
    /// the extensions `.oslide` and `.otemplate`. Their first-level keys are
    /// `uuid`, `schema`, `size` `{width, height}`, ...": one that doesn't
    /// parse yet isn't read.
    func slide(_ url: URL) -> MediaRead? {
        guard let data = try? Data(contentsOf: url), let tree = try? JSONValue.parse(data), MediaID.slideIdentity(of: data) != nil else { return nil }
        let kind: MediaKind = url.pathExtension.lowercased() == "otemplate" ? .template : .slide
        return .media(MediaMetadata(kind: kind, width: tree["size"]?["width"]?.intValue, height: tree["size"]?["height"]?.intValue,
                                    hasAlpha: true))
    }
}
