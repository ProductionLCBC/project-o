import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §13, "Area 14, the Cues page" — what the inspector's four columns
/// show for one cue and for several: "the Trigger column and both pair
/// warnings; Use Previous Video's Length", the commands' rows, the chips,
/// and "multi-cue chips ... a field whose cues differ reads "Mixed"". Also
/// the top bar's short status and the Program panel's pill (Spec 11 §2).
@MainActor
final class CueInspectorTests: XCTestCase {
    private func inspector(_ name: String, uuid: String, cues: [Int], row: CueGridSelection.Row, tracking: Bool = true,
                           change: (inout ListDocument) -> Void = { _ in }) throws -> CueInspector {
        var document = try Recorded.list(name)
        change(&document)
        var catalog = try Recorded.catalog()
        if !tracking {
            var settings = catalog.settings ?? MachineSettings()
            settings.tracking.gain = false
            settings.tracking.transition = false
            catalog.settings = settings
        }
        var inputs = try Recorded.inputs(.list(uuid))
        inputs.lists[uuid] = document
        let section = try XCTUnwrap(GridModel.make(inputs).sections.first)
        let grid = CueGridModel.make(document: document, section: section, catalog: catalog, media: try Recorded.media(), folds: [:])
        let order = grid.headers.map(\.uuid)
        var selection = CueGridSelection()
        selection.click(cue: order[cues[0]], row: row)
        for index in cues.dropFirst() { selection.toggle(cue: order[index], in: order) }
        return CueInspector.make(list: document.list, grid: grid, selection: selection, catalog: catalog, media: try Recorded.media())
    }

    private func inspector42(_ cues: [Int], _ row: CueGridSelection.Row = .channel(1), tracking: Bool = true,
                             change: (inout ListDocument) -> Void = { _ in }) throws -> CueInspector {
        try inspector("list-42", uuid: Recorded.list42, cues: cues, row: row, tracking: tracking, change: change)
    }

    // MARK: - The header and the Cue column

    func test_theHeaderAndTheCueColumnForOneCue() throws {
        let third = try inspector42([2])
        // "Its header says "Cue 3 of 14", with the live dot on the live cue".
        XCTAssertEqual(third.number, 3)
        XCTAssertEqual(third.count, 4)
        XCTAssertFalse(third.isLive)
        XCTAssertFalse(third.isMulti)
        XCTAssertEqual(third.label, .same("Verse 1"))
        XCTAssertEqual(third.section, .same("Verse 1"))
        XCTAssertEqual(third.note, "")
        // The list's live cue is not marked from the Library window, where nothing of it is live.
        let chorus = try inspector42([3])
        XCTAssertEqual(chorus.note, "Build the lights here")
        // "section (a combo box offering the list's sections and E3's names)": the list's first, then the rest of E3's.
        XCTAssertEqual(Array(chorus.sections.prefix(4)), ["Verse 1", "Chorus", "Intro", "Verse"])
        XCTAssertEqual(chorus.sections.filter { $0 == "Chorus" }.count, 1)
        XCTAssertTrue(chorus.sections.contains("Pre-Chorus"))
    }

    // MARK: - The Trigger column

    func test_theTriggerColumnAndBothPairWarnings() throws {
        let third = try inspector42([2])
        XCTAssertEqual(third.trigger, .same(.time(ms: 8000)))
        XCTAssertEqual(third.advanceAfterMs, .same(12000))
        XCTAssertEqual(third.pairWarnings, [], "its neighbors set neither")
        // "When this cue's Time and the previous cue's advance-after are both set ... the shorter" wins.
        let before = try inspector42([2]) { $0.list.cues[1].advanceAfterMs = 5000 }
        XCTAssertEqual(before.pairWarnings, [PairWarning(advanceCue: 2, advanceMs: 5000, timeCue: 3, timeMs: 8000)])
        XCTAssertEqual(before.pairWarnings[0].winsMs, 5000)
        // "or this cue's advance-after and the next cue's Time".
        let after = try inspector42([2]) { $0.list.cues[3].trigger = .time(ms: 20000) }
        XCTAssertEqual(after.pairWarnings, [PairWarning(advanceCue: 3, advanceMs: 12000, timeCue: 4, timeMs: 20000)])
        XCTAssertEqual(after.pairWarnings[0].winsMs, 12000)
        // "The pair warning counts every selected cue", each pair once.
        let both = try inspector42([1, 2, 3]) { document in
            document.list.cues[1].advanceAfterMs = 5000
            document.list.cues[3].trigger = .time(ms: 20000)
        }
        XCTAssertEqual(both.pairWarnings.count, 2)
    }

    func test_usePreviousVideosLengthIsThePreviousCuesFirstMediaWithinItsInAndOutPoints() throws {
        // List 42's first cue loops a two-second video on channel 1.
        XCTAssertEqual(try inspector42([1]).previousVideoMs, 2000)
        XCTAssertNil(try inspector42([0]).previousVideoMs, "the first cue has no previous cue")
        XCTAssertNil(try inspector42([2]).previousVideoMs, "the cue before writes only text")
        // Doxology's first cue plays a minute-long video from 2 s to 60 s: "within its in and out points".
        XCTAssertEqual(try inspector("list-7", uuid: Recorded.list7, cues: [1], row: .header).previousVideoMs, 58000)
        // A still has no length.
        let still = try inspector42([1]) { document in
            document.list.cues[0].commands[0] = GuardedCommand(.channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(
                ref: "sha256:eb6384847a49f7a4ef82aedb9e2019080777b8be748690c33d91bba67c32a3d2")))))
        }
        XCTAssertNil(still.previousVideoMs)
    }

    // MARK: - The Commands column

    func test_theCommandsColumnListsTheCuesOtherCommandsWithTheirWarnings() throws {
        let out = try inspector("list-7", uuid: Recorded.list7, cues: [2], row: .header) { document in
            document.list.cues[2].commands.append(GuardedCommand(.edit(EditCommand(.list(7), .set(path: "title", value: .string("x"))))))
            document.list.cues[2].commands.append(GuardedCommand(.unknown(cmd: "laser.fire", fields: ["power": .number(11)])))
        }
        // "each as its plain name (Spec 10 §15)", at its place in the cue's commands.
        XCTAssertEqual(out.commands.map(\.position), [1, 3, 4])
        XCTAssertEqual(out.commands[0].name, KeyWording.plain(.macro(1)))
        XCTAssertEqual(out.commands.map(\.warning), [nil, .changesLibrary, .keptVerbatim])
        XCTAssertEqual(out.commands[2].name, "laser.fire")
        // "A command kept verbatim because it is unknown ... can only be removed."
        XCTAssertEqual(out.commands.map(\.canEdit), [true, true, false])
        XCTAssertEqual(out.commands.map(\.canMoveUp), [false, true, true])
        XCTAssertEqual(out.commands.map(\.canMoveDown), [true, true, false])
    }

    // MARK: - The Channel column

    func test_theChannelColumnShowsTheSelectedCellsStateContentAndChips() throws {
        let first = try inspector42([0])
        XCTAssertEqual(first.channel, 1)
        XCTAssertEqual(first.channelLabel, "Background")
        XCTAssertTrue(first.channelExists)
        XCTAssertEqual(first.state, .write)
        guard case .media? = first.content else { return XCTFail("the tile's content") }
        // "Attribute chips: transition, audio transition (E9), grade and gain, each showing its value and its scope".
        XCTAssertEqual(first.chips.map(\.kind), [.transition, .audioTransition, .grade, .gain])
        XCTAssertEqual(first.chips[0].value, .same(CueAttribute(kind: .transition, ref: 2, ms: 1000, scope: .once, isRider: true)))
        XCTAssertEqual(first.chips[0].scope, .once)
        XCTAssertEqual(first.chips[1].value, .same(nil), "a faint + and its name for one the cue doesn't write")
        XCTAssertTrue(first.chips[0].offersScope, "a rider has a scope")
        // The chorus holds channel 1 from cue 1, with a gain write: "always `track`", so its popover offers no scope.
        let chorus = try inspector42([3])
        XCTAssertEqual(chorus.state, .hold)
        XCTAssertEqual(chorus.heldFrom, 1)
        XCTAssertEqual(chorus.content, first.content)
        XCTAssertEqual(chorus.chips[3].value, .same(CueAttribute(kind: .gain, db: -6, scope: .track, isRider: false)))
        XCTAssertEqual(chorus.chips[3].scope, .track)
        XCTAssertFalse(chorus.chips[3].offersScope)
        // "with the header row selected by the channel last selected".
        var selection = CueGridSelection(cue: nil, channel: 2)
        selection.click(cue: Recorded.cues42[3], row: .header)
        XCTAssertEqual(selection.channel, 2)
    }

    func test_withTrackingOffAStandaloneCommandReadsThisCueOnlyAndANewChipStartsThere() throws {
        let chorus = try inspector42([3], tracking: false)
        // "A standalone command reads "this cue only", since that is how it plays here".
        XCTAssertEqual(chorus.chips[3].scope, .once)
        // "A new chip for that attribute is "this cue only"": transition's tracking is off, grade's is on.
        XCTAssertEqual(chorus.chips[0].scope, .once)
        XCTAssertEqual(chorus.chips[2].scope, .track)
    }

    // MARK: - Several cues (Spec 11 §4, "Multi-cue editing")

    func test_severalCuesReduceTheInspectorAndAFieldWhoseCuesDifferIsMixed() throws {
        let several = try inspector42([0, 2, 3], .channel(2))
        XCTAssertTrue(several.isMulti)
        XCTAssertEqual(several.selected, 3)
        XCTAssertEqual(several.number, 1, "the first of them")
        // "A field whose cues differ reads "Mixed"."
        XCTAssertEqual(several.section, .mixed)
        XCTAssertEqual(several.trigger, .mixed)
        XCTAssertEqual(several.advanceAfterMs, .mixed)
        XCTAssertEqual(try inspector42([0, 1]).section, .same("Verse 1"))
        XCTAssertEqual(try inspector42([0, 1]).trigger, .same(.go))
        // "the Channel column keeps the selected row's chips, without the three-way control or the content".
        XCTAssertNil(several.state)
        XCTAssertNil(several.content)
        XCTAssertEqual(several.chips[0].value, .same(nil))
        XCTAssertEqual(several.chips[2].value, .mixed, "only the chorus's text has a grade")
        // "the Commands column says to select one cue".
        XCTAssertTrue(several.commands.isEmpty)
    }

    // MARK: - The top bar's status and the Program panel (Spec 11 §2)

    private func dot(_ number: Int, _ state: OutputDot.State = .presenting, stack: Int = 1, blackout: Bool = false) -> OutputDot {
        OutputDot(number: number, label: "Out", stack: stack, state: state, isBlackedOut: blackout)
    }

    func test_atRestTheBarShowsSavedAndTheEnginePillAndAProblemShowsBesideThem() {
        // "the saving pill, which reads "Saved" while nothing waits ...; and the engine pill, a green dot
        // and "Engine" while the engine is connected, every output is presenting and no badge stands."
        let rest = EditStatus.make(dots: [dot(1), dot(2)], tags: [], isConnected: true)
        XCTAssertEqual(rest, EditStatus(saving: nil, engine: .fine, dots: [], tags: []))
        // "an output that isn't presenting or is blacked out shows as its show-mode dot".
        let lost = EditStatus.make(dots: [dot(1), dot(2, .lost)], tags: [], isConnected: true)
        XCTAssertEqual(lost.dots.map(\.number), [2])
        XCTAssertEqual(lost.engine, .attention)
        let dark = EditStatus.make(dots: [dot(1, blackout: true), dot(2)], tags: [], isConnected: true)
        XCTAssertEqual(dark.dots.map(\.number), [1])
        XCTAssertEqual(dark.engine, .fine, "it is presenting, as asked")
        // "each of show mode's tags shows while it applies"; the saving tag is the pill's.
        let tagged = EditStatus.make(dots: [dot(1)], tags: [.audioMuted, .popup(1), .engine(badges: 2), .saving(.unsaved(3))], isConnected: true)
        XCTAssertEqual(tagged.tags, [.audioMuted, .popup(1), .engine(badges: 2)])
        XCTAssertEqual(tagged.saving, .unsaved(3))
        XCTAssertEqual(tagged.engine, .attention, "a badge stands")
        // "While the engine isn't connected the pill is hollow and red".
        XCTAssertEqual(EditStatus.make(dots: [dot(1)], tags: [], isConnected: false).engine, .away)
    }

    func test_theProgramPillNamesTheOutputsThatShowTheStack() {
        let dots = [dot(1), dot(2), dot(3, stack: 2), dot(4, .lost)]
        // "with a pill naming those outputs, "On air · Out 1, 2"; when none does ... "Preview only"".
        XCTAssertEqual(ProgramPanel.make(stack: 1, dots: dots).outputs, [1, 2])
        XCTAssertFalse(ProgramPanel.make(stack: 1, dots: dots).isBlackedOut)
        XCTAssertEqual(ProgramPanel.make(stack: 3, dots: dots).outputs, [])
        XCTAssertTrue(ProgramPanel.make(stack: 2, dots: [dot(3, stack: 2, blackout: true)]).isBlackedOut)
    }
}
