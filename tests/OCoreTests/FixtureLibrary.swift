import Foundation
import XCTest
@testable import OCore

/// Spec 1 §10 — "A complete first-run library plus the worked examples above, in
/// `tests/fixtures/library-v1/`". This helper reads the two roots as the loader
/// sees them (`RootSnapshot`: relative path to bytes) and names the fixture's
/// fixed identities so tests can refer to them.
enum FixtureLibrary {
    /// tests/OCoreTests/FixtureLibrary.swift -> repository root.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OCoreTests
            .deletingLastPathComponent()   // tests
            .deletingLastPathComponent()   // root
    }

    static var root: URL { repoRoot.appendingPathComponent("tests/fixtures/library-v1") }
    static var libraryRoot: URL { root.appendingPathComponent("library") }
    static var machineRoot: URL { root.appendingPathComponent("machine") }
    static var mediaRoot: URL { libraryRoot.appendingPathComponent("media") }
    static var schemaZeroList: URL { repoRoot.appendingPathComponent("tests/fixtures/migrations/list-schema-0.json") }
    static var schemasRoot: URL { repoRoot.appendingPathComponent("formats/schemas") }

    /// Every `.json` document under a root, as (relative path, bytes), sorted by
    /// path. The media folder is not part of a root snapshot: it holds media,
    /// not documents.
    static func documents(under root: URL) -> [(path: String, data: Data)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, Data)] = []
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            if relative.hasPrefix("media/") { continue }
            guard let data = fm.contents(atPath: path) else { continue }
            out.append((relative, data))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    static func snapshot(of root: URL) -> RootSnapshot {
        RootSnapshot(files: Dictionary(uniqueKeysWithValues: documents(under: root).map { ($0.path, $0.data) }))
    }

    static var librarySnapshot: RootSnapshot { snapshot(of: libraryRoot) }
    static var machineSnapshot: RootSnapshot { snapshot(of: machineRoot) }

    /// Both roots as the fixture's loaded form, with the report of the load.
    static func load() -> (library: Library, machine: Machine, report: ValidationReport) {
        let lib = Loader.library(from: librarySnapshot)
        let mac = Loader.machine(from: machineSnapshot)
        var report = lib.report
        report.issues.append(contentsOf: mac.report.issues)
        return (lib.library, mac.machine, report)
    }

    /// The relative paths of every file under the media root, forward slashes.
    static var existingMediaPaths: Set<String> {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: mediaRoot, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let prefix = mediaRoot.standardizedFileURL.path + "/"
        var out: Set<String> = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(prefix) { out.insert(String(path.dropFirst(prefix.count))) }
        }
        return out
    }

    // MARK: - Fixed identities (tests/fixtures/README.md)

    static func uuid(_ prefix: String, _ n: Int) -> UUID {
        let head = prefix.padding(toLength: 8, withPad: "0", startingAt: 0)
        let hex = String(n, radix: 16)
        let tail = String(repeating: "0", count: 12 - hex.count) + hex
        guard let u = UUID(uuidString: "\(head)-0000-4000-8000-\(tail)") else { preconditionFailure("fixture uuid \(prefix) \(n)") }
        return u
    }

    static let libraryUuid = uuid("11b0a", 1)
    static let machineUuid = uuid("7a7a", 1)
    static func channelUuid(_ n: Int) -> UUID { uuid(n == 1 ? "8d1e" : "2b77", n) }
    static func presetUuid(_ n: Int) -> UUID { uuid("c0de", n) }
    static func listUuid(_ n: Int) -> UUID { uuid("a9f0", n) }
    static let list42Cues = [uuid("11aa", 1), uuid("22bb", 2), uuid("33cc", 3), uuid("44dd", 4)]
    static let list7Cues = [uuid("55ee", 1), uuid("66ff", 2), uuid("77aa", 3)]
    static let localCopyUuid = uuid("10ca1", 42)
    static let playlistUuid = uuid("b1a7", 1)
    static let slideUuid = uuid("51de", 1)

    static let dawn = "sha256:55c84469c37e1e6a72a9b8938422cd6536b302b583a5c127241c8304246f3527"
    static let cross = "sha256:eb6384847a49f7a4ef82aedb9e2019080777b8be748690c33d91bba67c32a3d2"
    static let announcement = "sha256:fa3021eba9c15cb8aa65b79e04c0df3d5291d79d397e5930610248bab8d3e2e0"
    static let mountains = "sha256:" + String(repeating: "9f2c6a1b", count: 8)
    static let welcomeSlide = "slide:51de0000-0000-4000-8000-000000000001"
}

// MARK: - Byte diff for failure messages

enum ByteDiff {
    /// A readable description of the first line where two texts differ.
    static func describe(expected: Data, actual: Data) -> String {
        let a = String(decoding: expected, as: UTF8.self).components(separatedBy: "\n")
        let b = String(decoding: actual, as: UTF8.self).components(separatedBy: "\n")
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "<end>"
            let y = i < b.count ? b[i] : "<end>"
            if x != y {
                return "line \(i + 1):\n  expected: \(x)\n  actual:   \(y)"
            }
        }
        return "identical"
    }
}
