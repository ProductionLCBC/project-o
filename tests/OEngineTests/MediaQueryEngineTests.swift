import Foundation
import OCore
import OFormats
import XCTest
@testable import OEngine

/// Spec 8 §7 and Spec 10 §3 — the `mediaUse` and `media` queries answered
/// through the engine's own publisher (Spec 2 §9, "Until the API server
/// exists (Area 19), the engine's areas ... answer their queries ... through
/// the engine's own publisher"; Adam's answer of 2026-11-11, 4).
final class MediaQueryEngineTests: XCTestCase {
    typealias E = EngineFixtures

    func ask(_ media: MediaFixture, _ fields: [String: JSONValue]) -> [String: JSONValue] {
        var request = fields
        request["id"] = .number(63)
        request["type"] = .string("query")
        return media.engine.engine.publisher.query(.object(request)).objectValue ?? [:]
    }

    func test_mediaUseAnswersTheDeleteConfirmation() throws {
        let media = try MediaFixture()
        XCTAssertEqual(ask(media, ["what": .string("mediaUse"), "media": .string(E.cross)]),
                       ["id": .number(63), "type": .string("answer"), "cues": .number(1), "macros": .number(1), "presets": .number(0), "keys": .number(0)],
                       "the shape Spec 8 §7 gives: the local copy's cue and the machine's macro 2")
        // After a replace, a reference to the old item counts for the new one.
        XCTAssertNil(media.run("media replace \(E.mountains) \(E.dawn)"))
        XCTAssertEqual(ask(media, ["what": .string("mediaUse"), "media": .string(E.dawn)])["cues"], .number(2),
                       "list 42's cue, and list 7's, rewritten to dawn")
        XCTAssertEqual(ask(media, ["what": .string("mediaUse"), "media": .string(E.mountains)])["cues"], .number(0),
                       "nothing that plays uses the replaced item")
        let unknown = ask(media, ["what": .string("mediaUse"), "media": .string("sha256:" + String(repeating: "0", count: 64))])
        XCTAssertEqual(unknown["result"], .string("rejected"))
        XCTAssertEqual(unknown["reason"]?.stringValue?.hasPrefix("unknownObject:"), true)
        XCTAssertEqual(ask(media, ["what": .string("nothing")])["result"], .string("rejected"))
    }

    func test_theMediaQueryListsBothIndexesWithPresenceUsesAndTiles() throws {
        let media = try MediaFixture()
        let answer = ask(media, ["what": .string("media")])
        XCTAssertEqual(answer["type"], .string("answer"))
        let items = try XCTUnwrap(answer["media"]?.arrayValue).compactMap(\.objectValue)
        XCTAssertEqual(items.count, media.control.library.mediaIndex.entries.count + media.control.machine.mediaLocal.entries.count)
        let dawn = try XCTUnwrap(items.first { $0["id"] == .string(E.dawn) })
        XCTAssertEqual(dawn["index"], .string("library"))
        XCTAssertEqual(dawn["presence"], .string("ok"))
        XCTAssertEqual(dawn["uses"], .number(1))
        let tile = try XCTUnwrap(dawn["tile"]?.stringValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tile), "its tile's file")
        XCTAssertTrue(tile.hasSuffix("thumbnails/pool/\(String(E.dawn.dropFirst(7)))-0.png"))
        let mountains = try XCTUnwrap(items.first { $0["id"] == .string(E.mountains) })
        XCTAssertEqual(mountains["presence"], .string("missing"))
        XCTAssertEqual(mountains["tile"], .null)
        XCTAssertEqual(items.first { $0["id"] == .string(MediaFixture.announcement) }?["index"], .string("machine"))
        // A delete shows in the next answer.
        XCTAssertNil(media.run("media delete \(MediaFixture.announcement)"))
        let after = try XCTUnwrap(ask(media, ["what": .string("media")])["media"]?.arrayValue).compactMap(\.objectValue)
        XCTAssertEqual(after.first { $0["id"] == .string(MediaFixture.announcement) }?["presence"], .string("deleted"))
    }
}
