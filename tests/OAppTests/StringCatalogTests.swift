import Foundation
import XCTest
@testable import OApp

/// The string catalog as the tests read it: the file the app's bundle is built from.
enum CatalogFile {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // OAppTests
        .deletingLastPathComponent()   // tests
        .deletingLastPathComponent()   // root
        .appendingPathComponent("app/Shell/Localizable.xcstrings")

    /// Points `Strings` at the catalog file, with no pseudolanguage.
    @MainActor
    static func install() throws {
        let file = try StringCatalogFile(contentsOf: url)
        Strings.lookup = { key, count in file.format(key, count: count) }
        Strings.transform = nil
    }
}

/// Spec 10 §15, "Localization" — "Every string shown is in the app's string
/// catalog, English only in v1, and built from whole sentences with
/// placeholders ... Counts use the catalog's plural variants". The catalog
/// file against the keys the code uses.
@MainActor
final class StringCatalogTests: XCTestCase {
    func test_everyKeyTheCodeUsesIsInTheCatalogAndTheCatalogHoldsNoOther() throws {
        let file = try StringCatalogFile(contentsOf: CatalogFile.url)
        let used = Set(StringKey.allCases.map(\.rawValue))
        let held = Set(file.entries.keys)
        XCTAssertEqual(used.subtracting(held).sorted(), [], "keys the code uses and the catalog lacks")
        XCTAssertEqual(held.subtracting(used).sorted(), [], "keys the catalog holds and no code uses")
        XCTAssertEqual(used.count, StringKey.allCases.count, "no key is used by two cases")
    }

    func test_everyStringHasItsEnglishAndANoteForATranslator() throws {
        let file = try StringCatalogFile(contentsOf: CatalogFile.url)
        for (key, entry) in file.entries.sorted(by: { $0.key < $1.key }) {
            XCTAssertFalse(entry.value.isEmpty, "\(key) has no English")
            XCTAssertFalse(entry.comment.isEmpty, "\(key) has no note for a translator")
            XCTAssertNotEqual(entry.value, key, "\(key)'s English is its key")
        }
    }

    func test_aStringWithACountHasPluralVariantsThatTakeTheSamePlaceholders() throws {
        let file = try StringCatalogFile(contentsOf: CatalogFile.url)
        func placeholders(_ text: String) -> [String] {
            var found: [String] = []
            var rest = Substring(text)
            while let percent = rest.firstIndex(of: "%") {
                let after = rest[rest.index(after: percent)...]
                if after.hasPrefix("lld") { found.append("%lld") } else if after.hasPrefix("@") { found.append("%@") }
                else if after.hasPrefix("1$@") { found.append("%1$@") } else if after.hasPrefix("2$@") { found.append("%2$@") }
                rest = after
            }
            return found
        }
        var plurals = 0
        for (key, entry) in file.entries {
            if let one = entry.one {
                plurals += 1
                XCTAssertEqual(placeholders(one), placeholders(entry.value), "\(key): one and other take the same placeholders")
                XCTAssertEqual(placeholders(one).first, "%lld", "\(key): a count comes first")
            } else {
                // A sentence that counts something must say one thing right: it needs the variants.
                XCTAssertFalse(placeholders(entry.value).contains("%lld") && entry.value.contains(" changes"), "\(key) counts changes without plural variants")
            }
        }
        XCTAssertGreaterThan(plurals, 0)
    }

    func test_theCatalogIsWhatItsScriptWrites() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = CatalogFile.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/strings-catalog.py")
        process.arguments = ["-I", script.path, "--check"]
        let output = Pipe()
        process.standardError = output
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func test_aStringIsLookedUpFilledInAndCounted() throws {
        try CatalogFile.install()
        XCTAssertEqual(Strings.text(.engineStarting), "Starting the engine…")
        XCTAssertEqual(Strings.text(.engineStopped), "The engine stopped. Restarting…")
        XCTAssertEqual(Strings.text(.quitTitle), "Quit Project O? The outputs will stop.")
        XCTAssertEqual(Strings.counted(.quitUnsaved, 3), "3 changes aren’t saved yet", "Spec 10 §2's own example")
        XCTAssertEqual(Strings.counted(.quitUnsaved, 1), "1 change isn’t saved yet")
        XCTAssertEqual(Strings.text(.engineBehindOutput, 2), "Project O is behind output 2. Press ⌃⌥⌘⎋ to take it off this screen.")
        XCTAssertEqual(Strings.text(.aboutVersions, "0.1.0", "0.0.9"), "Project O 0.1.0 · engine 0.0.9")
    }

    func test_thePseudolanguagesMarkEveryStringThatCameThroughTheTable() throws {
        try CatalogFile.install()
        Strings.transform = Pseudolanguage.accented
        XCTAssertEqual(Strings.text(.engineRestart), "Réstárt thé éñgíñé")
        Strings.transform = Pseudolanguage.longer
        let plain = "Restart the engine"
        XCTAssertEqual(Strings.text(.engineRestart).count, plain.count + 8, "forty per cent longer, rounded up")
        Strings.transform = nil
        XCTAssertEqual(Strings.text(.engineRestart), plain)
    }
}
