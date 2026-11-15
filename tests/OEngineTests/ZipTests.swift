import Foundation
import XCTest
@testable import OEngine

/// Spec 9 §3 — "It uses deflate, so the Finder and `unzip` open it." The zip
/// container is written in Swift over Apple's Compression framework (Adam's
/// answer of 2026-11-14); these prove what it writes is a zip other tools
/// read, and that what it reads back is what went in.
final class ZipTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_793_455_199) // 2026-10-30, a fixed moment
    private let zone = TimeZone(identifier: "America/New_York") ?? .current

    private func entries() -> [Zip.Entry] {
        let hymn = String(repeating: "Great is thy faithfulness, O God my Father; there is no shadow of turning with thee. ", count: 40)
        return [
            Zip.Entry(path: "snapshot.json", data: Data(#"{"kind":"snapshot","schema":1}"#.utf8)),
            Zip.Entry(path: "library/lists/Hymns/042-great-is-thy-faithfulness.json", data: Data(hymn.utf8)),
            Zip.Entry(path: "library/lists/Worship/New/007-être.json", data: Data("é".utf8)),
            Zip.Entry(path: "machine/keys.json", data: Data()),
        ]
    }

    func test_whatGoesInComesBackOut() throws {
        let archive = try Zip.archive(entries(), modified: stamp, timeZone: zone)
        XCTAssertEqual(try Zip.entries(of: archive), entries())
    }

    func test_textIsDeflatedAndAnEmptyFileIsStored() throws {
        let archive = try Zip.archive(entries(), modified: stamp, timeZone: zone)
        let plain = entries().reduce(0) { $0 + $1.data.count }
        XCTAssertLessThan(archive.count, plain, "a repeated hymn line deflates to less than its own size, headers included")
    }

    /// "the Finder and `unzip` open it": Info-ZIP's own test of every entry, its listing, and one file's bytes.
    func test_unzipOpensIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("2026-10-30-100000.zip")
        try Zip.archive(entries(), modified: stamp, timeZone: zone).write(to: file)

        let test = try run("/usr/bin/unzip", ["-t", file.path])
        XCTAssertEqual(test.status, 0, test.output)
        XCTAssertTrue(test.output.contains("No errors detected"), test.output)

        let listing = try run("/usr/bin/unzip", ["-Z1", file.path])
        // The listing prints a name's accents its own way; the extraction below proves the accented name.
        let listed = listing.output.split(separator: "\n").map(String.init)
        XCTAssertEqual(listed.count, entries().count)
        XCTAssertEqual(listed.filter { !$0.contains("007") }, entries().map(\.path).filter { !$0.contains("007") })

        let one = try run("/usr/bin/unzip", ["-p", file.path, "library/lists/Hymns/042-great-is-thy-faithfulness.json"])
        XCTAssertEqual(Data(one.output.utf8), entries()[1].data)

        let out = folder.appendingPathComponent("out")
        let extract = try run("/usr/bin/unzip", ["-q", file.path, "-d", out.path])
        XCTAssertEqual(extract.status, 0, extract.output)
        XCTAssertEqual(FileManager.default.contents(atPath: out.appendingPathComponent("machine/keys.json").path), Data())
        XCTAssertEqual(FileManager.default.contents(atPath: out.appendingPathComponent("library/lists/Worship/New/007-être.json").path),
                       Data("é".utf8))
    }

    /// CLAUDE.md — nothing that came from a file may crash the engine: a file that isn't a zip, one cut short,
    /// and one whose bytes changed are each refused.
    func test_aFileThatIsNotAWholeZipIsRefused() throws {
        let archive = try Zip.archive(entries(), modified: stamp, timeZone: zone)
        XCTAssertThrowsError(try Zip.entries(of: Data("not a zip at all".utf8)))
        XCTAssertThrowsError(try Zip.entries(of: Data()))
        XCTAssertThrowsError(try Zip.entries(of: archive.prefix(archive.count / 2)))
        for cut in [1, 10, 22, 60] {
            XCTAssertThrowsError(try Zip.entries(of: archive.prefix(archive.count - cut)), "cut \(cut) bytes short")
        }
        // A byte of the hymn's deflated data changed: the checksum no longer matches.
        var damaged = archive
        let offset = 30 + "snapshot.json".utf8.count + 30 + 30 + entries()[1].path.utf8.count + 12
        damaged[damaged.startIndex + offset] ^= 0x5A
        XCTAssertThrowsError(try Zip.entries(of: damaged))
    }

    func test_theChecksumIsCRC32() {
        XCTAssertEqual(Zip.crc32(Data("123456789".utf8)), 0xCBF4_3926, "the check value every CRC-32 table gives")
        XCTAssertEqual(Zip.crc32(Data()), 0)
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
