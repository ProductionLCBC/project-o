import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 10 §3, "Topics" — `channels`: "One event per channel ... On every
/// change, and once a second while timed media plays"; `outputs`, `audio`,
/// `popups`: "On change"; `engine`: "On subscribe and on change; remote
/// activity at most ten times a second"; `commands` as Spec 2 §9 has it.
/// Spec 10 §18, Area 19 — "Each topic's event fires once per change ...
/// timed media sends its position once a second; `remote` is coalesced to
/// ten a second under a caption feed".
final class ApiTopicTests: XCTestCase {
    func subscribed(_ api: ApiFixture, to topics: [String]) -> ApiTestClient {
        let client = api.local()
        client.send("subscribe", ["topics": .array(topics.map(JSONValue.string))])
        api.tick()
        _ = client.next()
        return client
    }

    // MARK: - channels

    func test_aWriteSendsOneChannelsEventWithItsContentAndItsTransitionOnce() throws {
        let api = try ApiFixture()
        let client = subscribed(api, to: ["channels"])
        try api.engine.send("channel 2 write text \"Great is Thy faithfulness,\\nO God my Father\"", source: .ui).map { throw $0 }
        api.tick()
        let events = client.next().events("channels")
        XCTAssertEqual(events.count, 1, "one event for the one change")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event["channel"], .number(2))
        XCTAssertEqual(event["state"], .string("held"), "as /o/channel/N/state reports it")
        XCTAssertEqual(event["lock"], .bool(false))
        let content = try XCTUnwrap(event["content"]?.objectValue)
        XCTAssertEqual(content["kind"], .string("text"))
        XCTAssertEqual(content["label"], .string("Great is Thy faithfulness,"), "its first line")
        XCTAssertEqual(content["fields"]?.objectValue?["body"], .string("Great is Thy faithfulness,\nO God my Father"))
        XCTAssertNotNil(event["provenance"]?.objectValue?["kind"])
        let attributes = try XCTUnwrap(event["attributes"]?.objectValue)
        XCTAssertEqual(Set(attributes.keys), ["grade", "transition", "audioTransition", "gain", "chase"])
        XCTAssertEqual(attributes["gain"]?.objectValue?["origin"], .string("default"), "each with its origin")
        XCTAssertNil(attributes["gain"]?.objectValue?["shadow"])
        XCTAssertNotNil(event["transition"]?.objectValue?["ms"], "a transition that starts, once")
        XCTAssertNotNil(event["transition"]?.objectValue?["audioMs"])
        XCTAssertNotNil(event["transition"]?.objectValue?["audioOffsetMs"])
        XCTAssertEqual(event["seq"]?.intValue, api.entries.last?.seq)

        api.tick(5)
        XCTAssertEqual(client.next().events("channels").count, 0, "nothing changed, nothing is sent")

        try api.engine.send("channel 2 clear", source: .ui).map { throw $0 }
        api.tick()
        let cleared = try XCTUnwrap(client.next().events("channels").first)
        XCTAssertEqual(cleared["content"], .null, "an empty channel has content null")
        XCTAssertEqual(cleared["state"], .string("empty"))
    }

    func test_timedMediaSendsItsPositionOnceASecondWhileItPlays() throws {
        let api = try ApiFixture()
        let client = subscribed(api, to: ["channels"])
        try api.engine.send("channel 1 write media \(EngineFixtures.dawn)", source: .ui).map { throw $0 }
        api.tick()
        let first = try XCTUnwrap(client.next().events("channels").first)
        let content = try XCTUnwrap(first["content"]?.objectValue)
        XCTAssertEqual(content["kind"], .string("media"))
        XCTAssertEqual(content["ref"], .string(EngineFixtures.dawn))
        XCTAssertEqual(content["missing"], .bool(false))
        XCTAssertEqual(content["hasPicture"], .bool(true))
        XCTAssertNotNil(content["hasAudio"]?.boolValue)
        XCTAssertNotNil(content["loop"]?.boolValue)
        XCTAssertNotNil(content["endBehavior"]?.stringValue)
        let duration = try XCTUnwrap(content["durationMs"]?.intValue)
        XCTAssertGreaterThan(duration, 0, "within its in and out points")
        XCTAssertEqual(first["state"], .string("playing"))

        // Three seconds of ticks: an event as each second of its position turns over, and none between.
        var positions: [Int] = []
        for _ in 0..<180 {
            api.tick()
            for event in client.next(wait: 1).events("channels") where event["channel"] == .number(1) {
                positions.append(event["content"]?.objectValue?["positionMs"]?.intValue ?? -1)
            }
        }
        XCTAssertEqual(positions.count, 3, "once a second: \(positions)")
        for (index, position) in positions.enumerated() {
            XCTAssertEqual(Double(position % duration), Double(((index + 1) * 1000) % duration), accuracy: 60, "position \(index + 1): \(positions)")
        }

        // Paused, it stands where it is and says so once.
        try api.engine.send("channel 1 pause", source: .ui).map { throw $0 }
        api.tick()
        XCTAssertEqual(client.next().events("channels").first?["state"], .string("paused"))
        api.tick(120)
        XCTAssertEqual(client.next().events("channels").count, 0)
    }

    // MARK: - outputs, audio, popups

    func test_outputsStacksAudioAndPopupsEachSendOneEventPerChange() throws {
        let api = try ApiFixture()
        let client = subscribed(api, to: ["outputs", "audio", "popups"])

        try api.engine.send("output 1 stack 2", source: .ui).map { throw $0 }
        api.tick()
        var events = client.next().events()
        XCTAssertEqual(events.shape, ["event:outputs"])
        XCTAssertEqual(events.first?["output"], .number(1))
        XCTAssertEqual(events.first?["stack"], .number(2), "its live stack")
        XCTAssertEqual(events.first?["state"], .string("presenting"))
        XCTAssertEqual(events.first?["reference"], .null, "a display has no reference")

        try api.engine.send("stack 2 blackout on", source: .ui).map { throw $0 }
        api.tick()
        events = client.next().events()
        XCTAssertEqual(events.shape, ["event:outputs"])
        XCTAssertNil(events.first?["output"], "a stack's event")
        XCTAssertEqual(events.first?["stack"], .number(2))
        XCTAssertEqual(events.first?["blackout"], .bool(true))
        XCTAssertEqual(events.first?["muted"], .array([]))

        try api.engine.send("audio 1 mute on", source: .ui).map { throw $0 }
        api.tick()
        events = client.next().events()
        XCTAssertEqual(events.shape, ["event:audio"])
        XCTAssertEqual(events.first?["audioOutput"], .number(1))
        XCTAssertEqual(events.first?["muted"], .bool(true))
        XCTAssertNotNil(events.first?["state"]?.stringValue)

        try api.engine.send("popup 2 set \"Nursery: 214\" clearafter 2", source: .ui).map { throw $0 }
        api.tick()
        events = client.next().events()
        XCTAssertEqual(events.shape, ["event:popups"])
        XCTAssertEqual(events.first?["popup"], .number(2))
        XCTAssertEqual(events.first?["text"], .string("Nursery: 214"))
        let left = try XCTUnwrap(events.first?["clearInMs"]?.intValue)
        XCTAssertEqual(Double(left), 2000, accuracy: 40, "the milliseconds left on its clear-after")

        // It counts down in the engine, not on the wire: one more event, when it clears.
        api.tick(60)
        XCTAssertEqual(client.next().events().count, 0)
        api.tick(70)
        events = client.next().events()
        XCTAssertEqual(events.shape, ["event:popups"])
        XCTAssertEqual(events.first?["text"], .string(""))
        XCTAssertEqual(events.first?["clearInMs"], .null)
    }

    // MARK: - commands

    func test_theCommandsTopicStreamsEveryExecutedCommandWithItsSeq() throws {
        let api = try ApiFixture()
        let client = subscribed(api, to: ["commands"])
        try api.engine.send("playlist \"Sunday\"", source: .osc).map { throw $0 }
        try api.engine.send("next", source: .osc).map { throw $0 }
        api.tick()
        let events = client.next().events("commands")
        let logged = api.entries
        XCTAssertEqual(events.compactMap { $0["seq"]?.intValue }, logged.map(\.seq), "every line the build logged, the cue's commands included")
        XCTAssertEqual(events.first?["command"], try JSONCoding.encode(try XCTUnwrap(logged.first).command), "the command object")
        XCTAssertEqual(events.first?["source"]?.objectValue?["kind"], .string("osc"))
        XCTAssertEqual(events.first?["result"], .string("ok"))
    }

    // MARK: - engine

    func test_theEngineTopicIsSentOnSubscribeAndOnChange() throws {
        let api = try ApiFixture()
        let client = api.local()
        client.send("subscribe", ["topics": .array([.string("engine")])])
        api.tick()
        let first = client.next().events("engine")
        XCTAssertEqual(first.count, 1, "on subscribe")
        let event = try XCTUnwrap(first.first)
        XCTAssertEqual(event["run"], .string(api.engine.engine.run.uuidString.lowercased()))
        XCTAssertEqual(event["lock"], .bool(false))
        XCTAssertEqual(event["passcode"], .bool(false))
        XCTAssertEqual(event["lan"]?.objectValue?["state"], .string("closed"), "no token has been read")
        XCTAssertEqual(event["lan"]?.objectValue?["clients"], .number(0))
        XCTAssertEqual(event["lastState"], .null, "the setting is off and this is no relaunch: nothing to say")
        XCTAssertEqual(event["badges"], .array([]))

        api.tick(10)
        XCTAssertEqual(client.next().events("engine").count, 0)

        api.hub.lan.state = .waiting
        api.tick()
        let changed = client.next().events("engine")
        XCTAssertEqual(changed.count, 1, "on change")
        XCTAssertEqual(changed.first?["lan"]?.objectValue?["state"], .string("waiting"))
    }

    /// Spec 9 §4 and Spec 10 §3 — "the last state this run, put back with
    /// what didn't come back, or skipped with Spec 9 §2's reason".
    func test_theEngineTopicCarriesWhatBecameOfTheLastState() throws {
        let api = try ApiFixture(configure: { $0.settings.restoreLastState = true })
        // The fixture's last.json is days older than the tests' clock: skipped, as old.
        let client = api.local()
        client.send("subscribe", ["topics": .array([.string("engine")])])
        api.tick()
        let lastState = try XCTUnwrap(client.next().events("engine").first?["lastState"]?.objectValue)
        XCTAssertEqual(lastState["restored"], .bool(false))
        XCTAssertEqual(lastState["reason"], .string("old"))
    }

    func test_remoteActivityIsCoalescedToTenASecond() throws {
        let api = try ApiFixture()
        let client = subscribed(api, to: ["engine"])
        // A caption feed over OSC: a popup line on every tick for a second, and one command from the app.
        try api.send("stack 1 blackout toggle", from: client)
        for index in 0..<60 {
            try api.engine.send("popup 1 set \"caption \(index)\"", source: .osc).map { throw $0 }
            api.tick()
        }
        let remote = client.next(wait: 2).events("engine").filter { $0["remote"] != nil }
        XCTAssertGreaterThanOrEqual(remote.count, 9)
        XCTAssertLessThanOrEqual(remote.count, 10, "at most ten times a second")
        for event in remote {
            XCTAssertEqual(event["remote"], .array([.string("osc")]), "the sources from outside the app, and not the app's own")
        }

        // What arrived since the last event goes out once, a tenth of a second on; then it is quiet.
        api.tick(30)
        XCTAssertLessThanOrEqual(client.next().events("engine").filter { $0["remote"] != nil }.count, 1)
        api.tick(30)
        XCTAssertEqual(client.next().events("engine").filter { $0["remote"] != nil }.count, 0, "quiet again")
    }

    // MARK: - metrics

    /// Spec 4 §13 — "a live summary the API exposes under the `metrics`
    /// topic"; Spec 10 §3 — "`MetricsSnapshot` ... Once a second".
    func test_theMetricsTopicSendsTheLiveSummaryOnceASecondWhileSomeoneListens() throws {
        let api = try ApiFixture()
        let asked = LockedList()
        api.engine.engine.metricsSource = {
            asked.append("asked")
            return MetricsSnapshot(tickNanoseconds: 16_666_667)
        }
        api.tick(120)
        XCTAssertEqual(asked.values.count, 0, "nobody listens, so nothing is worked out")

        let client = subscribed(api, to: ["metrics"])
        var events: [[String: JSONValue]] = []
        for _ in 0..<180 {
            api.tick()
            events += client.next(wait: 1).events("metrics")
        }
        XCTAssertEqual(events.count, 3, "once a second")
        XCTAssertEqual(events.first?["tickNanoseconds"], .number(16_666_667), "the summary's own fields")
        XCTAssertNotNil(events.first?["seq"]?.intValue)
    }

    // MARK: - what was already published, now on the wire

    func test_theEarlierAreasTopicsReachASubscriber() throws {
        let api = try ApiFixture()
        let client = api.local()
        client.send("subscribe", ["topics": .array(["library", "live", "timers", "history", "saving"].map(JSONValue.string))])
        api.tick()
        let current = client.next().events()
        XCTAssertEqual(Set(current.shape), ["event:history", "event:saving"], "the topics that keep a current value send it on subscribe (Spec 9 §5, §7)")

        try api.engine.send("playlist \"Sunday\"", source: .ui).map { throw $0 }
        try api.engine.send("next", source: .ui).map { throw $0 }
        try api.engine.send("timer 1 set 5:00", source: .ui).map { throw $0 }
        try api.engine.send("edit playlist create \"Easter\"", source: .ui).map { throw $0 }
        api.tick()
        let events = client.next().events()
        XCTAssertTrue(events.shape.contains("event:live"))
        XCTAssertTrue(events.shape.contains("event:timers"))
        XCTAssertTrue(events.shape.contains("event:library"))
        XCTAssertTrue(events.shape.contains("event:history"))
        let live = try XCTUnwrap(events.events("live").last)
        XCTAssertEqual(live["playlistTitle"], .string("Sunday"), "with the titles Spec 10 §3 adds")
        XCTAssertEqual(live["listTitle"], .string("Great Is Thy Faithfulness"))
        XCTAssertNotNil(live["label"]?.stringValue)
        XCTAssertEqual(events.events("history").last?["undo"]?.objectValue?["source"]?.objectValue?["kind"], .string("ui"), "each group's source too")
    }
}
