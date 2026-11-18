import Foundation
import XCTest
@testable import OCore

/// Spec 3 §7, "Cue view and thumbnails" — "Start from a fresh ShowState,
/// treat the list's first cue as a boundary into that list, and fold cue 1
/// through cue K. The result is what the default stack would show if the
/// list ran from the start, which is the UX spec's definition of a cue
/// thumbnail and of the chip colours."
///
/// Spec 3 §3, "What a chip colour means" — "An attribute whose value changed
/// and whose origin is `tracked` or `once` from this cue is *new*; one whose
/// value is unchanged and was not written by this cue is *held*; one written
/// by this cue to the value it already had is *redundant*, a write worth
/// removing. Content follows the same three rules." Spec 10 §6 gives a clear
/// its own chip: "struck through for a clear".
final class CueViewTests: XCTestCase {
    typealias F = Fixtures

    private func fold(_ list: List, through index: Int? = nil, library: Library = F.library) -> [CueView.Step] {
        CueView.fold(list, through: index, library: library, machine: F.machine)
    }

    private func states(_ steps: [CueView.Step], channel: Int) -> [ChipState] {
        steps.map { $0.chips.first { $0.channel == channel }?.state ?? .held }
    }

    private func list(_ cues: [[Command]], number: Int = 30) -> List {
        List(uuid: F.listUuid(number), number: number, title: "List \(number)",
             cues: cues.enumerated().map { F.cue(list: number, $0.offset + 1, commands: $0.element) })
    }

    // MARK: - The fold

    func test_theFoldRunsFromAFreshStateThroughEveryCue() {
        let steps = fold(F.list1)
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[0].state.channels[1]?.content.media?.ref, F.mediaA)
        XCTAssertEqual(steps[2].state.channels[1]?.content.media?.ref, F.mediaA, "cue 1's background shows on every later cue")
        XCTAssertEqual(steps[1].state.channels[2]?.content, .text(TextInstance(fields: ["body": "chorus"])))
        XCTAssertEqual(steps[2].state.channels[2]?.content, .text(TextInstance(fields: ["body": "verse 2"])))
        XCTAssertEqual(steps[0].state.channels[3]?.content, .empty)
    }

    func test_eachStateNamesItsCueAndItsListAndNoPlaylist() {
        // Spec 6 §5 — "In a static box, a value reads the state's pointer: its cue and its list"; "A projected state has no playlist".
        let steps = fold(F.list1)
        XCTAssertEqual(steps.map(\.state.pointer), [1, 2, 3].map { LivePointer(listUuid: F.listUuid(1), cueUuid: F.cueUuid(list: 1, cue: $0)) })
        XCTAssertNil(steps[0].state.armed, "nothing is armed in a cue view")
    }

    func test_throughStopsAtTheCueAsked() {
        XCTAssertEqual(fold(F.list1, through: 1).count, 2)
        XCTAssertEqual(fold(F.list1, through: 0).count, 1)
        XCTAssertEqual(fold(F.list1, through: 9).count, 3, "past the end is the whole list")
        XCTAssertEqual(fold(list([])).count, 0)
    }

    func test_theStatesAreTheStepsStates() {
        XCTAssertEqual(CueView.states(of: F.list1, library: F.library, machine: F.machine), fold(F.list1).map(\.state))
    }

    func test_aGuardOnTheStateReadsItAsTheListsEarlierCuesLeftIt() {
        // Macro 1 writes "Welcome" to channel 2 when [Channel 2 Content] is empty (Spec 2 §7).
        let guarded = list([[.macro(1)], [.macro(1)]], number: 31)
        let steps = fold(guarded)
        XCTAssertEqual(steps[0].state.channels[2]?.content, .text(TextInstance(fields: ["body": "Welcome"])))
        XCTAssertEqual(states(steps, channel: 2), [.new, .held], "the second cue's guard saw the text and wrote nothing")
    }

    func test_aVariableTheStateDoesNotHoldIsAskedOfTheCallerWithTheStateBeforeTheCue() {
        // The thumbnail job resolves `[Timer 1]` and the like against the state each cue lands on; the fold hands it that state.
        var library = F.library
        library.macros.append(Macro(number: 9, commands: [GuardedCommand(F.write(3, text: "timed"), when: Guard(variable: "Timer 1", op: .isEmpty))]))
        let timed = list([[F.write(1, media: F.mediaA), .macro(9)], [.macro(9)]], number: 32)
        let steps = CueView.fold(timed, library: library, machine: F.machine) { name, before in
            name == "Timer 1" && before.channels[1]?.content.isEmpty == false ? "0:10" : nil
        }
        XCTAssertEqual(states(steps, channel: 3), [.new, .held],
                       "cue 1 lands on an empty channel 1, so the timer reads empty and the macro writes; cue 2 lands after it")
    }

    // MARK: - The chips

    func test_everyChannelHasAChipInNumberOrder() {
        // Area 13 reading — every channel in number order; one the cue doesn't touch is held.
        let steps = fold(F.list1)
        XCTAssertEqual(steps[0].chips.map(\.channel), [1, 2, 3])
        XCTAssertEqual(steps[0].chips.map(\.state), [.new, .new, .held])
        XCTAssertEqual(steps[1].chips.map(\.state), [.held, .new, .held])
        XCTAssertEqual(steps[2].chips.map(\.state), [.held, .new, .held])
    }

    func test_aWriteOfWhatIsAlreadyThereIsRedundant() {
        let steps = fold(list([
            [F.write(1, media: F.mediaA), F.write(2, text: "verse 1")],
            [F.write(1, media: F.mediaA), F.write(2, text: "verse 1")],
            [F.write(1, media: F.mediaB)],
        ]))
        XCTAssertEqual(states(steps, channel: 1), [.new, .redundant, .new], "the same media written again restarts it and changes nothing else")
        XCTAssertEqual(states(steps, channel: 2), [.new, .redundant, .held], "identical text from another cue changes its provenance alone")
    }

    func test_theSameMediaWithAnotherLoopOrTrimIsNew() {
        let looped = Command.channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: F.mediaA, loop: true))))
        let steps = fold(list([[F.write(1, media: F.mediaA)], [looped]]))
        XCTAssertEqual(states(steps, channel: 1), [.new, .new])
    }

    func test_aClearIsAClearAndASecondOneIsRedundant() {
        let steps = fold(list([
            [F.write(1, media: F.mediaA)],
            [.channelClear(channel: .number(1))],
            [.channelClear(channel: .number(1))],
        ]))
        XCTAssertEqual(states(steps, channel: 1), [.new, .clear, .redundant])
    }

    func test_aClearOfAChannelTheListHasNotWrittenIsStillAClear() {
        // Area 13 reading — Spec 3 §3 rule 4: "Content holds across lists". A clear at the top of a list empties whatever the
        // list before left there, so the cue view, which starts empty, can't call it redundant.
        let steps = fold(list([[.channelClear(channel: .number(2))], [F.write(2, text: "verse 1")]]))
        XCTAssertEqual(states(steps, channel: 2), [.clear, .new])
        XCTAssertEqual(states(steps, channel: 1), [.held, .held])
    }

    func test_clearAllClearsEveryChannelAndAClearOfAllDoesToo() {
        let all = fold(list([[F.write(1, media: F.mediaA)], [.systemClearAll], [.systemClearAll]]))
        XCTAssertEqual(all[1].chips.map(\.state), [.clear, .clear, .clear], "content holds across lists, so the channels this list never wrote are cleared too")
        XCTAssertEqual(all[2].chips.map(\.state), [.redundant, .redundant, .redundant])
        let each = fold(list([[F.write(1, media: F.mediaA)], [.channelClear(channel: .all)]]))
        XCTAssertEqual(each[1].chips.map(\.state), [.clear, .clear, .clear])
    }

    func test_aWriteOfEmptyIsAClear() {
        let empty = Command.channelWrite(ChannelWrite(channel: .number(1), content: .empty))
        let steps = fold(list([[F.write(1, media: F.mediaA)], [empty]]))
        XCTAssertEqual(states(steps, channel: 1), [.new, .clear])
    }

    func test_aWriteByAMacroTheCueRunsCounts() {
        let steps = fold(F.list7)
        XCTAssertEqual(steps[0].chips.map(\.state), [.held, .new, .held], "macro 2 writes channel 2")
    }

    func test_aSlidesBuildChangeIsNew() {
        let steps = fold(list([[F.write(1, slide: F.slideS, build: 1)], [F.write(1, slide: F.slideS, build: 2)], [F.write(1, slide: F.slideS, build: 2)]]))
        XCTAssertEqual(states(steps, channel: 1), [.new, .new, .redundant])
    }

    // MARK: - Attribute writes (Spec 10 §6: "A dot on a chip marks attribute writes, listed on hover")

    func test_attributeWritesAreListedOnTheirChannelsChip() {
        let graded = F.write(1, media: F.mediaA, riders: Riders(grade: GradeRider(ref: 5, scope: .once)))
        let steps = fold(list([
            [graded],
            [.channelGrade(channel: .number(2), ref: 5, ms: nil), .channelGain(channel: .number(2), db: -6)],
            [.channelGrade(channel: .number(2), ref: 5, ms: nil)],
        ]))
        XCTAssertEqual(steps[0].chips[0].attributes, [CueChip.AttributeWrite(attribute: .grade, value: .grade(5), isRedundant: false)])
        XCTAssertEqual(steps[0].chips[0].state, .new)
        XCTAssertEqual(steps[1].chips[1].state, .held, "the content is held; the dot says the attributes were written")
        XCTAssertEqual(steps[1].chips[1].attributes, [CueChip.AttributeWrite(attribute: .grade, value: .grade(5), isRedundant: false),
                                                       CueChip.AttributeWrite(attribute: .gain, value: .gain(-6), isRedundant: false)])
        XCTAssertEqual(steps[2].chips[1].attributes, [CueChip.AttributeWrite(attribute: .grade, value: .grade(5), isRedundant: true)],
                       "written to the value it already had: a write worth removing")
        XCTAssertEqual(steps[2].chips[0].attributes, [])
    }

    func test_aCommandForAChannelThatIsNotThereAddsNoChip() {
        let steps = fold(list([[F.write(9, text: "nowhere")]]))
        XCTAssertEqual(steps[0].chips.map(\.channel), [1, 2, 3])
        XCTAssertEqual(steps[0].chips.map(\.state), [.held, .held, .held])
    }
}
