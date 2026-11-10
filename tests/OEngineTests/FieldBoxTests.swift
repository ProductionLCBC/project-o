import XCTest
import OCore
@testable import OEngine

/// Spec 6 §3 — "Field boxes draw a field of the channel's text content: the
/// write's `fields` map, under the box's name (Spec 1 §2). If the write has no
/// such field, a box named `title`, `author`, `copyright` or `ccli` falls back
/// to the list's metadata of the same name (P12). A copyright slide is
/// therefore a text write with no fields." "'The list' is the one §5 names for
/// the content: the list whose cue wrote it, or the state's pointer for
/// content no cue wrote." "A field box draws only for text content. On media
/// or an empty channel it draws nothing." Spec 6 §11, Area 6: Field fallback.
final class FieldBoxTests: XCTestCase {
    typealias S = StageFixtures

    /// The four metadata boxes, as the fixture's preset 4 (Credits) will hold
    /// them (Spec 6 §9); numbered 9 here so it never meets the fixture's.
    static let credits = S.preset(9, "Credits", boxes: [S.body(0, y: 0.1, name: "title"), S.body(0, y: 0.3, name: "author"),
                                                        S.body(0, y: 0.5, name: "copyright"), S.body(0, y: 0.7, name: "ccli")])

    static let songA = S.list(60, title: "Song A", author: "Author A", copyright: "Copyright A", ccli: "1001", cues: [
        [S.fields([:])], [S.fields(["title": "Its own title"])], [S.media()], [S.fields(["title": ""])],
    ])
    /// Two songs' copyright slides: the same write, no fields, in two lists.
    static let slideA = S.list(62, title: "Song A", author: "Author A", copyright: "Copyright A", ccli: "1001", cues: [[S.fields([:])]])
    static let slideB = S.list(63, title: "Song B", author: "Author B", copyright: "Copyright B", ccli: "1002", cues: [[S.fields([:])]])
    static let run = Playlist(uuid: EngineFixtures.uuid("91a7", 1), title: "Credits run", items: [
        .linked(list: 62, listUuid: S.listUuid(62), uuid: EngineFixtures.uuid("17e0", 1)),
        .linked(list: 63, listUuid: S.listUuid(63), uuid: EngineFixtures.uuid("17e0", 2)),
    ])

    func engine(_ preset: Preset = FieldBoxTests.credits) throws -> HeadlessEngine {
        try S.engine(preset: preset, lists: [Self.songA, Self.slideA, Self.slideB], playlists: [Self.run])
    }

    /// The text each field box of stack 2 draws for channel 2, by field name.
    func fields(_ engine: HeadlessEngine, offset: Int = 0) -> [String: String] {
        var out: [String: String] = [:]
        for box in engine.boxes(stack: 2, channel: 2) where box.offset == offset {
            if case .field(let name) = box.binding.kind { out[name] = box.text ?? "" }
        }
        return out
    }

    func typed(_ fields: [String: String]) -> CommandGroup {
        CommandGroup(id: GroupID.random(), source: CommandSource(kind: .ui), commands: [GuardedCommand(S.fields(fields))])
    }

    func test_aTextWriteWithNoFieldsDrawsTheListsMetadata() throws {
        let engine = try engine()
        engine.send("list 60 cue 1")
        engine.tick()
        XCTAssertEqual(fields(engine), ["title": "Song A", "author": "Author A", "copyright": "Copyright A", "ccli": "1001"])
    }

    func test_aWritesOwnFieldWinsAndAnEmptyOneHidesItsBox() throws {
        let engine = try engine()
        engine.send("list 60 cue 2")
        engine.tick()
        XCTAssertEqual(fields(engine), ["title": "Its own title", "author": "Author A", "copyright": "Copyright A", "ccli": "1001"])
        engine.send("list 60 cue 4")
        engine.tick()
        XCTAssertEqual(fields(engine), ["author": "Author A", "copyright": "Copyright A", "ccli": "1001"],
                       "a field written empty is the write's own and hides its box")
    }

    /// Spec 6 §11 — "Back-to-back empty-field writes from two lists show the
    /// second list's metadata, live and at +1." With Adam's answer of
    /// 2026-11-10, the title box runs its own transition when its text changes.
    func test_backToBackEmptyFieldWritesFromTwoListsShowTheSecondListLiveAndAtPlusOne() throws {
        let dissolve = BoxTransition(ref: 2, ms: 500)
        let engine = try engine(S.preset(9, "Titles", boxes: [S.body(0, y: 0.1, transition: dissolve, name: "title"), S.body(1, y: 0.6, name: "title")]))
        engine.send("playlist \"Credits run\"")
        engine.send("next")
        engine.tick()
        XCTAssertEqual(fields(engine), ["title": "Song A"])
        XCTAssertEqual(fields(engine, offset: 1), ["title": "Song B"], "the next slide's write is identical but its list is song B's")
        engine.send("next")
        engine.tick()
        XCTAssertEqual(fields(engine), ["title": "Song B"])
        XCTAssertEqual(fields(engine, offset: 1), [:], "past the end")
        let title = try XCTUnwrap(engine.boxes(stack: 2, channel: 2).first { $0.offset == 0 })
        XCTAssertEqual(title.transition?.type, .dissolve, "the title box's text changed, so it runs its own transition")
        let write = engine.lastExecuted.first { $0.command == S.fields([:]) && $0.source.list == S.listUuid(63) }
        XCTAssertEqual(write?.result, .ok, "the identical write updated the provenance: not a noop")
    }

    /// Spec 6 §3 — the metadata fallback is part of the text rasterized ahead.
    func test_theFallbackTextOfTheNextCueIsRasterizedAhead() throws {
        let engine = try engine(S.preset(9, "Title", boxes: [S.body(0, y: 0.1, name: "title")]))
        let fake = try XCTUnwrap(engine.fakeText)
        fake.missAll = true
        engine.send("playlist \"Credits run\"")
        engine.send("next")
        engine.tick()
        XCTAssertTrue(fake.requested.contains { $0.text == "Song B" }, "\(fake.requested.map(\.text))")
    }

    /// Spec 6 §5 — "Content no cue wrote, from the UI, a key, OSC, the API or
    /// the scheduler, reads the state's pointer instead."
    func test_contentFromTheUIFallsBackToThePointersList() throws {
        let engine = try engine()
        engine.send(typed(["body": "typed"]))
        engine.tick()
        XCTAssertEqual(fields(engine), [:], "no pointer, so no list")
        engine.send("list 60 cue 3")
        engine.tick()
        engine.send(typed(["body": "typed again"]))
        engine.tick()
        XCTAssertEqual(fields(engine), ["title": "Song A", "author": "Author A", "copyright": "Copyright A", "ccli": "1001"])
    }

    func test_mediaAndAnEmptyChannelDrawNoFieldBox() throws {
        let engine = try engine()
        engine.tick()
        XCTAssertEqual(fields(engine), [:], "an empty channel")
        engine.send("list 60 cue 3")
        engine.tick()
        XCTAssertEqual(fields(engine), [:], "media, though list 60 is live")
        engine.send("list 60 cue 1")
        engine.tick()
        XCTAssertEqual(fields(engine).count, 4)
        engine.send("channel 2 clear")
        engine.tick()
        XCTAssertEqual(fields(engine), [:], "cleared")
    }
}

/// Spec 6 §3 — "Static boxes draw their own text, with its variables resolved,
/// whatever the channel holds, even when it is empty ... Slot mute, opacity
/// and blackout apply to them as to any box, so `channel N clear` and `system
/// clearall` leave a clock showing, and muting its slot hides it." Spec 6 §11,
/// Area 6: Static boxes.
final class StaticBoxTests: XCTestCase {
    func engine() throws -> HeadlessEngine {
        try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot)
    }

    /// Stack 2's `[Time]` box, drawn or not.
    func clock(_ engine: HeadlessEngine) -> ResolvedBox? {
        engine.boxes(stack: 2).first { if case .static = $0.binding.kind { return true } else { return false } }
    }

    func test_aStaticBoxDrawsOnAnEmptyChannelAndAfterAClearOrAClearAll() throws {
        let engine = try engine()
        engine.tick()
        XCTAssertEqual(clock(engine)?.text, "10:00 AM", "channel 2 is empty")
        engine.send("channel 2 write text \"Words\"")
        engine.tick()
        engine.send("channel 2 clear")
        engine.tick()
        XCTAssertEqual(clock(engine)?.text, "10:00 AM", "after a clear")
        engine.send("channel 2 write text \"Words\"")
        engine.tick()
        engine.send("system clearall")
        engine.tick()
        XCTAssertEqual(clock(engine)?.text, "10:00 AM", "after a clear-all")
        XCTAssertEqual(clock(engine)?.opacity, 1)
    }

    func test_aStaticBoxHidesWhenItsSlotIsMuted() throws {
        let engine = try engine()
        engine.send("stack 2 mute 2 on")
        engine.tick()
        XCTAssertEqual(clock(engine)?.opacity, 0)
        XCTAssertFalse(engine.lastPlan?.stackPasses.first { $0.stack == 2 }?.drawnBoxes.contains { $0.binding.isText } ?? true, "nothing of the slot is drawn")
        engine.send("stack 2 mute 2 off")
        engine.tick()
        XCTAssertEqual(clock(engine)?.opacity, 1)
    }

    /// Spec 4 §9, §10 — blackout is a mix at the sink, so it takes the clock out with its stack.
    func test_blackoutTakesAStaticBoxOutWithItsStack() throws {
        let engine = try engine()
        engine.send("stack 2 blackout on")
        engine.tick(count: 40)   // output 2's blackout transition is the 500 ms dissolve
        XCTAssertEqual(clock(engine)?.text, "10:00 AM", "the box still resolves")
        let sink = try XCTUnwrap(engine.lastPlan?.sinkPasses.first { $0.output == 2 })
        XCTAssertEqual(sink.second, .black)
        XCTAssertEqual(sink.mix, 1, accuracy: 0.0001)
    }
}
