import Foundation
import XCTest
@testable import OCore

/// Spec 9 §3 — "A snapshot is one zip file holding the documents of both
/// roots, as the engine holds them at that moment, unwritten edits included
/// ... under `library/` and `machine/` at the paths Spec 1 §5 gives them,
/// with a manifest". Spec 9 §10, Snapshots: "The zip holds exactly the
/// documents §3 lists ... with the manifest and its folders".
final class SnapshotContentTests: XCTestCase {
    typealias F = FixtureLibrary

    static let (library, machine, _) = F.load()
    let run = UUID(uuidString: "51e20000-0000-4000-8000-000000000001")

    func take(_ library: Library = SnapshotContentTests.library, _ machine: Machine = SnapshotContentTests.machine,
              reason: SnapshotManifest.Reason = .playlist) -> Snapshot {
        Snapshot.taking(id: "2026-11-08-085959", takenAt: "2026-11-08T08:59:59.120-05:00", reason: reason, library: library,
                        machine: machine, run: run, seq: 4821)
    }

    // MARK: - What one holds

    /// Every document of the fixture's two roots, each where its file is, and nothing else: no media, no
    /// kept version, no last state.
    func test_itHoldsExactlyTheDocumentsOfBothRoots() {
        let expected: Set<String> = [
            "library/audio-transitions.json", "library/channels.json", "library/grades.json", "library/library.json",
            "library/lists/007-doxology.json", "library/lists/Hymns/042-great-is-thy-faithfulness.json",
            "library/macros/001-welcome.json", "library/media-index.json", "library/presets/001-default.json",
            "library/presets/002-clock.json", "library/presets/003-lower-third.json", "library/presets/004-credits.json",
            "library/text-styles.json", "library/transitions.json",
            "machine/audio-outputs.json", "machine/clocks.json", "machine/inputs.json", "machine/keys.json",
            "machine/lists-local/042-great-is-thy-faithfulness-manheim.json", "machine/machine.json",
            "machine/macros/002-preshow.json", "machine/media-local.json", "machine/outputs.json",
            "machine/playlists/sunday-2026-11-01.json", "machine/playlists/sunday-night.json", "machine/playlists/sunday.json",
            "machine/stacks.json",
        ]
        XCTAssertEqual(Set(take().documents.keys), expected)
    }

    /// "as the engine holds them": each document's bytes are the ones a save would write, so the loader reads
    /// each back as the document the roots hold.
    func test_eachDocumentReadsBackAsTheRootsHoldIt() throws {
        let snapshot = take()
        let library = Loader.library(from: snapshot.root("library"))
        let machine = Loader.machine(from: snapshot.root("machine"))
        XCTAssertTrue(library.report.issues.filter { $0.severity == .error }.isEmpty, library.report.lines.joined(separator: "\n"))
        XCTAssertTrue(machine.report.issues.filter { $0.severity == .error }.isEmpty, machine.report.lines.joined(separator: "\n"))
        XCTAssertEqual(library.library.lists, Self.library.lists)
        XCTAssertEqual(library.library.channels, Self.library.channels)
        XCTAssertEqual(library.library.presets, Self.library.presets)
        XCTAssertEqual(library.library.info, Self.library.info)
        XCTAssertEqual(library.library.folders, Self.library.folders)
        XCTAssertEqual(machine.machine.playlists, Self.machine.playlists)
        XCTAssertEqual(machine.machine.keys, Self.machine.keys)
        XCTAssertEqual(machine.machine.localLists, Self.machine.localLists)
        XCTAssertEqual(machine.machine.settings, Self.machine.settings)
        XCTAssertNil(machine.machine.lastState, "the last state is left out (choice G-6)")
    }

    /// "unwritten edits included": the roots in memory are what is copied, whatever the files hold.
    func test_unwrittenEditsAreInIt() throws {
        var library = Self.library
        let index = try XCTUnwrap(library.lists.firstIndex { $0.number == 42 })
        library.lists[index].title = "Great Is Thy Faithfulness (edited)"
        let data = try XCTUnwrap(take(library).documents["library/lists/Hymns/042-great-is-thy-faithfulness.json"])
        guard case .list(let list) = try Loader.document(path: "lists/x.json", data: data).body else { return XCTFail("not a list") }
        XCTAssertEqual(list.title, "Great Is Thy Faithfulness (edited)")
    }

    /// A list that has no file yet goes where its first save will put it, and two documents never share a path.
    func test_aNewListAndTwoDocumentsOfOneNameEachGetTheirOwnPath() throws {
        var library = Self.library
        var made = try XCTUnwrap(library.list(number: 7))
        made.uuid = UUID()
        library.lists.append(made)
        let documents = take(library).documents
        XCTAssertNotNil(documents["library/lists/007-doxology.json"])
        XCTAssertNotNil(documents["library/lists/007-doxology-2.json"])
    }

    // MARK: - The manifest

    func test_theManifestNamesTheMachineTheLibraryTheLastCommandAndTheFolders() throws {
        let manifest = take().manifest
        XCTAssertEqual(manifest.id, "2026-11-08-085959")
        XCTAssertEqual(manifest.takenAt, "2026-11-08T08:59:59.120-05:00")
        XCTAssertEqual(manifest.reason, "playlist")
        XCTAssertEqual(manifest.machine, Self.machine.settings.uuid.uuidString.lowercased())
        XCTAssertEqual(manifest.campus, Self.machine.settings.campusName)
        XCTAssertEqual(manifest.library, Self.library.info.uuid.uuidString.lowercased())
        XCTAssertEqual(manifest.run, "51e20000-0000-4000-8000-000000000001")
        XCTAssertEqual(manifest.seq, 4821)
        XCTAssertEqual(manifest.folders, ["Christmas", "Hymns"], "an empty folder is listed, so it survives a restore (Spec 7 §2)")

        let members = try XCTUnwrap(try JSONValue.parse(manifest.data).objectValue)
        XCTAssertEqual(members["schema"], .number(1))
        XCTAssertEqual(members["app"], .string(OCore.appVersion))
        XCTAssertEqual(members["kind"], .string("snapshot"))
        XCTAssertEqual(Set(members.keys), ["schema", "app", "kind", "id", "takenAt", "reason", "machine", "campus", "library", "run", "seq",
                                           "folders"])
    }

    func test_theManifestReadsBackWithKeysThisAppDoesNotKnow() throws {
        var members = try XCTUnwrap(take().manifest.json.objectValue)
        members["later"] = .object(["a": .number(1)])
        let read = try XCTUnwrap(SnapshotManifest(data: JSONCanonical.data(.object(members))))
        XCTAssertEqual(read.extra["later"], .object(["a": .number(1)]))
        XCTAssertEqual(try JSONValue.parse(read.data), .object(members), "unknown keys survive a round trip (Spec 1 §8)")
        XCTAssertEqual(SnapshotManifest(data: take().manifest.data), take().manifest)
    }

    func test_bytesThatAreNotAManifestThisAppReadsAreRefused() throws {
        XCTAssertNil(SnapshotManifest(data: Data("not json".utf8)))
        XCTAssertNil(SnapshotManifest(data: Data(#"{"schema":1,"app":"0.1.0","kind":"list","id":"x"}"#.utf8)))
        XCTAssertNil(SnapshotManifest(data: Data(#"{"schema":2,"app":"9.0.0","kind":"snapshot","id":"x"}"#.utf8)), "a later schema")
        XCTAssertNil(SnapshotManifest(data: Data(#"{"schema":1,"app":"0.1.0","kind":"snapshot"}"#.utf8)), "no id")
    }

    func test_theReasons() {
        XCTAssertEqual(SnapshotManifest.Reason.allCases.map(\.rawValue), ["launch", "playlist", "timer", "command", "restore"])
        XCTAssertEqual(SnapshotManifest.Reason.allCases.filter(\.isAutomatic), [.launch, .playlist, .timer])
    }

    // MARK: - The zip's files

    func test_itsFilesAreTheManifestThenTheDocumentsAndReadBackTheSame() throws {
        let snapshot = take()
        let files = snapshot.files
        XCTAssertEqual(files.first?.path, "snapshot.json")
        XCTAssertEqual(files.dropFirst().map(\.path), snapshot.documents.keys.sorted())
        XCTAssertEqual(try Snapshot(files: files), snapshot)
    }

    func test_filesWithNoManifestOrOneThisAppCannotReadAreNotASnapshot() {
        XCTAssertThrowsError(try Snapshot(files: [("library/library.json", Data("{}".utf8))]))
        XCTAssertThrowsError(try Snapshot(files: [("snapshot.json", Data("{}".utf8))]))
    }

    // MARK: - Equal content

    /// "An automatic snapshot ... whose documents equal the newest snapshot's isn't written".
    func test_twoSnapshotsOfTheSameRootsHoldTheSameWhateverTheirManifestsSay() throws {
        let first = take()
        var later = Snapshot.taking(id: "2026-11-08-090959", takenAt: "2026-11-08T09:09:59.000-05:00", reason: .timer,
                                    library: Self.library, machine: Self.machine, run: UUID(), seq: 9000)
        XCTAssertTrue(later.holdsTheSame(as: first))

        var library = Self.library
        let index = try XCTUnwrap(library.lists.firstIndex { $0.number == 42 })
        library.lists[index].title += "!"
        XCTAssertFalse(take(library).holdsTheSame(as: first), "an edit")

        library = Self.library
        library.folders.append("Worship")
        XCTAssertFalse(take(library).holdsTheSame(as: first), "a folder made")

        later.documents["machine/keys.json"] = Data("{}".utf8)
        XCTAssertFalse(later.holdsTheSame(as: first), "a machine document")
    }
}
