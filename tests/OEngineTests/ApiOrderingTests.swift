import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 10 §3, "Connecting" — "A connection carries answers and events in
/// the order the engine produces them, so an answer reflects every event
/// sent before it: the app applies the events that arrive after an answer
/// and drops those that came before it. An event carries the `seq` of the
/// log line that caused it, or of the last line logged before it." Spec 10
/// §18, Area 19 — "answers and events arrive in the order produced, and a
/// subscribe followed by `state` loses and doubles nothing".
final class ApiOrderingTests: XCTestCase {
    /// The text on a channel as a `state` answer's `channels` events have it.
    func body(of channel: Int, in answer: [String: JSONValue]) -> String? {
        let events = answer["events"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let event = events.first { $0["topic"] == .string("channels") && $0["channel"] == .number(Double(channel)) }
        return event?["content"]?.objectValue?["fields"]?.objectValue?["body"]?.stringValue
    }

    func test_inOneBuildAConnectionGetsItsResultsThenTheEventsThenItsAnswers() throws {
        let api = try ApiFixture()
        let client = api.local()
        client.send("subscribe", ["topics": .array([.string("channels")])])
        api.tick()
        _ = client.next()

        // Sent in this order: a query, then a command. The command runs in the build; the query is answered after it.
        let query = client.send("query", ["what": .string("state")])
        let command = try api.send("channel 2 write text \"Morning by morning\"", from: client)
        let ping = client.send("ping")
        api.tick()
        let messages = client.next()
        XCTAssertEqual(messages.shape, ["result", "event:channels", "answer", "pong"], "the result, the build's events, then the answers in the order asked")
        XCTAssertEqual(messages[0]["id"], .number(Double(command)))
        XCTAssertEqual(messages[2]["id"], .number(Double(query)))
        XCTAssertEqual(messages[3]["id"], .number(Double(ping)))
        XCTAssertEqual(body(of: 2, in: messages[2]), "Morning by morning", "the answer reflects the event sent before it")
    }

    /// The app's first three messages: subscribe, then ask. A change that
    /// lands in the same build is in the answer and in no event; a change in
    /// the next build is one event, after the answer.
    func test_aSubscribeFollowedByStateLosesAndDoublesNothing() throws {
        let api = try ApiFixture()
        let client = api.local()
        let other = api.local()

        client.send("subscribe", ["topics": .array([.string("channels"), .string("outputs"), .string("popups")])])
        let asked = client.send("query", ["what": .string("state")])
        try api.send("channel 2 write text \"First\"", from: other)
        api.tick()
        var messages = client.next().filter { $0["type"] != .string("hello") }
        XCTAssertEqual(messages.shape, ["result", "answer"], "the build's own change isn't sent as an event: the subscription starts after it")
        let answer = try XCTUnwrap(messages.last)
        XCTAssertEqual(answer["id"], .number(Double(asked)))
        XCTAssertEqual(body(of: 2, in: answer), "First", "nothing lost: the change is in the answer")
        let answered = try XCTUnwrap(answer["seq"]?.intValue)

        try api.send("channel 2 write text \"Second\"", from: other)
        api.tick()
        messages = client.next()
        XCTAssertEqual(messages.shape, ["event:channels"], "nothing doubled: one event for the one change after the answer")
        XCTAssertEqual(messages.first?["content"]?.objectValue?["fields"]?.objectValue?["body"], .string("Second"))
        XCTAssertGreaterThan(messages.first?["seq"]?.intValue ?? 0, answered, "and it is later than the answer by its seq")

        api.tick(3)
        XCTAssertEqual(client.next().shape, [], "and nothing more until something changes")
    }

    func test_aRequestSentAfterACommandIsAnsweredAfterTheBuildThatRanIt() throws {
        let api = try ApiFixture()
        let client = api.local()
        try api.send("stack 1 blackout on", from: client)
        let asked = client.send("query", ["what": .string("state")])
        api.tick()
        let answer = try XCTUnwrap(client.answer(to: asked))
        // The `outputs` topic has an event per output and an event per stack; the stack's has no `output`.
        let stacks = answer["events"]?.arrayValue?.compactMap(\.objectValue).filter {
            $0["topic"] == .string("outputs") && $0["output"] == nil && $0["stack"] == .number(1)
        }
        XCTAssertEqual(stacks?.first?["blackout"], .bool(true), "the query saw what the command before it did")
    }

    func test_anEventCarriesTheSeqOfTheLineThatCausedIt() throws {
        let api = try ApiFixture()
        let client = api.local()
        client.send("subscribe", ["topics": .array([.string("channels"), .string("outputs")])])
        api.tick()
        _ = client.next()
        // Two commands in one build: each channel's event names its own line, not the build's last.
        let first = try api.send("channel 2 write text \"One\"", from: client)
        let second = try api.send("stack 2 blackout on", from: client)
        api.tick()
        let messages = client.next()
        let written = try XCTUnwrap(messages.first { $0["id"] == .number(Double(first)) }?["seq"]?.intValue)
        let blacked = try XCTUnwrap(messages.first { $0["id"] == .number(Double(second)) }?["seq"]?.intValue)
        XCTAssertEqual(messages.events("channels").first?["seq"]?.intValue, written)
        XCTAssertEqual(messages.events("outputs").first?["seq"]?.intValue, blacked, "the last line logged before it")
    }

    /// Spec 10 §2, "When it doesn't answer" — `pong` comes from the control
    /// side, so an engine whose control thread has stopped building is one
    /// that doesn't answer.
    func test_pingIsAnsweredOnlyByABuild() throws {
        let api = try ApiFixture()
        let client = api.local()
        _ = client.next()
        let ping = client.send("ping")
        XCTAssertEqual(client.next(wait: 0.2).shape, [], "no build has run")
        api.tick()
        let messages = client.next()
        XCTAssertEqual(messages.shape, ["pong"])
        XCTAssertEqual(messages.first?["id"], .number(Double(ping)))
    }

    func test_eachConnectionGetsOnlyItsOwnResultsAndItsOwnTopics() throws {
        let api = try ApiFixture()
        let one = api.local(), two = api.local()
        one.send("subscribe", ["topics": .array([.string("channels")])])
        two.send("subscribe", ["topics": .array([.string("outputs")])])
        api.tick()
        _ = one.next()
        _ = two.next()
        let command = try api.send("channel 2 write text \"Hello\"", from: two)
        api.tick()
        XCTAssertEqual(one.next().shape, ["event:channels"])
        let seen = two.next()
        XCTAssertEqual(seen.shape, ["result"])
        XCTAssertEqual(seen.first?["id"], .number(Double(command)))
    }

    /// A client that goes away is forgotten, and the engine goes on.
    func test_aClientThatGoesAwayIsClosedAndForgotten() throws {
        let api = try ApiFixture()
        let client = api.local()
        client.send("subscribe", ["topics": .array([.string("channels")])])
        api.tick()
        _ = client.next()
        XCTAssertEqual(api.hub.openConnections.count, 1)
        client.transport.failing = true
        let other = api.local()
        try api.send("channel 2 write text \"Still here\"", from: other)
        api.tick()
        _ = other.next()
        client.connection.drain(seconds: 2)
        XCTAssertTrue(client.connection.isClosed, "a write that failed closes the connection")
        XCTAssertEqual(api.hub.openConnections.map(\.id), [other.connection.id])
        XCTAssertEqual(api.engine.state.channels[2]?.content.kind, "text")
    }
}
