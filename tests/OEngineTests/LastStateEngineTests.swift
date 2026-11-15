import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 9 §4 — the last state in the engine: `machine/state/last.json` and
/// its writes ("At launch the engine writes it before it does anything else
/// with the last state ... After a runtime group, within a second, and at
/// most once a second while groups keep coming ... At least once a minute
/// while the engine runs ... When the engine stops on request ... it runs the
/// shutdown macro, then writes the file at once with `clean: true`"), when it
/// comes back (choice G-1), what comes back "the way Spec 3 §8 replaces
/// ShowState", and the launch order. Spec 9 §10, The last state.
final class LastStateEngineTests: XCTestCase {
    typealias E = EngineFixtures

    static let start = Date(timeIntervalSince1970: 1_793_368_800)   // 2026-10-30T10:00:00-04:00
    static let second = 60   // ticks, at the harness's 60 fps

    /// The fixture launched with the setting on or off, the startup macro as given.
    func fixture(setting: Bool = true, startupMacro: Int? = nil, shutdownMacro: Int? = nil, relaunch: Bool = false,
                 prepare: (URL) throws -> Void = { _ in }) throws -> DiskFixture {
        try DiskFixture(wallClock: Self.start, prepare: prepare, configure: { machine in
            machine.settings.restoreLastState = setting
            machine.settings.startupMacro = startupMacro
            machine.settings.shutdownMacro = shutdownMacro
        }, launch: true, relaunch: relaunch)
    }

    /// The next run on a fixture's roots: after a kill, unless the fixture stopped first.
    func next(after previous: DiskFixture, setting: Bool = true, startupMacro: Int? = nil, relaunch: Bool = false) throws -> DiskFixture {
        try DiskFixture(continuing: previous, configure: { machine in
            machine.settings.restoreLastState = setting
            machine.settings.startupMacro = startupMacro
        }, launch: true, relaunch: relaunch)
    }

    /// `state/last.json` as it is on disk now.
    func file(_ disk: DiskFixture) throws -> LastState {
        disk.engine.settleState()
        let data = try XCTUnwrap(disk.data(.machine, "state/last.json"), "no last.json")
        guard case .state(let state)? = try? Loader.document(path: "state/last.json", data: data).body else {
            throw XCTSkip("last.json doesn't read")
        }
        let members = (try JSONValue.parse(data)).objectValue ?? [:]
        return LastState(state: state, members: members)
    }

    /// A `last.json` written by hand into a copy of the fixture, before it loads.
    func plant(_ last: LastState) -> (URL) throws -> Void {
        { folder in
            let url = folder.appendingPathComponent("machine/state/last.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try last.data.write(to: url)
        }
    }

    func stamp(minutesAgo: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxxxx"
        return formatter.string(from: Self.start.addingTimeInterval(-minutesAgo * 60))
    }

    /// This run's part of the day's command log: from its `start` note on.
    func lines(_ disk: DiskFixture) -> [LogLine] {
        let all = disk.commandLog()
        return Array(all[(all.lastIndex { $0.note?.event == "start" } ?? 0)...])
    }

    func notes(_ disk: DiskFixture, _ event: String) -> [LogNote] {
        lines(disk).compactMap(\.note).filter { $0.event == event }
    }

    func entries(_ disk: DiskFixture) -> [LogEntry] {
        lines(disk).compactMap(\.entry)
    }

    func writes(_ disk: DiskFixture) -> [TestDisk.Write] {
        disk.engine.settleState()
        return disk.disk.writes(to: "last.json")
    }

    // MARK: - The writes

    /// "At launch the engine writes it before it does anything else with the
    /// last state: with its run's uuid, `clean: false` ... If it isn't
    /// putting a state back, the file holds the empty state it starts from."
    func test_atLaunchTheFileIsWrittenForThisRunWithTheEmptyStateItStartsFrom() throws {
        let disk = try fixture()
        // Already on disk when the launch returns: nothing was waited for here.
        let data = try XCTUnwrap(FileManager.default.contents(atPath: disk.url(.machine, "state/last.json").path))
        let tree = try JSONValue.parse(data)
        XCTAssertEqual(tree["run"], .string(disk.engine.engine.run.uuidString.lowercased()))
        XCTAssertEqual(tree["clean"], .bool(false))
        XCTAssertEqual(tree["restored"], .bool(false))
        XCTAssertEqual(tree["writtenAt"], .string("2026-10-30T10:00:00.000-04:00"))
        XCTAssertEqual(tree["pendingClears"], .array([]))
        let last = try file(disk)
        XCTAssertEqual(last.state, ShowState.fresh(library: disk.engine.engine.library, machine: disk.engine.engine.machine),
                       "the fixture's old file named dawn on channel 1; this run starts empty")
        XCTAssertEqual(data, last.data, "as every document is written (Spec 1 §5)")
        XCTAssertEqual(writes(disk).count, 1)
    }

    /// "After a runtime group, within a second, and at most once a second
    /// while groups keep coming, so a caption feed can't hold it back."
    func test_itIsWrittenWithinASecondOfARuntimeGroupAndAtMostOnceASecondDuringAFeed() throws {
        let disk = try fixture()
        disk.engine.tick(count: 2 * Self.second)
        disk.disk.clear()

        disk.send("channel 2 write text \"Amen\"", source: .osc)
        disk.engine.tick()
        XCTAssertEqual(writes(disk).count, 1, "nothing was written for a second: this goes out at once")
        XCTAssertEqual(try file(disk).state.channels[2]?.content, disk.engine.state.channels[2]?.content)

        // Three seconds of captions, one a tick.
        disk.disk.clear()
        for k in 0..<(3 * Self.second) {
            disk.send("popup 1 set \"caption \(k)\"", source: .osc)
            disk.engine.tick()
        }
        let during = writes(disk).count
        XCTAssertGreaterThanOrEqual(during, 2, "the feed doesn't hold it back")
        XCTAssertLessThanOrEqual(during, 3, "and at most once a second")
        // The feed's last line is on disk within a second of it.
        disk.engine.tick(count: Self.second + 1)
        XCTAssertEqual(try file(disk).state.popups[1], "caption \(3 * Self.second - 1)")
        XCTAssertEqual(writes(disk).count, during + 1)
        // Then nothing changes, and nothing is written until the minute.
        disk.engine.tick(count: 5 * Self.second)
        XCTAssertEqual(writes(disk).count, during + 1)
    }

    /// "At least once a minute while the engine runs, so `writtenAt` says
    /// when the run was last alive, not when the last cue was fired."
    func test_itIsRefreshedAtLeastOnceAMinute() throws {
        let disk = try fixture()
        disk.disk.clear()
        disk.clock.now = Self.start.addingTimeInterval(61)
        disk.engine.tick(count: 61 * Self.second + 1)
        XCTAssertEqual(writes(disk).count, 1, "one refresh in a minute of nothing")
        XCTAssertEqual(try file(disk).writtenAt, "2026-10-30T10:01:01.000-04:00")
        XCTAssertEqual(try file(disk).clean, false)
    }

    /// "Edits never change ShowState (Spec 5 §2), so they don't write it."
    func test_anEditNeverWritesIt() throws {
        let disk = try fixture()
        disk.engine.tick(count: 2 * Self.second)
        disk.disk.clear()
        disk.send("edit list 42 title \"Faithfulness\"")
        disk.nextSecond()
        disk.engine.tick(count: 2 * Self.second)
        XCTAssertEqual(writes(disk).count, 0)
        XCTAssertFalse(disk.disk.writes.isEmpty, "the edit's own document was written")
    }

    /// "`pendingClears` lists the popup slots with a clear-after still
    /// counting (Spec 6 §7)."
    func test_thePendingClearsAreSaved() throws {
        let disk = try fixture()
        disk.engine.tick(count: 2 * Self.second)
        disk.send("popup 3 set \"Nursery: room 12\" clearafter 30", source: .ui)
        disk.send("popup 1 set \"Welcome\"", source: .ui)
        disk.engine.tick()
        let last = try file(disk)
        XCTAssertEqual(last.pendingClears, [3])
        XCTAssertEqual(last.state.popups, [1: "Welcome", 3: "Nursery: room 12"])
    }

    /// "When the engine stops on request ... it runs the shutdown macro, then
    /// writes the file at once with `clean: true`. A crash, a power cut or a
    /// force quit leaves `clean: false`." Spec 9 §2 — `stop`: "When the
    /// engine stops on request, after the shutdown macro".
    func test_aCleanStopRunsTheShutdownMacroThenWritesCleanTrue() throws {
        // Machine macro 2 (the fixture's preshow) clears everything.
        let disk = try fixture(shutdownMacro: 2)
        disk.send("channel 2 write text \"Amen\"", source: .osc)
        disk.engine.tick(count: 2)
        XCTAssertEqual(try file(disk).clean, false)
        disk.engine.stop()

        let last = try file(disk)
        XCTAssertEqual(last.clean, true)
        XCTAssertEqual(last.restored, false)
        XCTAssertEqual(last.state.channels[2]?.content, .empty, "written after the macro ran: its clear-all is in the file")
        let lines = disk.commandLog()
        let macro = try XCTUnwrap(lines.firstIndex { $0.entry?.source.kind == .shutdown })
        XCTAssertEqual(lines[macro].entry?.command, .macro(2))
        let stop = try XCTUnwrap(lines.firstIndex { $0.note?.event == "stop" })
        XCTAssertLessThan(macro, stop, "the stop note comes after the shutdown macro")
        XCTAssertEqual(stop, lines.count - 1)
        // The next run learns it ended cleanly.
        let after = try next(after: disk)
        XCTAssertEqual(notes(after, "start").last?.note["previous"], .string("clean"))
    }

    func test_aKilledEngineLeavesCleanFalse() throws {
        let disk = try fixture()
        disk.send("channel 2 write text \"Amen\"", source: .osc)
        disk.engine.tick(count: 2)
        // Killed: dropped without stopping.
        let after = try next(after: disk, setting: false)
        XCTAssertEqual(notes(after, "start").last?.note["previous"], .string("unclean"))
        XCTAssertFalse(after.commandLog().contains { $0.note?.event == "stop" }, "the killed run wrote no stop note")
        XCTAssertEqual(after.commandLog().filter { $0.note?.event == "start" }.count, 2)
    }

    // MARK: - What comes back

    /// One run that fires, grades, locks, switches, blacks out, mutes and
    /// sets popups, then is killed; the next launch with the setting on.
    func killedAfterAService() throws -> (before: DiskFixture, state: ShowState) {
        let disk = try fixture(startupMacro: 2)
        disk.engine.tick(count: 2)
        disk.send("playlist \"Sunday\"", source: .ui)
        disk.send("next", source: .key)
        disk.engine.tick()
        for text in ["channel 1 gain -6", "channel 1 pause", "channel 2 lock", "output 1 stack 2", "stack 1 blackout on", "stack 2 mute 3 on",
                     "popup 1 set \"Welcome\"", "popup 3 set \"Nursery: room 12\" clearafter 30", "timer 1 set 5:00", "timer 1 start"] {
            XCTAssertNil(disk.send(text, source: .ui), text)
        }
        disk.engine.tick()
        XCTAssertTrue(disk.control.rejections.isEmpty, "\(disk.control.rejections)")
        // A second later the state is on disk.
        disk.engine.tick(count: Self.second + 1)
        return (disk, disk.engine.state)
    }

    /// Spec 9 §10 — "With the setting on, an unclean end and a state written
    /// under two hours ago, launch restores content, attributes with origins,
    /// outputs, blackout, mutes, popups without a pending clear, locks and
    /// the pointer ...; media restarts from its in-point and plays though the
    /// walk hasn't hashed it; changes are cuts with provenance `restored`;
    /// `armed` and outgoing instances don't come back and timers are unset;
    /// ... the startup macro doesn't run; `lastStateRestored` carries the state."
    func test_launchPutsTheLastStateBack() throws {
        let (before, saved) = try killedAfterAService()
        before.clock.now = Self.start.addingTimeInterval(20 * 60)
        let disk = try next(after: before, startupMacro: 2)
        let state = disk.engine.state

        // Content and tracked attributes with their origins.
        let dawn = try XCTUnwrap(state.channels[1]?.content.media)
        XCTAssertEqual(dawn.ref, E.dawn)
        XCTAssertEqual(state.channels[2]?.content, saved.channels[2]?.content)
        XCTAssertEqual(state.channels[1]?.attributes, saved.channels[1]?.attributes)
        XCTAssertEqual(state.channels[1]?.attributes.gain, Tracked(value: -6, origin: .tracked))
        // Outputs, blackout, mutes, locks.
        XCTAssertEqual(state.outputs, saved.outputs)
        XCTAssertEqual(state.outputs[1], 2)
        XCTAssertEqual(state.stacks, saved.stacks)
        XCTAssertEqual(state.stacks[1]?.blackout, true)
        XCTAssertEqual(state.stacks[2]?.muted, [3])
        XCTAssertEqual(state.channels[2]?.lock, true)
        // Popups without a pending clear.
        XCTAssertEqual(state.popups, [1: "Welcome"])
        // The pointer, and where `next` goes from it (Spec 7 §4: the kept copies are taken at the restore).
        XCTAssertEqual(state.pointer, saved.pointer)
        XCTAssertEqual(state.pointer?.cueUuid, E.list42Cues[0])
        // Media from its in-point at the restore's frame, its transport as it was.
        XCTAssertEqual(dawn.startedAtFrame, 0)
        XCTAssertEqual(dawn.transport, .paused)
        XCTAssertFalse(dawn.missing, "its file is at its location: present without waiting for a walk")
        // Provenance restored, keeping cue and list; nothing armed; no outgoing.
        XCTAssertEqual(state.channels[1]?.provenance, .restored(cue: E.list42Cues[0], list: E.list42))
        XCTAssertNil(state.armed)
        XCTAssertEqual(state.channels[1]?.outgoing, [])
        // Timers come back unset (Spec 6 §6).
        XCTAssertTrue(disk.control.timerReadings(at: 0).values.allSatisfy { $0 == .unset })

        disk.engine.tick()
        // Every change was a cut: the source is open and nothing dissolves.
        XCTAssertEqual(disk.engine.sources(onChannel: 1).count, 1)
        XCTAssertNil(disk.control.model.channels[1]?.outgoing)
        XCTAssertEqual(disk.control.model.channels[1]?.live.media?.clock.playing, false, "paused when it stopped, paused now")
        XCTAssertEqual(disk.control.model.outputs[1]?.blackoutMix ?? 0, 0, "output 1 shows stack 2, which isn't blacked out")
        // The startup macro doesn't run (choice G-2).
        XCTAssertFalse(entries(disk).contains { $0.source.kind == .startup || $0.source.macro != nil })
        XCTAssertEqual(disk.engine.state.channels[2]?.content, saved.channels[2]?.content, "its clear-all didn't happen")
        // The note carries the state put back.
        let note = try XCTUnwrap(notes(disk, "lastStateRestored").last)
        XCTAssertEqual(note.source, CommandSource(kind: .engine))
        XCTAssertEqual(note.note["state"], try JSONCoding.encode(state))
        XCTAssertEqual(note.note["left"], .array([.object(["popup": .number(3), "why": .string("clearing")])]))
        XCTAssertEqual(note.note["writtenAt"]?.stringValue?.hasPrefix("2026-10-30T10:00:0"), true)
        XCTAssertEqual(notes(disk, "start").last?.note["previous"], .string("unclean"))
        XCTAssertTrue(notes(disk, "lastStateSkipped").isEmpty)
        // And `next` fires what followed.
        disk.send("next", source: .key)
        disk.engine.tick()
        XCTAssertEqual(disk.engine.state.pointer?.cueUuid, E.list42Cues[1])
    }

    /// "At launch the engine writes it before it does anything else with the
    /// last state: with its run's uuid, `clean: false`, and `restored: true`
    /// when it is about to put that state back".
    func test_theFileSaysRestoredBeforeTheStateIsPutBackAndForAMinuteAfter() throws {
        let (before, _) = try killedAfterAService()
        before.engine.settleState()
        before.disk.clear()
        let disk = try next(after: before)
        let first = try XCTUnwrap(writes(disk).first)
        let written = try JSONValue.parse(first.bytes)
        XCTAssertEqual(written["restored"], .bool(true))
        XCTAssertEqual(written["clean"], .bool(false))
        XCTAssertEqual(written["run"], .string(disk.engine.engine.run.uuidString.lowercased()))
        XCTAssertEqual(written["state"], try JSONCoding.encode(disk.engine.state), "the state it is about to put back")

        // "`restored` stays `true` for the first minute after a restore, whatever runs in it, and is `false` after that."
        disk.engine.tick(count: 20 * Self.second)
        disk.send("popup 2 set \"a caption\"", source: .osc)
        disk.engine.tick(count: 2)
        XCTAssertEqual(try file(disk).restored, true)
        XCTAssertEqual(try file(disk).state.popups[2], "a caption")
        disk.engine.tick(count: 41 * Self.second)
        XCTAssertEqual(try file(disk).restored, false)
    }

    /// "The pointer, as it was saved, whatever its shape: a cue fired, a
    /// playlist loaded with no cue fired, or a list fired from the library".
    func test_thePointerComesBackInEachOfItsThreeShapes() throws {
        for commands in [["playlist \"Sunday\"", "next"], ["playlist \"Sunday\""], ["list 42 cue 2"]] {
            let before = try fixture()
            before.engine.tick(count: 2)
            for text in commands { before.send(text, source: .ui) }
            before.engine.tick()
            before.engine.tick(count: Self.second + 1)
            let pointer = try XCTUnwrap(before.engine.state.pointer, "\(commands)")
            let disk = try next(after: before)
            XCTAssertEqual(disk.engine.state.pointer, pointer, "\(commands)")
            // The place is known: the next cue fires from it.
            disk.send("next", source: .key)
            disk.engine.tick()
            XCTAssertTrue(disk.control.rejections.isEmpty)
            XCTAssertNotNil(disk.engine.state.pointer?.cueUuid, "\(commands)")
            XCTAssertNotEqual(disk.engine.state.pointer, pointer, "\(commands)")
        }
    }

    /// "A channel the library no longer has is left out, and content whose
    /// media no index knows, or whose file isn't there, comes back missing."
    func test_aVanishedChannelIsLeftOutAndUnknownMediaComesBackMissing() throws {
        var saved = ShowState.fresh(library: try E.library(), machine: try E.spikeMachine())
        let unknown = "sha256:" + String(repeating: "0", count: 64)
        saved.channels[9] = saved.channels[1]
        saved.channels[9]?.content = .text(TextInstance(fields: ["body": "on a channel that is gone"]))
        saved.channels[1]?.content = .media(MediaInstance(ref: unknown, inMs: nil, outMs: nil, loop: false, gainOverride: nil, syncOffsetMs: nil,
                                                          startedAtFrame: 500, transport: .playing, endBehavior: .hold, missing: false))
        let disk = try fixture(prepare: plant(LastState(writtenAt: stamp(minutesAgo: 10), run: UUID(), clean: false, restored: false, state: saved)))

        XCTAssertNil(disk.engine.state.channels[9])
        XCTAssertEqual(disk.engine.state.channels[1]?.content.media?.missing, true)
        disk.engine.tick()
        XCTAssertEqual(disk.control.model.channels[1]?.live.media?.missing, true)
        XCTAssertEqual(disk.engine.sources(onChannel: 1).count, 0, "nothing to open")
        let note = try XCTUnwrap(notes(disk, "lastStateRestored").last)
        XCTAssertEqual(note.note["left"], .array([
            .object(["channel": .number(1), "media": .string(unknown), "why": .string("missing")]),
            .object(["channel": .number(9), "why": .string("gone")]),
        ]))
    }

    /// Spec 3 §8 — the restore's effects reach whoever mirrors state: Spec 2
    /// §6's feedback after the first build ("Feedback addresses mirror
    /// state"), and Spec 7 §6's live position.
    func test_aRestoredStateIsMirroredInFeedbackOnce() throws {
        let (before, _) = try killedAfterAService()
        let disk = try next(after: before)
        disk.engine.tick()
        let engine = disk.engine.engine
        let messages = OSCFeedbackDeriver.messages(forEffects: disk.control.lastReplaced, state: disk.engine.state,
                                                   library: engine.library, machine: engine.machine)
        let addresses = Set(messages.map(\.address))
        for address in ["/o/channel/1/content", "/o/channel/1/state", "/o/channel/2/content", "/o/output/1/stack", "/o/stack/1/blackout",
                        "/o/popup/1", "/o/lock/2"] {
            XCTAssertTrue(addresses.contains(address), address)
        }
        XCTAssertTrue(messages.contains(OSCFeedback.channelState(1, .paused)))
        XCTAssertNotNil(disk.control.lastLiveFeedback, "the live position is sent as after a fire")
        disk.engine.tick()
        XCTAssertTrue(disk.control.lastReplaced.isEmpty, "once")
        XCTAssertNil(disk.control.lastLiveFeedback)
    }

    // MARK: - When it comes back

    /// Spec 9 §10 — "An engine killed 20 seconds after a restore, with a
    /// caption line in between, starts empty next time with `restoredBefore`".
    func test_killedWithinAMinuteOfARestoreTheNextLaunchStartsEmpty() throws {
        let (before, _) = try killedAfterAService()
        let restored = try next(after: before)
        XCTAssertEqual(restored.engine.state.popups[1], "Welcome")
        restored.engine.tick(count: 10 * Self.second)
        restored.send("popup 2 set \"a caption\"", source: .osc)
        restored.engine.tick(count: 10 * Self.second)
        restored.clock.now = Self.start.addingTimeInterval(20)

        let disk = try next(after: restored, startupMacro: 2)
        XCTAssertEqual(disk.engine.state, ShowState.fresh(library: disk.engine.engine.library, machine: disk.engine.engine.machine))
        let skipped = try XCTUnwrap(notes(disk, "lastStateSkipped").last)
        XCTAssertEqual(skipped.note["reason"], .string("restoredBefore"))
        XCTAssertNotNil(skipped.note["writtenAt"])
        XCTAssertTrue(notes(disk, "lastStateRestored").isEmpty)
        XCTAssertEqual(try file(disk).restored, false, "this run put nothing back")
        // It starts empty, so the startup macro runs.
        disk.engine.tick()
        XCTAssertTrue(entries(disk).contains { $0.source.kind == .startup && $0.command == .macro(2) })
    }

    /// "one killed 40 minutes after a restore with nothing fired restores again."
    func test_killedFortyMinutesAfterARestoreItRestoresAgain() throws {
        let (before, _) = try killedAfterAService()
        let restored = try next(after: before)
        let state = restored.engine.state
        // The restored minute passes; forty minutes on, the refresh says the run is alive.
        restored.engine.tick(count: 61 * Self.second)
        restored.clock.now = Self.start.addingTimeInterval(40 * 60)
        restored.engine.tick(count: 61 * Self.second)
        XCTAssertEqual(try file(restored).restored, false)

        let disk = try next(after: restored)
        XCTAssertEqual(notes(disk, "lastStateRestored").count, 1)
        XCTAssertEqual(disk.engine.state.popups, state.popups)
        XCTAssertEqual(disk.engine.state.pointer, state.pointer)
        XCTAssertEqual(disk.engine.state.channels[2]?.content, state.channels[2]?.content)
    }

    /// "At a launch that isn't a relaunch, a clean end, a state written over
    /// two hours ago and the setting off each start empty and run the startup
    /// macro, the first two with `lastStateSkipped` and its reason."
    func test_aCleanEndAnOldStateAndTheSettingOffEachStartEmptyAndRunTheStartupMacro() throws {
        func empty(_ disk: DiskFixture, _ what: String) {
            XCTAssertEqual(disk.engine.state.popups, [:], what)
            XCTAssertNil(disk.engine.state.pointer, what)
            disk.engine.tick()
            XCTAssertTrue(entries(disk).contains { $0.source.kind == .startup && $0.command == .macro(2) }, "\(what): the startup macro runs")
            XCTAssertTrue(notes(disk, "lastStateRestored").isEmpty, what)
        }
        // A clean end.
        let stopped = try killedAfterAService().before
        stopped.engine.stop()
        let afterClean = try next(after: stopped, startupMacro: 2)
        empty(afterClean, "clean")
        XCTAssertEqual(notes(afterClean, "lastStateSkipped").last?.note["reason"], .string("clean"))

        // Written over two hours ago.
        let old = try killedAfterAService().before
        old.clock.now = Self.start.addingTimeInterval(2 * 60 * 60 + 5)
        let afterOld = try next(after: old, startupMacro: 2)
        empty(afterOld, "old")
        let skipped = try XCTUnwrap(notes(afterOld, "lastStateSkipped").last)
        XCTAssertEqual(skipped.note["reason"], .string("old"))
        XCTAssertEqual(skipped.note["writtenAt"]?.stringValue?.hasPrefix("2026-10-30T10:00:0"), true)

        // The setting off: nothing is considered, and no note is owed.
        let off = try killedAfterAService().before
        let afterOff = try next(after: off, setting: false, startupMacro: 2)
        empty(afterOff, "off")
        XCTAssertTrue(notes(afterOff, "lastStateSkipped").isEmpty)
    }

    /// "A relaunch restores with the setting off, and runs no startup macro
    /// even when it starts empty (Spec 10 §2)."
    func test_aRelaunchRestoresWithTheSettingOffAndNeverRunsTheStartupMacro() throws {
        let (before, saved) = try killedAfterAService()
        let disk = try next(after: before, setting: false, startupMacro: 2, relaunch: true)
        XCTAssertEqual(disk.engine.state.popups, [1: "Welcome"])
        XCTAssertEqual(disk.engine.state.pointer, saved.pointer)
        XCTAssertEqual(notes(disk, "lastStateRestored").count, 1)
        disk.engine.tick()
        XCTAssertFalse(entries(disk).contains { $0.source.kind == .startup })

        // A relaunch that starts empty (the state is too old) still runs none.
        let old = try killedAfterAService().before
        old.clock.now = Self.start.addingTimeInterval(3 * 60 * 60)
        let empty = try next(after: old, setting: false, startupMacro: 2, relaunch: true)
        XCTAssertNil(empty.engine.state.pointer)
        XCTAssertEqual(notes(empty, "lastStateSkipped").last?.note["reason"], .string("old"), "at a relaunch the note is owed, setting or not")
        empty.engine.tick()
        XCTAssertFalse(entries(empty).contains { $0.source.kind == .startup })
    }

    // MARK: - The launch order

    /// Spec 9 §4 — "2. The `start` note (§2). 3. `last.json` written for this
    /// run, then the last state put back or not. ... 5. The startup macro,
    /// unless the last state was restored (choice G-2) or the launch is a
    /// relaunch".
    func test_theLaunchOrderInTheLog() throws {
        let disk = try fixture(startupMacro: 2)
        disk.engine.tick()
        let lines = disk.commandLog()
        XCTAssertEqual(lines.first?.note?.event, "start")
        XCTAssertEqual(lines.first?.seq, 1)
        let macro = try XCTUnwrap(lines.firstIndex { $0.entry?.source.kind == .startup })
        XCTAssertEqual(lines[macro].entry?.command, .macro(2))
        XCTAssertEqual(lines[macro].entry?.text, "macro 2")
        // Its commands follow under its group, with source macro and its number (Spec 2 §5).
        XCTAssertEqual(lines[macro + 1].entry?.source.macro, 2)
        XCTAssertEqual(lines[macro + 1].entry?.group, lines[macro].entry?.group)
        // The file was written at launch, before any of the macro's lines.
        XCTAssertEqual(try file(disk).run, disk.engine.engine.run)

        // After a restore: start, then the restored note, and no startup macro.
        let (before, _) = try killedAfterAService()
        let restored = try next(after: before, startupMacro: 2)
        restored.engine.tick()
        XCTAssertEqual(self.lines(restored).compactMap(\.note).map(\.event), ["start", "lastStateRestored"])
        XCTAssertTrue(entries(restored).isEmpty, "no startup macro")
    }

    /// A machine with no startup macro, or one that names a macro that isn't
    /// there, launches all the same.
    func test_aMissingStartupMacroDoesNotStopTheLaunch() throws {
        let disk = try fixture(startupMacro: 77)
        disk.engine.tick()
        XCTAssertFalse(entries(disk).contains { $0.result == .ok && $0.source.kind == .startup })
        disk.send("channel 2 clear", source: .osc)
        disk.engine.tick()
        XCTAssertEqual(entries(disk).last?.text, "channel 2 clear")
    }
}
