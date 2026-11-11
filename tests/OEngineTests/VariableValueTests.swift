import XCTest
import OCore
@testable import OEngine

/// A wall clock a test sets, for the engine's variables (Spec 4 §2).
final class SettableWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_793_368_800)) {
        self.date = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func set(_ date: Date) {
        lock.lock()
        self.date = date
        lock.unlock()
    }

    func advance(seconds: Double) {
        lock.lock()
        date = date.addingTimeInterval(seconds)
        lock.unlock()
    }

    /// A moment in America/New_York, the fixtures' time zone.
    static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Double = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let whole = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: Int(second)))
        return (whole ?? Date()).addingTimeInterval(second - second.rounded(.down))
    }
}

/// Spec 6 §11, Area 11 — "Values. Each v1 variable is read from a live state,
/// a +1 lookahead state and a thumbnail's state. Context values follow
/// provenance in content and the pointer in static boxes. `[Next Title]`
/// skips headers, is empty after the last list, and is empty in a thumbnail.
/// A +1 box shows a popup the next cue sets." "Popups. ... A variable in a
/// popup's text resolves, a `[Popup N]` inside it prints as written, and other
/// bracketed text shows as sent. `system clearall` leaves popups." And
/// "Parsing ... a timer number above the count resolving empty, and an
/// unknown format falling back with one log line."
///
/// The wall clock moves a second, and six frames run, with each change, so
/// the adoption pacing (Spec 6 §5, `AdoptionTests`) never holds a value these
/// tests read.
final class VariableValueTests: XCTestCase {
    typealias S = StageFixtures
    typealias E = EngineFixtures

    static let context = "[Live Title]|[Section]|[Cue Note]|[Copyright]|[CCLI]|[Next Title]"

    static func cue(_ list: Int, _ position: Int, section: String?, note: String = "", _ commands: [Command]) -> Cue {
        Cue(uuid: S.cueUuid(list: list, position), label: "cue \(position)", section: section, note: note, commands: commands)
    }

    /// Song A writes channel 2 on both cues; Song B's first cue writes only
    /// channel 1, so channel 2 keeps Song A's content.
    static let songA = List(uuid: S.listUuid(60), number: 60, title: "Song A", cues: [
        cue(60, 1, section: "Verse 1", note: "Slow", [S.text("A one: [Live Title] / [Section] / [Cue Note]")]),
        cue(60, 2, section: "Chorus", [S.text("A two")]),
    ], author: "Anon", copyright: "PD A", ccli: "111")
    static let songB = List(uuid: S.listUuid(61), number: 61, title: "Song B", cues: [
        cue(61, 1, section: "Intro", note: "Pads", [S.media(channel: 1)]),
        cue(61, 2, section: "Verse", [S.text("B two")]),
    ], copyright: "PD B", ccli: "222")
    /// The second cue sets a popup whose text names a context value.
    static let popups = List(uuid: S.listUuid(62), number: 62, title: "Popups", cues: [
        cue(62, 1, section: "One", [S.text("one")]),
        cue(62, 2, section: "Two", [.popupSet(popup: 1, text: "Section: [Section]", clearAfterMs: nil)]),
    ])
    /// A header, then Song A and Song B.
    static let playlist = Playlist(uuid: E.uuid("b1a7", 0x60), title: "Variables", items: [
        PlaylistItem(uuid: E.uuid("17e0", 1), kind: .header(label: "Welcome")),
        PlaylistItem(uuid: E.uuid("17e0", 2), kind: .linked(list: 60, listUuid: S.listUuid(60))),
        PlaylistItem(uuid: E.uuid("17e0", 3), kind: .linked(list: 61, listUuid: S.listUuid(61))),
    ])

    /// Stack 2's slot for channel 2: the context values at 0 and +1, a body
    /// box, and `[Popup 1]` at 0 and +1.
    static let stage = S.preset(9, "Stage", boxes: [
        S.label(context, 0, y: 0.02), S.label(context, 1, y: 0.14), S.body(0, y: 0.3),
        S.label("[Popup 1]", 0, y: 0.5), S.label("[Popup 1]", 1, y: 0.62),
    ])

    func engine(_ preset: Preset = stage, clock: SettableWallClock, edit: (inout Library, inout Machine) -> Void = { _, _ in }) throws -> HeadlessEngine {
        var library = try E.library()
        var machine = try E.spikeMachine()
        library.presets.append(preset)
        library.lists.append(contentsOf: [Self.songA, Self.songB, Self.popups])
        machine.playlists.append(Self.playlist)
        machine.stacks[1].slots[0].preset = preset.number
        edit(&library, &machine)
        return try HeadlessEngine(library: library, machine: machine, media: E.media, wallClock: { clock.now })
    }

    /// The text the static box with `raw` draws at `offset` on stack 2, or nil when it draws nothing.
    func shown(_ engine: HeadlessEngine, _ raw: String, offset: Int = 0, channel: Int = 2) -> String? {
        engine.boxes(stack: 2, channel: channel).first { box in
            guard case .static(let text) = box.binding.kind else { return false }
            return text == raw && box.offset == offset
        }?.text
    }

    /// The text the body box draws at offset 0 on stack 2.
    func body(_ engine: HeadlessEngine) -> String? {
        engine.boxes(stack: 2, channel: 2).first { box in
            guard case .field = box.binding.kind else { return false }
            return box.offset == 0
        }?.text
    }

    /// A second of the wall clock and six frames (100 ms) after `command`, so
    /// no change waits on the adoption pacing (Spec 6 §5).
    func step(_ engine: HeadlessEngine, _ clock: SettableWallClock, _ command: String? = nil) {
        clock.advance(seconds: 1)
        if let command { engine.send(command) }
        engine.tick(count: 6)
    }

    // MARK: - Context values (Spec 6 §5)

    /// "In text content, a value reads the content's provenance ... Content
    /// no cue wrote ... reads the state's pointer instead"; "In a static box,
    /// a value reads the state's pointer"; `[Next Title]` "skips headers ...
    /// and is empty after the last list". Spec 7 §4 — "A playlist loaded, no
    /// cue fired: Empty, but ... The first list's title".
    func test_contextValuesFollowThePointerInStaticBoxesAndTheProvenanceInContent() throws {
        let clock = SettableWallClock()
        let engine = try engine(clock: clock)
        let context = Self.context
        step(engine, clock, "playlist \"Variables\"")
        XCTAssertEqual(shown(engine, context), "|||||Song A", "loaded, no cue fired: only the first list's title")
        XCTAssertEqual(shown(engine, context, offset: 1), "Song A|Verse 1|Slow|PD A|111|Song B", "the +1 state: Song A's first cue")
        step(engine, clock, "next")
        XCTAssertEqual(shown(engine, context), "Song A|Verse 1|Slow|PD A|111|Song B")
        XCTAssertEqual(body(engine), "A one: Song A / Verse 1 / Slow", "the content's own cue and list")
        XCTAssertEqual(shown(engine, context, offset: 1), "Song A|Chorus||PD A|111|Song B")
        step(engine, clock, "item 3 cue 1")
        XCTAssertEqual(shown(engine, context), "Song B|Intro|Pads|PD B|222|", "the pointer, and nothing after the last list")
        XCTAssertEqual(body(engine), "A one: Song A / Verse 1 / Slow", "Song B's cue wrote channel 1: the body still reads the cue that wrote it")
        XCTAssertEqual(shown(engine, context, offset: 1), "Song B|Verse||PD B|222|")
        step(engine, clock, "channel 2 write text \"[Live Title] / [Section]\"")
        XCTAssertEqual(body(engine), "Song B / Intro", "content no cue wrote reads the pointer")
    }

    /// "`[Popup N]` reads the state's own popup text (Spec 3 §2), so a +1 box
    /// shows a popup that the next cue sets. The variables inside that text
    /// read the same state."
    func test_aPlusOneBoxShowsAPopupTheNextCueSetsReadInItsState() throws {
        let clock = SettableWallClock()
        let engine = try engine(clock: clock)
        step(engine, clock, "list 62 cue 1")
        XCTAssertNil(shown(engine, "[Popup 1]"), "no popup yet")
        XCTAssertEqual(shown(engine, "[Popup 1]", offset: 1), "Section: Two", "the next cue's popup, with the next cue's section")
        step(engine, clock, "next")
        XCTAssertEqual(shown(engine, "[Popup 1]"), "Section: Two")
        XCTAssertNil(shown(engine, "[Popup 1]", offset: 1), "past the list's last cue")
    }

    // MARK: - Popups (Spec 6 §5, §7)

    /// "A popup's text resolves its variables one level deep when a box shows
    /// it (§5, choice T-2) ... Brackets around anything that isn't a v1 name
    /// still print as written (T-1), so a caption's `[MUSIC]` shows as sent";
    /// "A `[Popup N]` inside a popup's text prints as written". "Clear-all.
    /// `system clearall` leaves popups as they are".
    func test_aPopupsVariablesResolveOneLevelDeepAndClearAllLeavesIt() throws {
        let clock = SettableWallClock()
        let engine = try engine(clock: clock)
        step(engine, clock, "list 42 cue 4")
        step(engine, clock, "popup 1 set \"Now: [Section] at [Time]\"")
        XCTAssertEqual(shown(engine, "[Popup 1]"), "Now: Chorus at 10:00 AM")
        step(engine, clock, "popup 1 set \"[Popup 2] then [MUSIC] [[x]]\"")
        XCTAssertEqual(shown(engine, "[Popup 1]"), "[Popup 2] then [MUSIC] [x]")
        step(engine, clock, "system clearall")
        XCTAssertEqual(engine.state.popups[1], "[Popup 2] then [MUSIC] [[x]]")
        XCTAssertEqual(shown(engine, "[Popup 1]"), "[Popup 2] then [MUSIC] [x]", "clear-all leaves popups")
    }

    // MARK: - Variables in text content (Spec 6 §5)

    /// "Where variables resolve. In static box text and in text content,
    /// wherever text is rendered"; "Doubled brackets print one bracket";
    /// T-1 — "a lyric's `[Chorus]` or `[x2]` shows unchanged".
    func test_variablesResolveInTextContent() throws {
        let clock = SettableWallClock()
        let engine = try engine(clock: clock)
        step(engine, clock, "channel 2 write text \"[[Verse]] at [Time] [x2]\"")
        XCTAssertEqual(body(engine), "[Verse] at 10:00 AM [x2]", "the time, the brackets as written")
        // A field that is empty once its variables resolve hides the box.
        step(engine, clock, "channel 2 write text \"[Popup 1]\"")
        XCTAssertNil(body(engine), "an empty field hides the box")
        step(engine, clock, "popup 1 set \"Caption\"")
        XCTAssertEqual(body(engine), "Caption")
    }

    // MARK: - Clocked values and formats (Spec 6 §5)

    /// "`[Date]` Today, in the machine's time zone | `MMMM d` (choice T-9)",
    /// and its other formats; the harness's clock is Friday 30 October 2026,
    /// 10:00 in America/New_York.
    func test_theDateAndTheTimeInEachFormat() throws {
        let clock = SettableWallClock()
        let engine = try engine(S.preset(9, boxes: [S.label("[Date]", 0, y: 0.02), S.label("[Date EEEE, MMMM d]", 0, y: 0.14),
                                                    S.label("[Date yyyy-MM-dd]", 0, y: 0.26), S.label("[Time HH:mm]", 0, y: 0.38),
                                                    S.label("[time h:mm:ss a]", 0, y: 0.5)]), clock: clock)
        step(engine, clock)
        XCTAssertEqual(shown(engine, "[Date]"), "October 30")
        XCTAssertEqual(shown(engine, "[Date EEEE, MMMM d]"), "Friday, October 30")
        XCTAssertEqual(shown(engine, "[Date yyyy-MM-dd]"), "2026-10-30")
        XCTAssertEqual(shown(engine, "[Time HH:mm]"), "10:00")
        XCTAssertEqual(shown(engine, "[time h:mm:ss a]"), "10:00:01 AM")
    }

    /// "A timer or popup number above the machine's count is still a v1 name.
    /// It resolves empty"; "`[Timer N]` ... empty while unset".
    func test_aTimerOrAPopupAboveTheCountResolvesEmpty() throws {
        let clock = SettableWallClock()
        let engine = try engine(S.preset(9, boxes: [S.label("T [Timer 9] P [Popup 9]", 0, y: 0.02), S.label("[Timer 1]", 0, y: 0.14)]), clock: clock)
        step(engine, clock)
        XCTAssertEqual(shown(engine, "T [Timer 9] P [Popup 9]"), "T  P ")
        XCTAssertNil(shown(engine, "[Timer 1]"), "every timer is unset")
    }

    /// "A format outside the set, or `overrun` on anything but a timer,
    /// renders with the default and is logged once per box. So does a machine
    /// `timeFormat` outside the `[Time]` set."
    func test_anUnknownFormatFallsBackWithOneLogLinePerBox() throws {
        let clock = SettableWallClock()
        let engine = try engine(S.preset(9, boxes: [S.label("[Time HH:mm:ss]", 0, y: 0.02), S.label("[Date dd/MM]", 0, y: 0.14),
                                                    S.label("[Section x]", 0, y: 0.26)]), clock: clock) { _, machine in
            machine.settings.timeFormat = "HH:mm:ss"
        }
        step(engine, clock, "list 42 cue 4")
        for _ in 0..<5 { step(engine, clock) }
        XCTAssertEqual(shown(engine, "[Time HH:mm:ss]"), "10:00 AM")
        XCTAssertEqual(shown(engine, "[Date dd/MM]"), "October 30")
        XCTAssertEqual(shown(engine, "[Section x]"), "Chorus")
        XCTAssertEqual(shown(engine, "[Time]", channel: 3), "10:00 AM", "the Clock's [Time] with the machine's format outside the set")
        let lines = engine.log.recent.map(\.message)
        for token in ["[Time HH:mm:ss]", "[Date dd/MM]", "[Section x]"] {
            XCTAssertEqual(lines.filter { $0.contains(token) }.count, 1, "\(token): \(lines)")
        }
        XCTAssertEqual(lines.filter { $0.contains("timeFormat \"HH:mm:ss\"") }.count, 1, "the Clock's one box: \(lines)")
    }

    // MARK: - Thumbnails (Spec 6 §5)

    /// "Context values and list metadata come from the state being drawn: the
    /// live state, an offset box's lookahead state, or a thumbnail's projected
    /// state"; "A projected state has no playlist, so in a thumbnail it is
    /// empty"; "`[Service In]` reads the live playlist"; "A thumbnail shows
    /// them as they were when it rendered".
    func test_aThumbnailReadsItsProjectedState() throws {
        let metal = try MetalHarness.backend()
        var library = try E.library()
        var machine = try E.spikeMachine()
        library.presets.append(S.preset(9, "Stage", boxes: [S.label(Self.context, 0, y: 0.02), S.label(Self.context, 1, y: 0.14),
                                                            S.body(0, y: 0.3), S.label("[Service In]", 0, y: 0.5)]))
        library.lists.append(contentsOf: [Self.songA, Self.songB])
        machine.stacks[1].slots[0].preset = 9
        machine.settings.thumbnailStack = 2
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-thumbnails-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = EngineLog(category: "test-thumbnails")
        let variables = VariableProvider(settings: machine.settings, wallClock: HeadlessEngine.fixedWallClock)
        let service = try ThumbnailService(library: library, machine: machine, media: E.media, backend: metal,
                                           posters: ImagePosterProvider(backend: metal, media: E.media, log: log),
                                           variables: variables, cacheFolder: folder, log: log)
        variables.publish(livePlaylist: machine.playlists.first { $0.title == "Sunday Night" }, timers: [:])
        let roots = (library: service.library, machine: service.machine)
        let states = service.projectedStates(of: Self.songA, through: 1, roots: roots)
        let pass = service.stackPass(states: states, index: 0, roots: roots, list: Self.songA)
        func text(_ raw: String, _ offset: Int) -> String? {
            pass.boxes.first { box in
                guard case .static(let text) = box.binding.kind else { return false }
                return text == raw && box.offset == offset
            }?.text
        }
        XCTAssertEqual(text(Self.context, 0), "Song A|Verse 1|Slow|PD A|111|", "the cue drawn; no next title in a thumbnail")
        XCTAssertEqual(text(Self.context, 1), "Song A|Chorus||PD A|111|", "the +1 box: the list's next cue")
        XCTAssertEqual(pass.boxes.first { if case .field = $0.binding.kind { return $0.offset == 0 } else { return false } }?.text,
                       "A one: Song A / Verse 1 / Slow")
        XCTAssertEqual(text("[Service In]", 0), "8:00:00", "the live playlist, Sunday Night at 18:00, from 10:00")
    }
}

/// Spec 6 §11, Area 11 — "`[Service In]`. Dated and undated playlists,
/// before, at and after the time, and across midnight. It is empty with no
/// `serviceTime` and with no playlist live." Spec 6 §5 — "On a dated
/// playlist it counts to that time on its `serviceDate`; on an undated one,
/// to that time today. Once the time arrives it shows `0:00`, and an undated
/// playlist starts counting again at midnight, toward the next day's time
/// (choice T-3). It reads only the live playlist, whatever state is being
/// drawn."
final class ServiceInTests: XCTestCase {
    typealias S = StageFixtures
    typealias E = EngineFixtures

    static let dated = Playlist(uuid: E.uuid("b1a7", 0x61), title: "Dated", serviceDate: "2026-10-30", serviceTime: "10:30", items: [
        PlaylistItem(uuid: E.uuid("17e1", 1), kind: .linked(list: 42, listUuid: E.list42)),
    ])
    static let sunday9 = Playlist(uuid: E.uuid("b1a7", 0x62), title: "Sunday Nine", serviceDate: "2026-11-01", serviceTime: "09:00", items: [
        PlaylistItem(uuid: E.uuid("17e2", 1), kind: .linked(list: 42, listUuid: E.list42)),
    ])
    static let saturday9 = Playlist(uuid: E.uuid("b1a7", 0x63), title: "Saturday Nine", serviceDate: "2026-10-31", serviceTime: "09:00", items: [
        PlaylistItem(uuid: E.uuid("17e3", 1), kind: .linked(list: 42, listUuid: E.list42)),
    ])
    static let garbled = Playlist(uuid: E.uuid("b1a7", 0x64), title: "Garbled", serviceDate: nil, serviceTime: "6pm", items: [
        PlaylistItem(uuid: E.uuid("17e4", 1), kind: .linked(list: 42, listUuid: E.list42)),
    ])

    func engine(_ clock: SettableWallClock) throws -> HeadlessEngine {
        var library = try E.library()
        var machine = try E.spikeMachine()
        library.presets.append(S.preset(9, boxes: [S.label("[Service In]", 0, y: 0.02), S.label("[Service In mm:ss]", 0, y: 0.14),
                                                   S.label("[Service In h:mm:ss]", 0, y: 0.26), S.label("[Service In]", 1, y: 0.38)]))
        machine.playlists.append(contentsOf: [Self.dated, Self.sunday9, Self.saturday9, Self.garbled])
        machine.stacks[1].slots[0].preset = 9
        return try HeadlessEngine(library: library, machine: machine, media: E.media, wallClock: { clock.now })
    }

    func serviceIn(_ engine: HeadlessEngine, _ raw: String = "[Service In]", offset: Int = 0) -> String? {
        engine.boxes(stack: 2, channel: 2).first { box in
            guard case .static(let text) = box.binding.kind else { return false }
            return text == raw && box.offset == offset
        }?.text
    }

    func at(_ engine: HeadlessEngine, _ clock: SettableWallClock, _ date: Date) {
        clock.set(date)
        engine.tick()
    }

    typealias C = SettableWallClock

    func test_aDatedPlaylistCountsToItsTimeOnItsDateAndHoldsAtZero() throws {
        let clock = SettableWallClock(C.at(2026, 10, 30, 10, 0))
        let engine = try engine(clock)
        engine.send("playlist \"Dated\"")
        engine.tick()
        XCTAssertEqual(serviceIn(engine), "30:00", "loaded, no cue fired: it reads the playlist")
        XCTAssertEqual(serviceIn(engine, "[Service In mm:ss]"), "30:00")
        XCTAssertEqual(serviceIn(engine, "[Service In h:mm:ss]"), "0:30:00")
        XCTAssertEqual(serviceIn(engine, offset: 1), "30:00", "it reads only the live playlist, whatever state is drawn")
        at(engine, clock, C.at(2026, 10, 30, 10, 29, 59))
        XCTAssertEqual(serviceIn(engine), "0:01")
        at(engine, clock, C.at(2026, 10, 30, 10, 29, 59.5))
        XCTAssertEqual(serviceIn(engine), "0:01", "rounded up")
        at(engine, clock, C.at(2026, 10, 30, 10, 30))
        XCTAssertEqual(serviceIn(engine), "0:00", "the time arrives")
        at(engine, clock, C.at(2026, 10, 30, 11, 45))
        XCTAssertEqual(serviceIn(engine), "0:00", "it holds")
        at(engine, clock, C.at(2026, 10, 31, 9, 0))
        XCTAssertEqual(serviceIn(engine), "0:00", "a dated playlist does not count again")
    }

    /// The Sunday Night fixture: undated, at 18:00.
    func test_anUndatedPlaylistCountsToItsTimeTodayAndAgainFromMidnight() throws {
        let clock = SettableWallClock(C.at(2026, 10, 30, 10, 0))
        let engine = try engine(clock)
        engine.send("playlist \"Sunday Night\"")
        engine.tick()
        XCTAssertEqual(serviceIn(engine), "8:00:00")
        XCTAssertEqual(serviceIn(engine, "[Service In mm:ss]"), "480:00")
        at(engine, clock, C.at(2026, 10, 30, 17, 59, 30))
        XCTAssertEqual(serviceIn(engine), "0:30")
        at(engine, clock, C.at(2026, 10, 30, 18, 0))
        XCTAssertEqual(serviceIn(engine), "0:00")
        at(engine, clock, C.at(2026, 10, 30, 23, 59, 59))
        XCTAssertEqual(serviceIn(engine), "0:00", "it holds until midnight (choice T-3)")
        at(engine, clock, C.at(2026, 10, 31, 0, 0))
        XCTAssertEqual(serviceIn(engine), "18:00:00", "toward the next day's time")
        at(engine, clock, C.at(2026, 10, 31, 0, 0, 1))
        XCTAssertEqual(serviceIn(engine), "17:59:59")
    }

    /// Across midnight to a dated service the next day, and across the change
    /// of clocks on 1 November 2026: from Friday 10:00 EDT to Sunday 09:00 EST
    /// is 48 hours.
    func test_acrossMidnightAndAChangeOfClocks() throws {
        let clock = SettableWallClock(C.at(2026, 10, 30, 23, 59, 30))
        let engine = try engine(clock)
        engine.send("playlist \"Saturday Nine\"")
        engine.tick()
        XCTAssertEqual(serviceIn(engine), "9:00:30")
        at(engine, clock, C.at(2026, 10, 31, 0, 0, 30))
        XCTAssertEqual(serviceIn(engine), "8:59:30")
        // A new playlist and a new second together: "[Service In] alone changes the box at most once per
        // wall-clock second" (Spec 6 §5), so the load lands in a second of its own.
        clock.set(C.at(2026, 10, 30, 10, 0))
        engine.send("playlist \"Sunday Nine\"")
        engine.tick()
        XCTAssertEqual(serviceIn(engine), "48:00:00")
    }

    /// "It is empty when no playlist is live or the live one has no
    /// `serviceTime`." A `serviceTime` that doesn't read, from a hand-made
    /// file, leaves it empty too.
    func test_itIsEmptyWithNoServiceTimeAndNoPlaylistLive() throws {
        let clock = SettableWallClock(C.at(2026, 10, 30, 10, 0))
        let engine = try engine(clock)
        engine.tick()
        XCTAssertNil(serviceIn(engine), "nothing loaded")
        at(engine, clock, C.at(2026, 10, 30, 10, 0, 1))
        engine.send("playlist \"Sunday\"")
        engine.tick()
        XCTAssertNil(serviceIn(engine), "Sunday has no serviceTime")
        at(engine, clock, C.at(2026, 10, 30, 10, 0, 2))
        engine.send("playlist \"Garbled\"")
        engine.tick()
        XCTAssertNil(serviceIn(engine), "a serviceTime that doesn't read")
        at(engine, clock, C.at(2026, 10, 30, 10, 0, 3))
        engine.send("list 42 cue 1")
        engine.tick()
        XCTAssertNil(serviceIn(engine), "a list fired from the library: no playlist live")
    }
}
