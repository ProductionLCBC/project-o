import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §3, "Queries" — each answer read into OCore's own document types,
/// from the engine's answers on the fixture roots as `EngineContractTests`
/// recorded them (`tests/fixtures/api-v1/`).
final class DocumentTests: XCTestCase {
    func test_theCatalogHoldsBothRootsDocumentsAndASummaryOfEachList() throws {
        let catalog = try XCTUnwrap(Catalog(answer: RecordedAPI.load("catalog")))
        XCTAssertEqual(catalog.issues, [], "everything the engine sends reads")
        XCTAssertEqual(catalog.rev, 1)
        XCTAssertEqual(catalog.info?.name, "LCBC Library")
        XCTAssertEqual(catalog.channels.map(\.label), ["Background", "Foreground", "Clock"])
        XCTAssertEqual(catalog.presets.count, 4)
        XCTAssertEqual(catalog.textStyles.count, 2)
        XCTAssertEqual(catalog.grades.count, 1)
        XCTAssertEqual(catalog.transitions.count, 3)
        XCTAssertEqual(catalog.audioTransitions.count, 3)
        XCTAssertEqual(catalog.folders, ["Christmas", "Hymns"], "an empty folder is there too")
        XCTAssertEqual(catalog.stacks.map(\.label), ["Main", "Confidence"])
        XCTAssertEqual(catalog.outputs.map(\.number), [1])
        XCTAssertEqual(catalog.audioOutputs.count, 2)
        XCTAssertEqual(catalog.settings?.popups, 4)
        XCTAssertEqual(catalog.settings?.timers, 4)
        XCTAssertEqual(catalog.settings?.campusName, "Manheim")
        XCTAssertFalse(catalog.mastersAreReadOnly)
        XCTAssertEqual(catalog.macros.map(\.number), [1, 2], "the library's and the machine's, by number")
        XCTAssertEqual(catalog.keys.count, 6, "every row, the other devices' too; the keys pick out the keyboard's (Spec 10 §9)")
    }

    func test_theCatalogsPlaylistsCarryTheirItemsAndWhetherTheirTitleNamesThem() throws {
        let catalog = try XCTUnwrap(Catalog(answer: RecordedAPI.load("catalog")))
        XCTAssertEqual(Set(catalog.playlists.map(\.playlist.title)), ["Sunday", "Sunday Night", "Sunday 2026-11-01"])
        XCTAssertTrue(catalog.playlists.allSatisfy(\.named))
        let sunday = try XCTUnwrap(catalog.playlists.first { $0.playlist.title == "Sunday" })
        XCTAssertEqual(sunday.playlist.items.count, 5, "two headers, a linked list, the local copy, a linked list")
        XCTAssertEqual(catalog.playlists.filter(\.playlist.archived).map(\.playlist.title), ["Sunday 2026-11-01"])
        XCTAssertEqual(catalog.playlist(uuid: sunday.playlist.uuid.uuidString.lowercased())?.playlist.title, "Sunday")
    }

    func test_theCatalogsListSummariesSayWhichNumberNamesWhichList() throws {
        let catalog = try XCTUnwrap(Catalog(answer: RecordedAPI.load("catalog")))
        XCTAssertEqual(catalog.lists.map(\.number), [7, 42, 42])
        let master = try XCTUnwrap(catalog.lists.first { $0.number == 42 && !$0.local })
        XCTAssertEqual(master.title, "Great Is Thy Faithfulness")
        XCTAssertEqual(master.folder, "Hymns")
        XCTAssertEqual(master.cues, 4)
        XCTAssertEqual(master.ccli, "18723")
        XCTAssertTrue(master.named)
        let local = try XCTUnwrap(catalog.lists.first { $0.local })
        XCTAssertFalse(local.named, "a local copy is fired through its playlist item, never by its number")
        XCTAssertEqual(catalog.list(uuid: master.uuid), master)
        XCTAssertTrue(try XCTUnwrap(catalog.lists.first { $0.number == 7 }).trackThrough)
    }

    func test_oneDocumentThatCannotBeReadDoesNotCostTheRest() throws {
        var answer = try RecordedAPI.load("catalog")
        var library = try XCTUnwrap(answer["library"]?.objectValue)
        var channels = try XCTUnwrap(library["channels"]?.arrayValue)
        channels[1] = .object(["number": .string("two")])
        library["channels"] = .array(channels)
        answer["library"] = .object(library)
        let catalog = try XCTUnwrap(Catalog(answer: answer))
        XCTAssertEqual(catalog.channels.map(\.number), [1, 3])
        XCTAssertEqual(catalog.issues, ["channel 2 of 3 couldn't be read"])
        XCTAssertNil(Catalog(answer: ["rev": .number(1)]), "an answer with neither root isn't a catalog")
    }

    func test_aListArrivesWholeWithItsFolder() throws {
        let master = try XCTUnwrap(ListDocument(answer: RecordedAPI.load("list-42")))
        XCTAssertEqual(master.list.number, 42)
        XCTAssertEqual(master.folder, "Hymns")
        XCTAssertFalse(master.local)
        XCTAssertEqual(master.list.cues.count, 4)
        XCTAssertEqual(master.list.cues.map(\.label), ["Verse 1", "Verse 1", "Verse 1", "Chorus"])
        XCTAssertEqual(master.list.cues[2].advanceAfterMs, 12_000)
        XCTAssertEqual(master.uuid, "a9f00000-0000-4000-8000-00000000002a")
        let local = try XCTUnwrap(ListDocument(answer: RecordedAPI.load("list-local")))
        XCTAssertTrue(local.local)
        XCTAssertEqual(local.list.cues.count, 2)
        XCTAssertNil(ListDocument(answer: ["folder": .string("Hymns")]))
    }

    func test_mediaCarriesEachEntrysIndexPresenceUsesAndTile() throws {
        let (items, issues) = MediaItem.items(answer: try RecordedAPI.load("media"))
        XCTAssertEqual(issues, [])
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items.filter(\.isMissing).count, 1, "the fixture's mountains video isn't on disk")
        XCTAssertEqual(items.filter { $0.index == "machine" }.count, 1)
        let dawn = try XCTUnwrap(items.first { $0.entry.path == "backgrounds/dawn.mp4" })
        XCTAssertEqual(dawn.presence, "ok")
        XCTAssertEqual(dawn.uses, 1)
        XCTAssertNil(dawn.tile, "no tile is written on the headless engine")
        XCTAssertNil(dawn.replacedBy)
        XCTAssertEqual(dawn.entry.defaults.defaultChannel, 1)
        XCTAssertTrue(dawn.id.hasPrefix("sha256:"))
    }

    func test_theSmallAnswers() throws {
        XCTAssertEqual(MediaUseCount(answer: try RecordedAPI.load("mediaUse")), MediaUseCount(cues: 1, macros: 0, presets: 0, keys: 0))
        XCTAssertEqual(MediaUseCount(answer: ["cues": .number(12), "macros": .number(1), "presets": .number(0), "keys": .number(2)]).total, 15,
                       "Spec 8 §7's example")
        let use = ListUse(answer: try RecordedAPI.load("listUse-42"))
        XCTAssertEqual(use.playlists.map(\.title), ["Sunday Night", "Sunday", "Sunday 2026-11-01"])
        XCTAssertEqual(use.playlists.filter(\.archived).count, 1)
        let versions = KeptVersion.all(answer: try RecordedAPI.load("versions-42"))
        XCTAssertEqual(versions.map(\.version), [16])
        XCTAssertEqual(versions.first?.cues, 2)
        XCTAssertEqual(versions.first?.title, "Great Is Thy Faithfulness")
        let snapshots = SnapshotSummary.all(answer: try RecordedAPI.load("snapshots"))
        XCTAssertEqual(snapshots.map(\.id), ["2026-10-30-100000"])
        XCTAssertEqual(snapshots.first?.reason, "launch")
        XCTAssertEqual(snapshots.first?.campus, "Manheim")
        let thumbnails = CueThumbnails(answer: try RecordedAPI.load("thumbnails-42"))
        XCTAssertEqual(thumbnails.stack, 1)
        XCTAssertEqual(thumbnails.files, [:], "none is drawn yet; a thumbnails event follows each as it is written")
        let drawn = CueThumbnails(answer: ["stack": .number(1), "thumbnails": .array([.object(["cue": .string("11aa"), "file": .string("thumbnails/1/11aa.png")]),
                                                                                       .object(["cue": .string("22bb"), "file": .null])])])
        XCTAssertEqual(drawn.files, ["11aa": "thumbnails/1/11aa.png"])
    }
}
