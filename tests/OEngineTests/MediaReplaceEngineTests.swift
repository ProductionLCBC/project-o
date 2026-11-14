import Foundation
import OCore
import OFormats
import XCTest
@testable import OEngine

/// Spec 8 §6 — `media replace` in the engine, on a temporary copy of the
/// fixture: an ordinary edit (§2), logged with what it did and its inverse,
/// one `library` event with cause `edit`, the documents written; and the
/// logged inverse sent back puts every document back byte for byte (the
/// plan's proof of "`media unreplace` puts the references, the mappings and
/// the defaults back exactly"; Area 12 sends it as an undo). Spec 8 §2 —
/// held in a cue it waits for the fire, and a refusal there is `blocked`.
final class MediaReplaceEngineTests: XCTestCase {
    typealias E = EngineFixtures
    var media: MediaFixture!

    override func setUpWithError() throws {
        media = try MediaFixture()
    }

    override func tearDown() {
        media = nil
    }

    /// Every document of both roots as written, but the caches the engine keeps beside them.
    func documents() -> [String: Data] {
        var out: [String: Data] = [:]
        for root in [media.libraryRoot, media.machineRoot] {
            let base = root.standardizedFileURL.path + "/"
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                let path = url.standardizedFileURL.path
                guard path.hasSuffix(".json"), !path.hasSuffix("media-cache.json"), !path.contains("/state/"), !path.contains("/thumbnails/") else { continue }
                out[root.lastPathComponent + "/" + path.dropFirst(base.count)] = FileManager.default.contents(atPath: path)
            }
        }
        return out
    }

    /// Ticks past the writer's one-second spacing (Spec 5 §2), then waits for it.
    func flush() {
        for _ in 0..<70 { media.engine.tick() }
        media.settle()
    }

    /// A new video imported as the re-export: empty defaults, its poster at 0.
    func importReExport() throws -> String {
        let staged = try media.stage("Dawn v2.mp4", "dawn, re-exported")
        XCTAssertNil(media.importPath(staged))
        return MediaFixture.id("dawn, re-exported")
    }

    func test_replaceIsAnEditAndItsLoggedInversePutsEveryDocumentBack() throws {
        let new = try importReExport()
        flush()
        let before = documents()
        let revision = media.control.revision
        media.library.clear()
        XCTAssertNil(media.run("media replace \(E.dawn) \(new)"))
        let entry = try XCTUnwrap(media.control.commandLog.entries.last)
        XCTAssertEqual(entry.kind, .edit)
        XCTAssertEqual(entry.undo, .edit, "undone through Spec 5 §8")
        XCTAssertEqual(entry.result, .ok)
        guard case .media(.replace(_, _, let record?)) = entry.command else { return XCTFail("logged with what it did: \(entry.text)") }
        XCTAssertEqual(entry.inverse, .media(.unreplace(old: E.dawn, new: new, record: record)))
        XCTAssertFalse(record.refs.isEmpty, "list 42's cue wrote dawn")
        XCTAssertEqual(media.control.revision, revision + 1)
        let events = media.library.all.filter { $0["cause"] == .string("edit") }
        XCTAssertEqual(events.count, 1, "one library event, cause edit")
        XCTAssertEqual(media.control.library.list(number: 42)?.cues[0].commands[0].command.mediaRef, new)
        XCTAssertEqual(media.control.library.mediaIndex.replaced[E.dawn], new)
        XCTAssertEqual(media.control.library.mediaIndex.entry(new)?.defaults, media.control.library.mediaIndex.entry(E.dawn)?.defaults,
                       "the re-export, its defaults empty, takes dawn's")
        flush()
        XCTAssertNotEqual(documents(), before, "written")
        // The logged inverse, sent back.
        let inverse = try XCTUnwrap(entry.inverse.flatMap(CommandText.print))
        XCTAssertNil(media.run(inverse))
        XCTAssertEqual(media.control.commandLog.entries.last?.result, .ok)
        XCTAssertEqual(media.control.commandLog.entries.last?.inverse, .media(.replace(old: E.dawn, new: new, record: record)))
        flush()
        let after = documents()
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        // Byte for byte, but a list's `version`, which "rises on every save" (Spec 1 §4): the replace's and the unreplace's.
        for (path, data) in before where after[path] != data {
            let old = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            let now = String(decoding: after[path] ?? Data(), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            let differing = zip(old, now).filter { $0 != $1 }
            XCTAssertEqual(old.count, now.count, path)
            XCTAssertTrue(path.contains("/lists/"), "\(path) differs: \(differing)")
            XCTAssertEqual(differing.map(\.0), ["  \"version\": 17"], path)
            XCTAssertEqual(differing.map(\.1), ["  \"version\": 19"], "two saves")
        }
    }

    /// Spec 8 §2 — "Inside a cue, a macro, a key binding or a scheduler entry,
    /// any refusal of a media command is `blocked` with its reason and logged,
    /// and the rest of the group runs"; an applied one waits for its fire, as
    /// a held edit does (Spec 7 §4).
    func test_aCueHoldingReplaceAppliesAfterItsFireAndARefusalThereIsBlocked() throws {
        let new = try importReExport()
        // List 7's first cue writes mountains; give its second cue a replace, a refused replace, and a write.
        var library = media.control.library
        let list = try XCTUnwrap(library.lists.firstIndex { $0.number == 7 })
        library.lists[list].cues[1].commands = [
            GuardedCommand(.media(.replace(old: E.mountains, new: new, record: nil))),
            GuardedCommand(.media(.replace(old: E.dawn, new: E.dawn, record: nil))),
            GuardedCommand(.channelWrite(ChannelWrite(channel: .number(2), content: .media(MediaContent(ref: E.cross))))),
        ]
        try media.writeList(library.lists[list])
        media.engine.scanDisk()
        media.settle()
        XCTAssertNil(media.run("list 7 cue 2"))
        let lines = media.control.commandLog.entries.suffix(4)
        XCTAssertEqual(lines.map(\.result), [.ok, .ok, .ok, .blocked], "the navigation, the write, then the held replaces")
        XCTAssertEqual(lines.dropFirst().first?.command.mediaRef, E.cross, "the cue's write ran first")
        XCTAssertEqual(media.control.library.mediaIndex.replaced[E.mountains], new, "the held replace applied after the fire")
        XCTAssertEqual(media.engine.state.channels[2]?.content.media?.ref, E.cross, "the rest of the group ran")
        XCTAssertTrue(media.engine.log.contains("blocked cue edit media replace \(E.dawn) \(E.dawn)"))
    }
}

extension MediaFixture {
    /// A list written to disk as a hand edit or a sync would, at the path its key names.
    func writeList(_ list: List) throws {
        let key = FileLayout.documentKey(list: list.uuid)
        let path = try XCTUnwrap(control.library.documentPaths[key])
        try Writer.data(for: .list(list)).write(to: libraryRoot.appendingPathComponent(path))
    }
}
