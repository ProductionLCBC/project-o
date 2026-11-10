import XCTest
import OCore
@testable import OEngine

/// Spec 7 §6 — "Consoles and clients follow the live position and the
/// countdown (L6). The engine sends them on a fire, a load, an arm and a
/// disarm, and after any applied edit group or reload that changes what they
/// carry". Spec 7 §10 — "Feedback. `/o/live/item` and `/o/live/cue` follow an
/// insert above the live item. With the live cue gone they send the number
/// and label of the cue before the place; with the live item gone, item 0
/// and the live cue's own number. A retitled playlist and a relabelled live
/// cue are resent. `/o/live/armed` arrives on arming with the positions and
/// the milliseconds, again when an edit moves them, and empty on disarm,
/// lapse and fire. The `live` event carries both handles, the positions,
/// `gone` and `armed`." On "Sunday Night": 1 a header, 2 list 42, 3 list 7,
/// 4 list 42.
final class LiveFeedbackTests: XCTestCase {
    typealias E = EngineFixtures
    static let night = "b1a70000-0000-4000-8000-000000000010"

    var engine: HeadlessEngine!
    var events = EventRecorder()

    override func setUpWithError() throws {
        var machine = try E.spikeMachine()
        machine.settings.libraryMode = .writable
        engine = try HeadlessEngine(library: E.library(), machine: machine, mediaRoot: E.mediaRoot)
        events = EventRecorder()
        let events = self.events
        engine.engine.publisher.subscribe(["live"]) { events.record($0) }
    }

    var sent: [OSCMessage] { engine.control.lastLiveFeedback?.messages ?? [] }

    func positions(_ playlist: String, _ item: Int, _ cue: Int, _ label: String) -> [OSCMessage] {
        [OSCFeedback.livePlaylist(playlist), OSCFeedback.liveItem(item), OSCFeedback.liveCue(cue), OSCFeedback.liveLabel(label)]
    }

    func armed(_ item: Int, _ cue: Int, _ ms: Int) -> OSCMessage { OSCFeedback.liveArmed((item, cue, ms)) }
    let disarmed = OSCFeedback.liveArmed(nil)

    func edit(_ text: String) {
        XCTAssertNil(engine.send(text, source: .ui))
        engine.tick()
    }

    func fireSecondVerse() {
        XCTAssertNil(engine.send(group: ["playlist \"Sunday Night\"", "item 2 cue 2"]))
        engine.tick()
    }

    // MARK: - Positions

    /// On a fire: the positions, and the countdown it armed — "the positions
    /// of the cue that will fire and the milliseconds left".
    func test_aFireSendsThePositionAndTheCountdown() {
        fireSecondVerse()
        XCTAssertEqual(sent, positions("Sunday Night", 2, 2, "Verse 1") + [armed(2, 3, 8000)])
        engine.tick()
        XCTAssertNil(engine.control.lastLiveFeedback, "nothing changed")
    }

    /// "`/o/live/item` and `/o/live/cue` follow an insert above the live
    /// item", and the countdown's positions move with them.
    func test_anInsertAboveTheLiveItemResendsThePositions() {
        fireSecondVerse()
        edit("edit playlist \(Self.night) insert items 0 { \"kind\": \"header\", \"label\": \"Prelude\" }")
        XCTAssertEqual(sent, positions("Sunday Night", 3, 2, "Verse 1") + [armed(3, 3, 8000 - 17)])
    }

    /// "With the live cue gone they send the number and label of the cue
    /// before the place".
    func test_withTheLiveCueGoneTheCueBeforeThePlace() {
        fireSecondVerse()
        edit("edit list 42 cue 22bb0000-0000-4000-8000-000000000002 remove")
        XCTAssertEqual(Array(sent.prefix(4)), positions("Sunday Night", 2, 1, "Verse 1"))
        XCTAssertEqual(sent.last?.address, "/o/live/armed", "33cc is now cue 2, and still next")
        XCTAssertEqual(sent.last?.arguments.prefix(2), [.int32(2), .int32(2)])
    }

    /// "with the live item gone, item 0 and the live cue's own number".
    func test_withTheLiveItemGoneItemZeroAndTheCuesOwnNumber() throws {
        fireSecondVerse()
        let item = try XCTUnwrap(engine.state.pointer?.itemUuid).uuidString.lowercased()
        edit("edit playlist \(Self.night) item \(item) remove")
        XCTAssertEqual(Array(sent.prefix(4)), positions("Sunday Night", 0, 2, "Verse 1"))
        XCTAssertEqual(sent.last?.arguments.prefix(2), [.int32(0), .int32(3)], "the countdown's cue is in the gone item")
    }

    /// "A retitled playlist and a relabelled live cue are resent."
    func test_aRetitledPlaylistAndARelabelledCueAreResent() {
        fireSecondVerse()
        edit("edit playlist \(Self.night) title \"Sunday Evening\"")
        XCTAssertEqual(sent, positions("Sunday Evening", 2, 2, "Verse 1"))
        edit("edit list 42 cue 22bb0000-0000-4000-8000-000000000002 label \"Verse 1b\"")
        XCTAssertEqual(sent, positions("Sunday Evening", 2, 2, "Verse 1b"))
        edit("edit list 7 title \"Doxology (Old 100th)\"")
        XCTAssertNil(engine.control.lastLiveFeedback, "an edit that changes nothing they carry sends nothing")
    }

    // MARK: - The countdown

    /// "`/o/live/armed` ... with no arguments when the trigger disarms,
    /// lapses or fires."
    func test_theCountdownIsSentEmptyOnDisarmLapseAndFire() {
        fireSecondVerse()
        engine.send("disarm")
        engine.tick()
        XCTAssertEqual(sent, positions("Sunday Night", 2, 2, "Verse 1") + [disarmed])

        fireSecondVerse()
        edit("edit list 42 insert cues 2 { \"label\": \"Bridge\", \"uuid\": \"b0b00000-0000-4000-8000-000000000001\" }")
        XCTAssertEqual(sent, [disarmed], "lapsed: shown disarmed straight away")
        edit("edit list 42 cue b0b00000-0000-4000-8000-000000000001 remove")
        XCTAssertEqual(sent.map(\.address), ["/o/live/armed"], "back")
        XCTAssertEqual(sent.first?.arguments.prefix(2), [.int32(2), .int32(3)])

        engine.send("next")
        engine.tick()
        XCTAssertEqual(sent, positions("Sunday Night", 2, 3, "Verse 1") + [disarmed, armed(2, 4, 12000)],
                       "empty for the trigger the fire used up, then the new arming (33cc's advance-after)")
    }

    // MARK: - The live event and /o/query

    /// "The `live` event is sent at the same moments. It names the pointer
    /// by both handles ... with the positions the OSC messages send, what is
    /// gone and the armed trigger"; Spec 10 §3's titles, label and boundary.
    func test_theLiveEventCarriesBothHandlesThePositionsGoneAndArmed() throws {
        fireSecondVerse()
        let event = try XCTUnwrap(events.all.last)
        XCTAssertEqual(event["type"], .string("event"))
        XCTAssertEqual(event["topic"], .string("live"))
        XCTAssertEqual(event["playlist"], .string(Self.night))
        XCTAssertEqual(event["item"], .string("f5ddefa0-c441-5343-9e77-91de5edd9942"))
        XCTAssertEqual(event["list"], .number(42))
        XCTAssertEqual(event["listUuid"], .string(E.list42.uuidString.lowercased()))
        XCTAssertEqual(event["cue"], .string(E.list42Cues[1].uuidString.lowercased()))
        XCTAssertEqual(event["position"], .object(["item": .number(2), "cue": .number(2)]))
        XCTAssertEqual(event["gone"], .array([]))
        XCTAssertEqual(event["armed"], .object(["item": .string("f5ddefa0-c441-5343-9e77-91de5edd9942"),
                                                "cue": .string(E.list42Cues[2].uuidString.lowercased()),
                                                "position": .object(["item": .number(2), "cue": .number(3)]),
                                                "inMs": .number(8000)]))
        XCTAssertEqual(event["playlistTitle"], .string("Sunday Night"))
        XCTAssertEqual(event["listTitle"], .string("Great Is Thy Faithfulness"))
        XCTAssertEqual(event["label"], .string("Verse 1"))
        XCTAssertEqual(event["boundary"], .object(["reset": .bool(true)]))
        XCTAssertEqual(event["seq"], .number(Double(engine.control.commandLog.lastSeq)))

        edit("edit list 42 delete")
        let gone = try XCTUnwrap(events.all.last)
        XCTAssertEqual(gone["gone"], .array([.string("list")]))
        XCTAssertNil(gone["boundary"])
        XCTAssertEqual(gone["listTitle"], .string("Great Is Thy Faithfulness"), "from the kept copy")
    }

    /// Spec 2 §6 — "Any client may ask for a current value with `/o/query`":
    /// the live addresses answer from the last build's reading.
    func test_queryAnswersTheLiveAddresses() {
        fireSecondVerse()
        let published = engine.control.publishedLive
        func ask(_ address: String) -> OSCMessage? {
            published.live.answer(query: address, frame: published.frame, rate: engine.engine.pacing.masterRate)
        }
        XCTAssertEqual(ask("/o/live/playlist"), OSCFeedback.livePlaylist("Sunday Night"))
        XCTAssertEqual(ask("/o/live/item"), OSCFeedback.liveItem(2))
        XCTAssertEqual(ask("/o/live/cue"), OSCFeedback.liveCue(2))
        XCTAssertEqual(ask("/o/live/label"), OSCFeedback.liveLabel("Verse 1"))
        XCTAssertEqual(ask("/o/live/armed"), armed(2, 3, 8000))
        XCTAssertNil(ask("/o/live/nothing"))
    }
}
