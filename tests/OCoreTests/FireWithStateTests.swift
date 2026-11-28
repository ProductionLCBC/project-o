import Foundation
import XCTest
@testable import OCore

/// Spec 3 §5 as corrected 2026-11-24 — "Firing with `state` ... takes up,
/// between the boundary and the cue's commands, the state its list leaves
/// before it: the cue view of §7 folded through the cue before it. Each
/// channel those cues touched takes that state's content and tracked
/// attributes with a cut ...; a channel already playing the same media (ref,
/// in, out and loop) keeps playing it; a locked channel is left as it is (§8).
/// A channel the list never touched before the cue keeps what is live. Then
/// the cue fires as above, its writes with their own transitions". Spec 2 §3 —
/// `cue N [state]`, `item N cue M [state]`, `list N cue M [state]`.
final class FireWithStateTests: XCTestCase {
    typealias F = Fixtures

    /// List 8: cue 1 writes clip A on channel 1 at -6 dB from here on and verse 1 on channel 2; cue 2 the chorus;
    /// cue 3 verse 2 with a dissolve; channel 3 is never touched.
    static let list8 = List(uuid: F.listUuid(8), number: 8, title: "Jumps", cues: [
        F.cue(list: 8, 1, commands: [F.write(1, media: F.mediaA, riders: Riders(gain: GainRider(db: -6, scope: .track))),
                                     F.write(2, text: "verse 1")]),
        F.cue(list: 8, 2, commands: [F.write(2, text: "chorus")]),
        F.cue(list: 8, 3, commands: [F.write(2, text: "verse 2", riders: Riders(transition: TransitionRider(ref: 2, scope: .once)))]),
    ])

    var library: Library {
        var library = F.library
        library.lists.append(Self.list8)
        return library
    }

    func context(frame: Int) -> ProjectionContext {
        F.context(frame: frame, source: .ui, library: library)
    }

    func text(_ state: ShowState, _ channel: Int) -> String? {
        if case .text(let t)? = state.channels[channel]?.content { return t.fields["body"] }
        return nil
    }

    func transitions(_ effects: [Effect], channel: Int) -> [TransitionEffect] {
        effects.compactMap { effect in
            if case .transition(let t) = effect, t.channel == channel { return t }
            return nil
        }
    }

    func test_aJumpPutsUpWhatTheCuesThumbnailShows() {
        // Channel 3 holds something of its own, which the list never touches.
        var state = F.fresh()
        (state, _) = project(state, [F.write(3, text: "clock")], context: context(frame: 10))
        let (after, effects) = project(state, [.listCue(list: 8, cue: 3, state: true)], context: context(frame: 100))
        // The clip held from cue 1 comes up, from its start, now, with a cut, at the gain cue 1 tracked.
        let clip = after.channels[1]?.content.media
        XCTAssertEqual(clip?.ref, F.mediaA)
        XCTAssertEqual(clip?.startedAtFrame, 100)
        XCTAssertEqual(clip?.transport, .playing)
        XCTAssertEqual(transitions(effects, channel: 1).map(\.ms), [0], "a cut")
        XCTAssertEqual(after.channels[1]?.attributes.gain.value, -6)
        // Channel 2 goes straight to the cue's own write, with its own transition: no flash of the chorus between.
        XCTAssertEqual(text(after, 2), "verse 2")
        XCTAssertEqual(transitions(effects, channel: 2).count, 1)
        XCTAssertEqual(transitions(effects, channel: 2).first?.from, .empty)
        XCTAssertGreaterThan(transitions(effects, channel: 2).first?.ms ?? 0, 0, "the cue's own dissolve, as when the show runs")
        // Channel 3, untouched by the list, keeps what is live.
        XCTAssertEqual(text(after, 3), "clock")
        // The pointer is on cue 3, as any fire leaves it.
        XCTAssertEqual(after.pointer?.cueUuid, F.cueUuid(list: 8, cue: 3))
        // And what is up is cue 3's thumbnail, on the channels the list touched.
        let thumbnail = CueView.states(of: Self.list8, through: 2, library: library, machine: F.machine).last
        XCTAssertEqual(after.channels[2]?.content, thumbnail?.channels[2]?.content)
        XCTAssertEqual(after.channels[1]?.content.media?.ref, thumbnail?.channels[1]?.content.media?.ref)
    }

    func test_aClipAlreadyPlayingKeepsPlaying() {
        var state = F.fresh()
        (state, _) = project(state, [.listCue(list: 8, cue: 1)], context: context(frame: 100))
        let (after, effects) = project(state, [.listCue(list: 8, cue: 3, state: true)], context: context(frame: 500))
        XCTAssertEqual(after.channels[1]?.content.media?.startedAtFrame, 100, "not restarted")
        XCTAssertEqual(transitions(effects, channel: 1), [], "nothing to animate on channel 1")
        XCTAssertEqual(text(after, 2), "verse 2")
    }

    func test_aLockedChannelIsLeftAsItIs() {
        var state = F.fresh()
        (state, _) = project(state, [.channelLock(channel: .number(1), locked: true)], context: context(frame: 10))
        let (after, _) = project(state, [.listCue(list: 8, cue: 2, state: true)], context: context(frame: 100))
        XCTAssertEqual(after.channels[1]?.content, .empty)
        XCTAssertEqual(text(after, 2), "chorus")
    }

    func test_comingInFromAnotherListTheBoundaryComesFirst() {
        var state = F.fresh()
        (state, _) = project(state, [.listCue(list: 2, cue: 1)], context: context(frame: 10))
        let (after, _) = project(state, [.listCue(list: 8, cue: 2, state: true)], context: context(frame: 100))
        XCTAssertEqual(after.channels[1]?.attributes.gain.value, -6, "the boundary resets, then the state is taken up")
        XCTAssertEqual(after.channels[1]?.content.media?.ref, F.mediaA)
    }

    func test_theFirstCueTakesUpNothingAndWithoutStateNothingChanges() {
        var state = F.fresh()
        (state, _) = project(state, [F.write(1, media: F.mediaB)], context: context(frame: 10))
        let (first, _) = project(state, [.listCue(list: 8, cue: 1, state: true)], context: context(frame: 100))
        XCTAssertEqual(first.channels[1]?.content.media?.ref, F.mediaA, "cue 1's own write")
        let (plain, _) = project(state, [.listCue(list: 8, cue: 3)], context: context(frame: 100))
        XCTAssertEqual(plain.channels[1]?.content.media?.ref, F.mediaB, "a plain fire runs the cue's commands alone")
    }

    func test_itemAndLiveCueFormsTakeStateToo() {
        var state = F.fresh()
        state.pointer = LivePointer(playlist: F.playlistUuid)
        let (item, _) = project(state, [.itemCue(item: 2, cue: 3, state: true)], context: F.context(frame: 100))
        XCTAssertEqual(item.channels[1]?.content.media?.ref, F.mediaA, "list 1's cue 1 clip, under item 2's cue 3")
        let (live, _) = project(item, [.channelClear(channel: .number(1)), .cue(2, state: true)], context: F.context(frame: 200))
        XCTAssertEqual(live.channels[1]?.content.media?.ref, F.mediaA, "`cue N state` in the live list")
    }

    /// A cue that fires its own list with `state` (from a file, so anything may be there) takes up a state folded
    /// with plain fires, so the fold ends.
    func test_aCueThatFiresItsOwnListWithStateEnds() {
        let loop = List(uuid: F.listUuid(9), number: 9, title: "Loop", cues: [
            F.cue(list: 9, 1, commands: [F.write(1, media: F.mediaA)]),
            F.cue(list: 9, 2, commands: [.listCue(list: 9, cue: 3, state: true)]),
            F.cue(list: 9, 3, commands: [F.write(2, text: "end")]),
        ])
        var library = self.library
        library.lists.append(loop)
        let (after, _) = project(F.fresh(), [.listCue(list: 9, cue: 3, state: true)], context: F.context(frame: 100, library: library))
        XCTAssertEqual(text(after, 2), "end")
        XCTAssertEqual(after.channels[1]?.content.media?.ref, F.mediaA)
    }

    // MARK: - Through the runner, as the engine runs it

    /// Adam's try of 2026-11-24: Live sent `item 1 cue 4 state` and the background held from cue 1 never came up. The
    /// runner logs a fire as its own line and the cue's commands as theirs, rebuilding each line's effects, and the
    /// state's cuts were on none of them, so the engine, which acts on the lines' effects, never put them on air.
    /// Spec 3 §5 — the state is taken up "between the boundary and the cue's commands": the fire's own line carries it.
    func test_theRunnerPutsTheTakenStateOnTheFiresOwnLine() throws {
        let group = CommandGroup(id: GroupID("g-1"), source: CommandSource(kind: .ui), commands: [.listCue(list: 8, cue: 3, state: true)])
        var counter = 1
        let outcome = try CommandRunner.run(group, state: F.fresh(), context: context(frame: 100), makeGroupID: {
            counter += 1
            return GroupID("g-\(counter)")
        }).get()
        XCTAssertEqual(outcome.executed.map(\.command), [.listCue(list: 8, cue: 3, state: true), F.write(2, text: "verse 2",
                       riders: Riders(transition: TransitionRider(ref: 2, scope: .once)))])
        let fire = outcome.executed[0]
        XCTAssertEqual(transitions(fire.effects, channel: 1).map(\.ms), [0], "the clip held from cue 1, cut up on the fire's own line")
        XCTAssertEqual(transitions(fire.effects, channel: 1).first?.to.media?.ref, F.mediaA)
        XCTAssertTrue(fire.effects.contains { if case .attribute(1, .gain, _, .gain(-6), _) = $0 { return true } else { return false } },
                      "and its tracked gain")
        // The cue's own write runs over the state taken up, from what is on air, with its own transition.
        let write = outcome.executed[1]
        XCTAssertEqual(transitions(write.effects, channel: 2).first?.from, .empty)
        XCTAssertGreaterThan(transitions(write.effects, channel: 2).first?.ms ?? 0, 0)
        XCTAssertEqual(outcome.state.channels[1]?.content.media?.ref, F.mediaA)
        // Every change the state shows is on some line, so the engine acts on all of it.
        let all = outcome.executed.flatMap(\.effects)
        XCTAssertEqual(transitions(all, channel: 1).count, 1)
    }

    // MARK: - Spec 2 — the text and object forms

    func parse(_ text: String) throws -> Command {
        try CommandText.parse(text).get().command
    }

    func print(_ command: Command) -> String? {
        CommandText.print(command)
    }

    func test_stateIsAWordAtTheEndAndATrueInTheObject() throws {
        XCTAssertEqual(try parse("list 8 cue 3 state"), .listCue(list: 8, cue: 3, state: true))
        XCTAssertEqual(try parse("item 2 cue 3 STATE"), .itemCue(item: 2, cue: 3, state: true))
        XCTAssertEqual(try parse("cue 3 state"), .cue(3, state: true))
        XCTAssertEqual(try parse("list 8 cue 3"), .listCue(list: 8, cue: 3))
        XCTAssertEqual(print(.listCue(list: 8, cue: 3, state: true)), "list 8 cue 3 state")
        XCTAssertEqual(print(.itemCue(item: 2, cue: 3, state: true)), "item 2 cue 3 state")
        XCTAssertEqual(print(.cue(3, state: true)), "cue 3 state")
        XCTAssertEqual(print(.listCue(list: 8, cue: 3)), "list 8 cue 3")
        let object: JSONValue = .object(["cmd": .string("list.goto"), "list": .number(8), "cue": .number(3), "state": .bool(true)])
        XCTAssertEqual(try JSONCoding.encode(Command.listCue(list: 8, cue: 3, state: true)), object)
        XCTAssertEqual(try JSONCoding.decode(Command.self, from: object), .listCue(list: 8, cue: 3, state: true))
        let plain: JSONValue = .object(["cmd": .string("list.goto"), "list": .number(8), "cue": .number(3)])
        XCTAssertEqual(try JSONCoding.encode(Command.listCue(list: 8, cue: 3)), plain, "written only when true")
    }
}
