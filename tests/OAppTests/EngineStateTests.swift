import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §14 — the saving tag, the engine tag's list, the last state's
/// banner and the snapshots; and §3's notes `browse` and `backToLive`.
@MainActor
final class EngineStateTests: XCTestCase {
    typealias Rig = ShowModelTests.Rig

    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    private let english = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC") ?? .current

    private func engine(_ rig: Rig, _ change: (inout [String: JSONValue]) -> Void) throws {
        var event = try RecordedAPI.event("engine")
        event["run"] = .string("51e2")
        change(&event)
        rig.store.apply(event: "engine", event, now: rig.clock.now)
    }

    private func saving(_ rig: Rig, unsaved: Int, disk: String = "ok", log: String = "file") throws {
        var event = try RecordedAPI.event("saving")
        event["unsaved"] = .number(Double(unsaved))
        event["disk"] = .string(disk)
        event["log"] = .string(log)
        rig.store.apply(event: "saving", event, now: rig.clock.now)
    }

    // MARK: - The saving tag

    /// "amber "Unsaved (3)" when documents have waited more than five
    /// seconds to be written, amber "Disk low", and red "Disk full: changes
    /// not saved" with the log in memory."
    func test_theSavingTagShowsOnceDocumentsHaveWaitedFiveSeconds() throws {
        XCTAssertNil(SavingTag.make(SavingStatus(unsaved: 3), unsavedFor: 5), "five seconds isn't more than five")
        XCTAssertEqual(SavingTag.make(SavingStatus(unsaved: 3), unsavedFor: 5.1), .unsaved(3))
        XCTAssertNil(SavingTag.make(SavingStatus(unsaved: 0), unsavedFor: 60))
        XCTAssertEqual(SavingTag.make(SavingStatus(unsaved: 0, disk: "low"), unsavedFor: nil), .diskLow)
        XCTAssertEqual(SavingTag.make(SavingStatus(unsaved: 2, disk: "low"), unsavedFor: 9), .unsaved(2), "what isn't written says more than a low disk")
        XCTAssertEqual(SavingTag.make(SavingStatus(unsaved: 2, disk: "full", log: "memory"), unsavedFor: 0), .diskFull, "a full disk says most, at once")
        XCTAssertTrue(SavingTag.diskFull.isRed)
        XCTAssertFalse(SavingTag.unsaved(1).isRed)

        let rig = try Rig()
        try saving(rig, unsaved: 3)
        XCTAssertNil(rig.model.savingTag, "a write that is only a moment late says nothing")
        XCTAssertFalse(rig.model.tags.contains { if case .saving = $0 { return true } else { return false } })
        rig.changes = []
        rig.clock.advance(by: 5.1)
        XCTAssertEqual(rig.model.savingTag, .unsaved(3))
        XCTAssertTrue(rig.changes.contains { $0.contains(.top) }, "the top bar is asked again when the five seconds are up")
        try saving(rig, unsaved: 1)
        XCTAssertEqual(rig.model.savingTag, .unsaved(1), "the count follows the engine; the wait isn't started again")
        try saving(rig, unsaved: 0)
        XCTAssertNil(rig.model.savingTag)
        try saving(rig, unsaved: 2)
        rig.clock.advance(by: 4)
        XCTAssertNil(rig.model.savingTag, "a new wait, from when they began to wait")
        try saving(rig, unsaved: 0, disk: "full", log: "memory")
        XCTAssertEqual(rig.model.savingTag, .diskFull)
    }

    func test_theSavingTagsWordsAndWhatAClickLists() throws {
        XCTAssertEqual(StateWording.tag(.unsaved(3)), "Unsaved (3)")
        XCTAssertEqual(StateWording.tag(.diskLow), "Disk low")
        XCTAssertEqual(StateWording.tag(.diskFull), "Disk full: changes not saved")
        XCTAssertEqual(StateWording.saving(SavingDetails(SavingStatus(unsaved: 3))), ["3 documents are waiting to be written"])
        XCTAssertEqual(StateWording.saving(SavingDetails(SavingStatus(unsaved: 1, disk: "low"))),
                       ["1 document is waiting to be written", "The disk is nearly full: automatic snapshots are paused."])
        XCTAssertEqual(StateWording.saving(SavingDetails(SavingStatus(unsaved: 0, disk: "full", log: "memory"))),
                       ["Every change is written.", "The disk is full: changes are kept in memory and aren’t saved.", "The log is kept in memory until the disk has room."])
    }

    // MARK: - The engine tag

    /// "The engine tag lists the standing badges in plain words".
    func test_theEngineTagsBadgesInPlainWords() {
        let sentences = ["thermal", "memory", "watchdog", "gpu", "clock", "keychain", "new"].map { StateWording.badge(EngineStatus.Badge(kind: $0)) }
        XCTAssertEqual(sentences, ["The Mac is hot and may slow down", "Memory is low", "The engine recovered from a stall", "The graphics card was reset",
                                   "Running on the backup clock", "The Keychain can’t be read: remote control and unlocking are off", "The engine reports “new”"])
    }

    // MARK: - The last state

    /// "a banner says "Picked up where the engine stopped, at 09:41. Video
    /// started again from the top." It names what didn't come back, and says
    /// that timers came back unset".
    func test_theBannerSaysWhatWasPutBackAndWhatWasNot() throws {
        let rig = try Rig()
        XCTAssertNil(rig.model.restoreBanner, "the engine reports no last state")
        try engine(rig) {
            $0["lastState"] = .object(["restored": .bool(true), "writtenAt": .string("2026-11-08T09:41:07Z"),
                                       "left": .array([.object(["kind": .string("channel"), "number": .number(4), "why": .string("gone")]),
                                                       .object(["kind": .string("channel"), "number": .number(1), "why": .string("missing"), "media": .string("sha256:aa")]),
                                                       .object(["kind": .string("popup"), "number": .number(2), "why": .string("clearing")]),
                                                       .object(["kind": .string("output"), "number": .number(3), "why": .string("gone")]),
                                                       .object(["kind": .string("stack"), "number": .number(2), "why": .string("gone")])])])
        }
        let banner = try XCTUnwrap(rig.model.restoreBanner)
        XCTAssertEqual(banner.timers, .unset, "the app didn't see the engine end, so it can only say they came back unset")
        XCTAssertNil(banner.fireAgain, "what was live came back")
        // The system writes a narrow space before AM; what is compared is the words.
        XCTAssertEqual(StateWording.banner(banner, locale: english, timeZone: utc).map { $0.replacingOccurrences(of: "\u{202F}", with: " ") },
                       ["Picked up where the engine stopped, at 9:41 AM. Video started again from the top.", "Channel 4 no longer exists.",
                        "Channel 1’s media is missing.", "Popup 2 was on its way off, and stayed off.", "Output 3 no longer exists.", "Stack 2 no longer exists.",
                        "Timers came back unset."])
        // "Dismissed, it stays away for that run (§4)": the run is a view setting, so it stays away across a relaunch of the app.
        rig.model.dismissRestoreBanner()
        XCTAssertNil(rig.model.restoreBanner)
        XCTAssertEqual(rig.model.settings.dismissedRestoreRun, "51e2")
        try engine(rig) { $0["run"] = .string("77aa"); $0["lastState"] = .object(["restored": .bool(true), "writtenAt": .null, "left": .array([])]) }
        XCTAssertEqual(StateWording.banner(try XCTUnwrap(rig.model.restoreBanner), locale: english, timeZone: utc),
                       ["Picked up where the engine stopped. Video started again from the top.", "Timers came back unset."], "another run's banner shows")
    }

    /// "with Set Timers Again, which sets each timer to its last value from
    /// the `timers` topic and starts those that were running."
    func test_setTimersAgainSetsEachTimerToItsLastValueAndStartsThoseThatRan() throws {
        let rig = try Rig()
        var down = try RecordedAPI.event("timers.set")
        down["state"] = .string("running")
        down["valueMs"] = .number(184_000)
        rig.store.apply(event: "timers", down, now: rig.clock.now)
        rig.store.apply(event: "timers", try RecordedAPI.event("timers.up"), now: rig.clock.now)
        // The engine ends, and the next one puts the last state back.
        rig.store.disconnected()
        try rig.connect()
        for slot in [1, 2] {
            rig.store.apply(event: "timers", ["topic": .string("timers"), "timer": .number(Double(slot)), "state": .string("unset"), "text": .string("")], now: rig.clock.now)
        }
        try engine(rig) { $0["lastState"] = .object(["restored": .bool(true), "writtenAt": .string("2026-11-08T09:41:07Z"), "left": .array([])]) }
        let banner = try XCTUnwrap(rig.model.restoreBanner)
        guard case .setAgain(let timers) = banner.timers else { return XCTFail("\(banner.timers)") }
        XCTAssertEqual(timers.map(\.slot), [1, 2])
        XCTAssertTrue(rig.model.setTimersAgain())
        XCTAssertEqual(rig.commands.last, ["timer 1 set 3:04", "timer 1 start", "timer 2 set 0:30 up"], "one group, in slot order")
        XCTAssertEqual(rig.model.restoreBanner?.timers, RestoreBanner.Timers.none, "offered once")
        XCTAssertFalse(rig.model.setTimersAgain())
        // An engine that ended with no timer set leaves nothing to say of them.
        rig.store.disconnected()
        try rig.connect()
        try engine(rig) { $0["run"] = .string("88bb"); $0["lastState"] = .object(["restored": .bool(true), "writtenAt": .null, "left": .array([])]) }
        XCTAssertEqual(rig.model.restoreBanner?.timers, RestoreBanner.Timers.none)
        XCTAssertEqual(StateWording.banner(try XCTUnwrap(rig.model.restoreBanner)), ["Picked up where the engine stopped. Video started again from the top."])
    }

    /// "When a relaunch couldn't put it back, the banner says why, from the
    /// reason (Spec 9 §2), and offers "Fire 3 Verse 2 again", built from the
    /// last `live` event the app saw as an ordinary fire."
    func test_whenNothingWasPutBackTheBannerSaysWhyAndOffersToFireAgain() throws {
        let rig = try Rig()
        try rig.live { $0["position"] = .object(["cue": .number(3), "item": .number(2)]); $0["label"] = .string("Verse 2") }
        rig.store.disconnected()
        // The relaunched engine starts empty.
        rig.store.connected(Hello.test())
        rig.store.apply(catalog: try RecordedAPI.load("catalog"))
        var state = try RecordedAPI.load("state")
        state["events"] = .array((state.items("events") ?? []).filter { $0.objectValue?.text("topic") != "live" })
        rig.store.apply(state: state, now: rig.clock.now)
        rig.store.apply(event: "live", ["topic": .string("live"), "gone": .array([])], now: rig.clock.now)
        try engine(rig) { $0["lastState"] = .object(["restored": .bool(false), "reason": .string("restoredBefore"), "writtenAt": .string("2026-11-08T09:41:07Z")]) }
        let banner = try XCTUnwrap(rig.model.restoreBanner)
        XCTAssertEqual(StateWording.banner(banner), ["Nothing was put back: it had been put back once already, and the engine stopped again within a minute."])
        let fire = try XCTUnwrap(banner.fireAgain)
        XCTAssertEqual(StateWording.fireAgain(fire), "Fire 3 Verse 2 again")
        XCTAssertNil(fire.refusal)
        let before = rig.sent.count
        XCTAssertTrue(rig.model.fireAgain())
        XCTAssertEqual(rig.sent.count, before + 1)
        XCTAssertEqual(rig.commands.last, ["playlist \"Sunday\"", "item 2 cue 3"], "an ordinary fire in a playlist that isn't loaded: one group")
        XCTAssertNil(rig.model.restoreBanner?.fireAgain, "offered once")

        // "the banner says why: the last run ended cleanly, the state was more than two hours old, or it had already been put back once."
        func words(_ reason: String) -> [String] { StateWording.banner(RestoreBanner(kind: .skipped(reason: reason))) }
        XCTAssertEqual(words("clean"), ["Nothing was put back: the last run ended cleanly."])
        XCTAssertEqual(words("old"), ["Nothing was put back: what was on the screens was saved more than two hours ago."])
        XCTAssertEqual(words("later"), ["Nothing was put back."])
        // A launch the app didn't see an engine end before has nothing to fire again.
        let fresh = try Rig()
        try engine(fresh) { $0["lastState"] = .object(["restored": .bool(false), "reason": .string("clean")]) }
        XCTAssertNil(try XCTUnwrap(fresh.model.restoreBanner).fireAgain)
    }

    /// "its Make Live and the restore banner's Fire Again (§14) are disabled with "Rename to fire"" (§6).
    func test_fireAgainFollowsTheNamingRulesAndWhatIsStillThere() throws {
        let catalog = try Recorded.catalog()
        var seen = LiveStatus()
        seen.playlist = Recorded.sunday
        seen.cue = "11aa0000-0000-4000-8000-000000000001"
        seen.itemPosition = 2
        seen.cuePosition = 1
        seen.label = "Verse 1"
        XCTAssertEqual(RestoreBanner.fireAgain(seen, catalog: catalog, live: LiveStatus())?.sending?.text, ["playlist \"Sunday\"", "item 2 cue 1"])
        // A list fired from the library.
        var library = LiveStatus()
        library.listUuid = Recorded.list42
        library.list = 42
        library.cue = seen.cue
        library.cuePosition = 2
        XCTAssertEqual(RestoreBanner.fireAgain(library, catalog: catalog, live: LiveStatus())?.sending?.text, ["list 42 cue 2"])
        // No cue had fired, or what was live is gone.
        var loaded = seen
        loaded.cue = nil
        XCTAssertNil(RestoreBanner.fireAgain(loaded, catalog: catalog, live: LiveStatus()))
        var gone = seen
        gone.playlist = "b1a70000-0000-4000-8000-0000000000ff"
        XCTAssertNil(RestoreBanner.fireAgain(gone, catalog: catalog, live: LiveStatus()))
    }

    // MARK: - Snapshots

    /// "Restore a Snapshot… ... opens the snapshots from the `snapshots`
    /// query ... Restore asks ... Then `system restore snapshot "ID"`, which
    /// runs on the engine's worker, so the sheet shows it working until its result."
    func test_aSnapshotIsRestoredAfterTheQuestionAndTheResultComesBack() throws {
        let asking = try ShowModelFlowTests.Asking()
        let rig = asking.rig
        var listed: [SnapshotSummary] = []
        rig.model.snapshots { listed = $0 }
        XCTAssertEqual(rig.sent.first?.fields["what"], .string("snapshots"))
        rig.answers[0](.answer(try RecordedAPI.load("snapshots")))
        let snapshot = try XCTUnwrap(listed.first)
        XCTAssertEqual(snapshot.id, "2026-10-30-100000")
        var began = 0
        var ended: [EngineRejection?] = []
        rig.model.restore(snapshot, began: { began += 1 }, ended: { ended.append($0) })
        XCTAssertEqual(asking.asked, [.restoreSnapshot(takenAt: EditWording.when(snapshot.takenAt), mastersReadOnly: false)])
        XCTAssertEqual(rig.commands.last, ["system restore snapshot \"2026-10-30-100000\""])
        XCTAssertEqual(began, 1, "the sheet shows it working")
        XCTAssertEqual(ended.count, 0, "until its result")
        rig.answers[1](.result(CommandOutcome(kind: .ok)))
        XCTAssertEqual(ended, [nil])
        // A refusal comes back with its code and the engine's words.
        rig.model.restore(snapshot, began: {}, ended: { ended.append($0) })
        rig.answers[2](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "conflict", message: "channel 3 and macro 2 were renumbered"))))
        XCTAssertEqual(ended.last, EngineRejection(code: "conflict", message: "channel 3 and macro 2 were renumbered"))
        // Cancel sends nothing.
        asking.answer = false
        rig.model.restore(snapshot, began: { began += 1 }, ended: { ended.append($0) })
        XCTAssertEqual(rig.sent.count, 3)
        XCTAssertEqual(began, 1)
    }

    /// §12 — "the lock disables ... the restore pickers ... Take Snapshot ... all work."
    func test_theLockLeavesTakeSnapshotAndRefusesARestore() throws {
        let asking = try ShowModelFlowTests.Asking()
        let rig = asking.rig
        try engine(rig) { $0["lock"] = .bool(true) }
        XCTAssertEqual(rig.model.cannotRestore, .unavailable(.locked))
        let snapshot = SnapshotSummary(id: "2026-11-08-085959", takenAt: "2026-11-08T08:59:59Z", reason: "playlist", bytes: 1, machine: "", campus: "")
        rig.model.restore(snapshot, began: {}, ended: { _ in })
        XCTAssertEqual(asking.asked, [])
        XCTAssertEqual(rig.model.notices[.top], .notSent(.unavailable(.locked)))
        rig.model.takeSnapshot()
        XCTAssertEqual(rig.commands, [["system snapshot"]])
        rig.answers[0](.result(CommandOutcome(kind: .ok)))
        XCTAssertEqual(rig.model.notices[.top], .snapshotTaken)
        XCTAssertEqual(EditWording.notice(.snapshotTaken), "Snapshot taken.")
        rig.model.takeSnapshot()
        rig.answers[1](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "diskFull", message: ""))))
        XCTAssertEqual(rig.model.notices[.top], .rejected(EngineRejection(code: "diskFull", message: "")))
    }

    func test_aSnapshotsRowAndARefusalInPlainWords() throws {
        let own = SnapshotSummary(id: "2026-11-08-085959", takenAt: "2026-11-08T08:59:59Z", reason: "playlist", bytes: 2_400_000,
                                  machine: "7A7A0000-0000-4000-8000-000000000001", campus: "Manheim")
        let mine = StateWording.snapshot(own, thisMachine: "7a7a0000-0000-4000-8000-000000000001", locale: english, timeZone: utc)
        XCTAssertEqual(mine.title, EditWording.when(own.takenAt, locale: english, timeZone: utc))
        XCTAssertTrue(mine.detail.hasPrefix("taken when a playlist went live · "), mine.detail)
        XCTAssertFalse(mine.detail.contains("Manheim"), "this machine's own says nothing of whose it is")
        // "and the campus and machine when another machine took it."
        let other = StateWording.snapshot(own, thisMachine: "9c9c0000-0000-4000-8000-000000000002", locale: english, timeZone: utc)
        XCTAssertTrue(other.detail.hasSuffix(" · from Manheim, machine 7A7A0000"), other.detail)
        let reasons = ["launch", "timer", "command", "restore", "new"].map {
            StateWording.snapshot(SnapshotSummary(id: "x", takenAt: "", reason: $0, bytes: 0, machine: "", campus: ""), thisMachine: nil).detail
        }
        XCTAssertEqual(reasons.map { String($0.prefix { $0 != "·" }).trimmingCharacters(in: .whitespaces) },
                       ["taken at launch", "taken automatically", "taken by hand", "taken before a restore", "a snapshot"])
        // "the renumbered objects for `conflict`, the channel on air for `onAir`, the disk for `diskFull`."
        XCTAssertEqual(StateWording.refusal(EngineRejection(code: "conflict", message: "channel 3 and macro 2 were renumbered")),
                       "Not restored. " + EditWording.rejection(code: "conflict") + " The engine says: channel 3 and macro 2 were renumbered")
        XCTAssertEqual(StateWording.refusal(EngineRejection(code: "diskFull", message: "")), "Not restored. " + EditWording.rejection(code: "diskFull"))
    }

    // MARK: - Notes (Spec 10 §3)

    /// "`browse`: The grid shows another playlist or list — `playlist`
    /// (uuid) or `list` (number)"; "`backToLive`: Back to live". Noted, and
    /// nothing else; with no engine, nothing is noted and nothing kept.
    func test_browsingAndBackToLiveAreNotedInTheCommandLog() throws {
        let rig = try Rig()
        var noted: [[String: JSONValue]] = []
        var texts: [String] = []
        rig.model.note = { fields, text in
            noted.append(fields)
            texts.append(text)
        }
        rig.model.browse(.playlist(Recorded.sundayNight))
        XCTAssertEqual(noted, [["event": .string("browse"), "playlist": .string(Recorded.sundayNight)]])
        rig.model.browse(.playlist(Recorded.sundayNight))
        XCTAssertEqual(noted.count, 1, "the grid shows the same thing: nothing is noted")
        rig.model.browse(.list(Recorded.list42))
        XCTAssertEqual(noted.last, ["event": .string("browse"), "list": .number(42)])
        XCTAssertEqual(texts, ["The grid shows the playlist \"Sunday Night\"", "The grid shows list 42, \"Great Is Thy Faithfulness\""])
        rig.model.backToLive()
        XCTAssertEqual(noted.last, ["event": .string("backToLive")])
        rig.model.backToLive()
        XCTAssertEqual(noted.count, 3, "⌘L with the grid already on what is live only scrolls")
        XCTAssertEqual(rig.sent.count, 0, "a note is no command")
        // With no engine, nothing is noted and nothing kept for later.
        rig.model.note = nil
        rig.model.browse(.playlist(Recorded.sundayNight))
        XCTAssertEqual(noted.count, 3)
    }
}
