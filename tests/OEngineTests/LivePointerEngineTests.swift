import XCTest
import OCore
@testable import OEngine

/// Spec 7 §4 in the engine: the kept copies live between builds, a reload
/// refreshes them, and "When the engine clock reaches `atFrame`, the engine
/// sends `next` if the trigger is live and `disarm` if it isn't, both with
/// source `scheduler`". Spec 7 §10 — "The armed trigger. It fires its cue at
/// its time, with source `scheduler`. A cue inserted between the live and
/// armed cues lapses it ... at its time the engine sends `disarm`, not
/// `next`." On the fixture's "Sunday Night": 1 a header, 2 list 42, 3 list 7,
/// 4 list 42.
final class LivePointerEngineTests: XCTestCase {
    typealias E = EngineFixtures
    static let list7Cues = [E.uuid("55ee", 1), E.uuid("66ff", 2), E.uuid("77aa", 3)]
    static let list7 = E.uuid("a9f0", 7)

    var engine: HeadlessEngine!

    override func setUpWithError() throws {
        var machine = try E.spikeMachine()
        machine.settings.libraryMode = .writable
        engine = try HeadlessEngine(library: E.library(), machine: machine, mediaRoot: E.mediaRoot)
    }

    func fire(item: Int, cue: Int) {
        XCTAssertNil(engine.send(group: ["playlist \"Sunday Night\"", "item \(item) cue \(cue)"]))
        engine.tick()
    }

    var pointer: LivePointer? { engine.state.pointer }

    /// Ticks until `done`, at most `limit` times; the ticks it took.
    @discardableResult
    func tick(until done: () -> Bool, limit: Int = 1000) -> Int {
        var count = 0
        while !done(), count < limit {
            engine.tick()
            count += 1
        }
        return count
    }

    // MARK: - The armed trigger

    /// "It fires its cue at its time, with source `scheduler`."
    func test_theCountdownFiresItsCueAtItsTimeFromTheScheduler() throws {
        fire(item: 2, cue: 2)
        let armed = try XCTUnwrap(engine.state.armed)
        XCTAssertEqual(armed.cueUuid, E.list42Cues[2])
        XCTAssertEqual(Int64(armed.atFrame) - engine.frame, 480, "eight seconds at 60")
        tick { pointer?.cueUuid == E.list42Cues[2] }
        XCTAssertEqual(engine.frame, Int64(armed.atFrame))
        XCTAssertEqual(engine.lastExecuted.first?.command, .next)
        XCTAssertEqual(engine.lastExecuted.first?.source, CommandSource(kind: .scheduler))
    }

    /// "A cue inserted between the live and armed cues lapses it ... at its
    /// time the engine sends `disarm`, not `next`", with a log line.
    func test_aLapsedCountdownIsDisarmedAtItsTimeWithALogLine() throws {
        fire(item: 2, cue: 2)
        let armed = try XCTUnwrap(engine.state.armed)
        XCTAssertNil(engine.send("edit list 42 insert cues 2 { \"label\": \"Bridge\" }", source: .ui))
        engine.tick()
        tick { engine.state.armed == nil }
        XCTAssertEqual(engine.frame, Int64(armed.atFrame))
        XCTAssertEqual(engine.lastExecuted.map(\.command), [.disarm])
        XCTAssertEqual(engine.lastExecuted.first?.source, CommandSource(kind: .scheduler))
        XCTAssertEqual(pointer?.cueUuid, E.list42Cues[1], "nothing fired on its own")
        XCTAssertTrue(engine.log.contains("lapsed"), "\(engine.log.recent)")
    }

    /// "An edit that makes it next again before its time brings the
    /// countdown back": it fires.
    func test_aCountdownThatComesBackFires() throws {
        fire(item: 2, cue: 2)
        engine.send("edit list 42 insert cues 2 { \"label\": \"Bridge\", \"uuid\": \"b0b00000-0000-4000-8000-000000000001\" }", source: .ui)
        engine.tick()
        engine.send("edit list 42 cue b0b00000-0000-4000-8000-000000000001 remove", source: .ui)
        engine.tick()
        tick { pointer?.cueUuid == E.list42Cues[2] }
        XCTAssertEqual(engine.lastExecuted.first?.command, .next)
    }

    // MARK: - The kept copies between builds

    /// "A deleted live list ... runs on from the copy the engine keeps of
    /// it": the copy taken at the fire is there for the next build's `next`
    /// and `cue N`.
    func test_theKeptCopiesLiveBetweenBuilds() {
        fire(item: 2, cue: 1)
        engine.send("edit list 42 delete", source: .ui)
        engine.tick()
        XCTAssertNil(engine.engine.library.list(number: 42))
        XCTAssertEqual(engine.control.kept.list?.uuid, E.list42)
        engine.send("next")
        engine.tick()
        XCTAssertEqual(pointer?.cueUuid, E.list42Cues[1])
        engine.send("cue 4")
        engine.tick()
        XCTAssertEqual(pointer?.cueUuid, E.list42Cues[3])
        XCTAssertTrue(engine.rejections.isEmpty, "\(engine.rejections)")
    }

    /// "After any of these, firing into the next song is a boundary": from
    /// list 7's copy into list 42, which doesn't track through.
    func test_enteringTheNextSongAfterTheLiveListWentIsABoundary() {
        fire(item: 3, cue: 3)
        engine.send("edit list 7 delete", source: .ui)
        engine.tick()
        engine.send("next")
        engine.tick()
        XCTAssertEqual(pointer?.cueUuid, E.list42Cues[0])
        let effects = engine.lastExecuted.flatMap(\.effects)
        XCTAssertTrue(effects.contains(.boundary(list: E.list42, reset: true)), "\(effects)")
    }

    /// Lookahead reads the place: the +1 state after the live cue is removed
    /// is the cue `next` fires (Spec 3 §7, Spec 7 §4).
    func test_lookaheadReadsThePlace() {
        fire(item: 2, cue: 2)
        engine.send("edit list 42 cue 22bb0000-0000-4000-8000-000000000002 remove", source: .ui)
        engine.tick()
        let context = engine.control.projectionContext(frame: engine.frame, source: CommandSource(kind: .engine))
        XCTAssertEqual(lookahead(engine.state, steps: 1, context: context)?.pointer?.cueUuid, E.list42Cues[2])
    }

    /// Spec 5 §10 and Spec 7 §4 — "The same holds when the change arrives by
    /// reload": a sync removes the live cue, and `next` fires what followed it.
    func test_aReloadThatRemovesTheLiveCueLeavesNextWorking() throws {
        let disk = try DiskFixture()
        XCTAssertNil(disk.engine.send(group: ["playlist \"Sunday Night\"", "item 2 cue 2"]))
        disk.engine.tick()
        let path = "lists/Hymns/042-great-is-thy-faithfulness.json"
        guard let data = disk.data(.library, path), case .object(var members) = try JSONValue.parse(data),
              case .array(var cues)? = members["cues"] else { return XCTFail("list 42") }
        cues.remove(at: 1)
        members["cues"] = .array(cues)
        try disk.write(.library, path, JSONCanonical.data(.object(members)))
        disk.engine.scanDisk()
        XCTAssertEqual(disk.engine.engine.library.list(number: 42)?.cues.count, 3)
        disk.engine.send("next")
        disk.engine.tick()
        XCTAssertEqual(disk.engine.state.pointer?.cueUuid, E.list42Cues[2])
    }
}
