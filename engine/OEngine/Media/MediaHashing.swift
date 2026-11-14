// OEngine — Spec 1 §4 and Spec 8 §2, a file's identity, hashed with CryptoKit.

import CryptoKit
import Foundation
import OCore

/// Spec 1 §4 — "A media file's identity is the SHA-256 of its bytes, written
/// as `sha256:` followed by 64 lowercase hex characters"; Spec 8 §2 — "A
/// slide's id is its embedded uuid". The engine hashes with CryptoKit
/// (Adam's answer of 2026-11-11: Spec 1 §7 expects a large library to hash
/// in well under a minute); OCore's own SHA-256 gives the same ids, which the
/// tests check. Files are read in chunks, never whole.
public enum MediaHashing {
    /// The size of each read.
    public static let chunk = 1 << 20

    /// A running hash of bytes as they pass.
    public struct Running {
        var hasher = CryptoKit.SHA256()

        public init() {}

        public mutating func update(_ data: Data) {
            hasher.update(data: data)
        }

        /// The id of the bytes seen so far.
        public func finish() -> String {
            MediaID.hashPrefix + hasher.finalize().map { byte in
                let hex = String(byte, radix: 16)
                return byte < 16 ? "0" + hex : hex
            }.joined()
        }
    }

    /// Spec 8 §2 — the identity of the file at `url`: a slide's or template's
    /// `slide:` id, or the `sha256:` id of its bytes; nil when it can't be
    /// read, or a slide doesn't parse yet. `progress` hears the share read so far.
    public static func identity(of url: URL, progress: ((Double) -> Void)? = nil) -> String? {
        if MediaID.isSlideFile(url.lastPathComponent) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return MediaID.slideIdentity(of: data)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let total = (try? handle.seekToEnd()).map(Double.init) ?? 0
        try? handle.seek(toOffset: 0)
        var running = Running()
        var read = 0.0
        while true {
            let piece: Data
            do {
                guard let next = try handle.read(upToCount: chunk), !next.isEmpty else { break }
                piece = next
            } catch {
                return nil
            }
            running.update(piece)
            read += Double(piece.count)
            if total > 0 { progress?(min(1, read / total)) }
        }
        return running.finish()
    }
}
