// OEngine — Spec 10 §2, the engine's console output.

import Darwin
import Foundation

/// Spec 10 §2, "Starting" — "The app opens `machine/logs/engine-console.log`
/// for appending as the engine's standard output and error, so a failure
/// before the engine's own logger starts can still be read, and the engine
/// trims the file in place to its last 10 MB at launch."
public enum ConsoleLog {
    /// "its last 10 MB".
    public static let limit = 10 * 1024 * 1024

    /// Spec 1 §5 — `logs/`: "the engine's console output (Spec 10 §2)".
    public static func url(machineRoot: URL) -> URL {
        machineRoot.appendingPathComponent("logs/engine-console.log")
    }

    /// Trims the file to its last `limit` bytes, starting at the first whole
    /// line among them. "In place": the bytes are moved within the same file,
    /// never into a new one, so the handle the app opened for appending is
    /// still the log and what the engine prints next follows the kept lines.
    /// True when it trimmed; a file within the limit, or no file, is left alone.
    @discardableResult
    public static func trim(_ url: URL, to limit: Int = limit) -> Bool {
        let descriptor = open(url.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return false }
        let size = Int(status.st_size)
        guard limit > 0, size > limit else { return false }

        // The last `limit` bytes, and the one before them, which says whether they start a line.
        let count = limit + 1
        var tail = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let got = tail.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress?.advanced(by: filled), count - filled, off_t(size - count + filled)) }
            guard got > 0 else { break }
            filled += got
        }
        guard filled == count else { return false }
        // From the start of a line, unless the kept bytes are all one line's.
        var start = 1
        if tail[0] != 0x0A, let newline = tail[1...].firstIndex(of: 0x0A), newline + 1 < count { start = newline + 1 }

        guard ftruncate(descriptor, 0) == 0 else { return false }
        var written = start
        while written < count {
            let put = tail.withUnsafeBytes { pwrite(descriptor, $0.baseAddress?.advanced(by: written), count - written, off_t(written - start)) }
            guard put > 0 else { break }
            written += put
        }
        _ = fsync(descriptor)
        return true
    }
}
