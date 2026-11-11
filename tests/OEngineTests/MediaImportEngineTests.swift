import Foundation
import OCore
import OFormats
import XCTest
@testable import OEngine

/// Spec 8 §3 — import in the engine, on a temporary copy of the fixture with
/// the seams of §11. Spec 8 §11, Import: "A file is hashed before it's copied.
/// A known hash isn't copied and comes back `known`; a replaced hash resolves
/// to its replacement; a missing or deleted item's own hash brings it back. A
/// name that a file or another entry holds, a missing entry included, gets a
/// numbered name. A dropped folder keeps its subfolders, skips hidden files
/// and refuses an unsupported file without stopping. Kinds come from the
/// content: a `.mov` with a codec v1 can't play is refused. The copy appears
/// only when complete and matches the hash; a file changed mid-import is
/// refused; a full volume refuses with `diskFull`. A staged file is moved in
/// and cleaned up, Staging is emptied at launch, and an unreadable PATH is
/// rejected with `unreadable`. Each row of §3's table holds, on both kinds of
/// machine." Logging: "An import's ... index changes raise the revision and
/// send `library` events with cause `media`, and aren't in the command log".
/// Spec 8 §7 — the `media` topic's states and outcomes.
final class MediaImportEngineTests: XCTestCase {
    typealias E = EngineFixtures

    func outcome(_ media: MediaFixture, _ file: String) -> [String: JSONValue]? {
        media.outcomes.last { $0["file"] == .string(file) }
    }

    func hiddenLeft(_ folder: URL) -> [String] {
        let names = FileManager.default.enumerator(atPath: folder.path)?.compactMap { $0 as? String } ?? []
        return names.filter { ($0 as NSString).lastPathComponent.contains(".importing") }
    }

    // MARK: - One file, start to finish

    /// "1. Staged ... The engine moves a staged file into place rather than
    /// copying it when it can, removes a staged file once its import is done"
    /// · "2. Hash first" · "5. Index ... writes the entry with empty defaults,
    /// `addedAt` and `folder`"; Spec 8 §7 — one event per state, then the outcome.
    func test_aStagedFileIsHashedFirstMovedInAndIndexed() throws {
        let media = try MediaFixture()
        let staged = try media.stage("Welcome.mov", "welcome video")
        let lines = media.control.commandLog.entries.count
        XCTAssertNil(media.importPath(staged))
        let id = MediaFixture.id("welcome video")
        let job = try XCTUnwrap(media.jobs.last)
        XCTAssertTrue(job.hasPrefix("j-") && job.count == 10, job)
        let states = media.events(ofJob: job).compactMap { $0["state"]?.stringValue }
        XCTAssertEqual(states.first, "hashing")
        XCTAssertLessThan(try XCTUnwrap(states.firstIndex(of: "hashing")), try XCTUnwrap(states.firstIndex(of: "copying")), "hashed before it's copied")
        XCTAssertEqual(states.last, "done")
        XCTAssertTrue(states.contains("reading"))
        let done = try XCTUnwrap(outcome(media, "Welcome.mov"))
        XCTAssertEqual(done["outcome"], .string("imported"))
        XCTAssertEqual(done["id"], .string(id))
        XCTAssertEqual(done["job"], .string(job))
        // The entry, its file, and the staged file gone.
        let entry = try XCTUnwrap(media.control.library.mediaIndex.entry(id))
        XCTAssertEqual(entry.path, "imports/Welcome.mov")
        XCTAssertEqual(entry.folder, "imports")
        XCTAssertEqual(entry.defaults, MediaDefaults())
        XCTAssertNotNil(entry.addedAt)
        XCTAssertEqual(entry.kind, .video)
        XCTAssertEqual(try Data(contentsOf: media.url(.mediaRoot, "imports/Welcome.mov")), Data("welcome video".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "a staged file is moved in")
        XCTAssertEqual(hiddenLeft(media.mediaRoot), [])
        XCTAssertFalse(media.control.missing.contains(id))
        // Logging: the import's line is in the command log; its index change isn't, and raised the revision once.
        XCTAssertEqual(media.control.commandLog.entries.count, lines + 1)
        XCTAssertEqual(media.control.commandLog.entries.last?.command, .media(.importFile(path: staged.standardizedFileURL.path)))
        XCTAssertEqual(media.control.revision, 2)
        XCTAssertEqual(media.mediaLibraryEvents.count, 1)
        XCTAssertEqual(media.writtenIndex()?.entry(id)?.path, "imports/Welcome.mov")
        XCTAssertEqual(LocalFiles.mediaCache(machineRoot: media.machineRoot).record(at: MediaLocation(.mediaRoot, "imports/Welcome.mov")!)?.hash, id,
                       "the cache knows the copy, so the walk its watcher starts doesn't hash it again")
    }

    /// "A known hash isn't copied and comes back `known`".
    func test_aKnownHashIsntCopied() throws {
        let media = try MediaFixture()
        let staged = media.staging.appendingPathComponent("dawn again.mp4")
        try FileManager.default.copyItem(at: media.url(.mediaRoot, "backgrounds/dawn.mp4"), to: staged)
        XCTAssertNil(media.importPath(staged))
        XCTAssertEqual(outcome(media, "dawn again.mp4")?["outcome"], .string("known"))
        XCTAssertEqual(outcome(media, "dawn again.mp4")?["id"], .string(E.dawn))
        XCTAssertFalse(media.exists(.mediaRoot, "imports/dawn again.mp4"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "the staged file is removed once its import is done")
        XCTAssertEqual(media.mediaLibraryEvents.count, 0)
    }

    /// "A hash that a `replaced` map names resolves to its replacement".
    func test_aReplacedHashResolvesToItsReplacement() throws {
        let media = try MediaFixture()
        let original = media.staging.appendingPathComponent("the old dawn.mp4")
        try FileManager.default.copyItem(at: media.url(.mediaRoot, "backgrounds/dawn.mp4"), to: original)
        try media.write(.mediaRoot, "backgrounds/dawn.mp4", "dawn, re-exported")
        media.walk()
        let new = MediaFixture.id("dawn, re-exported")
        XCTAssertEqual(media.control.library.mediaIndex.replaced[E.dawn], new)
        XCTAssertNil(media.importPath(original))
        XCTAssertEqual(outcome(media, "the old dawn.mp4")?["outcome"], .string("known"))
        XCTAssertEqual(outcome(media, "the old dawn.mp4")?["id"], .string(new))
    }

    /// "A deleted or missing item's own hash brings the item back: the file is
    /// copied in, and the entry takes the copy's path and keeps its defaults".
    func test_aMissingOrDeletedItemsOwnHashBringsItBack() throws {
        let media = try MediaFixture(prepare: { media in
            // The announcement, deleted (Spec 8 §6): pathless, with deletedAt, its file in the Trash.
            let url = media.machineRoot.appendingPathComponent("media-local.json")
            let text = try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: "\"path\": \"announcement.png\",", with: "\"path\": \"\",\n      \"deletedAt\": \"2026-11-10T09:00:00Z\",")
            try Data(text.utf8).write(to: url)
            try FileManager.default.moveItem(at: media.url(.machineMedia, "announcement.png"), to: media.staging.appendingPathComponent("announcement.png"))
        })
        // Staging is emptied at launch: put the files back there now.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: media.staging.path), [])
        XCTAssertEqual(media.control.machine.mediaLocal.entry(MediaFixture.announcement)?.isDeleted, true)
        let defaults = try XCTUnwrap(media.control.library.mediaIndex.entry(E.dawn)?.defaults)
        let dawn = media.staging.appendingPathComponent("dawn.mp4")
        try FileManager.default.moveItem(at: media.url(.mediaRoot, "backgrounds/dawn.mp4"), to: dawn)
        media.walk()
        XCTAssertTrue(media.control.missing.contains(E.dawn))
        XCTAssertNil(media.importPath(dawn))
        XCTAssertEqual(outcome(media, "dawn.mp4")?["outcome"], .string("imported"))
        XCTAssertEqual(media.control.library.mediaIndex.entry(E.dawn)?.path, "imports/dawn.mp4")
        XCTAssertEqual(media.control.library.mediaIndex.entry(E.dawn)?.defaults, defaults, "it keeps its defaults")
        XCTAssertFalse(media.control.missing.contains(E.dawn))
        // A deleted machine item.
        let announcement = try media.stage("announcement.png", "")
        try FileManager.default.removeItem(at: announcement)
        try FileManager.default.copyItem(at: EngineFixtures.fixtureRoot.appendingPathComponent("machine/media/announcement.png"), to: announcement)
        XCTAssertNil(media.importPath(announcement))
        let back = try XCTUnwrap(media.control.machine.mediaLocal.entry(MediaFixture.announcement))
        XCTAssertNil(back.deletedAt)
        XCTAssertEqual(back.path, "imports/announcement.png")
        XCTAssertTrue(media.exists(.machineMedia, "imports/announcement.png"))
        XCTAssertFalse(media.control.missing.contains(MediaFixture.announcement))
    }

    // MARK: - Names, folders, kinds

    /// "A name that a file holds, or that another entry's path holds even
    /// while its file is missing, gets a space and `2`, `3` and so on before
    /// its extension".
    func test_aNameAFileOrAMissingEntryHoldsGetsANumberedName() throws {
        let media = try MediaFixture()
        media.importPath(try media.stage("Welcome.mov", "welcome, take one"))
        media.importPath(try media.stage("Welcome.mov", "welcome, take two"))
        XCTAssertEqual(media.control.library.mediaIndex.entry(MediaFixture.id("welcome, take two"))?.path, "imports/Welcome 2.mov")
        // An entry whose file is missing still holds its name.
        media.importPath(try media.stage("Hymn.mov", "hymn, first"))
        try media.remove(.mediaRoot, "imports/Hymn.mov")
        media.walk()
        XCTAssertTrue(media.control.missing.contains(MediaFixture.id("hymn, first")))
        media.importPath(try media.stage("Hymn.mov", "hymn, second"))
        XCTAssertEqual(media.control.library.mediaIndex.entry(MediaFixture.id("hymn, second"))?.path, "imports/Hymn 2.mov")
    }

    /// "A dropped folder (M5) imports its files recursively and keeps its
    /// subfolders under the import folder ... Hidden files and folders are
    /// skipped, and a file v1 doesn't take is refused without stopping the rest."
    func test_aDroppedFolderKeepsItsSubfoldersSkipsHiddenAndRefusesUnsupported() throws {
        let media = try MediaFixture()
        try media.stage("Easter/Openers/countdown.mov", "the countdown")
        try media.stage("Easter/Closing.mov", "the closing")
        try media.stage("Easter/.secret.mov", "hidden")
        try media.stage("Easter/notes.txt", "a note")
        XCTAssertNil(media.importPath(media.staging.appendingPathComponent("Easter")))
        XCTAssertEqual(media.control.library.mediaIndex.entry(MediaFixture.id("the countdown"))?.path, "imports/Easter/Openers/countdown.mov")
        XCTAssertEqual(media.control.library.mediaIndex.entry(MediaFixture.id("the closing"))?.path, "imports/Easter/Closing.mov")
        XCTAssertEqual(outcome(media, "Easter/notes.txt")?["outcome"], .string("refused"))
        XCTAssertEqual(outcome(media, "Easter/notes.txt")?["reason"], .string("unsupported"))
        XCTAssertEqual(outcome(media, "Easter/notes.txt")?["format"], .string("plain text"))
        XCTAssertNil(media.mediaEvents.first { $0["file"]?.stringValue?.contains("secret") == true }, "hidden files are skipped")
        XCTAssertNil(media.control.library.mediaIndex.entry(MediaFixture.id("hidden")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.staging.appendingPathComponent("Easter/Openers").path), "the staged folder is cleaned up")
    }

    /// "Kinds come from the content: a `.mov` with a codec v1 can't play is refused."
    func test_aMovWithACodecV1CantPlayIsRefused() throws {
        let media = try MediaFixture()
        XCTAssertNil(media.importPath(try media.stage("Codec.mov", "UNSUPPORTED motion jpeg")))
        XCTAssertEqual(outcome(media, "Codec.mov")?["reason"], .string("unsupported"))
        XCTAssertEqual(outcome(media, "Codec.mov")?["format"], .string("jpeg video"))
        XCTAssertFalse(media.exists(.mediaRoot, "imports/Codec.mov"))
    }

    // MARK: - The copy

    /// "The copy is written under a hidden name and renamed when complete ...
    /// and is checked against the hash: a file that changes while it's
    /// imported is refused with `changed`", copied or moved.
    func test_aFileChangedMidImportIsRefused() throws {
        let media = try MediaFixture(beforeCopy: { url in
            guard url.lastPathComponent.hasPrefix("Changing") else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(" and more".utf8))
                try? handle.close()
            }
        })
        // Outside both folders and not staged: copied.
        let outside = media.folder.appendingPathComponent("Elsewhere/Changing.mov")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a changing file".utf8).write(to: outside)
        XCTAssertNil(media.importPath(outside))
        XCTAssertEqual(outcome(media, "Changing.mov")?["reason"], .string("changed"))
        XCTAssertFalse(media.exists(.mediaRoot, "imports/Changing.mov"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "a file outside Staging is never moved or removed")
        // Staged: moved, then found changed.
        XCTAssertNil(media.importPath(try media.stage("Changing staged.mov", "a changing staged file")))
        XCTAssertEqual(outcome(media, "Changing staged.mov")?["reason"], .string("changed"))
        XCTAssertFalse(media.exists(.mediaRoot, "imports/Changing staged.mov"))
        XCTAssertEqual(hiddenLeft(media.mediaRoot), [], "nothing half-written is left")
    }

    /// "An import that would leave less than 1 GB free on its volume is
    /// refused with `diskFull`"; a staged file moved within the volume takes no room.
    func test_aFullVolumeRefusesWithDiskFull() throws {
        let media = try MediaFixture()
        media.free.bytes = 900_000_000
        let outside = media.folder.appendingPathComponent("Elsewhere/Big.mov")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("a big video".utf8).write(to: outside)
        XCTAssertNil(media.importPath(outside))
        XCTAssertEqual(outcome(media, "Big.mov")?["reason"], .string("diskFull"))
        XCTAssertFalse(media.exists(.mediaRoot, "imports/Big.mov"))
        XCTAssertNil(media.importPath(try media.stage("Staged.mov", "a staged video")))
        XCTAssertEqual(outcome(media, "Staged.mov")?["outcome"], .string("imported"))
    }

    /// "The engine ... empties the folder at launch."
    func test_stagingIsEmptiedAtLaunch() throws {
        let media = try MediaFixture(prepare: { media in
            try media.stage("left over.mov", "from a run that ended")
            try media.stage("Folder/also.mov", "this too")
        })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: media.staging.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.staging.path), "the folder stays")
    }

    // MARK: - The command (Spec 8 §2, §3)

    /// "A `media import` sent from elsewhere names its own PATH; one the
    /// engine can't read is rejected with `unreadable`", and a PATH where
    /// media may not live is never touched (Spec 8 §2). Held by a cue, the
    /// refusal is `blocked` and logged.
    func test_anUnreadablePathIsRejected() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let media = try MediaFixture(places: MediaPlaces(home: home.path, isOnStartupVolume: { _ in true }))
        XCTAssertEqual(media.importPath(URL(fileURLWithPath: "/no/such/file.mov"))?.reason, .unreadable)
        XCTAssertEqual(media.run("media import \"relative/path.mov\"")?.reason, .unreadable)
        let downloads = home.appendingPathComponent("Downloads/Welcome.mov")
        try FileManager.default.createDirectory(at: downloads.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("in Downloads".utf8).write(to: downloads)
        XCTAssertEqual(media.importPath(downloads)?.reason, .unreadable, "a place macOS guards is never read")
        XCTAssertTrue(media.control.rejections.last?.message.contains("Downloads") == true)
        // Held by a cue: blocked, logged, and the rest of the group runs.
        XCTAssertNil(media.engine.send(group: ["media import \"/no/such/file.mov\"", "channel 1 clear"], source: .cue))
        media.settle()
        let lines = media.control.commandLog.entries.suffix(2)
        XCTAssertEqual(lines.first?.result, .blocked)
        XCTAssertEqual(lines.last?.command, .channelClear(channel: .number(1)))
    }

    /// Spec 8 §2 — "Operator lock refuses every media command but `media
    /// rebuild` with `operatorLock`".
    func test_operatorLockRefusesImportButNotRebuild() throws {
        let media = try MediaFixture(configure: { $0.settings.operatorLock.enabled = true })
        XCTAssertEqual(media.importPath(try media.stage("Locked.mov", "under the lock"))?.reason, .operatorLock)
        XCTAssertNil(media.run("media rebuild", source: .osc))
        XCTAssertEqual(media.control.commandLog.entries.last?.result, .ok)
    }

    // MARK: - §3's table, both kinds of machine

    func test_whereAnImportGoesOnAReadOnlyMachine() throws {
        let media = try MediaFixture(writable: false)
        // From outside both folders: copied into machine/media/; a machine entry.
        XCTAssertNil(media.importPath(try media.stage("Campus.mov", "the campus's video")))
        let id = MediaFixture.id("the campus's video")
        XCTAssertEqual(media.control.machine.mediaLocal.entry(id)?.path, "imports/Campus.mov")
        XCTAssertTrue(media.exists(.machineMedia, "imports/Campus.mov"))
        XCTAssertNil(media.control.library.mediaIndex.entry(id))
        // Already in the media root: `known` if the library index lists it, otherwise refused with `notListed`.
        XCTAssertNil(media.importPath(media.url(.mediaRoot, "backgrounds/dawn.mp4")))
        XCTAssertEqual(outcome(media, "dawn.mp4")?["outcome"], .string("known"))
        try media.write(.mediaRoot, "Unlisted.mov", "central hasn't indexed it")
        XCTAssertNil(media.importPath(media.url(.mediaRoot, "Unlisted.mov")))
        XCTAssertEqual(outcome(media, "Unlisted.mov")?["reason"], .string("notListed"))
        // Already in machine/media/: indexed where it is; a machine entry.
        try media.write(.machineMedia, "Here.mov", "already here")
        XCTAssertNil(media.importPath(media.url(.machineMedia, "Here.mov")))
        XCTAssertEqual(outcome(media, "Here.mov")?["outcome"], .string("imported"))
        XCTAssertEqual(media.control.machine.mediaLocal.entry(MediaFixture.id("already here"))?.path, "Here.mov")
        // The id of a missing library item: refused with `readOnlyLibrary`.
        let dawn = media.staging.appendingPathComponent("dawn.mp4")
        try FileManager.default.moveItem(at: media.url(.mediaRoot, "backgrounds/dawn.mp4"), to: dawn)
        media.walk()
        XCTAssertNil(media.importPath(dawn))
        XCTAssertEqual(outcome(media, "dawn.mp4")?["reason"], .string("readOnlyLibrary"))
        XCTAssertEqual(media.writtenIndex(), try XCTUnwrap(EngineFixtures.library().mediaIndex), "the library index is never written")
    }

    func test_whereAnImportGoesOnAWritableMachine() throws {
        let media = try MediaFixture()
        // Already in the media root: indexed where it is; a library entry.
        try media.write(.mediaRoot, "Sermon/Bumper.mov", "already in the media root")
        XCTAssertNil(media.importPath(media.url(.mediaRoot, "Sermon/Bumper.mov")))
        XCTAssertEqual(outcome(media, "Bumper.mov")?["outcome"], .string("imported"))
        XCTAssertEqual(media.control.library.mediaIndex.entry(MediaFixture.id("already in the media root"))?.path, "Sermon/Bumper.mov")
        // Already in machine/media/: indexed where it is; a machine entry.
        try media.write(.machineMedia, "Here.mov", "already here")
        XCTAssertNil(media.importPath(media.url(.machineMedia, "Here.mov")))
        XCTAssertEqual(media.control.machine.mediaLocal.entry(MediaFixture.id("already here"))?.path, "Here.mov")
        XCTAssertFalse(media.exists(.mediaRoot, "imports/Here.mov"), "nothing is copied")
    }
}
