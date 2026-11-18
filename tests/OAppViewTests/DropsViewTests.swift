import AppKit
import XCTest
import OCore
@testable import OApp
@testable import OAppUI

/// A clock the test moves, for the views: nothing here waits for time.
@MainActor
final class StepClock: AppClock {
    private(set) var now: TimeInterval = 1_000
    private final class Waiting: ClockTask {
        let at: TimeInterval
        var work: (@MainActor () -> Void)?
        init(at: TimeInterval, work: @escaping @MainActor () -> Void) {
            self.at = at
            self.work = work
        }
        func cancel() { work = nil }
    }
    private var waiting: [Waiting] = []

    @discardableResult
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> any ClockTask {
        let task = Waiting(at: now + max(0, seconds), work: work)
        waiting.append(task)
        return task
    }

    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let next = waiting.filter({ $0.work != nil && $0.at <= end }).min(by: { $0.at < $1.at }) {
            now = max(now, next.at)
            let work = next.work
            next.work = nil
            work?()
        }
        waiting.removeAll { $0.work == nil }
        now = end
    }
}

/// A stager that copies nothing and answers at once with a path in a staging folder.
@MainActor
final class InstantStager: MediaStager {
    var staged: [String] = []

    func stage(_ path: String, done: @escaping @MainActor (Result<String, StagingError>) -> Void) {
        staged.append(path)
        done(.success("/staging/" + (path as NSString).lastPathComponent))
    }
}

/// Spec 10 §6, "Drops on the grid", "Importing" and "A tile's menu", §7,
/// "Drops", and §10 — the drops and the pool's edits as the window's views
/// take them. A drag itself needs a screen and a pointer; what each view
/// carries, what it would do with what is let go on it, and what it then
/// shows are tested here.
@MainActor
final class DropsViewTests: XCTestCase {
    @MainActor
    final class Rig {
        let clock = StepClock()
        let store = ShowStore()
        let model: ShowModel
        let window: MainWindowController
        let stager = InstantStager()
        var sent: [EngineRequest] = []
        var answers: [(Reply?) -> Void] = []
        var asked: [Confirmation] = []
        var revealed: [URL] = []
        /// What the file dialog was asked for, and the files it answers with.
        var choices: [FileChoice] = []
        var chosen: [String] = []
        var view: ShowWindowView { window.regions }

        init() throws {
            model = ShowModel(store: store, clock: clock)
            window = MainWindowController(model: model, mach: nil, clock: clock)
            model.transmit = { [unowned self] request, answer in
                self.sent.append(request)
                self.answers.append(answer)
            }
            model.confirm = { [unowned self] confirmation, reply in
                self.asked.append(confirmation)
                reply(true)
            }
            model.imports.stager = stager
            model.imports.isFolder = { $0.hasSuffix("/Easter") }
            store.connected(Hello(api: Hello.api, engine: OCore.appVersion, pid: 1, machine: "7a7a", run: "51e2", mach: "org.lcbc.projecto.engine.51e2"))
            store.apply(catalog: try ShowWindowTests.Rig.load("catalog"))
            store.apply(media: try ShowWindowTests.Rig.load("media"))
            for name in ["list-42", "list-7", "list-local"] { store.apply(list: try ShowWindowTests.Rig.load(name)) }
            store.apply(state: try ShowWindowTests.Rig.load("state"), now: clock.now)
            view.machineRoot = URL(fileURLWithPath: "/tmp/o/machine")
            view.chooseFiles = { [unowned self] choice, answer in
                self.choices.append(choice)
                answer(self.chosen)
            }
            view.reveal = { [unowned self] url in self.revealed.append(url) }
            view.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
            view.refreshAll()
            view.layoutSubtreeIfNeeded()
        }

        var commands: [[String]] {
            sent.map { request in
                let values = request.fields["commands"]?.arrayValue ?? request.fields["command"].map { [$0] } ?? []
                return values.compactMap { (try? JSONCoding.decode(Command.self, from: $0)).flatMap(CommandText.print) }
            }
        }

        func lock(_ on: Bool = true) throws {
            var engine = try XCTUnwrap(try ShowWindowTests.Rig.load("events")["engine"]?.objectValue)
            engine["lock"] = .bool(on)
            store.apply(event: "engine", engine, now: clock.now)
        }

        func cell(_ label: String, at index: Int = 0, file: StaticString = #filePath, line: UInt = #line) throws -> CueCellView {
            let found = view.grid.document.cells.filter { $0.cell.label == label }
            return try XCTUnwrap(found.indices.contains(index) ? found[index] : nil, label, file: file, line: line)
        }

        func tile(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> PoolTileView {
            try XCTUnwrap(view.pool.tiles.first { $0.name.stringValue == name }, name, file: file, line: line)
        }

        func stripCell(_ channel: Int, file: StaticString = #filePath, line: UInt = #line) throws -> StripCellView {
            try XCTUnwrap(view.strip.cells.first { $0.cell.number == channel }, "channel \(channel)", file: file, line: line)
        }

        /// The engine answers a `media import` with its job.
        func accept(job: String, at index: Int? = nil) {
            answers[index ?? answers.count - 1](.result(CommandOutcome(kind: .ok, job: job)))
        }

        func media(_ job: String, file: String, state: String, progress: Double? = nil, outcome: String? = nil, id: String? = nil, reason: String? = nil) {
            var event: [String: JSONValue] = ["topic": .string("media"), "op": .string("import"), "job": .string(job), "file": .string(file), "state": .string(state)]
            if let progress { event["progress"] = .number(progress) }
            if let outcome { event["outcome"] = .string(outcome) }
            if let id { event["id"] = .string(id) }
            if let reason { event["reason"] = .string(reason) }
            store.apply(event: "media", event, now: clock.now)
        }

        func key(_ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
    }

    override func setUp() async throws {
        try await MainActor.run { try ViewStrings.install() }
    }

    private let fresh = "sha256:" + String(repeating: "ab", count: 32)
    private let english = Locale(identifier: "en_US")

    // MARK: - A tile on a cue (Spec 10 §6, §10)

    /// "A pool tile dropped on a cue (S7) opens a popover of channels with
    /// the item's drop channel picked (§6). Return or a click sends one
    /// `edit.cueChannel` writing the item on that channel".
    func test_aTileLetGoOnACueOpensTheChannelsAndReturnOrAClickWritesIt() throws {
        let rig = try Rig()
        let tile = try rig.tile("dawn.mp4")
        let id = tile.tile.id
        XCTAssertEqual(tile.dragPayload, .media(id), "what a drag of the tile carries")
        let verse = try rig.cell("Verse 1")
        XCTAssertTrue(verse.accept(tile.dragPayload))
        let list = try XCTUnwrap(rig.view.picker, "the list of channels opens")
        XCTAssertEqual(list.heading.stringValue, "Write “dawn.mp4” into cue 1 on")
        XCTAssertEqual(list.titles, ["1 Background", "2 Foreground", "3 Clock"])
        XCTAssertEqual(list.picked, 1, "its drop channel is picked")
        XCTAssertEqual(rig.sent.count, 0, "nothing is sent until a channel is chosen")
        XCTAssertTrue(rig.view.hasPopover)
        XCTAssertTrue(rig.window.keyTap.context().sheet, "while it is open the show keys wait (§9)")
        XCTAssertEqual(Audit.unlabelled(in: list), [])
        // Return sends, on the picked channel.
        list.keyDown(with: try rig.key(36))
        XCTAssertEqual(rig.commands, [["edit list 42 cue \(verse.cell.uuid) channel 1 write media \(id) transition 2 1.0 once"]])
        XCTAssertNil(rig.view.picker, "and the list closes")
        XCTAssertFalse(rig.view.hasPopover)

        // The arrows move the pick; a click on a channel sends on that one.
        XCTAssertTrue(try rig.cell("Verse 1").accept(.media(id)))
        let again = try XCTUnwrap(rig.view.picker)
        again.keyDown(with: try rig.key(125))
        XCTAssertEqual(again.picked, 2)
        again.keyDown(with: try rig.key(125))
        again.keyDown(with: try rig.key(125))
        XCTAssertEqual(again.picked, 3, "the pick stops at the last channel")
        again.keyDown(with: try rig.key(126))
        XCTAssertEqual(again.picked, 2)
        again.rows[2].press()
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue \(verse.cell.uuid) channel 3 write media \(id)"])

        // Escape closes it and sends nothing.
        XCTAssertTrue(try rig.cell("Verse 1").accept(.media(id)))
        try XCTUnwrap(rig.view.picker).keyDown(with: try rig.key(53))
        XCTAssertNil(rig.view.picker)
        XCTAssertEqual(rig.sent.count, 2)
    }

    func test_anItemWithNoDropChannelWaitsForAPick() throws {
        let rig = try Rig()
        // A slide's own channel is 2; a sound file's kind asks on this machine.
        XCTAssertTrue(try rig.cell("Verse 1").accept(.files(["/x/walk-in.wav"])))
        let list = try XCTUnwrap(rig.view.picker)
        XCTAssertNil(list.picked, "audio asks, on first run's settings")
        list.keyDown(with: try rig.key(36))
        XCTAssertNotNil(rig.view.picker, "Return waits for a pick")
        XCTAssertEqual(rig.stager.staged, [])
        list.keyDown(with: try rig.key(125))
        XCTAssertEqual(list.picked, 1)
        list.keyDown(with: try rig.key(36))
        XCTAssertEqual(rig.commands, [["media import \"/staging/walk-in.wav\""]])
    }

    // MARK: - A file on a cue (Spec 10 §6; choice U-8)

    /// "the cell shows the import's progress from the `media` topic, by the
    /// `job` its result names, with Cancel ... Cancel drops the pending
    /// edit, and the import still finishes into the pool".
    func test_aFileLetGoOnACueShowsItsImportOnTheCellWithCancel() throws {
        let rig = try Rig()
        let verse = try rig.cell("Verse 1")
        XCTAssertTrue(verse.accept(.files(["/Users/x/Movies/Ocean loop.mov"])))
        let list = try XCTUnwrap(rig.view.picker)
        XCTAssertEqual(list.heading.stringValue, "Import “Ocean loop.mov” and write it into cue 1 on")
        XCTAssertEqual(list.picked, 1, "the drop channel for the kind the file's type suggests")
        XCTAssertEqual(rig.stager.staged, [], "nothing is copied until a channel is chosen")
        list.choose(1)
        XCTAssertEqual(rig.commands, [["media import \"/staging/Ocean loop.mov\""]])
        XCTAssertEqual(verse.dropNote.text, "Importing…")
        XCTAssertFalse(verse.dropNote.cancel.isHidden, "with Cancel")
        rig.accept(job: "j-1")
        rig.media("j-1", file: "Ocean loop.mov", state: "copying", progress: 0.42)
        XCTAssertEqual(verse.dropNote.text, ImportWording.note(.importing(row: 1, progress: 0.42)))
        XCTAssertEqual(rig.view.grid.document.cells.first, verse, "the cells stay as they are while a drop's word changes")
        XCTAssertEqual(rig.view.pool.jobs.map(\.label.stringValue), [ImportWording.row(ImportRow(id: 1, name: "Ocean loop.mov", state: .importing(progress: 0.42)))])
        XCTAssertEqual(rig.view.pool.jobs.first?.button.title, "Cancel", "the pool's header offers it too")
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(Audit.unlabelled(in: verse), [])
        verse.dropNote.cancel.press()
        XCTAssertEqual(verse.dropNote.text, "", "Cancel: the cell lets go of it")
        XCTAssertEqual(rig.view.pool.jobs.first?.button.isHidden, true, "the import goes on, with nothing waiting on it")
        rig.media("j-1", file: "Ocean loop.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(rig.view.pool.jobs.map(\.label.stringValue), ["Ocean loop.mov: imported"])
        XCTAssertEqual(rig.sent.count, 1, "and no edit is sent")

        // Left alone, the same drop writes the cue once the job's done names the item.
        XCTAssertTrue(try rig.cell("Verse 1").accept(.files(["/Users/x/Movies/Ocean loop.mov"])))
        try XCTUnwrap(rig.view.picker).choose(1)
        rig.accept(job: "j-2")
        rig.media("j-2", file: "Ocean loop.mov", state: "done", outcome: "known", id: fresh)
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue \(verse.cell.uuid) channel 1 write media \(fresh) transition 2 1.0 once"])
        XCTAssertEqual(try rig.cell("Verse 1").dropNote.text, "")
    }

    /// "A refusal shows its reason and writes nothing"; "several files, or a
    /// folder, are refused there, and the cell says to drop them on the
    /// pool"; and under the lock a cue takes nothing (§12).
    func test_whatACueRefusesItSaysOnItsCell() throws {
        let rig = try Rig()
        let verse = try rig.cell("Verse 1")
        XCTAssertTrue(verse.accept(.files(["/x/a.mov", "/x/b.mov"])), "they may be let go there")
        XCTAssertNil(rig.view.picker)
        XCTAssertEqual(verse.dropNote.text, "Drop several files, or a folder, on the pool.")
        XCTAssertTrue(verse.dropNote.cancel.isHidden)
        XCTAssertTrue(verse.accept(.files(["/x/Easter"])))
        XCTAssertEqual(verse.dropNote.text, "Drop several files, or a folder, on the pool.")
        rig.clock.advance(by: 5.1)
        XCTAssertEqual(verse.dropNote.text, "", "for a few seconds")
        // The engine refuses the file.
        XCTAssertTrue(verse.accept(.files(["/x/notes.txt"])))
        try XCTUnwrap(rig.view.picker).choose(2)
        rig.accept(job: "j-1")
        rig.media("j-1", file: "notes.txt", state: "done", outcome: "refused", reason: "unsupported")
        XCTAssertEqual(verse.dropNote.text, "Not imported. Project O can’t play this kind of file.")
        XCTAssertEqual(rig.sent.count, 1)
        XCTAssertEqual(rig.view.pool.jobs.first?.button.title, "Dismiss", "the pool's header keeps the refusal until it is dismissed")
        // Under the lock.
        try rig.lock()
        let locked = try rig.cell("Verse 1")
        XCTAssertTrue(locked.accept(.media(try rig.tile("dawn.mp4").tile.id)))
        XCTAssertNil(rig.view.picker)
        XCTAssertEqual(locked.dropNote.text, "Not sent. " + UnavailableWording.sentence(for: .locked))
        XCTAssertTrue(locked.accept(.files(["/x/c.mov"])))
        XCTAssertEqual(rig.stager.staged, ["/x/notes.txt"], "any file under the lock is refused")
        // A list is nothing a cue takes.
        XCTAssertFalse(locked.accept(.list(EditsViewTests.list42)))
    }

    // MARK: - The strip (Spec 10 §7, "Drops"; §18, "browsing and firing", "the strip")

    /// "a cell takes the tile only once it has hovered there for 0.3
    /// seconds, showing the live red and "Goes live on 2 Foreground"
    /// meanwhile, so a drag that overshoots a cue doesn't go to air."
    func test_aStripCellTakesATileOnlyOnceItHasHeldItForItsWait() throws {
        let rig = try Rig()
        let strip = rig.view.strip
        let id = try rig.tile("dawn.mp4").tile.id
        XCTAssertEqual(strip.dragOver(.media(id), channel: 2), .live(media: id, channel: 2))
        XCTAssertEqual(try rig.stripCell(2).dropNote.text, "Goes live on 2 Foreground")
        XCTAssertEqual(try rig.stripCell(2).outline, Palette.live, "the live red")
        XCTAssertEqual(try rig.stripCell(1).dropNote.text, "")
        rig.clock.advance(by: 0.29)
        XCTAssertFalse(strip.drop(.media(id), channel: 2), "let go too soon: nothing goes to air")
        XCTAssertEqual(rig.sent.count, 0)
        XCTAssertEqual(try rig.stripCell(2).dropNote.text, "", "and the cell says nothing more")

        // Held for its wait, through the cells being made again as the channels change.
        strip.dragOver(.media(id), channel: 2)
        rig.clock.advance(by: 0.2)
        strip.refresh()
        XCTAssertEqual(try rig.stripCell(2).dropNote.text, "Goes live on 2 Foreground", "the new cell says it still")
        strip.dragOver(.media(id), channel: 2)
        rig.clock.advance(by: 0.11)
        XCTAssertTrue(strip.drop(.media(id), channel: 2))
        XCTAssertEqual(rig.commands, [["channel 2 write media \(id)"]], "a live write from the pool, on the cell it was let go on")
        XCTAssertEqual(rig.sent.first?.fields["source"], .string("ui"))

        // Moving to another cell starts the wait again; leaving the strip ends it.
        strip.dragOver(.media(id), channel: 2)
        rig.clock.advance(by: 0.2)
        strip.dragOver(.media(id), channel: 3)
        XCTAssertEqual(try rig.stripCell(2).dropNote.text, "")
        XCTAssertEqual(try rig.stripCell(3).dropNote.text, "Goes live on 3 Clock")
        rig.clock.advance(by: 0.2)
        XCTAssertFalse(strip.drop(.media(id), channel: 3))
        strip.dragOver(.media(id), channel: 1)
        strip.dragLeft()
        XCTAssertEqual(try rig.stripCell(1).dropNote.text, "")
        XCTAssertNil(strip.hovering)
        XCTAssertEqual(rig.sent.count, 1)

        // Where a cell is, for the pointer.
        rig.view.layoutSubtreeIfNeeded()
        let second = try rig.stripCell(2)
        XCTAssertEqual(strip.channel(at: strip.convert(NSPoint(x: second.bounds.midX, y: second.bounds.midY), from: second)), 2)
        XCTAssertNil(strip.channel(at: NSPoint(x: 10, y: 10)), "the strip's header is no cell")
    }

    /// "A file from the Finder is taken the same way, saying "Goes live on 2
    /// Foreground when imported" ... Nothing is sent if a write or a clear
    /// has reached the channel since the drop ...; the cell then says so".
    func test_aFileOnAStripCellGoesLiveWhenImportedAndTheCellSaysWhatWasNotSent() throws {
        let rig = try Rig()
        let strip = rig.view.strip
        strip.dragOver(.files(["/x/a.mov"]), channel: 2)
        XCTAssertEqual(try rig.stripCell(2).dropNote.text, "Goes live on 2 Foreground when imported")
        rig.clock.advance(by: 0.31)
        XCTAssertTrue(strip.drop(.files(["/x/a.mov"]), channel: 2))
        XCTAssertEqual(rig.commands, [["media import \"/staging/a.mov\""]])
        XCTAssertEqual(try rig.stripCell(2).dropNote.text, "Importing…")
        XCTAssertFalse(try rig.stripCell(2).dropNote.cancel.isHidden)
        rig.accept(job: "j-1")
        // A cue writes channel 2 while the file is on its way in.
        rig.store.apply(event: "channels", ["topic": .string("channels"), "channel": .number(2), "state": .string("showing"),
                                            "content": .object(["kind": .string("text"), "label": .string("Welcome"), "fields": .object(["body": .string("Welcome")])])],
                        now: rig.clock.now)
        rig.media("j-1", file: "a.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(rig.sent.count, 1, "the live write isn't sent")
        XCTAssertEqual(try rig.stripCell(2).dropNote.text, "Not sent: channel 2 changed while importing")
        XCTAssertEqual(rig.view.pool.jobs.first?.label.stringValue, "a.mov: imported. Not sent: channel 2 changed while importing")

        // Left alone, it goes live when its import is done.
        strip.dragOver(.files(["/x/b.mov"]), channel: 3)
        rig.clock.advance(by: 0.31)
        XCTAssertTrue(strip.drop(.files(["/x/b.mov"]), channel: 3))
        rig.accept(job: "j-2")
        XCTAssertEqual(rig.sent.count, 2, "not before")
        rig.media("j-2", file: "b.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(rig.commands.last, ["channel 3 write media \(fresh)"])
        XCTAssertEqual(try rig.stripCell(3).dropNote.text, "")

        // "several files, a folder, or any file under the lock are refused": said on the cell, with no wait.
        XCTAssertTrue(strip.drop(.files(["/x/a.mov", "/x/b.mov"]), channel: 1))
        XCTAssertEqual(try rig.stripCell(1).dropNote.text, "Drop several files, or a folder, on the pool.")
        XCTAssertEqual(strip.dragOver(.files(["/x/Easter"]), channel: 1), .refused(.dropOnThePool))
        XCTAssertNil(strip.hovering, "a refused drop says nothing of going live")
        try rig.lock()
        XCTAssertTrue(rig.view.strip.drop(.files(["/x/c.mov"]), channel: 1))
        XCTAssertEqual(try rig.stripCell(1).dropNote.text, "Not sent. " + UnavailableWording.sentence(for: .locked))
        XCTAssertEqual(rig.sent.count, 3)
        // "drops of pool tiles on the strip ... all work" under the lock (§12).
        let id = try rig.tile("cross.png").tile.id
        rig.view.strip.dragOver(.media(id), channel: 3)
        rig.clock.advance(by: 0.31)
        XCTAssertTrue(rig.view.strip.drop(.media(id), channel: 3))
        XCTAssertEqual(rig.commands.last, ["channel 3 write media \(id)"])
    }

    // MARK: - The pool (Spec 10 §6, "Importing", "The header")

    /// "The header shows the jobs as the `media` topic reports them, each
    /// file's progress and outcome, and keeps refusals, with their reasons,
    /// until dismissed."
    func test_filesLetGoOnThePoolAreImportedAndItsHeaderListsThem() throws {
        let rig = try Rig()
        let pool = rig.view.pool
        XCTAssertTrue(pool.accept(.files(["/x/Ocean loop.mov", "/x/notes.txt"])))
        XCTAssertEqual(rig.commands, [["media import \"/staging/Ocean loop.mov\""], ["media import \"/staging/notes.txt\""]])
        XCTAssertEqual(pool.jobs.map(\.label.stringValue), ["Ocean loop.mov: importing…", "notes.txt: importing…"])
        XCTAssertEqual(pool.jobs.map(\.button.isHidden), [true, true], "nothing waits on them: nothing to cancel")
        rig.accept(job: "j-1", at: 0)
        rig.accept(job: "j-2", at: 1)
        rig.media("j-2", file: "notes.txt", state: "done", outcome: "refused", reason: "unsupported")
        rig.media("j-1", file: "Ocean loop.mov", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(pool.jobs.map(\.label.stringValue), ["notes.txt: not imported. Project O can’t play this kind of file.", "Ocean loop.mov: imported"],
                       "what must be read comes first")
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(Audit.unlabelled(in: pool), [])
        XCTAssertGreaterThan(pool.rail.frame.minY, PoolView.headerHeight, "the imports sit between the header and the tiles")
        rig.clock.advance(by: 5.1)
        XCTAssertEqual(pool.jobs.map(\.row.name), ["notes.txt"], "what ended well leaves by itself; the refusal stays")
        pool.jobs[0].button.press()
        XCTAssertEqual(pool.jobs.count, 0)
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(pool.rail.frame.minY, PoolView.headerHeight)

        // More than the header has room for.
        XCTAssertTrue(pool.accept(.files((1...5).map { "/x/\($0).txt" })))
        for index in 2...6 { rig.answers[index](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "unreadable", message: "")))) }
        XCTAssertEqual(pool.jobs.count, 3)
        XCTAssertEqual(pool.moreJobs.stringValue, "2 more")
        XCTAssertFalse(pool.dismissAll.isHidden)
        pool.dismissAll.press()
        XCTAssertEqual(pool.jobs.count, 0)
        XCTAssertTrue(pool.moreJobs.isHidden)
        // A tile is already in the pool, and a list is nothing it takes.
        XCTAssertFalse(pool.accept(.media(fresh)))
        XCTAssertFalse(pool.accept(.list(EditsViewTests.list42)))
    }

    /// "Import… (⌘I, a file dialog)"; the lock disables imports (§12).
    func test_importOpensAFileDialogAndImportsWhatIsChosen() throws {
        let rig = try Rig()
        let pool = rig.view.pool
        XCTAssertTrue(pool.importMedia.isEnabled)
        rig.chosen = ["/x/b.mov", "/x/Easter"]
        pool.importMedia.press()
        XCTAssertEqual(rig.choices, [.importMedia])
        XCTAssertEqual(rig.commands, [["media import \"/staging/b.mov\""], ["media import \"/staging/Easter\""]], "files and folders, each a job")
        // Cancel in the dialog chooses nothing.
        rig.chosen = []
        rig.view.importMedia()
        XCTAssertEqual(rig.sent.count, 2)
        try rig.lock()
        XCTAssertFalse(rig.view.pool.importMedia.isEnabled)
        XCTAssertEqual(rig.view.pool.importMedia.reason, UnavailableWording.sentence(for: .locked))
        rig.chosen = ["/x/c.mov"]
        rig.view.importMedia()
        XCTAssertEqual(rig.choices.count, 2, "no dialog opens under the lock")
        XCTAssertEqual(rig.view.pool.notice.stringValue, "Not sent. " + UnavailableWording.sentence(for: .locked))
        XCTAssertTrue(rig.view.pool.accept(.files(["/x/d.mov"])), "files may be let go on the pool, which says why nothing is imported")
        XCTAssertEqual(rig.sent.count, 2)
    }

    /// "A tile's menu: Fire to Channel N (its drop channel); Fire to… (a
    /// channel); Defaults… ...; Replace with… ...; Reveal in Finder; Delete… (§10)."
    func test_aTilesMenuFiresReplacesRevealsAndDeletes() throws {
        let rig = try Rig()
        let tile = try rig.tile("dawn.mp4")
        let id = tile.tile.id
        let menu = try XCTUnwrap(tile.menuNow)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Fire to Channel 1 Background", "Fire to…", "Defaults…", "Replace with…", "Reveal in Finder", "Delete…"])
        try XCTUnwrap(menu.entry("Fire to Channel 3 Clock")).choose()
        XCTAssertEqual(rig.commands, [["channel 3 write media \(id)"]])
        // Reveal in Finder: the file under the media root.
        try XCTUnwrap(menu.entry("Reveal in Finder")).choose()
        let root = try XCTUnwrap(rig.model.mediaRoot(machineRoot: URL(fileURLWithPath: "/tmp/o/machine")))
        XCTAssertEqual(rig.revealed.map(\.path), [root.path + "/backgrounds/dawn.mp4"])
        // "Replace with… (a file dialog: the app imports the file and sends `media replace OLD NEW` when the import's `done` names the new id".
        rig.chosen = ["/x/dawn v2.mp4"]
        try XCTUnwrap(menu.entry("Replace with…")).choose()
        XCTAssertEqual(rig.choices, [.replace(name: "dawn.mp4")])
        XCTAssertEqual(rig.commands.last, ["media import \"/staging/dawn v2.mp4\""])
        rig.accept(job: "j-1")
        rig.media("j-1", file: "dawn v2.mp4", state: "done", outcome: "imported", id: fresh)
        XCTAssertEqual(rig.commands.last, ["media replace \(id) \(fresh)"])
        // "Delete… on a pool tile asks `mediaUse` first".
        try XCTUnwrap(menu.entry("Delete…")).choose()
        XCTAssertEqual(rig.sent.last?.fields["what"], .string("mediaUse"))
        rig.answers[rig.answers.count - 1](.answer(try ShowWindowTests.Rig.load("mediaUse")))
        XCTAssertEqual(rig.asked, [.deleteMedia(name: "dawn.mp4", use: MediaUseCount(cues: 1))])
        XCTAssertEqual(rig.commands.last, ["media delete \(id)"])
        // A missing item fires nowhere and has nothing to reveal.
        let missing = try XCTUnwrap(try rig.tile("mountains.mp4").menuNow)
        XCTAssertEqual(missing.entry("Reveal in Finder")?.isEnabled, false)
        XCTAssertEqual(missing.items.first?.isEnabled, false)
        // The rail's menu offers Reveal in Finder, and nothing that makes, renames or moves a folder.
        let folder = try XCTUnwrap(rig.view.pool.rail.rows.first { $0.title.stringValue == "backgrounds" })
        let railMenu = try XCTUnwrap(folder.menuNow)
        XCTAssertEqual(railMenu.items.map(\.title), ["Reveal in Finder"])
        try XCTUnwrap(railMenu.entry("Reveal in Finder")).choose()
        XCTAssertEqual(rig.revealed.last?.path, root.path + "/backgrounds")
    }

    /// "Defaults… (a popover editing its trim in and out, loop, gain, grade,
    /// sync offset and default channel, each an `edit media sha256:… defaults.FIELD` edit, Spec 8 §5)".
    func test_theDefaultsPanelSendsTheFieldsThatChanged() throws {
        let rig = try Rig()
        let tile = try rig.tile("dawn.mp4")
        let id = tile.tile.id
        try XCTUnwrap(tile.menuNow?.entry("Defaults…")).choose()
        let made = try XCTUnwrap(rig.view.defaultsPanel)
        XCTAssertEqual(made.panel.heading.stringValue, "Defaults of “dawn.mp4”")
        XCTAssertEqual(made.trimIn.stringValue, "")
        XCTAssertEqual(made.loop.state, .on, "dawn.mp4 loops")
        XCTAssertEqual(made.channel.titleOfSelectedItem, "1 Background")
        XCTAssertEqual(made.grade.titleOfSelectedItem, "None")
        XCTAssertEqual(Audit.unlabelled(in: made.panel), [])
        // What isn't a number is said, and nothing is sent.
        made.gain.stringValue = "loud"
        made.panel.commit()
        XCTAssertEqual(made.panel.shownProblem, "Type a number, or leave it empty.")
        XCTAssertEqual(rig.sent.count, 0)
        XCTAssertNotNil(rig.view.prompt)
        made.trimIn.stringValue = "1.5"
        made.loop.state = .off
        made.gain.stringValue = "-6"
        made.grade.selectItem(at: 1)
        made.channel.selectItem(at: 0)
        made.panel.commit()
        let grade = try XCTUnwrap(rig.store.catalog?.grades.sorted { $0.number < $1.number }.first?.number)
        XCTAssertEqual(rig.commands, [["edit media \(id) defaults.trimInMs 1500", "edit media \(id) defaults.loop false", "edit media \(id) defaults.gain -6",
                                       "edit media \(id) defaults.grade \(grade)", "edit media \(id) defaults.defaultChannel null"]])
        XCTAssertNil(rig.view.prompt, "the panel closes")
        XCTAssertNil(rig.view.defaultsPanel)
        // The item's own defaults show when it has them.
        try XCTUnwrap(try rig.tile("announcement.png").menuNow?.entry("Defaults…")).choose()
        let own = try XCTUnwrap(rig.view.defaultsPanel)
        own.panel.commit()
        XCTAssertEqual(rig.sent.count, 1, "saved unchanged: nothing is sent")
    }

    /// "Single click selects and shows the item's size, duration, codec, sound and alpha, and its defaults, in the header."
    func test_aClickOnATileShowsItsDetailsInTheHeader() throws {
        let rig = try Rig()
        XCTAssertTrue(rig.view.pool.details.isHidden)
        try rig.tile("dawn.mp4").onClick?(1, NSEvent())
        let item = try XCTUnwrap(rig.store.media.first { $0.entry.path.hasSuffix("dawn.mp4") })
        XCTAssertFalse(rig.view.pool.details.isHidden)
        XCTAssertEqual(rig.view.pool.details.stringValue, ImportWording.details(item))
        XCTAssertTrue(rig.view.pool.details.stringValue.hasPrefix("dawn.mp4 · "))
        XCTAssertTrue(rig.view.pool.details.stringValue.contains("loops"))
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(Audit.unlabelled(in: rig.view.pool), [])
        XCTAssertEqual(rig.sent.count, 0, "There is no single-click firing")
    }

    /// "The header: ... tile size ...", a view setting (§4: "the pool's folder, sort, kind filter and tile size").
    func test_theHeadersTileSizeDrawsTheTilesAtThreeSizes() throws {
        let rig = try Rig()
        let pool = rig.view.pool
        XCTAssertEqual(pool.size.itemTitles, ["Small", "Medium", "Large"])
        XCTAssertEqual(pool.size.titleOfSelectedItem, "Medium", "the first-run layout")
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(pool.tiles.first?.frame.size, PoolTileView.size(.medium))
        pool.size.selectItem(at: 2)
        _ = NSApplication.shared.sendAction(try XCTUnwrap(pool.size.action), to: pool.size.target, from: pool.size)
        XCTAssertEqual(rig.model.settings.poolTileSize, .large)
        rig.view.layoutSubtreeIfNeeded()
        let large = try XCTUnwrap(rig.view.pool.tiles.first)
        XCTAssertEqual(large.frame.size, PoolTileView.size(.large))
        large.layoutSubtreeIfNeeded()
        XCTAssertFalse(Audit.isCutOff(large.kind), "the words under the picture show whole at every size")
        XCTAssertEqual(rig.view.pool.size.titleOfSelectedItem, "Large")
        rig.model.change { $0.poolTileSize = .small }
        rig.view.layoutSubtreeIfNeeded()
        let small = try XCTUnwrap(rig.view.pool.tiles.first)
        XCTAssertEqual(small.frame.size, PoolTileView.size(.small))
        small.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(small.kind.frame.maxY, small.bounds.height)
        // The collapsed panel's one strip, of what was used lately, stays at the middle size, which its height is made for.
        rig.model.goLive(media: try rig.tile("dawn.mp4").tile.id, on: 1)
        rig.model.change { $0.panel = .collapsed }
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(rig.view.pool.tiles.first?.frame.size, PoolTileView.size(.medium))
        XCTAssertEqual(Audit.unlabelled(in: rig.view.pool), [])
    }

    // MARK: - Panels (Spec 10 §9, §10)

    /// A popover the system closed by itself, on a click elsewhere, leaves
    /// the keys with the window: "A sheet or popover takes Return and plain
    /// Escape" holds only while one is open.
    func test_aPanelThatClosedByItselfIsForgotten() throws {
        let rig = try Rig()
        XCTAssertTrue(try rig.cell("Verse 1").accept(.media(try rig.tile("dawn.mp4").tile.id)))
        XCTAssertTrue(rig.view.hasPopover)
        rig.view.promptPopoverClosed()
        XCTAssertFalse(rig.view.hasPopover)
        XCTAssertNil(rig.view.picker)
        XCTAssertFalse(rig.window.keyTap.context().sheet)
        rig.view.present(PromptView(heading: "A panel"), at: nil)
        XCTAssertTrue(rig.view.hasPopover)
        rig.view.promptPopoverClosed()
        XCTAssertNil(rig.view.prompt)
        XCTAssertFalse(rig.view.hasPopover)
    }
}
