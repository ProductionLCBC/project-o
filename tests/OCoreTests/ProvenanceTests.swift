import Foundation
import XCTest
@testable import OCore

/// Spec 3 §2 (corrected by Spec 6 §10) — `provenance`: "the cue uuid that
/// wrote it and the uuid of the list it was fired from, also for a write by a
/// macro the cue ran; or `restored`, keeping the cue and list it had; or the
/// source kind". Spec 3 §4 — "Identical fields from another cue or list update
/// the provenance alone, with no transition (Spec 6 §5)." Spec 6 §11, Area 6:
/// "A cue's write records its cue and list, and so does a write by a macro
/// that cue ran. An identical text write from another list updates the
/// provenance with no transition, and the same cue firing again stays a
/// `noop` (Spec 3 §9 row 3)."
final class ProvenanceTests: XCTestCase {
    typealias F = Fixtures

    /// Two lists whose first cues write the same text to channel 2 with no
    /// fields: two songs' copyright slides (Spec 6 §3).
    private var library: Library {
        var library = F.library
        let slide = Command.channelWrite(ChannelWrite(channel: .number(2), content: .text(fields: [:])))
        library.lists.append(List(uuid: F.listUuid(8), number: 8, title: "Song A", cues: [F.cue(list: 8, 1, commands: [slide])]))
        library.lists.append(List(uuid: F.listUuid(9), number: 9, title: "Song B", cues: [F.cue(list: 9, 1, commands: [slide])]))
        return library
    }

    private func run(_ state: ShowState, _ commands: [Command], source: SourceKind = .ui) -> (ShowState, [Effect]) {
        project(state, commands, context: F.context(frame: 100, source: source, library: library))
    }

    private func transitions(on channel: Int, _ effects: [Effect]) -> [TransitionEffect] {
        effects.compactMap(\.transitionEffect).filter { $0.channel == channel }
    }

    // MARK: - Recording

    func test_aCuesWriteRecordsItsCueAndItsList() {
        let (fired, _) = run(F.fresh(), [.listCue(list: 1, cue: 1)])
        XCTAssertEqual(fired.channels[2]?.provenance, .cue(F.cueUuid(list: 1, cue: 1), list: F.listUuid(1)))
        XCTAssertEqual(fired.channels[1]?.provenance, .cue(F.cueUuid(list: 1, cue: 1), list: F.listUuid(1)))

        // Through the playlist: item 2 links list 1, and `next` fires its second cue.
        let (loaded, _) = run(F.fresh(), [.playlistLoad(title: "Sunday"), .next, .next])
        XCTAssertEqual(loaded.channels[2]?.provenance, .cue(F.cueUuid(list: 1, cue: 2), list: F.listUuid(1)))
    }

    func test_aWriteByAMacroACueRanRecordsThatCueAndItsList() {
        // List 7's cue runs macro 2, which writes channel 2.
        let (fired, _) = run(F.fresh(), [.listCue(list: 7, cue: 1)])
        XCTAssertEqual(fired.channels[2]?.content, .text(TextInstance(fields: ["body": "from macro"])))
        XCTAssertEqual(fired.channels[2]?.provenance, .cue(F.cueUuid(list: 7, cue: 1), list: F.listUuid(7)))
    }

    func test_contentNoCueWroteRecordsItsSourceKind() {
        let (written, _) = run(F.fresh(), [F.write(2, text: "x")], source: .osc)
        XCTAssertEqual(written.channels[2]?.provenance, .source(.osc))
        XCTAssertNil(written.channels[2]?.provenance?.list)
    }

    // MARK: - The identical-text rule (Spec 3 §4)

    func test_anIdenticalWriteFromAnotherListUpdatesTheProvenanceWithNoTransition() throws {
        let slide = Command.channelWrite(ChannelWrite(channel: .number(2), content: .text(fields: [:])))
        let (songA, _) = run(F.fresh(), [.listCue(list: 8, cue: 1)])
        XCTAssertEqual(songA.channels[2]?.provenance, .cue(F.cueUuid(list: 8, cue: 1), list: F.listUuid(8)))

        let (songB, effects) = run(songA, [.listCue(list: 9, cue: 1)])
        XCTAssertEqual(songB.channels[2]?.content, songA.channels[2]?.content, "the fields are the same")
        XCTAssertEqual(songB.channels[2]?.provenance, .cue(F.cueUuid(list: 9, cue: 1), list: F.listUuid(9)), "song B's slide names song B")
        XCTAssertTrue(transitions(on: 2, effects).isEmpty, "no transition: \(effects)")
        XCTAssertTrue(effects.contains(.applied(slide)), "the provenance alone changed: \(effects)")
        XCTAssertFalse(effects.contains(.noop(slide)))
    }

    func test_theSameCueFiringAgainStaysANoop() {
        let slide = Command.channelWrite(ChannelWrite(channel: .number(2), content: .text(fields: [:])))
        let (once, _) = run(F.fresh(), [.listCue(list: 8, cue: 1)])
        let (twice, effects) = run(once, [.listCue(list: 8, cue: 1)])
        XCTAssertEqual(twice.channels[2], once.channels[2])
        XCTAssertTrue(effects.contains(.noop(slide)), "\(effects)")
        XCTAssertTrue(transitions(on: 2, effects).isEmpty)
    }

    func test_identicalFieldsFromAnotherSourceTakeThatSource() {
        let write = F.write(2, text: "verse 1")
        let (fired, _) = run(F.fresh(), [.listCue(list: 1, cue: 1)])
        let (typed, effects) = run(fired, [write], source: .ui)
        XCTAssertEqual(typed.channels[2]?.content, fired.channels[2]?.content)
        XCTAssertEqual(typed.channels[2]?.provenance, .source(.ui))
        XCTAssertEqual(effects, [.applied(write)])
        // And from the UI again: identical fields and provenance, a noop.
        XCTAssertEqual(run(typed, [write], source: .ui).1, [.noop(write)])
    }

    /// Spec 3 §9 row 5 — riders on identical text still apply; with the
    /// provenance unchanged they are the only effects.
    func test_ridersOnIdenticalTextStillApply() {
        let plain = F.write(2, text: "y")
        let graded = F.write(2, text: "y", riders: Riders(grade: GradeRider(ref: 6, scope: .once)))
        let (first, _) = run(F.fresh(), [plain])
        let (second, effects) = run(first, [graded])
        XCTAssertEqual(second.channels[2]?.attributes.grade.value, 6)
        XCTAssertEqual(second.channels[2]?.provenance, .source(.ui))
        XCTAssertTrue(transitions(on: 2, effects).isEmpty)
        XCTAssertFalse(effects.contains(.applied(graded)))
    }

    // MARK: - Restores (Spec 3 §8)

    func test_aRestoredChannelKeepsTheCueAndListItHad() {
        let cue = Provenance.cue(F.cueUuid(list: 1, cue: 2), list: F.listUuid(1))
        XCTAssertEqual(Provenance.restored(from: cue), .restored(cue: F.cueUuid(list: 1, cue: 2), list: F.listUuid(1)))
        XCTAssertEqual(Provenance.restored(from: Provenance.restored(from: cue)), Provenance.restored(from: cue), "a second restore keeps them too")
        XCTAssertEqual(Provenance.restored(from: .source(.ui)), .restored(cue: nil, list: nil))
        XCTAssertEqual(Provenance.restored(from: nil), .restored(cue: nil, list: nil))
    }

    // MARK: - The file shape (Spec 1 §5, §9; Spec 10 §3's example)

    func test_theJSONNamesTheCueAndTheListAndReadsTheOlderShapes() throws {
        let cue = F.cueUuid(list: 1, cue: 2)
        let list = F.listUuid(1)
        let lower = { (u: UUID) in u.uuidString.lowercased() }
        let written = try JSONCoding.encode(Provenance.cue(cue, list: list))
        XCTAssertEqual(written, .object(["kind": .string("cue"), "cue": .string(lower(cue)), "list": .string(lower(list))]))
        XCTAssertEqual(try JSONCoding.encode(Provenance.restored(cue: nil, list: nil)), .object(["kind": .string("restored")]))
        XCTAssertEqual(try JSONCoding.encode(Provenance.restored(cue: cue, list: list)),
                       .object(["kind": .string("restored"), "cue": .string(lower(cue)), "list": .string(lower(list))]))

        // Before Spec 6 a cue's provenance had no list, and `restored` nothing.
        let older = JSONValue.object(["kind": .string("cue"), "cue": .string(lower(cue))])
        XCTAssertEqual(try JSONCoding.decode(Provenance.self, from: older), .cue(cue, list: nil))
        XCTAssertEqual(try JSONCoding.encode(try JSONCoding.decode(Provenance.self, from: older)), older, "an older shape is written back as read")
        XCTAssertEqual(try JSONCoding.decode(Provenance.self, from: .object(["kind": .string("restored")])), .restored(cue: nil, list: nil))
    }
}

/// Spec 6 §3 and §5 — "the list" a channel's content reads: "the list whose
/// cue wrote it, or the state's pointer for content no cue wrote", looked up
/// in the library, the local copies, or the kept copy (Spec 7 §4).
final class ContentListTests: XCTestCase {
    typealias F = FixtureLibrary

    private var roots: (library: Library, machine: Machine) {
        let (library, machine, _) = F.load()
        return (library, machine)
    }

    private func state(provenance: Provenance?, pointerList: UUID? = nil, machine: Machine) -> ShowState {
        let (library, _) = roots
        var state = ShowState.fresh(library: library, machine: machine)
        state.channels[2]?.content = .text(TextInstance(fields: [:]))
        state.channels[2]?.provenance = provenance
        state.pointer = pointerList.map { LivePointer(playlist: nil, itemUuid: nil, listUuid: $0, cueUuid: nil) }
        return state
    }

    func test_contentACueWroteReadsThatCuesList() throws {
        let (library, machine) = roots
        let shown = state(provenance: .cue(F.list42Cues[0], list: F.listUuid(42)), pointerList: F.listUuid(7), machine: machine)
        let list = try XCTUnwrap(shown.contentList(channel: 2, library: library, machine: machine))
        XCTAssertEqual(list.uuid, F.listUuid(42), "the cue's list, not the pointer's")
        XCTAssertEqual(list.metadata("title"), "Great Is Thy Faithfulness")
        XCTAssertEqual(list.metadata("author"), "Thomas Chisholm")
        XCTAssertEqual(list.metadata("copyright"), "Public domain")
        XCTAssertEqual(list.metadata("ccli"), "18723")
        XCTAssertNil(list.metadata("body"), "only the four list fields fall back")
        XCTAssertEqual(List.metadataFields, ["title", "author", "copyright", "ccli"])

        let restored = state(provenance: .restored(cue: F.list42Cues[0], list: F.listUuid(42)), pointerList: F.listUuid(7), machine: machine)
        XCTAssertEqual(restored.contentList(channel: 2, library: library, machine: machine)?.uuid, F.listUuid(42),
                       "a restored channel keeps the cue and list it had")
    }

    func test_aLocalCopyAndAKeptCopyAreFound() throws {
        let (library, machine) = roots
        let local = state(provenance: .cue(F.list42Cues[0], list: F.localCopyUuid), machine: machine)
        XCTAssertEqual(local.contentList(channel: 2, library: library, machine: machine)?.uuid, F.localCopyUuid)

        // The live list was deleted from the library: its kept copy stands in (Spec 7 §4).
        var without = library
        let gone = try XCTUnwrap(library.list(number: 7))
        without.lists.removeAll { $0.uuid == gone.uuid }
        let kept = KeptCopies(list: gone)
        let shown = state(provenance: .cue(gone.cues[0].uuid, list: gone.uuid), machine: machine)
        XCTAssertNil(shown.contentList(channel: 2, library: without, machine: machine))
        XCTAssertEqual(shown.contentList(channel: 2, library: without, machine: machine, kept: kept)?.uuid, gone.uuid)
    }

    func test_contentNoCueWroteReadsThePointersList() {
        let (library, machine) = roots
        let typed = state(provenance: .source(.ui), pointerList: F.listUuid(7), machine: machine)
        XCTAssertEqual(typed.contentList(channel: 2, library: library, machine: machine)?.uuid, F.listUuid(7))
        let older = state(provenance: .cue(F.list42Cues[0], list: nil), pointerList: F.listUuid(7), machine: machine)
        XCTAssertEqual(older.contentList(channel: 2, library: library, machine: machine)?.uuid, F.listUuid(7),
                       "a cue provenance written before lists were recorded reads the pointer's list")
        let nothing = state(provenance: .source(.ui), machine: machine)
        XCTAssertNil(nothing.contentList(channel: 2, library: library, machine: machine), "no pointer, no list")
        let missing = state(provenance: .cue(F.list42Cues[0], list: UUID()), machine: machine)
        XCTAssertNil(missing.contentList(channel: 2, library: library, machine: machine))
    }
}
