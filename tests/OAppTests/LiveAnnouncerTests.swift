import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §15, "VoiceOver" — "Every change of the live cue is announced,
/// with its source when it wasn't the app ("Auto: Chorus b", "From OSC:
/// Verse 2"), and so are a trigger arming ("Auto in 8 seconds"), an output
/// that stops presenting, and a write a lock blocked or that stepped on a
/// transition." §18: "each live change is announced with its source".
@MainActor
final class LiveAnnouncerTests: XCTestCase {
    typealias Rig = ShowModelTests.Rig

    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    private func command(_ rig: Rig, cmd: String, source: String) throws {
        var event = try RecordedAPI.event("commands.navigation")
        event["command"] = .object(["cmd": .string(cmd)])
        event["source"] = .object(["kind": .string(source)])
        rig.store.apply(event: "commands", event, now: rig.clock.now)
    }

    private func fire(_ rig: Rig, cue: String, number: Int, label: String) throws {
        try rig.live {
            $0["cue"] = .string(cue)
            $0["position"] = .object(["cue": .number(Double(number)), "item": .number(2)])
            $0["label"] = .string(label)
        }
    }

    func test_eachLiveChangeIsAnnouncedWithItsSource() throws {
        let rig = try Rig()
        var said: [Announcement] = []
        rig.model.onAnnounce = { said.append($0) }
        // The app's own press: the `commands` event comes ahead of the `live` event of the same tick.
        try command(rig, cmd: "playlist.goto", source: "ui")
        try fire(rig, cue: "22bb0000-0000-4000-8000-000000000002", number: 2, label: "Verse 2")
        // An armed trigger fires as the engine's own `next`.
        try command(rig, cmd: "playlist.next", source: "scheduler")
        try fire(rig, cue: "33cc0000-0000-4000-8000-000000000003", number: 3, label: "Chorus b")
        try command(rig, cmd: "playlist.next", source: "osc")
        try fire(rig, cue: "44dd0000-0000-4000-8000-000000000004", number: 4, label: "Verse 2")
        XCTAssertEqual(said, [.live(number: 2, label: "Verse 2", source: "ui"), .live(number: 3, label: "Chorus b", source: "scheduler"),
                              .live(number: 4, label: "Verse 2", source: "osc")])
        XCTAssertEqual(said.map(AnnounceWording.text), ["Verse 2", "Auto: Chorus b", "From OSC: Verse 2"])
        // A command that doesn't move the pointer names no source for the next fire.
        try command(rig, cmd: "channel.clear", source: "osc")
        try fire(rig, cue: "22bb0000-0000-4000-8000-000000000002", number: 2, label: "")
        XCTAssertEqual(said.last, .live(number: 2, label: "", source: nil))
        XCTAssertEqual(AnnounceWording.text(try XCTUnwrap(said.last)), "Cue 2", "a cue with no label is said by its number")
        // The same `live` event again, with no command behind it, is no change.
        try fire(rig, cue: "22bb0000-0000-4000-8000-000000000002", number: 2, label: "")
        XCTAssertEqual(said.count, 4)
        // A refire of the live cue is a fire.
        try command(rig, cmd: "playlist.goto", source: "key")
        try fire(rig, cue: "22bb0000-0000-4000-8000-000000000002", number: 2, label: "")
        XCTAssertEqual(said.count, 5)
    }

    func test_whatIsLiveAtAConnectionIsNotAChange() throws {
        let rig = try Rig(connected: false)
        var said: [Announcement] = []
        rig.model.onAnnounce = { said.append($0) }
        try rig.connect()
        XCTAssertEqual(said, [], "the recorded state has a cue live: that is where things stand")
        rig.store.disconnected()
        try rig.connect()
        XCTAssertEqual(said, [])
        try fire(rig, cue: "22bb0000-0000-4000-8000-000000000002", number: 2, label: "Verse 2")
        XCTAssertEqual(said.count, 1)
    }

    func test_everySourceHasItsWords() {
        func words(_ source: String?) -> String { AnnounceWording.text(.live(number: 1, label: "Chorus", source: source)) }
        XCTAssertEqual(["key", "commandbar", nil].map(words), ["Chorus", "Chorus", "Chorus"], "the app's own keys and its command bar are the app")
        XCTAssertEqual(["cue", "timeline", "engine"].map(words), ["Auto: Chorus", "Auto: Chorus", "Auto: Chorus"])
        XCTAssertEqual(["api", "midi", "streamdeck", "macro", "startup", "restore", "telepathy"].map(words),
                       ["From the network: Chorus", "From MIDI: Chorus", "From Stream Deck: Chorus", "From a macro: Chorus", "From a macro: Chorus",
                        "Put back: Chorus", "From elsewhere: Chorus"])
    }

    /// "a trigger arming ("Auto in 8 seconds")".
    func test_aTriggerArmingIsAnnouncedOnce() throws {
        let rig = try Rig()
        var said: [Announcement] = []
        rig.model.onAnnounce = { said.append($0) }
        let armed: JSONValue = .object(["cue": .string("44dd0000-0000-4000-8000-000000000004"), "inMs": .number(8000), "item": .null,
                                        "position": .object(["cue": .number(4), "item": .number(2)])])
        try rig.live { $0["armed"] = armed }
        XCTAssertEqual(said, [.armed(seconds: 8)])
        XCTAssertEqual(AnnounceWording.text(.armed(seconds: 8)), "Auto in 8 seconds")
        XCTAssertEqual(AnnounceWording.text(.armed(seconds: 1)), "Auto in 1 second")
        // The same trigger, said again by the engine as it counts, isn't announced again.
        try rig.live { $0["armed"] = armed }
        XCTAssertEqual(said.count, 1)
    }

    /// "an output that stops presenting, and a write a lock blocked or that stepped on a transition."
    func test_anOutputThatStopsAndAWriteBlockedOrSteppedOnAreAnnounced() throws {
        let rig = try Rig()
        var said: [Announcement] = []
        rig.model.onAnnounce = { said.append($0) }
        let output = try XCTUnwrap(rig.model.outputDots.first { $0.state == .presenting } ?? rig.model.outputDots.first)
        // It presents, then pauses.
        var event = try RecordedAPI.event("outputs.output")
        event["output"] = .number(Double(output.number))
        event["state"] = .string("presenting")
        rig.store.apply(event: "outputs", event, now: rig.clock.now)
        XCTAssertEqual(said, [], "an output that starts presenting says nothing")
        event["state"] = .string("paused")
        rig.store.apply(event: "outputs", event, now: rig.clock.now)
        guard case .outputStopped(let stopped)? = said.last else { return XCTFail("\(said)") }
        XCTAssertEqual(stopped.number, output.number)
        XCTAssertEqual(stopped.state, .lost)
        XCTAssertEqual(AnnounceWording.text(.outputStopped(stopped)), "Output stopped presenting: " + ShowWording.output(stopped))
        rig.store.apply(event: "outputs", event, now: rig.clock.now)
        XCTAssertEqual(said.count, 1, "said once")

        var channel = try RecordedAPI.event("channels.locked")
        channel["blocked"] = .bool(true)
        rig.store.apply(event: "channels", channel, now: rig.clock.now)
        channel["blocked"] = .bool(false)
        channel["steppedOn"] = .bool(true)
        rig.store.apply(event: "channels", channel, now: rig.clock.now)
        XCTAssertEqual(Array(said.suffix(2)), [.blocked(channel: 1), .steppedOn(channel: 1)])
        XCTAssertEqual(said.suffix(2).map(AnnounceWording.text), ["Channel 1 is locked: a write was blocked", "A write on channel 1 cut a transition short"])
    }

    /// Spec 10 §15 — Reduce Motion "shows the transition bar's end state instead of running it".
    func test_reduceMotionShowsATransitionsEndState() throws {
        let rig = try Rig()
        var channel = try RecordedAPI.event("channels.locked")
        channel["transition"] = .object(["ms": .number(2000), "audioMs": .number(0), "audioOffsetMs": .number(0)])
        rig.store.apply(event: "channels", channel, now: rig.clock.now)
        rig.clock.advance(by: 0.5)
        XCTAssertEqual(try XCTUnwrap(rig.model.transitionProgress(channel: 1)), 0.25, accuracy: 0.01)
        rig.model.reducesMotion = true
        XCTAssertEqual(rig.model.transitionProgress(channel: 1), 1, "its end state, for as long as the transition runs")
        rig.clock.advance(by: 2)
        XCTAssertNil(rig.model.transitionProgress(channel: 1))
    }
}
