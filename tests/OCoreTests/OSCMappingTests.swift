import Foundation
import XCTest
@testable import OCore

/// Spec 2 §10 — OSC mapping: "Every vocabulary row maps to its address and
/// back; typed-argument and single-string forms produce the same object; a
/// bundle with one invalid message runs nothing." Spec 2 §6 — "The OSC
/// address is the text form with slashes: `/o/TARGET/NUMBER/VERB`, and the
/// arguments are the rest of the command."
final class OSCMappingTests: XCTestCase {
    typealias F = FixtureLibrary

    static let dawn = F.dawn
    static let slide = F.welcomeSlide

    func i(_ n: Int32) -> OSCArgument { .int32(n) }
    func f(_ x: Float) -> OSCArgument { .float32(x) }
    func s(_ text: String) -> OSCArgument { .string(text) }

    func write(_ channel: Target, _ content: ContentExpression, _ riders: Riders = .none) -> Command {
        .channelWrite(ChannelWrite(channel: channel, content: content, riders: riders))
    }

    struct Row {
        let command: Command
        let message: OSCMessage
    }

    func row(_ command: Command, _ address: String, _ arguments: [OSCArgument] = []) -> Row {
        Row(command: command, message: OSCMessage(address, arguments))
    }

    /// Spec 2 §6, the address table plus one row for everything else in §3.
    lazy var rows: [Row] = [
        row(.channelGrade(channel: .number(2), ref: 5, ms: nil), "/o/channel/2/grade", [i(5)]),
        row(.channelGrade(channel: .number(2), ref: 5, ms: 2000), "/o/channel/2/grade", [i(5), i(2)]),
        row(.channelGrade(channel: .number(2), ref: 5, ms: 500), "/o/channel/2/grade", [i(5), f(0.5)]),
        row(write(.number(2), .media(MediaContent(ref: Self.dawn, loop: true)),
                  Riders(transition: TransitionRider(ref: 2, ms: 1000, scope: .once))),
            "/o/channel/2/write", [s("media \(Self.dawn) loop transition 2 1.0 once")]),
        row(write(.number(2), .text(fields: ["body": "There is no shadow\nof turning"])),
            "/o/channel/2/write", [s("text \"There is no shadow\\nof turning\"")]),
        row(write(.number(3), .slide(ref: Self.slide, build: 2)), "/o/channel/3/write", [s("\(Self.slide) build 2")]),
        row(write(.all, .empty), "/o/channel/all/write", [s("empty")]),
        row(.channelClear(channel: .number(2)), "/o/channel/2/clear"),
        row(.channelClear(channel: .all), "/o/channel/all/clear"),
        row(.channelReset(channel: .number(2)), "/o/channel/2/reset"),
        row(.channelTransition(channel: .number(1), ref: 2, ms: 1000), "/o/channel/1/transition", [i(2), i(1)]),
        row(.channelTransition(channel: .number(1), ref: 2, ms: nil), "/o/channel/1/transition", [i(2)]),
        row(.channelAudioTransition(channel: .number(1), ref: 2, ms: 250), "/o/channel/1/audiotransition", [i(2), f(0.25)]),
        row(.channelGain(channel: .number(2), db: -6), "/o/channel/2/gain", [f(-6)]),
        row(.channelGain(channel: .number(2), db: -6.5), "/o/channel/2/gain", [f(-6.5)]),
        row(.channelGain(channel: .number(2), db: -6.1), "/o/channel/2/gain", [.double(-6.1)]),
        row(.channelTransport(channel: .number(1), mode: .play), "/o/channel/1/play"),
        row(.channelTransport(channel: .number(1), mode: .pause), "/o/channel/1/pause"),
        row(.channelTransport(channel: .number(1), mode: .stop), "/o/channel/1/stop"),
        row(.channelEndBehavior(channel: .number(1), mode: .loop), "/o/channel/1/end", [s("loop")]),
        row(.channelLock(channel: .number(1), locked: true), "/o/channel/1/lock"),
        row(.channelLock(channel: .number(1), locked: false), "/o/channel/1/unlock"),
        row(.channelFreeze(channel: .number(1), state: .on), "/o/channel/1/freeze", [s("on")]),
        row(.channelTrack(channel: .number(1), direction: .skip), "/o/channel/1/skip"),
        row(.channelTrack(channel: .number(1), direction: .back), "/o/channel/1/back"),
        row(.channelBuild(channel: .number(1), build: 3), "/o/channel/1/build", [i(3)]),
        row(.outputStack(output: 1, stack: 4), "/o/output/1/stack", [i(4)]),
        row(.stackBlackout(stack: 2, state: .toggle), "/o/stack/2/blackout", [s("toggle")]),
        row(.stackMute(stack: 2, channel: 1, state: .off), "/o/stack/2/mute", [i(1), s("off")]),
        row(.next, "/o/next"),
        row(.previous, "/o/previous"),
        row(.cue(7), "/o/cue", [i(7)]),
        row(.itemCue(item: 4, cue: 3), "/o/item/4/cue", [i(3)]),
        row(.itemSection(item: 4, section: "chorus"), "/o/item/4/section", [s("chorus")]),
        row(.listCue(list: 42, cue: 3), "/o/list/42/cue", [i(3)]),
        row(.playlistLoad(title: "Sunday", date: "2026-11-01"), "/o/playlist", [s("Sunday"), s("2026-11-01")]),
        row(.playlistLoad(title: "Sunday", date: nil), "/o/playlist", [s("Sunday")]),
        row(.timerSet(timer: 1, ms: 300_000), "/o/timer/1/set", [i(300)]),
        row(.timerSet(timer: 1, ms: 1500), "/o/timer/1/set", [f(1.5)]),
        row(.timerStart(timer: 1), "/o/timer/1/start"),
        row(.timerPause(timer: 1), "/o/timer/1/pause"),
        row(.timerReset(timer: 1), "/o/timer/1/reset"),
        row(.popupSet(popup: 3, text: "text", clearAfterMs: 30_000), "/o/popup/3/set", [s("text"), i(30)]),
        row(.popupSet(popup: 3, text: "Nursery: please come to room 12", clearAfterMs: nil),
            "/o/popup/3/set", [s("Nursery: please come to room 12")]),
        row(.popupClear(popup: 3), "/o/popup/3/clear"),
        row(.audioMute(audio: .all, state: .on), "/o/audio/all/mute", [s("on")]),
        row(.audioMute(audio: .number(2), state: .toggle), "/o/audio/2/mute", [s("toggle")]),
        row(.macro(12), "/o/macro/12"),
        row(.undo, "/o/undo"),
        row(.redo, "/o/redo"),
        row(.historyJump(5), "/o/history/jump", [i(5)]),
        row(.systemClearAll, "/o/system/clearall"),
        row(.systemPreflight, "/o/system/preflight"),
        row(.systemSnapshot, "/o/system/snapshot"),
        row(.edit(EditCommand(target: "channel", number: 2, field: "label", value: .string("Lyrics"))),
            "/o/edit", [s("channel 2 label \"Lyrics\"")]),
    ]

    func test_everyRowMapsToItsAddressAndBack() {
        var seen: Set<String> = []
        for row in rows {
            seen.insert(row.command.cmd)
            XCTAssertEqual(OSCMapping.message(for: row.command), row.message, "\(row.command)")
            switch OSCMapping.command(from: row.message) {
            case .success(let command): XCTAssertEqual(command, row.command, row.message.address)
            case .failure(let rejection): XCTFail("\(row.message): \(rejection.reason.rawValue): \(rejection.message)")
            }
        }
        let expected = Command.knownNames.subtracting(["macro", "next", "previous", "cue", "undo", "redo"])
        XCTAssertEqual(expected.subtracting(seen), [], "rows missing")
    }

    /// Spec 2 §6 — "As an alternative for any command, a single string
    /// argument is parsed as the remainder of the text form ... Both spellings
    /// reach the same command object."
    func test_typedAndSingleStringFormsAgree() {
        func same(_ a: OSCMessage, _ b: OSCMessage, file: StaticString = #filePath, line: UInt = #line) {
            let left = OSCMapping.command(from: a)
            let right = OSCMapping.command(from: b)
            guard case .success(let x) = left, case .success(let y) = right else {
                return XCTFail("\(a) → \(left); \(b) → \(right)", file: file, line: line)
            }
            XCTAssertEqual(x, y, "\(a) vs \(b)", file: file, line: line)
        }
        same(OSCMessage("/o/timer/1/set", [s("5:00")]), OSCMessage("/o/timer/1/set", [i(300)]))
        same(OSCMessage("/o/timer/1/set", [s("300")]), OSCMessage("/o/timer/1/set", [i(300)]))
        same(OSCMessage("/o/stack/2/blackout", [s("toggle")]), OSCMessage("/o/stack/2/blackout", [s("toggle")]))
        same(OSCMessage("/o/popup/3/set", [s("\"text\" clearafter 30")]), OSCMessage("/o/popup/3/set", [s("text"), i(30)]))
        same(OSCMessage("/o/popup/3/set", [s("\"Nursery\"")]), OSCMessage("/o/popup/3/set", [s("Nursery")]))
        same(OSCMessage("/o/channel/2/grade", [s("5 2.0")]), OSCMessage("/o/channel/2/grade", [i(5), f(2)]))
        same(OSCMessage("/o/channel/2/grade", [s("5 0:02")]), OSCMessage("/o/channel/2/grade", [i(5), i(2)]))
        same(OSCMessage("/o/output/1/stack", [s("4")]), OSCMessage("/o/output/1/stack", [i(4)]))
        same(OSCMessage("/o/channel/2/gain", [s("-6")]), OSCMessage("/o/channel/2/gain", [f(-6)]))
        same(OSCMessage("/o/channel/2/gain", [i(-6)]), OSCMessage("/o/channel/2/gain", [.double(-6)]))
        same(OSCMessage("/o/stack/2/mute", [s("1 off")]), OSCMessage("/o/stack/2/mute", [i(1), s("off")]))
        same(OSCMessage("/o/item/4/section", [s("\"chorus\"")]), OSCMessage("/o/item/4/section", [s("chorus")]))
        same(OSCMessage("/o/playlist", [s("\"Sunday\" 2026-11-01")]), OSCMessage("/o/playlist", [s("Sunday"), s("2026-11-01")]))
        same(OSCMessage("/o/cue", [s("7")]), OSCMessage("/o/cue", [i(7)]))
        same(OSCMessage("/o/next", [s("")]), OSCMessage("/o/next"))
        same(OSCMessage("/o/channel/2/write", [s("media \(Self.dawn) loop transition 2 1.0 once")]),
             OSCMessage("/o/channel/2/write", [s("media sha256:55c84469c37e loop tr 2 1 once")]))
        // The address is case-insensitive like the text keywords; `ch` expands.
        same(OSCMessage("/o/CHANNEL/2/Clear"), OSCMessage("/o/channel/2/clear"))
        same(OSCMessage("/o/ch/2/clear"), OSCMessage("/o/channel/2/clear"))
        same(OSCMessage("/o/channel/2/transition", [i(2), .double(1)]), OSCMessage("/o/channel/2/transition", [i(2), i(1)]))
        same(OSCMessage("/o/channel/2/transition", [.int64(2), i(1)]), OSCMessage("/o/channel/2/transition", [i(2), i(1)]))
    }

    func test_abbreviatedHashesExpandWithTheIdsGiven() {
        let options = ParseOptions(mediaIDs: [Self.dawn])
        let message = OSCMessage("/o/channel/2/write", [s("media sha256:55c84469c37e")])
        XCTAssertEqual(try OSCMapping.command(from: message, options: options).get(),
                       write(.number(2), .media(MediaContent(ref: Self.dawn))))
        XCTAssertEqual(try? OSCMapping.command(from: message).get(), nil)
    }

    func test_rejections() {
        func reason(_ message: OSCMessage, file: StaticString = #filePath, line: UInt = #line) -> RejectionReason? {
            switch OSCMapping.command(from: message) {
            case .success(let command):
                XCTFail("\(message) was accepted as \(command)", file: file, line: line)
                return nil
            case .failure(let rejection):
                XCTAssertFalse(rejection.message.isEmpty, file: file, line: line)
                return rejection.reason
            }
        }
        XCTAssertEqual(reason(OSCMessage("/x/channel/2/clear")), .malformed)
        XCTAssertEqual(reason(OSCMessage("/o")), .malformed)
        XCTAssertEqual(reason(OSCMessage("o/channel/2/clear")), .malformed)
        XCTAssertEqual(reason(OSCMessage("/o/chanel/2/clear")), .unknownTarget)
        XCTAssertEqual(reason(OSCMessage("/o/channel/2/teleport")), .unknownVerb)
        XCTAssertEqual(reason(OSCMessage("/o/channel/2/grade", [s("five")])), .badArgument)
        XCTAssertEqual(reason(OSCMessage("/o/channel/2/grade", [f(5)])), .badArgument)
        XCTAssertEqual(reason(OSCMessage("/o/channel/2/grade")), .missingArgument)
        XCTAssertEqual(reason(OSCMessage("/o/channel/2/clear", [i(1)])), .unexpectedToken)
        XCTAssertEqual(reason(OSCMessage("/o/channel/2/write")), .missingArgument)
        XCTAssertEqual(reason(OSCMessage("/o/channel/2/write", [i(5)])), .badArgument)
        XCTAssertEqual(reason(OSCMessage("/o/channel/2/write", [s("media \(Self.dawn) transition 2 1.0")])), .missingRiderScope)
        XCTAssertEqual(reason(OSCMessage("/o/channel/2/gain", [.blob(Data([1, 2]))])), .badArgument)
        XCTAssertEqual(reason(OSCMessage("/o/channel/2/gain", [.bool(true)])), .badArgument)
        XCTAssertEqual(reason(OSCMessage("/o/channel/2/transition", [i(2), i(1), i(1)])), .unexpectedToken)
        XCTAssertEqual(reason(OSCMessage("/o/timer/1/set", [s("0:90")])), .badArgument)
        XCTAssertEqual(reason(OSCMessage("/o/popup/3/set", [i(30)])), .badArgument)
        XCTAssertEqual(reason(OSCMessage("/o/register", [s("host"), i(9000)])), .unknownTarget)
    }

    /// Spec 2 §6 — "Bundles run as one group, in order, and either all
    /// validate or none run."
    func test_bundles() {
        let good = OSCBundle(elements: [
            .message(OSCMessage("/o/channel/1/clear")),
            .bundle(OSCBundle(elements: [.message(OSCMessage("/o/channel/2/grade", [i(1)]))])),
            .message(OSCMessage("/o/next")),
        ])
        XCTAssertEqual(try OSCMapping.commands(from: good).get(),
                       [.channelClear(channel: .number(1)), .channelGrade(channel: .number(2), ref: 1, ms: nil), .next])

        let bad = OSCBundle(elements: [
            .message(OSCMessage("/o/channel/1/clear")),
            .message(OSCMessage("/o/channel/9/teleport")),
            .message(OSCMessage("/o/next")),
        ])
        switch OSCMapping.commands(from: bad) {
        case .success(let commands): XCTFail("\(commands)")
        case .failure(let rejection):
            XCTAssertEqual(rejection.reason, .unknownVerb)
            XCTAssertEqual(rejection.index, 1)
            XCTAssertTrue(rejection.message.contains("/o/channel/9/teleport"), rejection.message)
        }
        XCTAssertEqual(try OSCMapping.commands(from: OSCBundle(elements: [])).get(), [])
    }

    // MARK: - Spec 2 §6, feedback and client requests

    func test_feedbackMessageShapes() {
        XCTAssertEqual(OSCFeedback.livePlaylist("Sunday"), OSCMessage("/o/live/playlist", [s("Sunday")]))
        XCTAssertEqual(OSCFeedback.liveItem(4), OSCMessage("/o/live/item", [i(4)]))
        XCTAssertEqual(OSCFeedback.liveCue(3), OSCMessage("/o/live/cue", [i(3)]))
        XCTAssertEqual(OSCFeedback.liveLabel("Verse 1"), OSCMessage("/o/live/label", [s("Verse 1")]))
        XCTAssertEqual(OSCFeedback.channelContent(2, kind: "text", label: "Verse 1"), OSCMessage("/o/channel/2/content", [s("text"), s("Verse 1")]))
        XCTAssertEqual(OSCFeedback.channelState(2, .playing), OSCMessage("/o/channel/2/state", [s("playing")]))
        XCTAssertEqual(OSCFeedback.channelState(2, .empty), OSCMessage("/o/channel/2/state", [s("empty")]))
        XCTAssertEqual(OSCFeedback.channelRemaining(2, ms: 12_345), OSCMessage("/o/channel/2/remaining", [i(12_345)]))
        XCTAssertEqual(OSCFeedback.outputStack(1, stack: 4), OSCMessage("/o/output/1/stack", [i(4)]))
        XCTAssertEqual(OSCFeedback.stackBlackout(2, on: true), OSCMessage("/o/stack/2/blackout", [i(1)]))
        XCTAssertEqual(OSCFeedback.stackBlackout(2, on: false), OSCMessage("/o/stack/2/blackout", [i(0)]))
        XCTAssertEqual(OSCFeedback.timer(1, formatted: "4:59", ms: 299_000), OSCMessage("/o/timer/1", [s("4:59"), i(299_000)]))
        XCTAssertEqual(OSCFeedback.popup(3, text: "Nursery"), OSCMessage("/o/popup/3", [s("Nursery")]))
        XCTAssertEqual(OSCFeedback.popup(3, text: ""), OSCMessage("/o/popup/3", [s("")]))
        XCTAssertEqual(OSCFeedback.lock(2, locked: true), OSCMessage("/o/lock/2", [i(1)]))
        XCTAssertEqual(OSCFeedback.error(address: "/o/channel/9/clear", reason: "channel 9 does not exist"),
                       OSCMessage("/o/error", [s("/o/channel/9/clear"), s("channel 9 does not exist")]))
        XCTAssertEqual(ChannelFeedbackState.allCases.map(\.rawValue), ["empty", "playing", "paused", "held", "missing"])
    }

    func test_clientRequests() {
        XCTAssertEqual(OSCClientRequest(OSCMessage("/o/register", [s("10.0.0.5"), i(9000)])), .register(host: "10.0.0.5", port: 9000))
        XCTAssertEqual(OSCClientRequest(OSCMessage("/o/subscribe", [s("/o/channel/2/remaining")])), .subscribe("/o/channel/2/remaining"))
        XCTAssertEqual(OSCClientRequest(OSCMessage("/o/unsubscribe", [s("/o/channel/2/remaining")])), .unsubscribe("/o/channel/2/remaining"))
        XCTAssertEqual(OSCClientRequest(OSCMessage("/o/query", [s("/o/channel/2/state")])), .query("/o/channel/2/state"))
        XCTAssertNil(OSCClientRequest(OSCMessage("/o/register", [s("10.0.0.5")])))
        XCTAssertNil(OSCClientRequest(OSCMessage("/o/register", [i(9000), s("10.0.0.5")])))
        XCTAssertNil(OSCClientRequest(OSCMessage("/o/query")))
        XCTAssertNil(OSCClientRequest(OSCMessage("/o/channel/2/clear")))
        XCTAssertNil(OSCClientRequest(OSCMessage("/o/next")))
        XCTAssertEqual(OSCClientRequest.registrationSeconds, 60)
    }
}
