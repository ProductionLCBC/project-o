import XCTest
import OCore
@testable import OEngine

/// The edits subscribed clients see. A lock-guarded box, since the publisher
/// delivers on the control side.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: JSONValue]] = []

    var all: [[String: JSONValue]] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func record(_ event: JSONValue) {
        guard case .object(let members) = event else { return }
        lock.lock()
        events.append(members)
        lock.unlock()
    }
}

/// Spec 5 §2 and §5 in the engine: the one queue, "An edit changes the
/// document in memory", the revision ("starts at 1 at launch and goes up by
/// one for every applied edit group"), the `library` event ("After each
/// applied group ... one event"), the log ("Every applied edit is logged with
/// kind `edit`, its source and its inverse", Spec 5 §1), typing ("fold into
/// one edit per second"), and Spec 5 §7's operator lock and library mode.
final class EditEngineTests: XCTestCase {
    typealias E = EngineFixtures
    static let sunday = "b1a70000-0000-4000-8000-000000000001"

    var engine: HeadlessEngine!
    var events = EventRecorder()

    func makeEngine(library: Library? = nil, configure: (inout Machine) -> Void = { _ in }) throws {
        var machine = try E.spikeMachine()
        machine.settings.libraryMode = .writable
        configure(&machine)
        engine = try HeadlessEngine(library: library ?? E.library(), machine: machine, mediaRoot: E.mediaRoot)
        events = EventRecorder()
        let events = self.events
        engine.engine.publisher.subscribe(["library"]) { events.record($0) }
    }

    override func setUpWithError() throws {
        try makeEngine()
    }

    var log: CommandLog { engine.control.commandLog }
    var title42: String? { engine.engine.library.list(number: 42)?.title }

    func string(_ value: JSONValue?) -> String? { value?.stringValue }

    // MARK: - The library changes, and the next command reads it

    /// Spec 5 §2 — "An edit changes the document in memory"; "An edit and a
    /// fire therefore never race: whichever arrives first lands first."
    func test_anEditChangesTheLibraryTheNextFireReads() throws {
        XCTAssertNil(engine.send("edit list 42 title \"Faithfulness\"", source: .osc))
        engine.tick()
        XCTAssertEqual(title42, "Faithfulness")
        XCTAssertEqual(engine.control.publishedRoots.library.list(number: 42)?.title, "Faithfulness")
        engine.send("list 42 cue 1", source: .osc)
        engine.tick()
        let fire = engine.lastExecuted.first { $0.fire != nil }?.fire
        XCTAssertEqual(fire?.listTitle, "Faithfulness", "the fire record snapshots the list as it is now")
    }

    // MARK: - The revision and the library event

    /// "goes up by one for every applied edit group"; a group's edits share
    /// "one `library` event"; a `noop` or a rejected group applies nothing.
    func test_theRevisionAndOneEventPerAppliedGroup() throws {
        XCTAssertEqual(engine.control.revision, 1, "it starts at 1 at launch")
        engine.send(group: ["edit list 42 title \"A\"", "edit list 42 author \"B\"", "edit list 7 ccli \"1\""], source: .ui)
        engine.tick()
        XCTAssertEqual(engine.control.revision, 2)
        XCTAssertEqual(events.all.count, 1)
        let event = try XCTUnwrap(events.all.first)
        XCTAssertEqual(string(event["type"]), "event")
        XCTAssertEqual(string(event["topic"]), "library")
        XCTAssertEqual(event["rev"], .number(2))
        XCTAssertEqual(string(event["cause"]), "edit")
        XCTAssertEqual(string(event["group"]), engine.lastExecuted.first?.group.rawValue)
        XCTAssertEqual(event["source"], .object(["kind": .string("ui")]))
        XCTAssertEqual(event["changed"], .array([
            .object(["object": .string("list"), "list": .number(42), "listUuid": .string(E.list42.uuidString.lowercased()),
                     "paths": .array([.string("title"), .string("author")])]),
            .object(["object": .string("list"), "list": .number(7), "listUuid": .string(E.uuid("a9f0", 7).uuidString.lowercased()),
                     "paths": .array([.string("ccli")])]),
        ]), "each object once, with the paths that changed")
        XCTAssertEqual(event["seq"], .number(Double(log.lastSeq)), "the seq of the group's last line")

        engine.send("edit list 42 title \"A\"", source: .ui)
        engine.tick()
        XCTAssertEqual(engine.lastExecuted.map(\.result), [.noop])
        engine.send("edit list 99 title \"x\"", source: .ui)
        engine.tick()
        XCTAssertEqual(engine.rejections.last?.reason, .unknownObject)
        XCTAssertEqual(engine.control.revision, 2, "neither applied anything")
        XCTAssertEqual(events.all.count, 1)
    }

    /// The whole object changed: created, deleted, renumbered or moved.
    func test_aCreatedObjectIsNamedWithNoPaths() throws {
        engine.send("edit playlist create \"Easter\"", source: .ui)
        engine.tick()
        let created = try XCTUnwrap(engine.engine.machine.playlist(titled: "Easter"))
        XCTAssertEqual(events.all.first?["changed"], .array([
            .object(["object": .string("playlist"), "playlist": .string(created.uuid.uuidString.lowercased()), "paths": .array([])]),
        ]))
    }

    /// Spec 5 §2 — "A cue holding an edit changes the library when it fires":
    /// the event names the cue's group and source.
    func test_aCueHoldingAnEditSendsItsEventAsTheCue() throws {
        var library = try E.library()
        let index = try XCTUnwrap(library.lists.firstIndex { $0.number == 42 })
        library.lists[index].cues[1].commands.append(GuardedCommand(.edit(EditCommand(.list(7), .set(path: "ccli", value: .string("1"))))))
        try makeEngine(library: library)
        engine.send("list 42 cue 2", source: .osc)
        engine.tick()
        XCTAssertEqual(engine.engine.library.list(number: 7)?.ccli, "1")
        let cueLines = engine.lastExecuted.filter { $0.source.kind == .cue }
        XCTAssertEqual(cueLines.last?.command.cmd, "edit.set")
        let event = try XCTUnwrap(events.all.first)
        XCTAssertEqual(string(event["group"]), cueLines.last?.group.rawValue)
        XCTAssertEqual(event["source"], .object(["kind": .string("cue"), "list": .string(E.list42.uuidString.lowercased()),
                                                 "cue": .string(E.list42Cues[1].uuidString.lowercased())]))
    }

    // MARK: - The log

    /// Spec 2 §9 — every executed command is a line, `seq` from 1; Spec 5 §1
    /// — "Every applied edit is logged with kind `edit`, its source and its
    /// inverse".
    func test_everyExecutedCommandIsALineAndEditsCarryTheirInverse() throws {
        engine.send(group: ["channel 2 clear", "edit list 42 title \"A\""], source: .osc)
        engine.tick()
        let lines = log.entries
        XCTAssertEqual(lines.map(\.seq), [1, 2])
        XCTAssertEqual(lines.map(\.kind), [.runtime, .edit])
        XCTAssertEqual(lines[1].undo, .edit)
        XCTAssertEqual(lines[1].source, CommandSource(kind: .osc))
        XCTAssertEqual(lines[1].text, "edit list 42 title \"A\"")
        XCTAssertEqual(lines[1].inverse, .edit(EditCommand(.list(42), .set(path: "title", value: .string("Great Is Thy Faithfulness")))))
        XCTAssertNil(lines[0].inverse)
        XCTAssertEqual(lines[1].ts, "2026-10-30T10:00:00.000-04:00", "the machine's local time with its offset")
    }

    // MARK: - Typing (Spec 5 §5)

    /// "Edits that set the same text, from the same client, fold into one edit
    /// per second ... The engine then writes one log line and pushes one undo
    /// step, whose inverse is the value from before the run." Each edit still
    /// applies at once, with its event.
    func test_typingFoldsIntoOneLineASecond() throws {
        for text in ["G", "Gr", "Gre"] {
            engine.send("edit list 42 title \"\(text)\"", source: .ui, client: "app")
            engine.tick()
            XCTAssertEqual(title42, text, "each edit applies at once")
        }
        XCTAssertEqual(events.all.count, 3)
        XCTAssertEqual(engine.control.revision, 4)
        XCTAssertEqual(Set(events.all.map { string($0["group"]) ?? "" }).count, 1, "one run, one group")
        XCTAssertEqual(log.lastSeq, 0, "no line while the run is open")
        XCTAssertEqual(log.openRuns, ["app"])

        engine.tick(count: 60)
        XCTAssertTrue(log.openRuns.isEmpty, "a run closes one second after it starts")
        let lines = log.entries
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.command, .edit(EditCommand(.list(42), .set(path: "title", value: .string("Gre")))))
        XCTAssertEqual(lines.first?.inverse, .edit(EditCommand(.list(42), .set(path: "title", value: .string("Great Is Thy Faithfulness")))))
        XCTAssertEqual(lines.first?.group.rawValue, string(events.all.first?["group"]))
        XCTAssertEqual(lines.first?.result, .ok)

        // "If typing continues, the next edit starts a new run".
        engine.send("edit list 42 title \"Grea\"", source: .ui, client: "app")
        engine.tick()
        XCTAssertEqual(log.openRuns, ["app"])
        XCTAssertNotEqual(string(events.all.last?["group"]), lines.first?.group.rawValue)
    }

    /// "any other command from that client closes the run early"; another
    /// client's command doesn't, and another client's typing is its own run.
    func test_anyOtherCommandFromTheClientClosesTheRun() throws {
        engine.send("edit list 42 title \"G\"", source: .ui, client: "app")
        engine.tick()
        engine.send("channel 2 clear", source: .ui, client: "panel")
        engine.send("edit list 7 title \"D\"", source: .ui, client: "panel")
        engine.tick()
        XCTAssertEqual(log.openRuns, ["app", "panel"])
        XCTAssertEqual(log.entries.map(\.command.cmd), ["channel.clear"])

        engine.send("channel 2 clear", source: .ui, client: "app")
        engine.tick()
        XCTAssertEqual(log.entries.map(\.command.cmd), ["channel.clear", "edit.set", "channel.clear"], "the run's line, then the command")
        XCTAssertEqual(log.openRuns, ["panel"])
    }

    /// "or one cue's text write on one channel".
    func test_aCuesTextWriteOnOneChannelFolds() throws {
        let cue = E.list42Cues[1].uuidString.lowercased()
        for text in ["T", "Th", "The"] {
            engine.send("edit list 42 cue \(cue) channel 2 write text \"\(text)\"", source: .ui, client: "app")
            engine.tick()
        }
        XCTAssertEqual(log.lastSeq, 0)
        log.flush()
        let line = try XCTUnwrap(log.entries.last)
        guard case .edit(let edit) = line.command, case .cueChannel(let channel) = edit.action,
              case .write(.text(let fields), _) = channel.state else { return XCTFail("\(line.command)") }
        XCTAssertEqual(fields["body"], "The")
        guard case .edit(let inverse)? = line.inverse, case .cueChannel(let before) = inverse.action,
              case .write(.text(let old), _) = before.state else { return XCTFail("\(String(describing: line.inverse))") }
        XCTAssertEqual(old["body"], "There is no shadow\nof turning with Thee", "the value from before the run")
    }

    // MARK: - Spec 5 §7, operator lock and library mode

    /// "While the lock is on, the engine refuses every `edit` ... The refusal
    /// comes from every source, OSC and the API included, with code
    /// `operatorLock` ... Inside a cue, a macro, a key binding or a scheduler
    /// entry the refusal is a `blocked` result rather than a rejection".
    func test_operatorLockRefusesEditsAndBlocksHeldOnes() throws {
        try makeEngine { $0.settings.operatorLock.enabled = true }
        engine.send("edit list 42 title \"A\"", source: .osc)
        engine.tick()
        XCTAssertEqual(engine.rejections.last?.reason, .operatorLock)
        XCTAssertEqual(title42, "Great Is Thy Faithfulness")

        engine.send(group: ["edit list 42 title \"A\"", "channel 2 write text \"Welcome\""], source: .key)
        engine.tick()
        XCTAssertEqual(engine.lastExecuted.map(\.result), [.blocked, .ok], "runtime commands pass")
        XCTAssertEqual(log.entries.map(\.result), [.blocked, .ok])
        XCTAssertTrue(engine.log.contains("blocked key edit edit list 42 title \"A\": operatorLock"))
        XCTAssertEqual(engine.control.revision, 1)
        XCTAssertTrue(events.all.isEmpty)
    }

    /// "On a `readOnlyMasters` machine it refuses edits of library objects
    /// with code `readOnlyLibrary` ... Machine-level edits pass".
    func test_readOnlyMastersRefusesLibraryEditsOnly() throws {
        try makeEngine { $0.settings.libraryMode = .readOnlyMasters }
        engine.send("edit list 42 title \"A\"", source: .osc)
        engine.tick()
        XCTAssertEqual(engine.rejections.last?.reason, .readOnlyLibrary)
        engine.send("edit playlist \(Self.sunday) title \"Sunday Morning\"", source: .osc)
        engine.tick()
        XCTAssertEqual(engine.engine.machine.playlist(titled: "Sunday Morning")?.uuid.uuidString.lowercased(), Self.sunday)
        XCTAssertEqual(engine.control.revision, 2)
    }

    // MARK: - Thumbnails follow the library (Spec 5 §2)

    func test_theThumbnailJobTakesTheEditedLibrary() throws {
        let metal = try MetalHarness.backend()
        var machine = try E.spikeMachine()
        machine.settings.libraryMode = .writable
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-thumbnails-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let harness = try HeadlessEngine(library: E.library(), machine: machine, mediaRoot: E.mediaRoot, metal: metal, thumbnailFolder: folder)
        harness.send("edit list 42 title \"Faithfulness\"", source: .osc)
        harness.tick()
        XCTAssertEqual(harness.engine.thumbnails?.library.list(number: 42)?.title, "Faithfulness")
    }
}
