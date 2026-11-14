import Foundation
import XCTest
@testable import OCore

/// Spec 9 §4 — "What comes back, the way Spec 3 §8 replaces ShowState":
/// content and tracked attributes with their origins, outputs on their
/// stacks, stacks with their blackout and muted channels, and locks; popups
/// without a pending clear-after; the pointer as it was saved; media from its
/// in-point at the frame of the restore, its transport as it was; every
/// restored channel's provenance `restored`, keeping its cue and list;
/// outgoing instances dropped; `armed` cleared; a vanished channel left out
/// and unknown or absent media back as missing. Spec 3 §8 — "the engine diffs
/// old and new state and synthesizes `transition` effects as cuts,
/// `attribute` effects for every changed attribute, and a `pointer` effect".
/// Spec 9 §10, The last state.
final class LastStateRestoreTests: XCTestCase {
    typealias F = FixtureLibrary

    static let (library, machine, _) = F.load()
    static let cue1 = F.list42Cues[0]
    static let list42 = F.listUuid(42)

    func fresh() -> ShowState { ShowState.fresh(library: Self.library, machine: Self.machine) }

    func media(_ ref: String, startedAt: Int = 1200, transport: Transport = .playing, missing: Bool = false) -> ContentInstance {
        .media(MediaInstance(ref: ref, inMs: 500, outMs: nil, loop: true, gainOverride: nil, syncOffsetMs: nil, startedAtFrame: startedAt,
                             transport: transport, endBehavior: .loop, missing: missing))
    }

    func text(_ body: String) -> ContentInstance { .text(TextInstance(fields: ["body": body])) }

    func restore(_ state: ShowState, pendingClears: [Int] = [], frame: Int = 0, missing: Set<String> = [],
                 library: Library = LastStateRestoreTests.library, machine: Machine = LastStateRestoreTests.machine) -> LastState.Restored {
        LastState(writtenAt: "2026-11-08T09:41:07.002-05:00", run: UUID(), clean: false, restored: false, pendingClears: pendingClears, state: state)
            .restored(library: library, machine: machine, frame: frame, missing: missing)
    }

    // MARK: - What comes back

    /// "Content and tracked attributes with their origins, outputs on their
    /// stacks, stacks with their blackout and muted channels, and locks
    /// (choice G-3)."
    func test_contentAttributesOutputsStacksAndLocksComeBack() throws {
        var saved = fresh()
        saved.channels[1]?.content = media(F.dawn)
        saved.channels[1]?.provenance = .cue(Self.cue1, list: Self.list42)
        saved.channels[1]?.attributes.grade = Tracked(value: 3, origin: .tracked)
        saved.channels[1]?.attributes.gain = Tracked(value: -6, origin: .once, shadow: -3)
        saved.channels[1]?.lock = true
        saved.channels[2]?.content = text("Great is Thy faithfulness")
        saved.channels[2]?.provenance = .source(.ui)
        saved.outputs[1] = 2
        saved.stacks[1] = StackState(blackout: true, muted: [2])
        saved.stacks[2] = StackState(blackout: false, muted: [3])

        let back = restore(saved, frame: 7)
        XCTAssertEqual(back.left, [])
        let one = try XCTUnwrap(back.state.channels[1])
        XCTAssertEqual(one.attributes.grade, Tracked(value: 3, origin: .tracked))
        XCTAssertEqual(one.attributes.gain, Tracked(value: -6, origin: .once, shadow: -3), "the origin and what a once falls back to")
        XCTAssertEqual(one.attributes.transition, saved.channels[1]?.attributes.transition)
        XCTAssertTrue(one.lock, "the operator's last word")
        XCTAssertEqual(back.state.channels[2]?.content, text("Great is Thy faithfulness"))
        XCTAssertEqual(back.state.outputs[1], 2)
        XCTAssertEqual(back.state.outputs[2], saved.outputs[2])
        XCTAssertEqual(back.state.stacks[1], StackState(blackout: true, muted: [2]))
        XCTAssertEqual(back.state.stacks[2], StackState(blackout: false, muted: [3]))
    }

    /// "Video and audio start again from their in-points: `startedAtFrame` is
    /// the frame of the restore, and the transport is as it was."
    func test_mediaStartsAgainFromItsInPointWithItsTransportAsItWas() throws {
        var saved = fresh()
        saved.channels[1]?.content = media(F.dawn, startedAt: 54_000, transport: .paused)
        let back = restore(saved, frame: 3)
        let instance = try XCTUnwrap(back.state.channels[1]?.content.media)
        XCTAssertEqual(instance.startedAtFrame, 3)
        XCTAssertEqual(instance.transport, .paused)
        XCTAssertEqual(instance.inMs, 500, "from its in-point: the playhead isn't saved")
        XCTAssertEqual(instance.endBehavior, .loop)
        XCTAssertFalse(instance.missing)
    }

    /// "Every change is a cut, every restored channel's provenance is
    /// `restored` keeping its cue and list, and outgoing instances are
    /// dropped." A channel nothing ever wrote has no provenance to restore.
    func test_provenanceIsRestoredKeepingCueAndListAndOutgoingIsDropped() throws {
        var saved = fresh()
        saved.channels[1]?.content = media(F.dawn)
        saved.channels[1]?.provenance = .cue(Self.cue1, list: Self.list42)
        saved.channels[1]?.outgoing = [OutgoingInstance(instance: MediaInstance(ref: F.cross, inMs: nil, outMs: nil, loop: false, gainOverride: nil,
                                                                              syncOffsetMs: nil, startedAtFrame: 900, transport: .playing,
                                                                              endBehavior: .hold, missing: false), endsAtFrame: 1260)]
        saved.channels[2]?.content = text("typed by hand")
        saved.channels[2]?.provenance = .source(.ui)
        let back = restore(saved)
        XCTAssertEqual(back.state.channels[1]?.provenance, .restored(cue: Self.cue1, list: Self.list42))
        XCTAssertEqual(back.state.channels[1]?.outgoing, [])
        XCTAssertEqual(back.state.channels[2]?.provenance, .restored(cue: nil, list: nil))
        XCTAssertNil(back.state.channels[3]?.provenance, "empty and never written: nothing was put back on it")
        XCTAssertEqual(back.state.channels[3], fresh().channels[3])
    }

    /// "Popups with their text, apart from those with a pending clear-after:
    /// they were on their way off, and a nursery call shouldn't stay up until
    /// someone notices."
    func test_popupsComeBackButNotThoseWithAPendingClear() {
        var saved = fresh()
        saved.popups = [1: "Welcome", 3: "Nursery: room 12", 9: "a slot this machine doesn't have"]
        let back = restore(saved, pendingClears: [3])
        XCTAssertEqual(back.state.popups, [1: "Welcome"])
        XCTAssertEqual(back.left, [LastState.Left(kind: .popup, number: 3, why: .clearing), LastState.Left(kind: .popup, number: 9, why: .gone)])
    }

    /// "The pointer, as it was saved, whatever its shape: a cue fired, a
    /// playlist loaded with no cue fired, or a list fired from the library".
    /// "`armed` is cleared."
    func test_thePointerComesBackInEachOfItsThreeShapesAndArmedIsCleared() {
        let shapes = [
            LivePointer(playlist: F.playlistUuid, itemUuid: F.sundayItems[1], listUuid: Self.list42, cueUuid: Self.cue1),
            LivePointer(playlist: F.playlistUuid),
            LivePointer(listUuid: Self.list42, cueUuid: F.list42Cues[2]),
        ]
        for pointer in shapes {
            var saved = fresh()
            saved.pointer = pointer
            saved.armed = ArmedTrigger(itemUuid: pointer.itemUuid, cueUuid: F.list42Cues[2], atFrame: 99_999)
            let back = restore(saved)
            XCTAssertEqual(back.state.pointer, pointer)
            XCTAssertNil(back.state.armed)
        }
        // What the pointer names may be gone: it comes back as saved, and Spec 7 §4 says what it does.
        var saved = fresh()
        saved.pointer = LivePointer(listUuid: UUID(), cueUuid: UUID())
        XCTAssertEqual(restore(saved).state.pointer, saved.pointer)
    }

    /// "A channel the library no longer has is left out, and content whose
    /// media no index knows, or whose file isn't there, comes back missing."
    func test_aVanishedChannelIsLeftOutAndUnknownOrAbsentMediaComesBackMissing() throws {
        var saved = fresh()
        saved.channels[9] = saved.channels[1]
        saved.channels[9]?.content = text("on a channel that is gone")
        saved.channels[1]?.content = media("sha256:" + String(repeating: "0", count: 64))
        saved.channels[2]?.content = media(F.cross)
        saved.channels[3]?.content = .slide(SlideInstance(ref: "slide:00000000-0000-4000-8000-00000000dead", build: 2, missing: false))

        let back = restore(saved, missing: [F.cross])
        XCTAssertNil(back.state.channels[9])
        XCTAssertEqual(Set(back.state.channels.keys), Set(fresh().channels.keys), "exactly the channels the library has")
        XCTAssertEqual(back.state.channels[1]?.content.media?.missing, true, "no index knows it")
        XCTAssertEqual(back.state.channels[2]?.content.media?.missing, true, "its file isn't there")
        if case .slide(let slide)? = back.state.channels[3]?.content {
            XCTAssertTrue(slide.missing)
            XCTAssertEqual(slide.build, 2)
        } else {
            XCTFail("the slide comes back as a slide")
        }
        XCTAssertEqual(back.left, [
            LastState.Left(kind: .channel, number: 1, why: .missing, media: "sha256:" + String(repeating: "0", count: 64)),
            LastState.Left(kind: .channel, number: 2, why: .missing, media: F.cross),
            LastState.Left(kind: .channel, number: 3, why: .missing, media: "slide:00000000-0000-4000-8000-00000000dead"),
            LastState.Left(kind: .channel, number: 9, why: .gone),
        ])
        // Media saved as missing whose file is back now plays.
        var again = fresh()
        again.channels[1]?.content = media(F.dawn, missing: true)
        XCTAssertEqual(restore(again).state.channels[1]?.content.media?.missing, false)
    }

    /// The plan's reading — "An output, a stack or a popup slot the machine
    /// no longer has | Left out and named in `left`, as a vanished channel is".
    func test_anOutputOrAStackTheMachineNoLongerHasIsLeftOut() {
        var saved = fresh()
        saved.outputs[7] = 1
        saved.outputs[1] = 9
        saved.stacks[9] = StackState(blackout: true, muted: [])
        let back = restore(saved)
        XCTAssertNil(back.state.outputs[7])
        XCTAssertNil(back.state.stacks[9])
        XCTAssertEqual(back.state.outputs[1], fresh().outputs[1], "an output whose stack is gone stays on its default")
        XCTAssertEqual(back.left, [LastState.Left(kind: .output, number: 7, why: .gone), LastState.Left(kind: .stack, number: 9, why: .gone)])
    }

    /// A channel, an output or a stack the saved state doesn't mention starts as a fresh launch has it.
    func test_whatTheFileDoesNotMentionStartsFresh() {
        var saved = ShowState()
        saved.channels[2] = fresh().channels[2]
        saved.channels[2]?.content = text("only this")
        let back = restore(saved)
        XCTAssertEqual(back.state.channels[1], fresh().channels[1])
        XCTAssertEqual(back.state.outputs, fresh().outputs)
        XCTAssertEqual(back.state.stacks, fresh().stacks)
        XCTAssertEqual(back.state.channels[2]?.content, text("only this"))
    }

    /// Spec 9 §2 — `lastStateRestored`'s `left`, "what didn't come back", as the note writes it.
    func test_whatWasLeftIsWrittenByKindNumberAndWhy() {
        XCTAssertEqual(LastState.Left(kind: .channel, number: 9, why: .gone).json, .object(["channel": .number(9), "why": .string("gone")]))
        XCTAssertEqual(LastState.Left(kind: .popup, number: 3, why: .clearing).json, .object(["popup": .number(3), "why": .string("clearing")]))
        XCTAssertEqual(LastState.Left(kind: .channel, number: 2, why: .missing, media: F.cross).json,
                       .object(["channel": .number(2), "why": .string("missing"), "media": .string(F.cross)]))
    }

    // MARK: - Spec 3 §8, the effects of a replacement

    /// "the engine diffs old and new state and synthesizes `transition`
    /// effects as cuts, `attribute` effects for every changed attribute, and
    /// a `pointer` effect".
    func test_aReplacementIsCutsAttributeEffectsAndAPointerEffect() throws {
        var saved = fresh()
        saved.channels[1]?.content = media(F.dawn)
        saved.channels[1]?.attributes.grade = Tracked(value: 3, origin: .tracked)
        saved.channels[1]?.attributes.gain = Tracked(value: -6, origin: .tracked)
        saved.channels[1]?.lock = true
        saved.channels[2]?.content = text("Great is Thy faithfulness")
        saved.outputs[1] = 2
        saved.stacks[1] = StackState(blackout: true, muted: [2])
        saved.popups = [1: "Welcome"]
        saved.pointer = LivePointer(playlist: F.playlistUuid)
        let new = restore(saved, frame: 5).state
        let effects = StateReplacement.effects(from: fresh(), to: new)

        let transitions = effects.compactMap(\.transitionEffect)
        XCTAssertEqual(transitions.map(\.channel), [1, 2])
        for cut in transitions {
            XCTAssertEqual(cut.ms, 0, "a cut")
            XCTAssertEqual(cut.audioMs, 0)
            XCTAssertEqual(cut.from, .empty)
            XCTAssertFalse(cut.restart)
        }
        XCTAssertEqual(transitions.first?.to, new.channels[1]?.content)
        XCTAssertTrue(effects.contains(.attribute(channel: 1, attribute: .grade, old: .grade(0), new: .grade(3), ms: nil)))
        XCTAssertTrue(effects.contains(.attribute(channel: 1, attribute: .gain, old: .gain(0), new: .gain(-6), ms: nil)))
        XCTAssertFalse(effects.contains { if case .attribute(2, _, _, _, _) = $0 { return true } else { return false } }, "only what changed")
        XCTAssertTrue(effects.contains(.pointer(old: nil, new: LivePointer(playlist: F.playlistUuid), armed: nil)))
        // What else the state holds follows, each as its own effect with no transition, for whoever mirrors state.
        XCTAssertTrue(effects.contains(.stackSwitch(output: 1, old: fresh().outputs[1] ?? 0, new: 2, transition: nil)))
        XCTAssertTrue(effects.contains(.blackout(stack: 1, old: false, new: true, transition: nil)))
        XCTAssertTrue(effects.contains(.mute(stack: 1, channel: 2, old: false, new: true)))
        XCTAssertTrue(effects.contains(.variable(popup: 1, text: "Welcome", clearAfterMs: nil)))
        XCTAssertTrue(effects.contains(.applied(.channelLock(channel: .number(1), locked: true))))
    }

    /// A state replaced by itself changes nothing but still says where the pointer is.
    func test_replacingAStateWithItselfIsOnlyThePointerEffect() {
        var state = fresh()
        state.channels[2]?.content = text("the same")
        state.pointer = LivePointer(playlist: F.playlistUuid)
        XCTAssertEqual(StateReplacement.effects(from: state, to: state), [.pointer(old: state.pointer, new: state.pointer, armed: nil)])
    }

    /// Going back to nothing clears: content to empty, as cuts, and popups to none.
    func test_replacingWithAFreshStateCutsEverythingToEmpty() {
        var state = fresh()
        state.channels[1]?.content = media(F.dawn)
        state.popups = [2: "up"]
        let effects = StateReplacement.effects(from: state, to: fresh())
        XCTAssertEqual(effects.compactMap(\.transitionEffect).map(\.to), [.empty])
        XCTAssertTrue(effects.contains(.variable(popup: 2, text: nil, clearAfterMs: nil)))
    }
}
