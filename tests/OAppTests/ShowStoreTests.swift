import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §1 — "What the app shows comes from the engine's events and
/// queries (§3). It keeps no state of its own". Spec 10 §3, "Connecting" —
/// "an answer reflects every event sent before it: the app applies the
/// events that arrive after an answer and drops those that came before it."
/// The store, fed the engine's recorded answers and events.
@MainActor
final class ShowStoreTests: XCTestCase {
    private func connectedStore() throws -> ShowStore {
        let store = ShowStore()
        store.connected(.test())
        store.apply(state: try RecordedAPI.load("state"), now: 10)
        return store
    }

    func test_theStateAnswerGivesEveryStanding() throws {
        let store = try connectedStore()
        XCTAssertTrue(store.hasState)
        XCTAssertEqual(store.channels.keys.sorted(), [1, 2, 3])
        XCTAssertEqual(store.channels[1]?.state, "playing")
        XCTAssertNil(store.channels[3]?.content, "channel 3 has nothing on it")
        XCTAssertEqual(store.popups.keys.sorted(), [1, 2, 3, 4], "one per popup slot")
        XCTAssertEqual(store.popups[1]?.text, "Nursery 14")
        XCTAssertEqual(store.timers.keys.sorted(), [1, 2, 3, 4])
        XCTAssertEqual(store.timers[1]?.setMs, 300_000)
        XCTAssertEqual(store.outputs[1]?.state, "presenting")
        XCTAssertEqual(store.stacks[2]?.blackout, true)
        XCTAssertEqual(store.audio[1]?.muted, true)
        XCTAssertEqual(store.live.listTitle, "Great Is Thy Faithfulness")
        XCTAssertEqual(store.live.cuePosition, 1)
        XCTAssertEqual(store.liveAt, 10, "when it arrived, for the countdowns the app counts itself")
        XCTAssertEqual(store.channelAt[1], 10)
    }

    func test_eventsThatCameBeforeTheStateAnswerAreDropped() throws {
        let store = ShowStore()
        store.connected(.test())
        var moments: [StoreMoment] = []
        store.observeMoments { moments.append($0) }
        store.apply(event: "channels", try RecordedAPI.event("channels.media"), now: 1)
        store.apply(event: "live", try RecordedAPI.event("live.fired"), now: 1)
        store.apply(event: "popups", try RecordedAPI.event("popups.set"), now: 1)
        XCTAssertEqual(store.channels, [:], "the answer reflects them already, and an old transition must not run again")
        XCTAssertFalse(store.live.isSomethingLive)
        XCTAssertEqual(moments, [])
        // The topics that keep a current value send it on subscribe, before any answer: those count at once.
        store.apply(event: "saving", try RecordedAPI.event("saving"), now: 1)
        store.apply(event: "history", try RecordedAPI.event("history.undo"), now: 1)
        store.apply(event: "engine", try RecordedAPI.event("engine"), now: 1)
        XCTAssertEqual(store.saving.lastSnapshot, "2026-10-30-100000")
        XCTAssertNotNil(store.history.undo)
        XCTAssertEqual(store.engine.lanState, "closed")

        store.apply(state: try RecordedAPI.load("state"), now: 2)
        store.apply(event: "channels", try RecordedAPI.event("channels.empty"), now: 3)
        XCTAssertNil(store.channels[2]?.content, "an event after the answer is applied")
        XCTAssertEqual(store.channelAt[2], 3)
    }

    func test_eachEventChangesItsOwnPartAndSaysSo() throws {
        let store = try connectedStore()
        var changes: [Set<StoreChange>] = []
        store.observe { changes.append($0) }
        store.apply(event: "live", try RecordedAPI.event("live.armed"), now: 20)
        store.apply(event: "channels", try RecordedAPI.event("channels.locked"), now: 20)
        store.apply(event: "outputs", try RecordedAPI.event("outputs.output"), now: 20)
        store.apply(event: "outputs", try RecordedAPI.event("outputs.muted"), now: 20)
        store.apply(event: "audio", try RecordedAPI.event("audio.muted"), now: 20)
        store.apply(event: "popups", try RecordedAPI.event("popups.cleared"), now: 20)
        store.apply(event: "timers", try RecordedAPI.event("timers.up"), now: 20)
        store.apply(event: "metrics", ["type": .string("event"), "topic": .string("metrics"), "outputs": .array([])], now: 20)
        XCTAssertEqual(changes, [[.live], [.channels], [.outputs], [.stacks], [.audio], [.popups], [.timers], [.metrics]])
        XCTAssertEqual(store.live.armed?.cuePosition, 4)
        XCTAssertEqual(store.liveAt, 20)
        XCTAssertEqual(store.channels[1]?.lock, true)
        XCTAssertEqual(store.outputs[1]?.stack, 2)
        XCTAssertEqual(store.stacks[1]?.muted, [2])
        XCTAssertEqual(store.popups[1]?.isSet, false)
        XCTAssertEqual(store.timers[2]?.direction, "up")
        XCTAssertNotNil(store.metrics)
    }

    func test_momentsAreHandedOnAndNeverKept() throws {
        let store = try connectedStore()
        var moments: [StoreMoment] = []
        let token = store.observeMoments { moments.append($0) }
        let fired = try RecordedAPI.event("live.fired")
        store.apply(event: "live", fired, now: 20)
        store.apply(event: "channels", try RecordedAPI.event("channels.media"), now: 20)
        store.apply(event: "engine", ["type": .string("event"), "topic": .string("engine"), "remote": .array([.string("osc")])], now: 20)
        store.apply(event: "commands", try RecordedAPI.event("commands.navigation"), now: 20)
        XCTAssertEqual(moments.count, 4)
        XCTAssertEqual(moments[0], .boundary(reset: true))
        guard case .channel(let moment) = moments[1] else { return XCTFail() }
        XCTAssertEqual(moment.transition?.ms, 1000)
        XCTAssertEqual(moments[2], .remote(["osc"]))
        guard case .command(let line) = moments[3] else { return XCTFail() }
        XCTAssertEqual(line["source"]?.objectValue?["kind"], .string("ui"), "the source the live event doesn't carry")
        store.stopObserving(token)
        store.apply(event: "live", fired, now: 21)
        XCTAssertEqual(moments.count, 4)
    }

    func test_theCatalogAListAndTheMediaAreKept() throws {
        let store = try connectedStore()
        store.apply(catalog: try RecordedAPI.load("catalog"))
        store.apply(media: try RecordedAPI.load("media"))
        store.apply(list: try RecordedAPI.load("list-42"))
        XCTAssertEqual(store.catalog?.channels.count, 3)
        XCTAssertTrue(store.hasMedia)
        XCTAssertEqual(store.media.count, 5)
        let uuid = "a9f00000-0000-4000-8000-00000000002a"
        XCTAssertEqual(store.lists[uuid]?.list.cues.count, 4)
        store.apply(thumbnails: ["stack": .number(1), "thumbnails": .array([.object(["cue": .string("11aa"), "file": .string("thumbnails/a.png")])])], list: uuid)
        XCTAssertEqual(store.thumbnails[uuid], ["11aa": "thumbnails/a.png"])
        store.apply(event: "thumbnails", ["topic": .string("thumbnails"), "stack": .number(1), "list": .number(42), "listUuid": .string(uuid),
                                           "cue": .string("22bb"), "file": .string("thumbnails/b.png")], now: 30)
        XCTAssertEqual(store.thumbnails[uuid]?["22bb"], "thumbnails/b.png")
        store.drop(list: uuid)
        XCTAssertNil(store.lists[uuid])
        XCTAssertNil(store.thumbnails[uuid])
        XCTAssertEqual(store.issues, [], "everything the engine sent was read")
    }

    func test_aMediaItemsFileGoingAndComingAndItsTileBeingWritten() throws {
        let store = try connectedStore()
        store.apply(media: try RecordedAPI.load("media"))
        let dawn = try XCTUnwrap(store.media.first { $0.entry.path == "backgrounds/dawn.mp4" })
        var moments: [StoreMoment] = []
        store.observeMoments { moments.append($0) }
        store.apply(event: "media", ["topic": .string("media"), "op": .string("missing"), "id": .string(dawn.id), "missing": .bool(true)], now: 5)
        XCTAssertEqual(store.media.first { $0.id == dawn.id }?.presence, "missing")
        store.apply(event: "media", ["topic": .string("media"), "op": .string("missing"), "id": .string(dawn.id), "missing": .bool(false)], now: 6)
        XCTAssertEqual(store.media.first { $0.id == dawn.id }?.presence, "ok")
        XCTAssertEqual(moments.count, 2, "the pool shows the change as it happens too")
        store.apply(event: "thumbnails", ["topic": .string("thumbnails"), "id": .string(dawn.id), "file": .string("thumbnails/pool/55c8-0.png")], now: 7)
        XCTAssertEqual(store.media.first { $0.id == dawn.id }?.tile, "thumbnails/pool/55c8-0.png")
    }

    func test_aLibraryEventTheCatalogAlreadyReflectsIsDropped() throws {
        let store = try connectedStore()
        store.apply(catalog: try RecordedAPI.load("catalog"))   // rev 1
        var moments: [StoreMoment] = []
        store.observeMoments { moments.append($0) }
        var old = try RecordedAPI.event("library.edit")
        old["rev"] = .number(1)
        store.apply(event: "library", old, now: 5)
        XCTAssertEqual(moments, [], "revision 1 is what the catalog holds")
        store.apply(event: "library", try RecordedAPI.event("library.edit"), now: 6)   // rev 2
        XCTAssertEqual(moments.count, 1)
    }

    func test_whileTheEngineIsAwayWhatItLastReportedStaysOnShow() throws {
        let store = try connectedStore()
        store.apply(catalog: try RecordedAPI.load("catalog"))
        XCTAssertNil(store.cannotSend)
        var changes: [Set<StoreChange>] = []
        store.observe { changes.append($0) }
        store.disconnected()
        XCTAssertEqual(changes, [[.connection]])
        XCTAssertFalse(store.isConnected)
        XCTAssertEqual(store.cannotSend, .engineAway, "Spec 10 §2: every control that sends something is disabled")
        XCTAssertEqual(store.catalog?.playlists.count, 3, "the library stays browsable as the app last read it")
        XCTAssertEqual(store.channels.count, 3)
        store.disconnected()
        XCTAssertEqual(changes.count, 1, "said once")
        store.connected(.test(run: "next"))
        XCTAssertEqual(store.cannotSend, .engineAway, "until the new engine's state has arrived")
        store.apply(state: try RecordedAPI.load("state"), now: 40)
        XCTAssertNil(store.cannotSend)
    }

    func test_whyAnEditCannotBeMade() throws {
        let store = try connectedStore()
        var answer = try RecordedAPI.load("catalog")
        store.apply(catalog: answer)
        XCTAssertNil(store.cannotEdit(master: true), "the fixture machine is writable here")
        var machine = try XCTUnwrap(answer["machine"]?.objectValue)
        var settings = try XCTUnwrap(machine["settings"]?.objectValue)
        settings["libraryMode"] = .string("readOnlyMasters")
        machine["settings"] = .object(settings)
        answer["machine"] = .object(machine)
        answer["rev"] = .number(2)
        store.apply(catalog: answer)
        XCTAssertEqual(store.cannotEdit(master: true), .readOnlyMasters, "Spec 5 §7: edits to masters are refused")
        XCTAssertNil(store.cannotEdit(master: false), "this machine's own documents can still be edited")
        var locked = try RecordedAPI.event("engine")
        locked["lock"] = .bool(true)
        store.apply(event: "engine", locked, now: 50)
        XCTAssertEqual(store.cannotEdit(master: false), .locked, "Spec 10 §10: all of them are refused under the lock")
        store.disconnected()
        XCTAssertEqual(store.cannotEdit(master: false), .engineAway)
    }

    func test_whatCannotBeReadIsNotedAndNothingElseChanges() throws {
        let store = try connectedStore()
        store.apply(event: "channels", ["topic": .string("channels")], now: 1)
        store.apply(event: "somethingNew", ["topic": .string("somethingNew")], now: 1)
        store.apply(catalog: ["rev": .number(9)])
        XCTAssertEqual(store.issues.count, 3)
        XCTAssertEqual(store.channels.count, 3)
        XCTAssertNil(store.catalog)
    }
}
