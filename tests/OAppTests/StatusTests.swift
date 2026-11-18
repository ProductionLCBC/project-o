import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §3, "Topics" — each topic's event read into the value the app
/// keeps. The events are the engine's own, as `EngineContractTests` recorded
/// them from the real API hub (`tests/fixtures/api-v1/events.json`), with the
/// spec's printed examples for what the fixture stage doesn't produce.
final class StatusTests: XCTestCase {
    private func event(_ line: String) throws -> [String: JSONValue] {
        try XCTUnwrap(JSONValue.parse(Data(line.utf8)).objectValue)
    }

    // MARK: - live

    func test_aPlaylistLoadedWithNoCueFiredIsLiveAndHasNotFired() throws {
        let live = try XCTUnwrap(LiveStatus(event: RecordedAPI.event("live.loaded")))
        XCTAssertEqual(live.playlistTitle, "Sunday")
        XCTAssertNotNil(live.playlist)
        XCTAssertNil(live.cue)
        XCTAssertTrue(live.isSomethingLive, "Spec 10 §7: a playlist loaded is enough for Next")
        XCTAssertFalse(live.hasFired)
        XCTAssertFalse(live.isLibraryList)
        XCTAssertEqual([live.itemPosition, live.cuePosition], [0, 0])
        XCTAssertNil(live.armed)
    }

    func test_aFiredCueCarriesItsTitlesItsLabelItsPositionsAndTheBoundary() throws {
        let recorded = try RecordedAPI.event("live.fired")
        let live = try XCTUnwrap(LiveStatus(event: recorded))
        XCTAssertEqual(live.list, 42)
        XCTAssertEqual(live.listTitle, "Great Is Thy Faithfulness")
        XCTAssertEqual(live.label, "Verse 1")
        XCTAssertEqual([live.itemPosition, live.cuePosition], [2, 1])
        XCTAssertTrue(live.hasFired)
        XCTAssertEqual(LiveStatus.boundaryReset(in: recorded), true, "the fire entered another list, and it doesn't track through")
        XCTAssertNil(LiveStatus.boundaryReset(in: try RecordedAPI.event("live.loaded")))
    }

    func test_anArmedTriggerNamesTheCueThatWillFireAndTheMillisecondsLeft() throws {
        let live = try XCTUnwrap(LiveStatus(event: RecordedAPI.event("live.armed")))
        XCTAssertEqual(live.armed?.cuePosition, 4)
        XCTAssertEqual(live.armed?.itemPosition, 2)
        XCTAssertNotEqual(live.armed?.cue, live.cue, "the armed cue is the next one, not the live one")
        let spec = try XCTUnwrap(LiveStatus(event: event(#"{ "type": "event", "topic": "live", "playlist": "2b2b", "item": "4d4d", "list": 42, "listUuid": "a9f0", "cue": "22bb", "position": { "item": 4, "cue": 3 }, "gone": [], "armed": { "item": "4d4d", "cue": "33cc", "position": { "item": 4, "cue": 4 }, "inMs": 8000 }, "seq": 5131 }"#)))
        XCTAssertEqual(spec.armed, LiveStatus.Armed(item: "4d4d", cue: "33cc", itemPosition: 4, cuePosition: 4, inMs: 8000), "Spec 7 §6's example")
    }

    func test_nothingLiveAListFromTheLibraryAndWhatIsGone() throws {
        XCTAssertFalse(LiveStatus().isSomethingLive)
        let library = try XCTUnwrap(LiveStatus(event: event(#"{ "type": "event", "topic": "live", "playlist": null, "item": null, "list": 42, "listUuid": "a9f0", "cue": "22bb", "position": { "item": 0, "cue": 3 }, "gone": ["item", "playlist"], "armed": null, "playlistTitle": "", "listTitle": "Great Is Thy Faithfulness", "label": "Chorus" }"#)))
        XCTAssertTrue(library.isLibraryList)
        XCTAssertTrue(library.isSomethingLive)
        XCTAssertEqual(library.gone, ["item", "playlist"])
        XCTAssertNil(LiveStatus(event: try RecordedAPI.event("saving")), "another topic's event isn't a live event")
    }

    // MARK: - channels

    func test_aChannelWithMediaCarriesItsTimingItsProvenanceAndItsAttributes() throws {
        let recorded = try RecordedAPI.event("channels.media")
        let channel = try XCTUnwrap(ChannelStatus(event: recorded))
        XCTAssertEqual(channel.number, 1)
        XCTAssertEqual(channel.state, "playing")
        XCTAssertFalse(channel.lock)
        let content = try XCTUnwrap(channel.content)
        guard case .media(let ref, let missing, let loop, let end) = content.kind else { return XCTFail("\(content.kind)") }
        XCTAssertTrue(ref.hasPrefix("sha256:"))
        XCTAssertFalse(missing)
        XCTAssertTrue(loop)
        XCTAssertEqual(end, "loop")
        XCTAssertEqual(content.label, "dawn.mp4")
        XCTAssertTrue(content.hasPicture)
        XCTAssertFalse(content.hasAudio)
        XCTAssertEqual(content.durationMs, 2000)
        XCTAssertTrue(content.isTimed)
        XCTAssertNotNil(channel.provenance?.cue, "a cue wrote it")
        XCTAssertNotNil(channel.provenance?.list)
        XCTAssertEqual(channel.attributes["transition"]?.origin, "once")
        XCTAssertEqual(channel.attributes["grade"], ChannelStatus.Attribute(value: .number(0), origin: "default"))
        let moment = try XCTUnwrap(ChannelMoment(event: recorded))
        XCTAssertEqual(moment.transition?.ms, 1000, "the transition that starts, said once")
        XCTAssertFalse(moment.steppedOn)
    }

    func test_aChannelWithTextCarriesItsFields() throws {
        let channel = try XCTUnwrap(ChannelStatus(event: RecordedAPI.event("channels.text")))
        XCTAssertEqual(channel.state, "held")
        guard case .text(let fields)? = channel.content?.kind else { return XCTFail() }
        XCTAssertEqual(fields["body"], "Great is Thy faithfulness,\nO God my Father")
        XCTAssertEqual(channel.content?.label, "Great is Thy faithfulness,")
        XCTAssertEqual(channel.content?.isTimed, false)
    }

    func test_anEmptyChannelHasNoContentAndALockedOneSaysSo() throws {
        let empty = try XCTUnwrap(ChannelStatus(event: RecordedAPI.event("channels.empty")))
        XCTAssertNil(empty.content, "An empty channel has content: null")
        XCTAssertEqual(empty.state, "empty")
        XCTAssertEqual(empty.provenance, .source(.ui), "the UI cleared it")
        let lockedEvent = try RecordedAPI.event("channels.locked")
        XCTAssertEqual(ChannelStatus(event: lockedEvent)?.lock, true)
        XCTAssertNil(ChannelMoment(event: lockedEvent), "a lock is state, with nothing said once")
    }

    func test_steppedOnAndBlockedAreMomentsAndAnUnknownKindIsKeptByItsLabel() throws {
        let stepped = try event(#"{ "type": "event", "topic": "channels", "channel": 1, "state": "playing", "lock": true, "content": { "kind": "hologram", "label": "Later" }, "provenance": null, "attributes": {}, "steppedOn": true, "blocked": true }"#)
        let moment = try XCTUnwrap(ChannelMoment(event: stepped))
        XCTAssertTrue(moment.steppedOn)
        XCTAssertTrue(moment.blocked)
        XCTAssertNil(moment.transition)
        let channel = try XCTUnwrap(ChannelStatus(event: stepped))
        XCTAssertEqual(channel.content?.kind, .other("hologram"), "a kind this build doesn't know is never guessed at")
        XCTAssertNil(channel.provenance)
    }

    // MARK: - outputs, audio, popups, timers

    func test_anOutputsEventIsAnOutputsOrAStacks() throws {
        let output = try RecordedAPI.event("outputs.output")
        XCTAssertEqual(OutputStatus(event: output), OutputStatus(number: 1, stack: 2, state: "presenting", reference: nil))
        XCTAssertNil(StackStatus(event: output), "an output's event names a stack too, and isn't a stack's")
        XCTAssertEqual(StackStatus(event: try RecordedAPI.event("outputs.stack")), StackStatus(number: 2, blackout: true, muted: []))
        XCTAssertEqual(StackStatus(event: try RecordedAPI.event("outputs.muted")), StackStatus(number: 1, blackout: false, muted: [2]))
        XCTAssertNil(OutputStatus(event: try RecordedAPI.event("outputs.stack")))
        let sdi = try event(#"{ "type": "event", "topic": "outputs", "output": 2, "stack": 1, "state": "paused", "reference": "freeRun" }"#)
        XCTAssertEqual(OutputStatus(event: sdi)?.reference, "freeRun")
        XCTAssertEqual(OutputStatus(event: sdi)?.isPresenting, false)
    }

    func test_audioPopupsAndTimers() throws {
        XCTAssertEqual(AudioStatus(event: try RecordedAPI.event("audio.muted")), AudioStatus(number: 1, state: "silent", muted: true))
        let set = try XCTUnwrap(PopupStatus(event: RecordedAPI.event("popups.set")))
        XCTAssertEqual(set.text, "Nursery 14")
        XCTAssertTrue(set.isSet)
        XCTAssertNotNil(set.clearInMs, "a clear-after is counting")
        XCTAssertEqual(PopupStatus(event: try RecordedAPI.event("popups.cleared")), PopupStatus(slot: 1, text: "", clearInMs: nil))
        XCTAssertEqual(TimerStatus(event: try RecordedAPI.event("timers.set")),
                       TimerStatus(slot: 1, state: "stopped", direction: "down", setMs: 300_000, valueMs: 300_000, text: "5:00"))
        XCTAssertEqual(TimerStatus(event: try RecordedAPI.event("timers.up"))?.direction, "up")
        let unset = try event(#"{ "type": "event", "topic": "timers", "timer": 2, "state": "unset", "direction": null, "setMs": null, "valueMs": null, "text": "" }"#)
        XCTAssertEqual(TimerStatus(event: unset), TimerStatus(slot: 2))
        XCTAssertEqual(TimerStatus(event: unset)?.isRunning, false)
    }

    // MARK: - history, saving, engine

    func test_historyNamesTheTopOfEachStackWithItsSource() throws {
        XCTAssertEqual(HistoryStatus(event: try RecordedAPI.event("history.empty")), HistoryStatus(undo: nil, redo: nil))
        let undo = try XCTUnwrap(HistoryStatus(event: RecordedAPI.event("history.undo")))
        XCTAssertEqual(undo.undo?.text, #"edit list 42 title "Great Is Thy Faithfulness (Runyan)""#)
        XCTAssertEqual(undo.undo?.commands, 1)
        XCTAssertEqual(undo.undo?.source, "ui")
        XCTAssertNil(undo.redo)
        XCTAssertNotNil(HistoryStatus(event: try RecordedAPI.event("history.redo"))?.redo)
    }

    func test_savingAndTheEnginesStanding() throws {
        XCTAssertEqual(SavingStatus(event: try RecordedAPI.event("saving")), SavingStatus(unsaved: 0, disk: "ok", log: "file", lastSnapshot: "2026-10-30-100000"))
        let recorded = try XCTUnwrap(EngineStatus(event: RecordedAPI.event("engine")))
        XCTAssertFalse(recorded.lock)
        XCTAssertEqual(recorded.lanState, "closed")
        XCTAssertNil(recorded.lastState)
        XCTAssertEqual(recorded.badges, [])
        let spec = try XCTUnwrap(EngineStatus(event: event(#"{ "type": "event", "topic": "engine", "run": "51e2", "lock": false, "passcode": true, "lan": { "state": "open", "clients": 2 }, "lastState": { "restored": false, "reason": "old" }, "badges": [ { "kind": "thermal", "level": "serious" } ] }"#)))
        XCTAssertEqual(spec, EngineStatus(run: "51e2", lock: false, passcode: true, lanState: "open", lanClients: 2,
                                          lastState: .skipped(reason: "old", writtenAt: nil), badges: [.init(kind: "thermal", level: "serious")]),
                       "Spec 10 §3's example")
        let restored = try XCTUnwrap(EngineStatus(event: event(#"{ "type": "event", "topic": "engine", "run": "51e2", "lastState": { "restored": true, "writtenAt": "2026-11-08T09:41:00-05:00", "left": [ { "channel": 1 } ] } }"#)))
        XCTAssertEqual(restored.lastState, .restored(writtenAt: "2026-11-08T09:41:00-05:00", left: [.object(["channel": .number(1)])]))
    }

    func test_remoteActivityIsAnEventOfItsOwn() throws {
        let remote = try event(#"{ "type": "event", "topic": "engine", "remote": ["osc"] }"#)
        XCTAssertEqual(EngineStatus.remoteSources(in: remote), ["osc"])
        XCTAssertNil(EngineStatus(event: remote), "it carries no standing")
        XCTAssertNil(EngineStatus.remoteSources(in: try RecordedAPI.event("engine")))
    }

    // MARK: - library, media, thumbnails

    func test_aLibraryEventNamesWhatChangedByItsAddress() throws {
        let edit = try XCTUnwrap(LibraryChangeEvent(event: RecordedAPI.event("library.edit")))
        XCTAssertEqual(edit.rev, 2)
        XCTAssertEqual(edit.cause, "edit")
        XCTAssertEqual(edit.source, "ui")
        XCTAssertEqual(edit.changed.count, 1)
        XCTAssertEqual(edit.changed.first?.object, "list")
        XCTAssertEqual(edit.changed.first?.address["list"], .number(42))
        XCTAssertNotNil(edit.changed.first?.address["listUuid"], "by uuid too, since two lists can share a number")
        XCTAssertEqual(edit.changed.first?.paths, ["title"])
        let undo = try XCTUnwrap(LibraryChangeEvent(event: RecordedAPI.event("library.undo")))
        XCTAssertEqual(undo.cause, "undo")
        XCTAssertEqual(undo.rev, 3)
    }

    func test_mediaEventsAsSpec8Section7PrintsThem() throws {
        let copying = try XCTUnwrap(MediaEvent(event: event(#"{ "type": "event", "topic": "media", "job": "j-3c1d9a20", "op": "import", "file": "Welcome.mov", "state": "copying", "progress": 0.42, "seq": 5200 }"#)))
        XCTAssertEqual(copying.job, "j-3c1d9a20")
        XCTAssertEqual(copying.progress, 0.42)
        XCTAssertFalse(copying.isDone)
        let done = try XCTUnwrap(MediaEvent(event: event(#"{ "type": "event", "topic": "media", "job": "j-3c1d9a20", "op": "import", "file": "Welcome.mov", "state": "done", "outcome": "imported", "id": "sha256:9f2c", "seq": 5207 }"#)))
        XCTAssertTrue(done.isDone)
        XCTAssertEqual(done.outcome, "imported")
        XCTAssertEqual(done.id, "sha256:9f2c")
        let refused = try XCTUnwrap(MediaEvent(event: event(#"{ "type": "event", "topic": "media", "job": "j-1", "op": "import", "file": "x.avi", "state": "done", "outcome": "refused", "reason": "unsupported" }"#)))
        XCTAssertEqual(refused.reason, "unsupported")
        let missing = try XCTUnwrap(MediaEvent(event: event(#"{ "type": "event", "topic": "media", "op": "missing", "id": "sha256:55c8", "missing": true, "seq": 5210 }"#)))
        XCTAssertEqual(missing.op, "missing")
        XCTAssertEqual(missing.missing, true)
    }

    func test_aThumbnailsEventIsACuesOrAPoolTiles() throws {
        let cue = try event(#"{ "type": "event", "topic": "thumbnails", "stack": 1, "list": 42, "listUuid": "a9f0", "cue": "11aa", "file": "thumbnails/1/a9f0/11aa.png" }"#)
        XCTAssertEqual(ThumbnailEvent(event: cue), .cue(stack: 1, listUuid: "a9f0", cue: "11aa", file: "thumbnails/1/a9f0/11aa.png"))
        let tile = try event(#"{ "type": "event", "topic": "thumbnails", "id": "sha256:55c8", "file": "thumbnails/pool/55c8-0.png" }"#)
        XCTAssertEqual(ThumbnailEvent(event: tile), .tile(id: "sha256:55c8", file: "thumbnails/pool/55c8-0.png"))
        XCTAssertNil(ThumbnailEvent(event: try event(#"{ "type": "event", "topic": "thumbnails", "file": "x.png" }"#)))
    }
}
