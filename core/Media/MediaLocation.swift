// OCore — Spec 8 §2, where a file is: a folder plus a path.

import Foundation

/// Spec 8 §2 — "The resolver returns a location, a folder plus a path, not
/// just a path under the media root: a library entry's `path` is relative to
/// the media root; a machine-index entry's `path` is relative to
/// `machine/media/`; an override (Spec 1 §7) is a path relative to
/// `machine/media/`, or an absolute one".
public enum MediaFolder: String, Codable, CaseIterable, Comparable, Sendable {
    /// The media root: `library/media/` unless machine settings point it
    /// elsewhere (Spec 1 §5).
    case mediaRoot
    /// `machine/media/`, "the machine's own media folder, never synced"
    /// (Spec 8 §2, choice M-1).
    case machineMedia
    /// An absolute override (Spec 1 §7).
    case absolute

    public static func < (a: MediaFolder, b: MediaFolder) -> Bool {
        let order: [MediaFolder] = [.mediaRoot, .machineMedia, .absolute]
        return (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0)
    }
}

/// Spec 8 §2 — a location: a folder plus a path, with forward slashes.
///
/// A location is never made from a path that would leave its folder: an
/// empty path, a relative path that starts with a slash, or a path with an
/// empty, `.` or `..` part. An absolute override must start with a slash and
/// obeys the same rule about its parts. A hand-edited index therefore can't
/// make the engine read outside the places Spec 8 §2 lets media live
/// (choice M-8): such an entry has no location and counts missing, and the
/// reference report names it (Spec 1 §8).
public struct MediaLocation: Hashable, Comparable, Codable, Sendable {
    public let folder: MediaFolder
    public let path: String

    /// Spec 8 §2 — a location in `folder`, or nil when `path` would leave it.
    public init?(_ folder: MediaFolder, _ path: String) {
        guard MediaLocation.isValid(path, absolute: folder == .absolute) else { return nil }
        self.folder = folder
        self.path = path
    }

    /// Spec 8 §2 — "an override (Spec 1 §7) is a path relative to
    /// `machine/media/`, or an absolute one".
    public static func override(_ value: String) -> MediaLocation? {
        value.hasPrefix("/") ? MediaLocation(.absolute, value) : MediaLocation(.machineMedia, value)
    }

    /// Whether `path` can name a file in its folder: relative paths never
    /// start with a slash, absolute ones always do, and no part is empty,
    /// `.` or `..`.
    public static func isValid(_ path: String, absolute: Bool) -> Bool {
        guard !path.isEmpty, path.hasPrefix("/") == absolute, !path.contains("\0") else { return false }
        let parts = (absolute ? String(path.dropFirst()) : path).split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The folder part of the path, as an entry's `folder` field holds it
    /// (Spec 1 §7, "For sort and the folder rail").
    public var parent: String { MediaEntry.folder(of: path) }

    /// The last part of the path, the file's name.
    public var name: String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    public static func < (a: MediaLocation, b: MediaLocation) -> Bool {
        a.folder != b.folder ? a.folder < b.folder : a.path < b.path
    }

    private enum CodingKeys: String, CodingKey { case folder, path }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let folder = try c.decode(MediaFolder.self, forKey: .folder)
        let path = try c.decode(String.self, forKey: .path)
        guard MediaLocation.isValid(path, absolute: folder == .absolute) else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: c, debugDescription: "a path that leaves its folder: \(path)")
        }
        self.folder = folder
        self.path = path
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(folder, forKey: .folder)
        try c.encode(path, forKey: .path)
    }
}
