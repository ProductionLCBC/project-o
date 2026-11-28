import XCTest

/// Spec 10 §16 — "Area 13's tests drive the app's models against a scripted
/// engine on a local socket, so no test needs the engine or a GPU." That
/// holds only while the app's behavior stays out of its views, so the rule
/// is made mechanical, as OCore's is (`ImportRuleTests`): OApp imports no
/// AppKit, no SwiftUI and nothing of the engine's, and the scripted engine
/// imports nothing of the app's, so the two can't agree by sharing code.
final class AppImportRuleTests: XCTestCase {
    func test_OAppImportsNoViewFrameworkAndNothingOfTheEngines() throws {
        let allowed: Set<String> = ["Foundation", "Darwin", "Synchronization", "IOSurface", "OCore", "OMach"]
        let violations = try Self.imports(under: "app/Sources/OApp").filter { !allowed.contains($0.module) }
        XCTAssertTrue(violations.isEmpty, "OApp may import only \(allowed.sorted()):\n" + violations.map(\.where).joined(separator: "\n"))
    }

    func test_theScriptedEngineSharesNoCodeWithTheApp() throws {
        let allowed: Set<String> = ["Foundation", "Darwin", "OCore"]
        let violations = try Self.imports(under: "app/Sources/OAppScripted").filter { !allowed.contains($0.module) }
        XCTAssertTrue(violations.isEmpty, "OAppScripted may import only \(allowed.sorted()):\n" + violations.map(\.where).joined(separator: "\n"))
    }

    func test_theViewsNeverImportTheEngine() throws {
        let refused: Set<String> = ["OEngine", "ODeckLink", "Metal", "MetalKit"]
        let violations = try Self.imports(under: "app/Sources/OAppUI").filter { refused.contains($0.module) }
        XCTAssertTrue(violations.isEmpty, "ARCHITECTURE.md: \"The app never renders show content\":\n" + violations.map(\.where).joined(separator: "\n"))
    }

    // MARK: - Helpers

    private struct Import {
        var module: String
        var `where`: String
    }

    /// Every `import` line of every Swift file under a folder of the repository.
    private static func imports(under folder: String) throws -> [Import] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OAppTests
            .deletingLastPathComponent()   // tests
            .deletingLastPathComponent()   // root
        let directory = root.appendingPathComponent(folder)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" { files.append(url) }
        XCTAssertFalse(files.isEmpty, "no Swift files found under \(directory.path)")

        var found: [Import] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let words = trimmed.split(separator: " ").map(String.init)
                // `import X`, `@preconcurrency import X`, `@testable import X`, `import struct X.Y`
                guard let index = words.firstIndex(of: "import"), words[..<index].allSatisfy({ $0.hasPrefix("@") }) else { continue }
                var rest = words[(index + 1)...]
                let kinds: Set<String> = ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias"]
                if let first = rest.first, kinds.contains(first) { rest = rest.dropFirst() }
                guard let spec = rest.first else { continue }
                let module = String(spec.split(separator: ".").first ?? Substring(spec))
                found.append(Import(module: module, where: "\(file.lastPathComponent):\(number + 1): \(trimmed)"))
            }
        }
        return found
    }
}
