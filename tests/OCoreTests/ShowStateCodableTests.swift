import Foundation
import XCTest
@testable import OCore

/// Spec 3 §10 — "a round-trip test that `ShowState` encodes and decodes to an
/// equal value." Also the JSON conventions of Spec 1 §5 that the state file
/// shares: string keys for every map, sorted keys, camelCase.
final class ShowStateCodableTests: XCTestCase {
    typealias F = Fixtures

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    private func roundTrip(_ state: ShowState, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let data = try encoder.encode(state)
        let decoded = try JSONDecoder().decode(ShowState.self, from: data)
        XCTAssertEqual(decoded, state, file: file, line: line)
        return data
    }

    func test_freshStateRoundTrips() throws {
        let data = try roundTrip(F.fresh())
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"channels\" : {"), "maps encode as JSON objects with string keys:\n\(json)")
        XCTAssertTrue(json.contains("\"1\" : {"), json)
        XCTAssertFalse(json.contains("\"shadow\""), "nil shadows are absent, not null")
    }

    func test_busyStateRoundTrips() throws {
        var state = F.fresh()
        state.channels[1]?.content = .media(MediaInstance(
            ref: "sha256:9f2c", inMs: 2000, outMs: 60_000, loop: true, gainOverride: -3, syncOffsetMs: 40,
            startedAtFrame: 123, transport: .paused, endBehavior: .loop, missing: true))
        state.channels[1]?.provenance = .cue(F.cueUuid(list: 1, cue: 1))
        state.channels[1]?.outgoing = [OutgoingInstance(instance: MediaInstance(ref: F.mediaA, startedAtFrame: 1), endsAtFrame: 61)]
        state.channels[1]?.attributes.grade = Tracked(value: 7, origin: .once, shadow: 5)
        state.channels[1]?.attributes.transition = Tracked(value: TransitionSetting(ref: 2, ms: 750), origin: .tracked)
        state.channels[1]?.lock = true
        state.channels[2]?.content = .text(TextInstance(fields: ["body": "Great is Thy faithfulness,\nO God my Father", "title": "Hymn"]))
        state.channels[2]?.provenance = .source(.osc)
        state.channels[3]?.content = .slide(SlideInstance(ref: F.slideS, build: 2))
        state.channels[3]?.provenance = .restored
        state.outputs[1] = 2
        state.stacks[1] = StackState(blackout: true, muted: [2, 1])
        state.pointer = F.pointer(item: 2, list: 1, cue: 2)
        state.armed = ArmedTrigger(cueUuid: F.cueUuid(list: 1, cue: 3), atFrame: 900)
        state.popups = [3: "Nursery: please come to room 12"]
        _ = try roundTrip(state)
    }

    func test_inputAndEmptyContentRoundTrip() throws {
        var state = F.fresh()
        state.channels[1]?.content = .input(InputInstance(input: 2, frozen: true))
        state.channels[2]?.content = .empty
        _ = try roundTrip(state)
    }

    func test_statesFromTheTableRoundTrip() throws {
        // Fold a representative group and round-trip the result.
        let commands: [Command] = [
            .listCue(list: 1, cue: 1),
            F.write(1, media: F.mediaB, riders: Riders(transition: TransitionRider(ref: 2, ms: 1000, scope: .once),
                                                    grade: GradeRider(ref: 5, scope: .track))),
            .next,
            .stackBlackout(stack: 1, state: .on),
            .popupSet(popup: 1, text: "x", clearAfterMs: nil),
        ]
        let (state, _) = project(F.fresh(), commands, context: F.context(frame: 100))
        _ = try roundTrip(state)
    }

    func test_unknownContentKindFailsToDecodeRatherThanTrapping() {
        let json = #"{"channels":{"1":{"content":{"kind":"hologram"},"outgoing":[],"attributes":{"grade":{"value":0,"origin":"default"},"transition":{"value":{"ref":1},"origin":"default"},"audioTransition":{"value":{"ref":1},"origin":"default"},"gain":{"value":0,"origin":"default"},"chase":{"value":false,"origin":"default"}},"lock":false}},"outputs":{},"stacks":{},"popups":{}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ShowState.self, from: Data(json.utf8)))
    }

    // MARK: - Command objects (Spec 1 §6 shape)

    func test_commandCorpusRoundTrips() throws {
        let corpus: [Command] = [
            F.write(1, media: F.mediaA, riders: Riders(
                transition: TransitionRider(ref: 2, ms: 1000, scope: .once),
                audioTransition: TransitionRider(ref: 2, ms: nil, scope: .track),
                grade: GradeRider(ref: 5, ms: 2000, scope: .track),
                gain: GainRider(db: -6, scope: .once),
                chase: ChaseRider(scope: .track),
                build: 2)),
            .channelWrite(ChannelWrite(channel: .all, content: .media(MediaContent(ref: "sha256:9f2c", inMs: 2000, outMs: nil, loop: true, gain: -3, syncOffsetMs: 10)))),
            F.write(2, text: "Great is Thy faithfulness,\nO God my Father"),
            F.write(3, slide: F.slideS, build: nil),
            .channelWrite(ChannelWrite(channel: .number(1), content: .input(2))),
            .channelWrite(ChannelWrite(channel: .number(1), content: .empty)),
            .channelClear(channel: .number(2)), .channelReset(channel: .all),
            .channelTransition(channel: .number(1), ref: 2, ms: 500),
            .channelAudioTransition(channel: .number(1), ref: 2, ms: nil),
            .channelGrade(channel: .number(1), ref: 0, ms: nil),
            .channelGain(channel: .number(1), db: -6.5),
            .channelTransport(channel: .number(1), mode: .stop),
            .channelEndBehavior(channel: .number(1), mode: .clear),
            .channelLock(channel: .number(1), locked: true),
            .channelFreeze(channel: .number(1), state: .on),
            .channelTrack(channel: .number(1), direction: .back),
            .channelBuild(channel: .number(1), build: 3),
            .outputStack(output: 1, stack: 4),
            .stackBlackout(stack: 2, state: .toggle),
            .stackMute(stack: 2, channel: 1, state: .off),
            .next, .previous, .cue(7),
            .itemCue(item: 4, cue: 3),
            .itemSection(item: 4, section: "chorus"),
            .listCue(list: 42, cue: 3),
            .playlistLoad(title: "Sunday", date: "2026-11-01"),
            .playlistLoad(title: "Sunday", date: nil),
            .timerSet(timer: 1, ms: 300_000), .timerStart(timer: 1), .timerPause(timer: 2), .timerReset(timer: 3),
            .popupSet(popup: 3, text: "Nursery", clearAfterMs: 30_000), .popupClear(popup: 3),
            .audioMute(audio: .all, state: .on),
            .macro(12), .undo, .redo, .historyJump(5),
            .systemClearAll, .systemPreflight, .systemSnapshot,
            .edit(EditCommand(target: "channel", number: 2, field: "label", value: .string("Lyrics"))),
            .unknown(cmd: "channel.teleport"),
        ]
        for command in corpus {
            let data = try encoder.encode(command)
            let decoded = try JSONDecoder().decode(Command.self, from: data)
            XCTAssertEqual(decoded, command, String(decoding: data, as: UTF8.self))
        }
    }

    func test_commandDecodesSpec1WorkedExample() throws {
        let json = #"""
        { "cmd": "channel.write", "channel": 1,
          "content": { "kind": "media", "ref": "sha256:9f2c", "in": 0, "out": null, "loop": true },
          "transition": { "ref": 2, "ms": 500, "scope": "once" },
          "grade": { "ref": 5, "scope": "track" } }
        """#
        let decoded = try JSONDecoder().decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, .channelWrite(ChannelWrite(
            channel: .number(1),
            content: .media(MediaContent(ref: "sha256:9f2c", inMs: 0, outMs: nil, loop: true)),
            riders: Riders(transition: TransitionRider(ref: 2, ms: 500, scope: .once),
                           grade: GradeRider(ref: 5, scope: .track)))))

        let macroShort = try JSONDecoder().decode(Command.self, from: Data(#"{"cmd": "macro", "macro": 12}"#.utf8))
        XCTAssertEqual(macroShort, .macro(12), "Spec 1 §6 spells the macro reference `macro`; Spec 2 §3 `macro.run`")
    }

    func test_guardedCommandRoundTrips() throws {
        let guarded = GuardedCommand(.channelClear(channel: .number(2)),
                                     when: Guard(variable: "Timer 1", op: .is, value: "0:00"))
        let data = try encoder.encode(guarded)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"var\" : \"Timer 1\""), json)
        XCTAssertEqual(try JSONDecoder().decode(GuardedCommand.self, from: data), guarded)
    }
}
