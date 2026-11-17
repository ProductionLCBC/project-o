import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §3, "Connecting" — "The app subscribes to every topic below that
/// it uses, then asks for `state`, `catalog` and `media` ... After each
/// `library` event (Spec 5 §2), the app asks again for the documents the
/// event names that it holds." Spec 10 §1 — "Nothing is queued to send
/// later". One connection's conversation, with the test in the engine's
/// part.
@MainActor
final class EngineSessionTests: XCTestCase {
    private let transport = FakeTransport()
    private let store = ShowStore()
    private let clock = ManualClock()
    private let list42 = "a9f00000-0000-4000-8000-00000000002a"
    private let list7 = "a9f00000-0000-4000-8000-000000000007"

    private func startedSession() -> EngineSession {
        let link = EngineLink(transport: transport)
        let session = EngineSession(link: link, hello: .test(), store: store, clock: clock)
        link.start { incoming in immediateHop { session.receive(incoming) } }
        session.start()
        return session
    }

    /// The engine answers the three opening queries from its recorded answers.
    private func answerOpening() throws {
        transport.engineAnswers(transport.id(of: "subscribe"), ["result": .string("ok")], type: "result")
        transport.engineAnswers(transport.id(of: "query", what: "state"), try RecordedAPI.load("state"))
        transport.engineAnswers(transport.id(of: "query", what: "catalog"), try RecordedAPI.load("catalog"))
        transport.engineAnswers(transport.id(of: "query", what: "media"), try RecordedAPI.load("media"))
    }

    func test_itSubscribesThenAsksForStateCatalogAndMedia() throws {
        _ = startedSession()
        XCTAssertEqual(transport.sent.map { $0["type"]?.stringValue }, ["subscribe", "query", "query", "query"])
        XCTAssertEqual(transport.sent.first?["topics"]?.arrayValue?.compactMap(\.stringValue), EngineSession.topics)
        XCTAssertEqual(transport.queries, ["state", "catalog", "media"])
        for topic in ["live", "channels", "outputs", "audio", "popups", "timers", "library", "media", "history", "saving", "thumbnails", "engine", "devices", "metrics"] {
            XCTAssertTrue(EngineSession.topics.contains(topic), "Spec 10 §3's table names \(topic)")
        }
        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(store.cannotSend, .engineAway, "nothing can be sent until the state has arrived")
    }

    func test_theAnswersFillTheStore() throws {
        _ = startedSession()
        try answerOpening()
        XCTAssertTrue(store.hasState)
        XCTAssertNil(store.cannotSend)
        XCTAssertEqual(store.channels.count, 3)
        XCTAssertEqual(store.catalog?.playlists.count, 3)
        XCTAssertEqual(store.media.count, 5)
    }

    func test_eventsBeforeTheStateAnswerAreDroppedAndEventsAfterItApplied() throws {
        _ = startedSession()
        transport.engineAnswers(transport.id(of: "subscribe"), ["result": .string("ok")], type: "result")
        // A build's events land between the subscribe and the answer: the answer reflects them.
        transport.engineSends(try RecordedAPI.event("channels.empty"))
        transport.engineSends(try RecordedAPI.event("popups.cleared"))
        XCTAssertEqual(store.channels, [:])
        transport.engineAnswers(transport.id(of: "query", what: "state"), try RecordedAPI.load("state"))
        XCTAssertEqual(store.popups[1]?.text, "Nursery 14", "as the answer has it, not as the earlier event had it")
        clock.advance(by: 3)
        transport.engineSends(try RecordedAPI.event("popups.cleared"))
        XCTAssertEqual(store.popups[1]?.text, "")
        XCTAssertEqual(store.popupAt[1], clock.now, "stamped with the app's clock as it arrives")
    }

    func test_aReplyGoesBackToWhoeverAskedAndToNobodyElse() {
        let session = startedSession()
        var first: Reply?
        var second: Reply?
        let a = session.send(.command(.next, source: .key)) { first = $0 }
        let b = session.send(.ping) { second = $0 }
        transport.engineAnswers(b, [:], type: "pong")
        XCTAssertEqual(second, .pong)
        XCTAssertNil(first)
        transport.engineAnswers(a, ["result": .string("noop"), "seq": .number(7)], type: "result")
        XCTAssertEqual(first?.outcome?.kind, .noop)
        // A reply nobody waits for, and a line that can't be read, change nothing.
        var unknown: [String] = []
        session.onUnknown = { unknown.append($0) }
        transport.engineAnswers(999, ["result": .string("ok")], type: "result")
        transport.engineSends(["type": .string("somethingNew")])
        XCTAssertEqual(unknown.count, 1)
    }

    func test_holdingAListAsksForItAndItsThumbnailsAndLettingItGoDropsIt() throws {
        let session = startedSession()
        try answerOpening()
        session.hold(lists: [list42])
        XCTAssertEqual(Array(transport.queries.suffix(2)), ["list a9f0", "thumbnails a9f0"])
        XCTAssertEqual(transport.sent("query").last?["listUuid"], .string(list42), "by its uuid, since two lists can share a number")
        transport.engineAnswers(transport.id(of: "query", what: "list"), try RecordedAPI.load("list-42"))
        transport.engineAnswers(transport.id(of: "query", what: "thumbnails"), try RecordedAPI.load("thumbnails-42"))
        XCTAssertEqual(store.lists[list42]?.list.cues.count, 4)
        XCTAssertEqual(store.thumbnails[list42], [:])
        let before = transport.sent.count
        session.hold(lists: [list42])
        XCTAssertEqual(transport.sent.count, before, "a list already held isn't asked for again")
        session.hold(lists: [])
        XCTAssertNil(store.lists[list42])
    }

    func test_aLocalCopyIsAskedForByItsLocalUuid() throws {
        let session = startedSession()
        try answerOpening()
        let local = try XCTUnwrap(store.catalog?.lists.first { $0.local }?.uuid)
        session.hold(lists: [local])
        let query = try XCTUnwrap(transport.sent("query").last { $0["what"] == .string("list") })
        XCTAssertEqual(query["local"], .string(local))
        XCTAssertNil(query["listUuid"])
    }

    func test_afterALibraryEventItAsksAgainForWhatTheEventNamesThatItHolds() throws {
        let session = startedSession()
        try answerOpening()
        session.hold(lists: [list42, list7])
        transport.engineAnswers(transport.sent("query").last { $0["listUuid"] == .string(list42) && $0["what"] == .string("list") }?["id"]?.intValue, try RecordedAPI.load("list-42"))
        transport.engineAnswers(transport.sent("query").last { $0["listUuid"] == .string(list7) && $0["what"] == .string("list") }?["id"]?.intValue, try RecordedAPI.load("list-7"))
        for query in transport.sent("query") where query["what"] == .string("thumbnails") {
            transport.engineAnswers(query["id"]?.intValue, ["stack": .number(1), "thumbnails": .array([])])
        }
        let before = transport.queries.count
        transport.engineSends(try RecordedAPI.event("library.edit"))   // list 42's title, revision 2
        XCTAssertEqual(Array(transport.queries.dropFirst(before)), ["catalog", "list a9f0", "thumbnails a9f0", "thumbnails a9f0"],
                       "the catalog for its summaries, the list the event names and not the other, and both held lists' thumbnails")
        XCTAssertEqual(transport.sent("query").filter { $0["what"] == .string("list") }.last?["listUuid"], .string(list42))
    }

    func test_aBurstOfLibraryEventsCostsOneMoreCatalogNotOneEach() throws {
        _ = startedSession()
        try answerOpening()
        func edit(rev: Int) throws -> [String: JSONValue] {
            var event = try RecordedAPI.event("library.edit")
            event["rev"] = .number(Double(rev))
            return event
        }
        transport.engineSends(try edit(rev: 2))
        transport.engineSends(try edit(rev: 3))
        transport.engineSends(try edit(rev: 4))
        XCTAssertEqual(transport.queries.filter { $0 == "catalog" }.count, 2, "the opening one and one in flight")
        var catalog = try RecordedAPI.load("catalog")
        catalog["rev"] = .number(4)
        transport.engineAnswers(transport.id(of: "query", what: "catalog"), catalog)
        XCTAssertEqual(transport.queries.filter { $0 == "catalog" }.count, 3, "asked once more when the first answered, since it was asked for meanwhile")
        transport.engineAnswers(transport.id(of: "query", what: "catalog"), catalog)
        XCTAssertEqual(transport.queries.filter { $0 == "catalog" }.count, 3)
        XCTAssertEqual(store.catalog?.rev, 4)
    }

    func test_aPlaylistChangeAsksForTheCatalogAloneAndAMediaChangeForTheMediaToo() throws {
        let session = startedSession()
        try answerOpening()
        session.hold(lists: [list42])
        transport.engineAnswers(transport.id(of: "query", what: "list"), try RecordedAPI.load("list-42"))
        transport.engineAnswers(transport.id(of: "query", what: "thumbnails"), try RecordedAPI.load("thumbnails-42"))
        let before = transport.queries.count
        transport.engineSends(["type": .string("event"), "topic": .string("library"), "rev": .number(2), "cause": .string("edit"),
                               "changed": .array([.object(["object": .string("playlist"), "playlist": .string("b1a7"), "paths": .array([.string("title")])])])])
        XCTAssertEqual(Array(transport.queries.dropFirst(before)), ["catalog"], "a playlist's title redraws no thumbnail and changes no list")
        var answered = try RecordedAPI.load("catalog")
        answered["rev"] = .number(2)
        transport.engineAnswers(transport.id(of: "query", what: "catalog"), answered)
        XCTAssertEqual(store.catalog?.rev, 2)
        let then = transport.queries.count
        transport.engineSends(["type": .string("event"), "topic": .string("library"), "rev": .number(3), "cause": .string("media"),
                               "changed": .array([.object(["object": .string("media"), "media": .string("sha256:55c8"), "paths": .array([])])])])
        XCTAssertEqual(Array(transport.queries.dropFirst(then)), ["catalog", "media", "thumbnails a9f0"])
    }

    func test_aListThatHasGoneFromTheLibraryIsHeldNoLonger() throws {
        let session = startedSession()
        try answerOpening()
        session.hold(lists: [list42])
        transport.engineAnswers(transport.id(of: "query", what: "list"), try RecordedAPI.load("list-42"))
        XCTAssertNotNil(store.lists[list42])
        transport.engineSends(["type": .string("event"), "topic": .string("library"), "rev": .number(2), "cause": .string("edit"),
                               "changed": .array([.object(["object": .string("list"), "list": .number(42), "listUuid": .string(list42), "paths": .array([])])])])
        transport.engineAnswers(transport.id(of: "query", what: "list"), ["result": .string("rejected"), "reason": .string("unknownObject: no list has the uuid")],
                                type: "result")
        XCTAssertNil(store.lists[list42], "the engine says it isn't there")
    }

    func test_whenTheConnectionGoesNothingWaitsAndNothingIsSentLater() throws {
        let session = startedSession()
        try answerOpening()
        var closed = 0
        session.onClosed = { closed += 1 }
        var reply: Reply?? = .none
        session.send(.command(.next, source: .key)) { reply = .some($0) }
        transport.engineCloses()
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(reply, .some(nil), "what was waiting is told the connection went")
        XCTAssertFalse(store.isConnected)
        XCTAssertEqual(store.catalog?.playlists.count, 3, "and what was read stays on show")
        let before = transport.sent.count
        var later: Reply?? = .none
        XCTAssertNil(session.send(.command(.next, source: .key)) { later = .some($0) })
        XCTAssertEqual(later, .some(nil), "Spec 10 §1: nothing is queued to send later")
        XCTAssertEqual(transport.sent.count, before)
        // A library change the store still holds no longer asks anything.
        store.apply(event: "library", try RecordedAPI.event("library.edit"), now: 1)
        XCTAssertEqual(transport.sent.count, before)
    }
}
