import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §6, "Drops on the grid" and the pool's tile menu, §7, "Drops",
/// and §10 — what a tile or a file let go on a cue, a strip cell or the pool
/// does, and what the pool's own edits send (§18, "commands" and "the strip").
@MainActor
final class PoolDropTests: XCTestCase {
    typealias Rig = ShowModelTests.Rig
    typealias Importing = MediaImportsTests.Importing

    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    private func media() throws -> (dawn: MediaItem, mountains: MediaItem, cross: MediaItem, own: MediaItem, all: [MediaItem]) {
        let all = try Recorded.media()
        func named(_ name: String) throws -> MediaItem { try XCTUnwrap(all.first { $0.entry.path.hasSuffix(name) }, name) }
        return (try named("dawn.mp4"), try named("mountains.mp4"), try named("cross.png"), try named("announcement.png"), all)
    }

    private let isFolder: (String) -> Bool = { $0.hasSuffix("/Easter") }

    // MARK: - The rules (Drops)

    /// "A pool tile dropped on a cue ... opens a popover of channels with the item's drop channel picked (§6)."
    func test_aTileOnACueAsksForAChannelWithItsDropChannelPicked() throws {
        let media = try media()
        let settings = try Recorded.catalog().settings
        func plan(_ item: MediaItem, cannot: CannotEdit? = nil) -> DropPlan {
            Drops.plan(.media(item.id), ontoCue: cannot, media: media.all, settings: settings, isFolder: isFolder)
        }
        XCTAssertEqual(plan(media.dawn), .chooseChannel(CueDrop(source: .media(media.dawn.id), picked: 1)), "its own default channel")
        XCTAssertEqual(plan(media.cross), .chooseChannel(CueDrop(source: .media(media.cross.id), picked: settings?.dropChannels?.image)),
                       "else the machine's drop channel for its kind")
        XCTAssertTrue(plan(media.dawn).isAccepted)
        // Area 13 reading — an item whose file is gone isn't written into a cue.
        XCTAssertEqual(plan(media.mountains), .refused(.missing))
        // A cue that takes no edit says why: the lock, a local copy, a list to renumber.
        XCTAssertEqual(plan(media.dawn, cannot: .unavailable(.locked)), .refused(.unavailable(.locked)))
        XCTAssertEqual(plan(media.dawn, cannot: .localCopy), .refused(.localCopy))
        XCTAssertEqual(Drops.plan(.media("sha256:none"), ontoCue: nil, media: media.all, settings: settings, isFolder: isFolder), .none)
        XCTAssertEqual(Drops.plan(.list(Recorded.list42), ontoCue: nil, media: media.all, settings: settings, isFolder: isFolder), .none, "a cue takes no list")
    }

    /// "The channel popover opens at the drop, with the drop channel for the
    /// kind the file's type suggests"; "The grid and the strip take one file
    /// at a time: several files, or a folder, are refused there".
    func test_oneFileOnACueAsksForAChannelAndSeveralOrAFolderAreRefused() throws {
        let media = try media()
        let settings = try Recorded.catalog().settings
        func plan(_ paths: [String], cannot: CannotEdit? = nil) -> DropPlan {
            Drops.plan(.files(paths), ontoCue: cannot, media: media.all, settings: settings, isFolder: isFolder)
        }
        XCTAssertEqual(plan(["/x/Ocean loop.mov"]), .chooseChannel(CueDrop(source: .file("/x/Ocean loop.mov"), picked: settings?.dropChannels?.video)))
        XCTAssertEqual(plan(["/x/walk-in.wav"]), .chooseChannel(CueDrop(source: .file("/x/walk-in.wav"), picked: nil)), "audio asks, on first run's settings")
        XCTAssertEqual(plan(["/x/a.mov", "/x/b.mov"]), .refused(.dropOnThePool))
        XCTAssertEqual(plan(["/x/Easter"]), .refused(.dropOnThePool))
        // Under the lock nothing is imported anywhere, so the pool isn't offered.
        XCTAssertEqual(plan(["/x/a.mov", "/x/b.mov"], cannot: .unavailable(.locked)), .refused(.unavailable(.locked)))
        XCTAssertEqual(plan(["/x/a.mov"], cannot: .unavailable(.locked)), .refused(.unavailable(.locked)))
        XCTAssertEqual(plan([]), .none)
    }

    /// Spec 10 §7 — "A pool tile dropped on a cell goes live at once"; §12:
    /// "drops of pool tiles on the strip ... all work" under the lock. §18:
    /// "several files, a folder, or any file under the lock are refused."
    func test_aStripCellTakesATileUnderTheLockAndAFileOnlyWithoutIt() throws {
        let media = try media()
        func plan(_ payload: DragPayload, send: Unavailable? = nil, importing: Unavailable? = nil) -> DropPlan {
            Drops.plan(payload, ontoChannel: 2, media: media.all, cannotSend: send, cannotImport: importing, isFolder: isFolder)
        }
        XCTAssertEqual(plan(.media(media.dawn.id)), .live(media: media.dawn.id, channel: 2), "on the cell it was let go on, whatever its drop channel")
        XCTAssertEqual(plan(.media(media.dawn.id), importing: .locked), .live(media: media.dawn.id, channel: 2), "the lock leaves a tile's drop working")
        XCTAssertEqual(plan(.media(media.dawn.id), send: .engineAway, importing: .engineAway), .refused(.unavailable(.engineAway)))
        XCTAssertEqual(plan(.media(media.mountains.id)), .refused(.missing))
        XCTAssertEqual(plan(.files(["/x/a.mov"])), .importLive(path: "/x/a.mov", channel: 2))
        XCTAssertEqual(plan(.files(["/x/a.mov"]), importing: .locked), .refused(.unavailable(.locked)), "any file under the lock")
        XCTAssertEqual(plan(.files(["/x/a.mov", "/x/b.png"])), .refused(.dropOnThePool))
        XCTAssertEqual(plan(.files(["/x/Easter"])), .refused(.dropOnThePool))
        XCTAssertEqual(plan(.list(Recorded.list42)), .none)
    }

    /// "Files dropped on the pool from outside ... are copied into the staging folder and imported".
    func test_thePoolTakesAnyNumberOfFilesAndFoldersUnlessTheLockIsOn() {
        XCTAssertEqual(Drops.planOnPool(.files(["/x/a.mov", "/x/Easter"]), cannotImport: nil), .importFiles(["/x/a.mov", "/x/Easter"]))
        XCTAssertEqual(Drops.planOnPool(.files(["/x/a.mov"]), cannotImport: .locked), .refused(.unavailable(.locked)))
        XCTAssertEqual(Drops.planOnPool(.media("sha256:9f2c"), cannotImport: nil), .none, "a tile is already in the pool")
        XCTAssertEqual(Drops.planOnPool(.files([]), cannotImport: nil), .none)
    }

    // MARK: - Landing on a cue (Spec 10 §6, §10)

    /// "Return or a click sends one `edit.cueChannel` writing the item on
    /// that channel: `write media sha256:…`, keeping the transition and
    /// audio-transition riders of what the cue wrote there before".
    func test_theChannelPopoversAnswerWritesTheTileIntoTheCue() throws {
        let rig = try Rig()
        let media = try media()
        let (verse, section) = rig.cell(1, 0)
        let plan = rig.model.plan(.media(media.dawn.id), ontoCue: verse, in: section)
        let drop = try XCTUnwrap(rig.model.land(plan, onCue: verse, in: section))
        XCTAssertEqual(drop, CueDrop(source: .media(media.dawn.id), picked: 1))
        XCTAssertEqual(rig.sent.count, 0, "nothing is sent until a channel is chosen")
        rig.model.write(drop, into: verse, in: section, channel: 1)
        XCTAssertEqual(rig.commands, [["edit list 42 cue \(verse.uuid) channel 1 write media \(media.dawn.id) transition 2 1.0 once"]])
        XCTAssertEqual(rig.sent.first?.fields["source"], .string("ui"))
        XCTAssertEqual(rig.model.settings.recentMedia.first, media.dawn.id, "and it leads the recently used")
        // Another channel than the one picked.
        rig.model.write(drop, into: verse, in: section, channel: 3)
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue \(verse.uuid) channel 3 write media \(media.dawn.id)"])
    }

    func test_aDropACueRefusesIsSaidOnItsCell() throws {
        let test = try Importing()
        let rig = test.rig
        let media = try media()
        let (verse, section) = rig.cell(1, 0)
        let key = MediaImports.key(list: Recorded.list42, cue: verse.uuid)
        test.imports.isFolder = isFolder
        // Several files: "the cell says to drop them on the pool."
        let several = rig.model.plan(.files(["/x/a.mov", "/x/b.mov"]), ontoCue: verse, in: section)
        XCTAssertNil(rig.model.land(several, onCue: verse, in: section))
        XCTAssertEqual(test.imports.cueNotes[key], .cannot(.dropOnThePool))
        rig.clock.advance(by: 5.1)
        XCTAssertNil(test.imports.cueNotes[key], "for a few seconds")
        // The lock came on while the popover was open: the answer is refused, and the cell says so.
        let drop = try XCTUnwrap(rig.model.land(rig.model.plan(.media(media.dawn.id), ontoCue: verse, in: section), onCue: verse, in: section))
        try test.lock()
        rig.model.write(drop, into: verse, in: section, channel: 1)
        XCTAssertEqual(test.imports.cueNotes[key], .cannot(.unavailable(.locked)))
        XCTAssertEqual(rig.model.plan(.media(media.dawn.id), ontoCue: verse, in: section), .refused(.unavailable(.locked)))
        XCTAssertEqual(rig.model.plan(.files(["/x/a.mov"]), ontoCue: verse, in: section), .refused(.unavailable(.locked)), "any file under the lock")
        XCTAssertEqual(rig.sent.count, 0)
        XCTAssertEqual(test.stager.staged, [])
    }

    /// "A file dropped from the Finder sends the same edit once its import is done (§6, choice U-8)."
    func test_theChannelPopoversAnswerImportsAFileAndThenWritesIt() throws {
        let test = try Importing()
        let rig = test.rig
        let (verse, section) = rig.cell(1, 0)
        let plan = rig.model.plan(.files(["/Users/x/Movies/Ocean loop.mov"]), ontoCue: verse, in: section)
        let drop = try XCTUnwrap(rig.model.land(plan, onCue: verse, in: section))
        XCTAssertEqual(test.stager.staged, [], "nothing is copied until a channel is chosen")
        rig.model.write(drop, into: verse, in: section, channel: 1)
        XCTAssertEqual(rig.commands, [["media import \"/staging/Ocean loop.mov\""]])
        test.accept(job: "j-1")
        let fresh = "sha256:" + String(repeating: "cd", count: 32)
        test.media("j-1", file: "Ocean loop.mov", state: "done", outcome: "known", id: fresh)
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue \(verse.uuid) channel 1 write media \(fresh) transition 2 1.0 once"], "`imported` or `known`")
    }

    // MARK: - Landing on a strip cell and on the pool

    func test_aTileLetGoOnAStripCellGoesLiveAndAFileIsImportedFirst() throws {
        let test = try Importing()
        let rig = test.rig
        let media = try media()
        rig.model.land(rig.model.plan(.media(media.dawn.id), ontoChannel: 3), onChannel: 3)
        XCTAssertEqual(rig.commands, [["channel 3 write media \(media.dawn.id)"]], "a live write from the pool (§6)")
        XCTAssertEqual(rig.sent.first?.fields["source"], .string("ui"))
        rig.model.land(rig.model.plan(.files(["/x/a.mov"]), ontoChannel: 2), onChannel: 2)
        XCTAssertEqual(rig.commands.last, ["media import \"/staging/a.mov\""])
        XCTAssertEqual(test.imports.stripNotes[2], .importing(row: 1, progress: nil))
        // Under the lock the tile still goes live, and the file is refused on the cell.
        try test.lock()
        rig.model.land(rig.model.plan(.media(media.cross.id), ontoChannel: 1), onChannel: 1)
        XCTAssertEqual(rig.commands.last, ["channel 1 write media \(media.cross.id)"])
        let refused = rig.model.plan(.files(["/x/b.mov"]), ontoChannel: 1)
        XCTAssertEqual(refused, .refused(.unavailable(.locked)))
        rig.model.land(refused, onChannel: 1)
        XCTAssertEqual(test.imports.stripNotes[1], .cannot(.unavailable(.locked)))
        XCTAssertEqual(rig.sent.count, 3)
    }

    func test_filesLetGoOnThePoolAreImportedOrThePoolSaysWhyNot() throws {
        let test = try Importing()
        let rig = test.rig
        rig.model.landOnPool(rig.model.planOnPool(.files(["/x/a.mov", "/x/b.png"])))
        XCTAssertEqual(rig.commands, [["media import \"/staging/a.mov\""], ["media import \"/staging/b.png\""]])
        XCTAssertNil(rig.model.cannotImport)
        try test.lock()
        XCTAssertEqual(rig.model.cannotImport, .unavailable(.locked))
        rig.model.landOnPool(rig.model.planOnPool(.files(["/x/c.mov"])))
        XCTAssertEqual(rig.model.notices[.pool], .notSent(.unavailable(.locked)))
        XCTAssertEqual(rig.sent.count, 2)
    }

    // MARK: - A tile's menu (Spec 10 §6, §10)

    func test_aTilesMenuAndItsDefaultsAsOneUndoableSave() throws {
        let rig = try Rig()
        let media = try media()
        let kinds = rig.model.tileMenu(for: media.dawn.id).filter { $0 != .separator }.map(\.kind)
        XCTAssertEqual(kinds, [.fireTo(channel: 1), .fireToMenu, .defaults, .replace, .reveal, .deleteMedia])
        // "each an `edit media sha256:… defaults.FIELD` edit": the fields that changed, and no other.
        var defaults = media.dawn.entry.defaults
        XCTAssertNil(rig.model.setDefaults(defaults, of: media.dawn.id))
        XCTAssertEqual(rig.sent.count, 0, "nothing changed: nothing is sent")
        defaults.loop = false
        defaults.trimInMs = 1500
        defaults.gain = -6
        defaults.defaultChannel = nil
        XCTAssertNil(rig.model.setDefaults(defaults, of: media.dawn.id))
        let id = media.dawn.id
        XCTAssertEqual(rig.commands, [["edit media \(id) defaults.trimInMs 1500", "edit media \(id) defaults.loop false", "edit media \(id) defaults.gain -6",
                                       "edit media \(id) defaults.defaultChannel null"]])
        XCTAssertEqual(rig.sent.first?.type, "commands", "one group: one Undo takes the Save back")
        defaults = media.dawn.entry.defaults
        defaults.grade = 2
        XCTAssertNil(rig.model.setDefaults(defaults, of: id))
        XCTAssertEqual(rig.commands.last, ["edit media \(id) defaults.grade 2"])
        XCTAssertEqual(rig.sent.last?.type, "command")
    }

    func test_anItemsEditsFollowTheIndexThatHoldsItAndTheLock() throws {
        let test = try Importing()
        let rig = test.rig
        let media = try media()
        XCTAssertNil(rig.model.cannotEdit(media: media.dawn.id))
        XCTAssertNil(rig.model.cannotEdit(media: media.own.id))
        XCTAssertEqual(rig.model.cannotEdit(media: "sha256:none"), .missing)
        try test.lock()
        XCTAssertEqual(rig.model.cannotEdit(media: media.dawn.id), .unavailable(.locked))
        XCTAssertEqual(rig.model.setDefaults(MediaDefaults(), of: media.dawn.id), .unavailable(.locked))
        rig.model.deleteMedia(media.dawn.id)
        XCTAssertEqual(rig.model.notices[.pool], .notSent(.unavailable(.locked)))
        XCTAssertEqual(rig.sent.count, 0)
    }

    /// "Delete… on a pool tile asks `mediaUse` first ... Then `media delete HASH` (Spec 8 §6)."
    func test_deletingAnItemLooksUpWhatUsesItThenAsks() throws {
        let asking = try ShowModelFlowTests.Asking()
        let rig = asking.rig
        let media = try media()
        rig.model.select(media: media.dawn.id)
        rig.model.deleteMedia(media.dawn.id)
        XCTAssertEqual(rig.sent.first?.type, "query")
        XCTAssertEqual(rig.sent.first?.fields["what"], .string("mediaUse"))
        XCTAssertEqual(rig.sent.first?.fields["media"], .string(media.dawn.id))
        XCTAssertEqual(asking.asked, [], "it asks once it knows")
        rig.answers[0](.answer(try RecordedAPI.load("mediaUse")))
        XCTAssertEqual(asking.asked, [.deleteMedia(name: "dawn.mp4", use: MediaUseCount(cues: 1))])
        XCTAssertEqual(rig.commands.last, ["media delete \(media.dawn.id)"])
        XCTAssertNil(rig.model.selectedMedia)
        // With no answer the question couldn't say what uses it: nothing is asked, nothing deleted.
        rig.model.deleteMedia(media.cross.id)
        rig.answers[2](nil)
        XCTAssertEqual(asking.asked.count, 1)
        XCTAssertEqual(rig.sent.count, 3)
        // Cancel deletes nothing.
        asking.answer = false
        rig.model.deleteMedia(media.cross.id)
        rig.answers[3](.answer(try RecordedAPI.load("mediaUse")))
        XCTAssertEqual(asking.asked.count, 2)
        XCTAssertEqual(rig.sent.count, 4)
    }

    /// Spec 8 §2, "Where a file is".
    func test_anItemsFileIsUnderTheMediaRootOrTheMachinesOwnMediaFolder() throws {
        let rig = try Rig()
        let media = try media()
        let machine = URL(fileURLWithPath: "/tmp/o/machine")
        let root = try XCTUnwrap(rig.model.mediaRoot(machineRoot: machine))
        let setting = try XCTUnwrap(rig.store.catalog?.settings?.mediaRoot)
        XCTAssertEqual(root.path, setting.hasPrefix("/") ? setting : URL(fileURLWithPath: "/tmp/o/machine/" + setting).standardizedFileURL.path)
        XCTAssertEqual(rig.model.location(ofMedia: media.dawn.id, machineRoot: machine)?.path, root.path + "/backgrounds/dawn.mp4")
        XCTAssertEqual(rig.model.location(ofMedia: media.own.id, machineRoot: machine)?.path, "/tmp/o/machine/media/announcement.png")
        XCTAssertNil(rig.model.location(ofMedia: "sha256:none", machineRoot: machine))
        XCTAssertNil(rig.model.location(ofMedia: media.dawn.id, machineRoot: nil))
    }

    // MARK: - The words (Spec 10 §6, §7)

    func test_theCellsAndThePoolsHeaderSayWhatHappenedInPlainWords() throws {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(ImportWording.note(.copying(row: 1)), "Copying…")
        XCTAssertEqual(ImportWording.note(.importing(row: 1, progress: nil)), "Importing…")
        XCTAssertEqual(ImportWording.note(.importing(row: 1, progress: 0.42), locale: english), "Importing… 42%")
        XCTAssertEqual(ImportWording.note(.refused("unsupported")), "Not imported. Project O can’t play this kind of file.")
        XCTAssertEqual(ImportWording.note(.copyFailed("The disk is full.")), "Not copied. The disk is full.")
        // The spec's own sentence.
        XCTAssertEqual(ImportWording.note(.notSent(.channelChanged(channel: 2))), "Not sent: channel 2 changed while importing")
        XCTAssertEqual(ImportWording.note(.notSent(.cueChanged(channel: 1))), "Not written: channel 1 changed in this cue while importing")
        XCTAssertEqual(ImportWording.note(.notSent(.engineEnded)), "The engine ended. Drop the file again.")
        XCTAssertEqual(ImportWording.note(.cannot(.dropOnThePool)), "Drop several files, or a folder, on the pool.")
        XCTAssertEqual(ImportWording.note(.cannot(.unavailable(.locked))), "Not sent. " + UnavailableWording.sentence(for: .locked))

        func row(_ state: ImportRow.State) -> String { ImportWording.row(ImportRow(id: 1, name: "Ocean loop.mov", state: state), locale: english) }
        XCTAssertEqual(row(.copying), "Ocean loop.mov: copying…")
        XCTAssertEqual(row(.importing(progress: 0.5)), "Ocean loop.mov: importing… 50%")
        XCTAssertEqual(row(.importing(progress: nil)), "Ocean loop.mov: importing…")
        XCTAssertEqual(row(.done(known: false)), "Ocean loop.mov: imported")
        XCTAssertEqual(row(.done(known: true)), "Ocean loop.mov: already in the pool")
        XCTAssertEqual(row(.refused("unreadable")), "Ocean loop.mov: not imported. " + EditWording.rejection(code: "unreadable"))
        XCTAssertEqual(row(.copyFailed("No permission.")), "Ocean loop.mov: not copied. No permission.")
        XCTAssertEqual(row(.engineAway), "Ocean loop.mov: the engine ended first. Import it again.")
        XCTAssertEqual(row(.notSent(.cueGone)), "Ocean loop.mov: imported. Not written: the cue is gone.")

        // "showing the live red and "Goes live on 2 Foreground" meanwhile"; "Goes live on 2 Foreground when imported".
        XCTAssertEqual(ImportWording.hover(.live(media: "sha256:a", channel: 2), label: "Foreground"), "Goes live on 2 Foreground")
        XCTAssertEqual(ImportWording.hover(.importLive(path: "/x/a.mov", channel: 2), label: "Foreground"), "Goes live on 2 Foreground when imported")
        XCTAssertNil(ImportWording.hover(.refused(.dropOnThePool), label: "Foreground"))
    }

    /// "Single click selects and shows the item's size, duration, codec, sound and alpha, and its defaults, in the header."
    func test_theSelectedItemsDetails() throws {
        let english = Locale(identifier: "en_US")
        var entry = MediaEntry(id: "sha256:a", path: "loops/Ocean loop.mov", kind: .video, size: 1_000_000, durationMs: 30_000, width: 1920, height: 1080,
                               hasAudio: true, hasAlpha: true, codec: "ProRes 4444")
        entry.defaults = MediaDefaults(trimInMs: 1500, loop: true, gain: -3, grade: 1, syncOffsetMs: 40, defaultChannel: 1)
        XCTAssertEqual(ImportWording.details(MediaItem(entry: entry), locale: english),
                       "Ocean loop.mov · 1920 × 1080 · 0:30 · ProRes 4444 · sound · alpha · trimmed · loops · gain -3 dB · grade 1 · sound offset 40 ms · channel 1")
        let still = MediaEntry(id: "sha256:b", path: "cross.png", kind: .image, size: 2000, width: 800, height: 600, hasAudio: false, hasAlpha: false)
        XCTAssertEqual(ImportWording.details(MediaItem(entry: still), locale: english), "cross.png · 800 × 600")
    }
}

/// Spec 8 §3, "Staged" — the app's copy of a dropped file, with real files under a temporary folder.
@MainActor
final class FileStagerTests: XCTestCase {
    private var folder = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUp() async throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("o-stager-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("outside"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("library/media"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func stage(_ stager: FileStager, _ path: String) -> Result<String, StagingError>? {
        let done = expectation(description: "staged")
        var result: Result<String, StagingError>?
        stager.stage(path) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return result
    }

    func test_aFileFromOutsideIsCopiedIntoTheStagingFolderAndOneInsideARootIsNot() throws {
        let staging = folder.appendingPathComponent("Staging")
        let library = folder.appendingPathComponent("library")
        let stager = FileStager(staging: staging) { [library] }
        let outside = folder.appendingPathComponent("outside/Ocean loop.mov")
        try Data("synthetic".utf8).write(to: outside)
        guard case .success(let staged)? = stage(stager, outside.path) else { return XCTFail("not staged") }
        XCTAssertTrue(FileStager.isInside(URL(fileURLWithPath: staged), staging), staged)
        XCTAssertEqual((staged as NSString).lastPathComponent, "Ocean loop.mov", "it keeps its name")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: staged)), Data("synthetic".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "a copy: the file stays where it was")
        // The same name again lands beside the first, not over it.
        guard case .success(let again)? = stage(stager, outside.path) else { return XCTFail("not staged") }
        XCTAssertNotEqual(again, staged)
        // "Already in the media root: indexed where it is".
        let inside = library.appendingPathComponent("media/dawn.mp4")
        try Data("synthetic".utf8).write(to: inside)
        XCTAssertEqual(stage(stager, inside.path), .success(inside.standardizedFileURL.path))
        // A folder goes whole.
        let easter = folder.appendingPathComponent("outside/Easter/Openers")
        try FileManager.default.createDirectory(at: easter, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: easter.appendingPathComponent("countdown.mov"))
        guard case .success(let copied)? = stage(stager, easter.deletingLastPathComponent().path) else { return XCTFail("not staged") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied + "/Openers/countdown.mov"))
    }

    func test_aCopyThatFailsSaysWhyInTheSystemsWords() throws {
        let stager = FileStager(staging: folder.appendingPathComponent("Staging")) { [] }
        guard case .failure(let error)? = stage(stager, folder.appendingPathComponent("outside/nothing.mov").path) else { return XCTFail("staged a file that isn't there") }
        XCTAssertFalse(error.message.isEmpty)
    }

    func test_theStagingFolderIsTheOneTheEngineEmpties() throws {
        let standard = try XCTUnwrap(FileStager.standardFolder)
        XCTAssertTrue(standard.path.hasSuffix("/Library/Application Support/Project O/Staging"), standard.path)
    }
}
