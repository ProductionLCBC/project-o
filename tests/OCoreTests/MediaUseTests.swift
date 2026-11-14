import Foundation
import XCTest
@testable import OCore

/// Spec 8 §7 — the use query, pure. Spec 8 §11, Feedback: "`mediaUse`
/// counting keys, scheduler entries and references through a `replaced`
/// map." In the fixture, list 42 writes dawn, list 7 writes mountains and the
/// welcome slide, the local copy of list 42 writes cross, and the machine's
/// macro 2 writes cross.
final class MediaUseTests: XCTestCase {
    typealias F = FixtureLibrary

    func test_eachHolderCountsOnceByWhatItsReferencesResolveTo() {
        var (library, machine, _) = F.load()
        XCTAssertEqual(MediaUse.of(F.dawn, library: library, machine: machine), MediaUse(cues: 1))
        XCTAssertEqual(MediaUse.of(F.cross, library: library, machine: machine), MediaUse(cues: 1, macros: 1),
                       "a local copy's cue and the machine's macro")
        XCTAssertEqual(MediaUse.of(F.announcement, library: library, machine: machine), MediaUse())
        // Key bindings and scheduler entries both count as keys.
        let write = Command.channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: F.cross))))
        machine.keys.append(KeyBinding(device: "keyboard", key: "c", command: write))
        machine.keys.append(KeyBinding(device: "scheduler", when: Schedule(days: ["sunday"], time: "09:00"), command: write))
        XCTAssertEqual(MediaUse.of(F.cross, library: library, machine: machine), MediaUse(cues: 1, macros: 1, keys: 2))
        XCTAssertEqual(MediaUse.of(F.cross, library: library, machine: machine).fields,
                       ["cues": .number(1), "macros": .number(1), "presets": .number(0), "keys": .number(2)])
        // "with references that resolve to the item through a `replaced` map": list 7 names mountains, which now
        // resolves to dawn, so it counts for dawn, and nothing that plays uses mountains.
        library.mediaIndex.replaced[F.mountains] = F.dawn
        XCTAssertEqual(MediaUse.of(F.dawn, library: library, machine: machine), MediaUse(cues: 2))
        XCTAssertEqual(MediaUse.of(F.mountains, library: library, machine: machine), MediaUse())
        // A cue with two writes of the same item counts once.
        let list = library.lists.firstIndex { $0.number == 42 }!
        let again = library.lists[list].cues[0].commands[0]
        library.lists[list].cues[0].commands.append(again)
        XCTAssertEqual(MediaUse.of(F.dawn, library: library, machine: machine).cues, 2)
    }

    /// Spec 10 §3 — the `media` query: "Every entry of both indexes, each with
    /// its index, its presence (`ok`, `missing` or `deleted`), what replaced
    /// it, its uses as `mediaUse` counts them in all, and its tile's file".
    func test_theCatalogListsEveryEntryWithItsPresenceReplacementUsesAndTile() throws {
        var (library, machine, _) = F.load()
        library.mediaIndex.replaced[F.mountains] = F.dawn
        let crossEntry = try XCTUnwrap(library.mediaIndex.entry(F.cross))
        let entries = MediaCatalog.entries(library: library, machine: machine, files: F.hashedMediaState,
                                           tile: { $0.id == F.dawn ? "/tiles/dawn-0.png" : nil })
        XCTAssertEqual(entries.count, library.mediaIndex.entries.count + machine.mediaLocal.entries.count)
        func item(_ id: String) -> [String: JSONValue]? {
            entries.compactMap(\.objectValue).first { $0["id"] == .string(id) }
        }
        let dawn = try XCTUnwrap(item(F.dawn))
        XCTAssertEqual(dawn["index"], .string("library"))
        XCTAssertEqual(dawn["presence"], .string("ok"))
        XCTAssertEqual(dawn["replacedBy"], .null)
        XCTAssertEqual(dawn["uses"], .number(2))
        XCTAssertEqual(dawn["tile"], .string("/tiles/dawn-0.png"))
        XCTAssertEqual(dawn["path"], .string("backgrounds/dawn.mp4"), "the entry as the index holds it")
        let mountains = try XCTUnwrap(item(F.mountains))
        XCTAssertEqual(mountains["presence"], .string("missing"), "its own file is absent")
        XCTAssertEqual(mountains["replacedBy"], .string(F.dawn))
        XCTAssertEqual(mountains["uses"], .number(0))
        XCTAssertEqual(mountains["tile"], .null)
        XCTAssertEqual(item(F.announcement)?["index"], .string("machine"))
        XCTAssertEqual(item(F.cross)?["presence"], .string("ok"), "an override's target holds its bytes")
        _ = crossEntry
        var deleted = library
        deleted.mediaIndex.entries[deleted.mediaIndex.position(of: F.cross)!].deletedAt = "2026-11-14T10:00:00Z"
        let after = MediaCatalog.entries(library: deleted, machine: machine, files: F.hashedMediaState, tile: { _ in nil })
        XCTAssertEqual(after.compactMap(\.objectValue).first { $0["id"] == .string(F.cross) }?["presence"], .string("deleted"))
    }
}
