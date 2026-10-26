import XCTest

/// The portability rule from Spec 3 §10 made mechanical: OCore imports nothing
/// from Apple frameworks. Foundation is the only permitted import, and only for
/// UUID, Codable and date parsing at the file boundary.
///
/// This test scans every Swift file under core/ for `import` statements and
/// fails if any module other than Foundation is imported. It runs on Linux too,
/// which is the stronger proof: if OCore builds and tests there, nothing
/// Apple-only has crept in.
final class ImportRuleTests: XCTestCase {
    /// Modules OCore may import.
    private let allowed: Set<String> = ["Foundation"]

    func test_OCoreImportsOnlyFoundation() throws {
        let coreDir = Self.repoRoot.appendingPathComponent("core")
        let files = try Self.swiftFiles(under: coreDir)
        XCTAssertFalse(files.isEmpty, "no Swift files found under \(coreDir.path)")

        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") || trimmed.hasPrefix("@testable import ") else { continue }
                // `import Foundation`, `import struct Foundation.UUID`, `@_exported import X`
                let words = trimmed.split(separator: " ").map(String.init)
                guard let importIndex = words.firstIndex(of: "import") else { continue }
                var rest = words[(importIndex + 1)...]
                // skip an optional kind keyword: struct, class, enum, func, var, typealias
                let kinds: Set<String> = ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias"]
                if let first = rest.first, kinds.contains(first) { rest = rest.dropFirst() }
                guard let spec = rest.first else { continue }
                let module = String(spec.split(separator: ".").first ?? Substring(spec))
                if !allowed.contains(module) {
                    violations.append("\(file.lastPathComponent):\(number + 1): \(trimmed)")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, "OCore may import only \(allowed.sorted()):\n" + violations.joined(separator: "\n"))
    }

    // MARK: - Helpers

    /// tests/OCoreTests/ImportRuleTests.swift -> repository root.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OCoreTests
            .deletingLastPathComponent()   // tests
            .deletingLastPathComponent()   // root
    }

    private static func swiftFiles(under dir: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }
}
