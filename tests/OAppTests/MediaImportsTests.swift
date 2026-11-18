import Foundation
import XCTest
import OCore
@testable import OApp

/// A stager that copies nothing: it answers with a path in a staging folder
/// at once, or when the test says, or with a failure.
@MainActor
final class FakeStager: MediaStager {
    var staged: [String] = []
    var holds = false
    var failure: StagingError?
    private var waiting: [(String, @MainActor (Result<String, StagingError>) -> Void)] = []

    func stage(_ path: String, done: @escaping @MainActor (Result<String, StagingError>) -> Void) {
        staged.append(path)
        if holds { waiting.append((path, done)) } else { answer(path, done) }
    }

    private func answer(_ path: String, _ done: @MainActor (Result<String, StagingError>) -> Void) {
        if let failure { done(.failure(failure)) } else { done(.success("/staging/" + (path as NSString).lastPathComponent)) }
    }

    /// The copies that were waiting finish.
    func release() {
        let all = waiting
        waiting = []
        for (path, done) in all { answer(path, done) }
    }
}

/// Spec 10 §6, "Importing" and "Drops on the grid", §7, "Drops", and Spec 10
/// §18's lines on a file from the Finder (choice U-8).
@MainActor
final class MediaImportsTests: XCTestCase {
    typealias Rig = ShowModelTests.Rig

    @MainActor
    final class Importing {
        let rig: Rig
        let stager = FakeStager()
        var imports: MediaImports { rig.model.imports }

        init() throws {
            rig = try Rig()
            rig.model.imports.stager = stager
        }

        /// The engine answers the last `media import` with its job.
        func accept(job: String, at index: Int? = nil) {
            rig.answers[index ?? rig.answers.count - 1](.result(CommandOutcome(kind: .ok, job: job)))
        }

        func media(_ job: String, file: String, state: String, progress: Double? = nil, outcome: String? = nil, id: String? = nil, reason: String? = nil) {
            var event: [String: JSONValue] = ["topic": .string("media"), "op": .string("import"), "job": .string(job), "file": .string(file), "state": .string(state)]
            if let progress { event["progress"] = .number(progress) }
            if let outcome { event["outcome"] = .string(outcome) }
            if let id { event["id"] = .string(id) }
            if let reason { event["reason"] = .string(reason) }
            rig.store.apply(event: "media", event, now: rig.clock.now)
        }

        func lock() throws {
            var engine = try RecordedAPI.event("engine")
            engine["lock"] = .bool(true)
            rig.store.apply(event: "engine", engine, now: rig.clock.now)
        }
    }

    private let fresh = "sha256:" + String(repeating: "ab", count: 32)

    // MARK: - The pool

    func test_aFileDroppedOnThePoolIsStagedThenImportedAndItsRowFollowsTheJob() throws {
        let test = try Importing()
        XCTAssertNil(test.imports.importFiles(["/Users/x/Movies/Ocean loop.mov"]))
        XCTAssertEqual(test.stager.staged, ["/Users/x/Movies/Ocean loop.mov"], "copied to the staging folder first (Spec 8 §3)")
        XCTAssertEqual(test.rig.commands, [["media import \"/staging/Ocean loop.mov\""]], "and imported from there")
        XCTAssertEqual(test.rig.sent.first?.fields["source"], .string("ui"))
        XCTAssertEqual(test.imports.rows.map(\.name), ["Ocean loop.mov"])
        XCTAssertEqual(test.imports.rows.first?.state, .importing(progress: nil))
        test.accept(job: "j-1")
        test.media("j-1", file: "Ocean loop.mov", state: "copying", progress: 0.42)
        XCTAssertEqual(test.imports.rows.first?.state, .importing(progress: 0.42))
        test.media("j-1", file: "Ocean loop.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(test.imports.rows.first?.state, .done(known: false))
        XCTAssertEqual(test.rig.sent.count, 1, "nothing waited on it: nothing more is sent")
        // A row that ended well leaves by itself.
        test.rig.clock.advance(by: 5.1)
        XCTAssertEqual(test.imports.rows, [])
    }

    /// "keeps refusals, with their reasons, until dismissed".
    func test_aRefusalStaysInTheHeaderUntilItIsDismissed() throws {
        let test = try Importing()
        test.imports.importFiles(["/Users/x/notes.txt", "/Users/x/known.mov"])
        test.accept(job: "j-1", at: 0)
        test.accept(job: "j-2", at: 1)
        test.media("j-1", file: "notes.txt", state: "done", outcome: "refused", reason: "unsupported")
        test.media("j-2", file: "known.mov", state: "done", outcome: "known", id: fresh)
        XCTAssertEqual(test.imports.rows.map(\.state), [.refused("unsupported"), .done(known: true)])
        test.rig.clock.advance(by: 60)
        XCTAssertEqual(test.imports.rows.map(\.name), ["notes.txt"], "the refusal stays")
        XCTAssertTrue(test.imports.rows[0].staysUntilDismissed)
        test.imports.dismiss(row: test.imports.rows[0].id)
        XCTAssertEqual(test.imports.rows, [])
    }

    /// Spec 8 §3 — "A dropped folder (M5) imports its files recursively": one row until the engine names its files.
    func test_aDroppedFolderIsOneJobWhoseFilesEachGetARow() throws {
        let test = try Importing()
        test.imports.importFiles(["/Users/x/Easter"])
        XCTAssertEqual(test.imports.rows.map(\.name), ["Easter"])
        test.accept(job: "j-1")
        test.media("j-1", file: "Openers/countdown.mov", state: "copying", progress: 0.5)
        test.media("j-1", file: "cross.png", state: "done", outcome: "imported", id: fresh)
        test.media("j-1", file: "Openers/countdown.mov", state: "done", outcome: "refused", reason: "unsupported")
        XCTAssertEqual(test.imports.rows.map(\.name), ["Openers/countdown.mov", "cross.png"])
        XCTAssertEqual(test.imports.rows.map(\.state), [.refused("unsupported"), .done(known: false)])
    }

    func test_whatTheJobSaysBeforeItsResultNamesItIsNotLost() throws {
        let test = try Importing()
        test.imports.importFiles(["/Users/x/Ocean loop.mov"])
        test.media("j-1", file: "Ocean loop.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(test.imports.rows.first?.state, .importing(progress: nil), "the app doesn't know yet that the job is its own")
        test.accept(job: "j-1")
        XCTAssertEqual(test.imports.rows.first?.state, .done(known: false))
    }

    func test_aCopyThatFailsAnEngineThatRefusesAndNoEngineAreEachSaid() throws {
        let test = try Importing()
        test.stager.failure = StagingError("The disk is full.")
        test.imports.importFiles(["/Users/x/a.mov"])
        XCTAssertEqual(test.imports.rows.first?.state, .copyFailed("The disk is full."))
        XCTAssertEqual(test.rig.sent.count, 0)
        test.stager.failure = nil
        test.imports.importFiles(["/Users/x/b.mov"])
        test.rig.answers[0](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "unreadable", message: "can't open b.mov"))))
        XCTAssertEqual(test.imports.rows.last?.state, .refused("unreadable"))
        // The copy finishes after the engine has gone: nothing is sent, and nothing kept to send.
        test.stager.holds = true
        test.imports.importFiles(["/Users/x/c.mov"])
        test.rig.store.disconnected()
        XCTAssertEqual(test.imports.rows.last?.state, .engineAway)
        test.stager.release()
        XCTAssertEqual(test.rig.sent.count, 1)
        // Under the lock, and while the engine is away, nothing is started.
        XCTAssertEqual(test.imports.importFiles(["/Users/x/d.mov"]), .unavailable(.engineAway))
        try test.rig.connect()
        try test.lock()
        XCTAssertEqual(test.imports.importFiles(["/Users/x/d.mov"]), .unavailable(.locked), "Spec 8 §2: the lock refuses every media command")
        XCTAssertEqual(test.stager.staged.count, 3)
    }

    // MARK: - A file dropped on a cue (Spec 10 §6; §18, "commands")

    /// "a file from the Finder dropped on a cue and written once its import is done".
    func test_aFileDroppedOnACueIsWrittenIntoItOnceItsImportIsDone() throws {
        let test = try Importing()
        let (verse, section) = test.rig.cell(1, 0)
        let key = MediaImports.key(list: Recorded.list42, cue: verse.uuid)
        XCTAssertNil(test.imports.importFile("/Users/x/Movies/Ocean loop.mov", intoCue: verse, in: section, channel: 1))
        XCTAssertEqual(test.imports.cueNotes[key], .importing(row: 1, progress: nil), "the cell shows the import, with Cancel")
        XCTAssertTrue(test.imports.rows[0].canCancel)
        test.accept(job: "j-1")
        test.media("j-1", file: "Ocean loop.mov", state: "copying", progress: 0.6)
        XCTAssertEqual(test.imports.cueNotes[key], .importing(row: 1, progress: 0.6))
        XCTAssertEqual(test.rig.sent.count, 1, "nothing is written until the job's done names the item")
        test.media("j-1", file: "Ocean loop.mov", state: "done", outcome: "imported", id: fresh)
        // "the edit a pool tile's drop sends": the write on that channel, keeping what the cue's old write there carried.
        XCTAssertEqual(test.rig.commands.last, ["edit list 42 cue \(verse.uuid) channel 1 write media \(fresh) transition 2 1.0 once"])
        XCTAssertNil(test.imports.cueNotes[key], "and the cell has nothing more to say")
        XCTAssertEqual(test.imports.rows[0].state, .done(known: false))
    }

    /// "and not when the cue is gone or its write on that channel changed
    /// meanwhile"; "What isn't sent is said on the cell, or in the pool's
    /// header when the cell is gone."
    func test_nothingIsWrittenWhenTheCueIsGoneOrWhatItWritesThereChangedMeanwhile() throws {
        let test = try Importing()
        let (verse, section) = test.rig.cell(1, 0)
        let key = MediaImports.key(list: Recorded.list42, cue: verse.uuid)
        test.imports.importFile("/Users/x/a.mov", intoCue: verse, in: section, channel: 1)
        test.accept(job: "j-1")
        // Meanwhile another edit changes what the cue writes on channel 1.
        var answer = try RecordedAPI.load("list-42")
        var list = try XCTUnwrap(answer["list"]?.objectValue)
        var cues = try XCTUnwrap(list["cues"]?.arrayValue)
        var first = try XCTUnwrap(cues[0].objectValue)
        var commands = try XCTUnwrap(first["commands"]?.arrayValue)
        commands[0] = .object(["cmd": .string("channel.clear"), "channel": .number(1)])
        first["commands"] = .array(commands)
        cues[0] = .object(first)
        list["cues"] = .array(cues)
        answer["list"] = .object(list)
        test.rig.store.apply(list: answer)
        test.media("j-1", file: "a.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(test.rig.sent.count, 1, "nothing is written")
        XCTAssertEqual(test.imports.cueNotes[key], .notSent(.cueChanged(channel: 1)))
        XCTAssertEqual(test.imports.rows[0].state, .notSent(.cueChanged(channel: 1)), "and the pool's header keeps it")
        XCTAssertTrue(test.imports.rows[0].staysUntilDismissed)
        test.rig.clock.advance(by: 5.1)
        XCTAssertNil(test.imports.cueNotes[key], "the cell's word goes after a while; the header's stays")
        XCTAssertEqual(test.imports.rows.count, 1)

        // The cue is gone by the time the import is done.
        let (second, _) = test.rig.cell(1, 1)
        test.imports.importFile("/Users/x/b.mov", intoCue: second, in: section, channel: 2)
        test.accept(job: "j-2")
        cues.remove(at: 1)
        list["cues"] = .array(cues)
        answer["list"] = .object(list)
        test.rig.store.apply(list: answer)
        test.media("j-2", file: "b.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(test.rig.sent.count, 2, "the two imports, and no edit")
        XCTAssertEqual(test.imports.rows.last?.state, .notSent(.cueGone))
    }

    /// "A refusal shows its reason and writes nothing. Cancel drops the
    /// pending edit, and the import still finishes into the pool; the engine
    /// ending drops it too ..., so the cell says to drop the file again."
    func test_aRefusalACancelAndTheEngineEndingEachWriteNothing() throws {
        let test = try Importing()
        let (verse, section) = test.rig.cell(1, 0)
        let key = MediaImports.key(list: Recorded.list42, cue: verse.uuid)
        test.imports.importFile("/Users/x/a.txt", intoCue: verse, in: section, channel: 1)
        test.accept(job: "j-1")
        test.media("j-1", file: "a.txt", state: "done", outcome: "refused", reason: "unsupported")
        XCTAssertEqual(test.imports.cueNotes[key], .refused("unsupported"))
        XCTAssertEqual(test.rig.sent.count, 1)

        test.imports.importFile("/Users/x/b.mov", intoCue: verse, in: section, channel: 1)
        test.accept(job: "j-2")
        test.imports.cancel(row: try XCTUnwrap(test.imports.rows.last?.id))
        XCTAssertNil(test.imports.cueNotes[key], "Cancel: the cell lets go of it")
        test.media("j-2", file: "b.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(test.imports.rows.last?.state, .done(known: false), "the import still finishes into the pool")
        XCTAssertEqual(test.rig.sent.count, 2, "and no edit is sent")

        test.imports.importFile("/Users/x/c.mov", intoCue: verse, in: section, channel: 1)
        test.accept(job: "j-3")
        test.rig.store.disconnected()
        XCTAssertEqual(test.imports.cueNotes[key], .notSent(.engineEnded), "drop the file again")
        XCTAssertEqual(test.imports.rows.last?.state, .notSent(.engineEnded))
        try test.rig.connect()
        test.media("j-3", file: "c.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(test.rig.sent.count, 3, "what was dropped with the engine isn't sent to the next one")
    }

    func test_aCueThatCannotBeEditedTakesNoFile() throws {
        let test = try Importing()
        let (local, section) = test.rig.cell(2, 0)
        XCTAssertEqual(test.imports.importFile("/Users/x/a.mov", intoCue: local, in: section, channel: 1), .localCopy)
        try test.lock()
        let (verse, masters) = test.rig.cell(1, 0)
        XCTAssertEqual(test.imports.importFile("/Users/x/a.mov", intoCue: verse, in: masters, channel: 1), .unavailable(.locked), "any file under the lock is refused")
        XCTAssertEqual(test.stager.staged, [])
        XCTAssertEqual(test.imports.rows, [])
    }

    // MARK: - A file dropped on a strip cell (Spec 10 §7; §18, "the strip")

    /// "a file from the Finder dropped on a cell goes live only when its import is done".
    func test_aFileDroppedOnAStripCellGoesLiveOnlyWhenItsImportIsDone() throws {
        let test = try Importing()
        XCTAssertNil(test.imports.importFile("/Users/x/Movies/Ocean loop.mov", liveOn: 3))
        XCTAssertEqual(test.imports.stripNotes[3], .importing(row: 1, progress: nil))
        test.accept(job: "j-1")
        XCTAssertEqual(test.rig.sent.count, 1, "not yet")
        test.media("j-1", file: "Ocean loop.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(test.rig.commands.last, ["channel 3 write media \(fresh)"])
        XCTAssertEqual(test.rig.sent.last?.fields["source"], .string("ui"))
        XCTAssertNil(test.imports.stripNotes[3])
    }

    /// "and not when the channel's content changed meanwhile, the drop was
    /// cancelled or the engine ended"; "the cell then says so ("Not sent:
    /// channel 2 changed while importing"), and an import that finished stays in the pool."
    func test_nothingGoesLiveWhenTheChannelChangedTheDropWasCancelledOrTheEngineEnded() throws {
        let test = try Importing()
        test.imports.importFile("/Users/x/a.mov", liveOn: 3)
        test.accept(job: "j-1")
        // A cue writes channel 3 while the file is on its way in.
        test.rig.store.apply(event: "channels", ["topic": .string("channels"), "channel": .number(3), "state": .string("showing"),
                                                 "content": .object(["kind": .string("text"), "label": .string("9:41"), "fields": .object(["body": .string("9:41")])])],
                             now: test.rig.clock.now)
        test.media("j-1", file: "a.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(test.rig.sent.count, 1, "the live write isn't sent")
        XCTAssertEqual(test.imports.stripNotes[3], .notSent(.channelChanged(channel: 3)))
        XCTAssertEqual(test.imports.rows[0].state, .notSent(.channelChanged(channel: 3)), "the import that finished stays in the pool, and the header says what wasn't sent")

        test.imports.importFile("/Users/x/b.mov", liveOn: 1)
        test.accept(job: "j-2")
        test.imports.cancel(row: try XCTUnwrap(test.imports.rows.last?.id))
        test.media("j-2", file: "b.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(test.rig.sent.count, 2, "cancelled: nothing goes live")

        test.imports.importFile("/Users/x/c.mov", liveOn: 1)
        test.accept(job: "j-3")
        test.rig.store.disconnected()
        XCTAssertEqual(test.imports.stripNotes[1], .notSent(.engineEnded))
        try test.rig.connect()
        test.media("j-3", file: "c.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(test.rig.sent.count, 3)
    }

    /// A once-a-second position on the channel isn't a write: the content and what put it there are what is compared.
    func test_aChannelsPositionMovingIsNotAChangeOfItsContent() throws {
        let test = try Importing()
        let playing = try XCTUnwrap(test.rig.store.channels[1])
        var later = playing
        later.content?.positionMs = (playing.content?.positionMs ?? 0) + 1000
        XCTAssertEqual(ChannelStamp(playing), ChannelStamp(later))
        XCTAssertNotEqual(ChannelStamp(playing), ChannelStamp(test.rig.store.channels[2]))
        XCTAssertNotEqual(ChannelStamp(playing), ChannelStamp(nil))
    }

    // MARK: - Replace with… (Spec 10 §6; Spec 8 §6)

    func test_replaceImportsTheFileThenSendsMediaReplace() throws {
        let test = try Importing()
        let old = try XCTUnwrap(test.rig.store.media.first?.id)
        XCTAssertNil(test.imports.importFile("/Users/x/Ocean loop v2.mov", replacing: old))
        test.accept(job: "j-1")
        test.media("j-1", file: "Ocean loop v2.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(test.rig.commands.last, ["media replace \(old) \(fresh)"])
    }

    // MARK: - What a file's name suggests

    func test_aFilesTypeSuggestsItsDropChannel() throws {
        XCTAssertEqual(FileKind.suggested(forPath: "/x/Ocean loop.MOV"), .video)
        XCTAssertEqual(FileKind.suggested(forPath: "/x/cross.png"), .image)
        XCTAssertEqual(FileKind.suggested(forPath: "/x/walk-in.m4a"), .audio)
        XCTAssertNil(FileKind.suggested(forPath: "/x/notes.txt"))
        XCTAssertNil(FileKind.suggested(forPath: "/x/Easter"))
        let settings = try Recorded.catalog().settings
        XCTAssertEqual(FileKind.dropChannel(forPath: "/x/a.mp4", settings: settings), settings?.dropChannels?.video)
        XCTAssertEqual(FileKind.dropChannel(forPath: "/x/a.jpg", settings: settings), settings?.dropChannels?.image)
        XCTAssertNil(FileKind.dropChannel(forPath: "/x/a.wav", settings: settings), "audio asks, on first run's settings")
        XCTAssertNil(FileKind.dropChannel(forPath: "/x/a.txt", settings: settings))
    }
}
