import Foundation
import XCTest
@testable import OCore

/// Spec 2 §10 — Rejections: "Table-driven: unknown target, missing rider
/// scope, out-of-range gain, unknown media id, macro cycle, guard on a cue
/// command. Each yields `rejected` with the documented reason and nothing
/// changes." The checks run in Spec 2 §8's order: the target number exists,
/// referenced objects exist, arguments are in range, content references
/// resolve, macro depth and cycles; Spec 2 §7 adds the guard on a cue.
final class CommandRejectionTests: XCTestCase {
    typealias F = FixtureLibrary

    static let dawn = F.dawn
    static let mountains = F.mountains
    static let zeros = "sha256:" + String(repeating: "0", count: 64)
    static let loaded = F.load()
    static var library: Library { loaded.library }
    static var machine: Machine { loaded.machine }

    /// A pointer on list 42 (item 2 of the fixture playlist), cue 1.
    static let livePointer = LivePointer(playlist: F.playlistUuid, item: 2, listUuid: F.listUuid(42), cueUuid: F.list42Cues[0])

    static var liveState: ShowState {
        var state = ShowState.fresh(library: library, machine: machine)
        state.pointer = livePointer
        return state
    }

    // MARK: - Helpers

    /// Parse, then validate; the first rejection is the answer, nil when accepted.
    func rejection(_ text: String, source: SourceKind = .ui, state: ShowState? = nil,
                   library: Library? = nil, machine: Machine? = nil, mediaIDs: Set<String> = []) -> Rejection? {
        switch CommandText.parse(text, options: ParseOptions(mediaIDs: mediaIDs)) {
        case .failure(let rejection):
            return rejection
        case .success(let entry):
            let context = ValidationContext(library: library ?? Self.library, machine: machine ?? Self.machine,
                                            state: state, source: CommandSource(kind: source))
            return CommandValidator.validate(entry.command, guard: entry.when, context: context)
        }
    }

    func expect(_ text: String, _ reason: RejectionReason, containing fragment: String? = nil,
                source: SourceKind = .ui, state: ShowState? = nil, library: Library? = nil, machine: Machine? = nil,
                mediaIDs: Set<String> = [], file: StaticString = #filePath, line: UInt = #line) {
        guard let rejection = rejection(text, source: source, state: state, library: library, machine: machine, mediaIDs: mediaIDs) else {
            return XCTFail("\(text) was accepted", file: file, line: line)
        }
        XCTAssertEqual(rejection.reason, reason, "\(text): \(rejection.message)", file: file, line: line)
        XCTAssertFalse(rejection.message.isEmpty, text, file: file, line: line)
        if let fragment {
            XCTAssertTrue(rejection.message.lowercased().contains(fragment.lowercased()), "\(text): \(rejection.message)", file: file, line: line)
        }
    }

    func accept(_ text: String, source: SourceKind = .ui, state: ShowState? = nil, library: Library? = nil,
                machine: Machine? = nil, mediaIDs: Set<String> = [], file: StaticString = #filePath, line: UInt = #line) {
        if let rejection = rejection(text, source: source, state: state, library: library, machine: machine, mediaIDs: mediaIDs) {
            XCTFail("\(text) was rejected: \(rejection.reason.rawValue): \(rejection.message)", file: file, line: line)
        }
    }

    // MARK: - Spec 2 §2 and §4, the grammar

    func test_grammarRejections() {
        expect("", .malformed)
        expect("   ", .malformed)
        expect("chanel 2 clear", .unknownTarget, containing: "chanel")
        expect("channel 2 teleport", .unknownVerb, containing: "teleport")
        expect("channel", .missingArgument)
        expect("channel clear", .badArgument)
        expect("channel 0 clear", .badArgument)
        expect("channel -1 clear", .badArgument)
        expect("channel 2", .missingArgument)
        expect("channel 2 clear extra", .unexpectedToken, containing: "extra")
        expect("channel 2 write", .missingArgument)
        expect("channel 2 write media", .missingArgument)
        expect("channel 2 write media sha256:abc", .badArgument)
        expect("channel 2 write media nothash", .badArgument)
        expect("channel 2 write media \(Self.dawn)zz", .badArgument)
        expect("channel 2 write slide:not-a-uuid", .badArgument)
        expect("channel 2 write nothing", .badArgument)
        expect("channel 2 write media \(Self.dawn) loop loop", .duplicateOption)
        expect("channel 2 write media \(Self.dawn) in 0:01 in 0:02", .duplicateOption)
        expect("channel 2 write media \(Self.dawn) transition 2 1.0 once transition 3 1.0 once", .duplicateRider)
        expect("channel 2 transition 2 once", .badArgument, containing: "track")
        expect("channel 2 grade 5 1.0 once", .badArgument, containing: "track")
        expect("channel 2 gain loud", .badArgument)
        expect("channel 2 end", .missingArgument)
        expect("channel 2 end sideways", .badArgument)
        expect("channel 2 freeze maybe", .badArgument)
        expect("channel 2 build", .missingArgument)
        expect("timer 1 set 0:90", .badArgument)
        expect("timer 1 set soon", .badArgument)
        expect("timer 0 start", .badArgument)
        expect("stack 2 mute on", .badArgument)
        expect("output 1 stack", .missingArgument)
        expect("item 4 cue", .missingArgument)
        expect("macro", .missingArgument)
        expect("macro twelve", .badArgument)
        expect("playlist Sunday", .badArgument)
        expect("popup 3 set Nursery", .badArgument)
        expect("popup 3 set \"x\" clearafter", .missingArgument)
        expect("popup 3 set \"x\" clearafter soon", .badArgument)
        expect("channel 2 write text \"unterminated", .malformed)
        expect("channel 2 write text \"bad \\q escape\"", .malformed)
        expect("edit channel 2", .missingArgument)
        expect("edit channel 2 label", .missingArgument)
        expect("edit channel 2 label {\"a\":", .malformed)
    }

    /// Spec 2 §2 — "A rider without a scope is an error, not a default."
    func test_missingRiderScope() {
        expect("channel 2 write media \(Self.dawn) transition 2 1.0", .missingRiderScope, containing: "transition")
        expect("channel 2 write media \(Self.dawn) transition 2", .missingRiderScope)
        expect("channel 2 write media \(Self.dawn) audiotransition 2 1.0", .missingRiderScope)
        expect("channel 2 write media \(Self.dawn) grade 1", .missingRiderScope, containing: "grade")
        expect("channel 2 write media \(Self.dawn) chase", .missingRiderScope)
        expect("channel 2 write media \(Self.dawn) transition 2 1.0 once gain -6", .missingRiderScope, containing: "gain")
        expect("channel 2 write text \"x\" gain -6", .missingRiderScope)
        expect("channel 2 write media \(Self.dawn) transition 2 1.0 later", .missingRiderScope)
    }

    func test_guardGrammar() {
        expect("when [Timer 1] is", .missingArgument)
        expect("when [Timer 1] is 0:00", .missingArgument)
        expect("when [Timer 1] 0:00 next", .badArgument)
        expect("when Timer 1 is 0:00 next", .badArgument)
        expect("when [Timer 1] between 1 next", .badArgument)
        expect("when [Timer 1] is empty next extra", .unexpectedToken)
    }

    // MARK: - Spec 2 §8, "the target number exists (or is `all`)"

    func test_targetNumbers() {
        expect("channel 9 clear", .noSuchTarget, containing: "channel 9")
        accept("channel all clear")
        expect("channel 9 write text \"x\"", .noSuchTarget)
        expect("output 9 stack 1", .noSuchTarget, containing: "output 9")
        expect("stack 9 blackout on", .noSuchTarget, containing: "stack 9")
        expect("stack 9 mute 1 on", .noSuchTarget)
        expect("audio 9 mute on", .noSuchTarget, containing: "audio output 9")
        accept("audio all mute on")
        expect("timer 5 set 1:00", .noSuchTarget, containing: "timer 5")
        accept("timer 4 set 1:00")
        expect("popup 5 clear", .noSuchTarget, containing: "popup 5")
        accept("popup 4 clear")
        expect("macro 99", .noSuchTarget, containing: "macro 99")
        accept("macro 1")
        accept("macro 2")
        expect("list 99 cue 1", .noSuchTarget, containing: "list 99")
        expect("playlist \"Nope\"", .noSuchTarget)
        expect("playlist \"Sunday\" 2025-01-01", .noSuchTarget)
        accept("playlist \"Sunday\"")
        accept("playlist \"sunday\" 2026-11-01")
        // Live-position targets are checked only when a ShowState is given.
        expect("cue 9", .noSuchTarget, containing: "cue 9", state: Self.liveState)
        accept("cue 4", state: Self.liveState)
        accept("cue 9")
        expect("item 9 cue 1", .noSuchTarget, containing: "item 9", state: Self.liveState)
        expect("item 1 cue 1", .noSuchTarget, containing: "header", state: Self.liveState)
        expect("item 2 cue 9", .noSuchReference, containing: "cue 9", state: Self.liveState)
        accept("item 2 cue 4", state: Self.liveState)
        accept("item 9 cue 1")
        expect("item 2 section \"zzz\"", .noSuchReference, containing: "zzz", state: Self.liveState)
        accept("item 2 section \"chorus\"", state: Self.liveState)
        var noPlaylist = Self.liveState
        noPlaylist.pointer = nil
        expect("cue 1", .noSuchTarget, state: noPlaylist)
        expect("item 2 cue 1", .noSuchTarget, state: noPlaylist)
        expect("edit channel 9 label \"x\"", .noSuchTarget)
        expect("edit nothing 1 label \"x\"", .noSuchTarget)
        accept("edit channel 2 label \"x\"")
    }

    // MARK: - Spec 2 §8, "referenced objects exist (a preset, a transition, a macro)"

    func test_references() {
        expect("output 1 stack 9", .noSuchReference, containing: "stack 9")
        accept("output 1 stack 2")
        expect("stack 1 mute 9 on", .noSuchReference, containing: "channel 9")
        accept("stack 1 mute 2 on")
        expect("channel 2 transition 9", .noSuchReference, containing: "transition 9")
        expect("channel 2 audiotransition 9", .noSuchReference, containing: "audio transition 9")
        expect("channel 2 grade 9", .noSuchReference, containing: "grade 9")
        accept("channel 2 grade 0")
        accept("channel 2 grade 1")
        expect("channel 2 write media \(Self.dawn) transition 9 1.0 once", .noSuchReference, containing: "transition 9")
        expect("channel 2 write media \(Self.dawn) audiotransition 9 once", .noSuchReference)
        expect("channel 2 write media \(Self.dawn) grade 9 once", .noSuchReference, containing: "grade 9")
        accept("channel 2 write media \(Self.dawn) grade 0 once")
        expect("channel 2 write input 9", .noSuchReference, containing: "input 9")
        accept("channel 2 write input 1")
        expect("list 42 cue 9", .noSuchReference, containing: "cue 9")
        accept("list 42 cue 4")
    }

    // MARK: - Spec 2 §8, "arguments are in range (gain within ±60 dB, offsets within ±1000 ms)"

    func test_ranges() {
        expect("channel 2 gain -61", .outOfRange, containing: "60")
        expect("channel 2 gain 60.5", .outOfRange)
        accept("channel 2 gain -60")
        accept("channel 2 gain 60")
        expect("channel 2 write media \(Self.dawn) gain -70 once", .outOfRange)
        expect("channel 2 write media \(Self.dawn) gain 61", .outOfRange)
        accept("channel 2 write media \(Self.dawn) gain -6")
        expect("channel 2 write media \(Self.dawn) sync 1001", .outOfRange, containing: "1000")
        expect("channel 2 write media \(Self.dawn) sync -1001", .outOfRange)
        accept("channel 2 write media \(Self.dawn) sync -1000")
        accept("channel 2 write media \(Self.dawn) sync 1000")
        expect("channel 2 build -1", .outOfRange)
        expect("channel 2 write \(F.welcomeSlide) build -1", .outOfRange)
        expect("popup 3 set \"x\" clearafter -5", .outOfRange)
        accept("popup 3 set \"x\" clearafter 0")
    }

    // MARK: - Spec 2 §8, "content references resolve in the media index"

    func test_mediaReferences() {
        expect("channel 2 write media \(Self.zeros)", .unknownMedia, containing: Self.zeros)
        // "a missing file is allowed and produces the missing state"
        accept("channel 2 write media \(Self.mountains)")
        accept("channel 2 write media \(Self.dawn)")
        accept("channel 2 write media \(F.announcement)")
        expect("channel 2 write slide:00000000-0000-4000-8000-000000000000", .unknownMedia)
        accept("channel 2 write \(F.welcomeSlide)")
        // Abbreviated hashes expand against the ids the parser is given (Spec 2 §2).
        expect("channel 2 write media sha256:55c84469c37e", .unknownMedia, containing: "abbreviat")
        accept("channel 2 write media sha256:55c84469c37e", mediaIDs: [Self.dawn])
        let twin = "sha256:55c84469c37e" + String(repeating: "f", count: 52)
        expect("channel 2 write media sha256:55c84469c37e", .ambiguousMedia, mediaIDs: [Self.dawn, twin])
        accept("channel 2 write media sha256:55c84469c37e1", mediaIDs: [Self.dawn, twin])
        expect("channel 2 write media sha256:55c84469c37", .badArgument, mediaIDs: [Self.dawn])
    }

    // MARK: - Spec 2 §8, "macro depth and cycles"; Spec 2 §5, "depth is capped at 8"

    func test_macroCyclesAndDepth() {
        var library = Self.library
        library.macros.append(Macro(number: 3, commands: [GuardedCommand(.macro(4))]))
        library.macros.append(Macro(number: 4, commands: [GuardedCommand(.macro(3))]))
        library.macros.append(Macro(number: 5, commands: [GuardedCommand(.macro(5))]))
        // 10 → 11 → … → 17: eight macros deep, allowed; 20 → … → 28: nine, not.
        for n in 10...17 {
            library.macros.append(Macro(number: n, commands: [GuardedCommand(n == 17 ? .next : .macro(n + 1))]))
        }
        for n in 20...28 {
            library.macros.append(Macro(number: n, commands: [GuardedCommand(n == 28 ? .next : .macro(n + 1))]))
        }
        expect("macro 3", .macroCycle, containing: "macro 4", library: library)
        expect("macro 4", .macroCycle, library: library)
        expect("macro 5", .macroCycle, containing: "macro 5", library: library)
        accept("macro 10", library: library)
        accept("macro 17", library: library)
        expect("macro 20", .macroDepth, containing: "8", library: library)
        accept("macro 21", library: library)
    }

    // MARK: - Spec 2 §7, "Guards on cue commands are reserved in the schema and rejected by the v1 validator"

    func test_guardOnACueCommand() {
        expect("when [Timer 1] is 0:00 channel 2 clear", .guardOnCue, source: .cue)
        expect("when [Timer 1] is 0:00 next", .guardOnCue, source: .timeline)
        accept("when [Timer 1] is 0:00 channel 2 clear", source: .macro)
        accept("when [Timer 1] is 0:00 channel 2 clear", source: .ui)
        accept("channel 2 clear", source: .cue)
    }

    /// Spec 2 §7 — the readable values a guard can name, and the numbers in them.
    func test_guardValues() {
        expect("when [Nothing 1] is 2 next", .badGuard, containing: "Nothing 1")
        expect("when [Channel 9 Content] is empty next", .noSuchReference, containing: "channel 9")
        expect("when [Channel 2 Weight] is empty next", .badGuard)
        expect("when [Timer 9] is 0:00 next", .noSuchReference, containing: "timer 9")
        expect("when [Popup 9] is empty next", .noSuchReference, containing: "popup 9")
        expect("when [Output 9 Stack] is 1 next", .noSuchReference)
        expect("when [Stack 9 Blackout] is on next", .noSuchReference)
        for text in ["when [Timer 1] is 0:00 next", "when [Popup 3] is not empty next", "when [Time] greater than 09:00 next",
                     "when [Date] is 2026-11-01 next", "when [Live Item] is 2 next", "when [Live Cue] is 1 next",
                     "when [Live Title] is \"Doxology\" next", "when [Channel 2 Content] is empty next",
                     "when [Channel 2 State] is playing next", "when [Output 1 Stack] is 2 next",
                     "when [Stack 1 Blackout] is off next", "when [Channel 1 Lock] is on next"] {
            accept(text)
        }
    }

    // MARK: - Unknown command objects (Spec 1 §6 kept them; Spec 2 §8 refuses to run them)

    func test_unknownAndInvalidObjectsAreRejected() {
        let context = ValidationContext(library: Self.library, machine: Self.machine)
        let unknown = CommandValidator.validate(.unknown(cmd: "channel.teleport", fields: ["channel": .number(2)]), context: context)
        XCTAssertEqual(unknown?.reason, .unknownCommand)
        XCTAssertTrue(unknown?.message.contains("channel.teleport") == true, unknown?.message ?? "nil")
        let invalid = CommandValidator.validate(.invalid(cmd: "channel.clear", fields: ["channel": .string("two")]), context: context)
        XCTAssertEqual(invalid?.reason, .unknownCommand)
        XCTAssertNil(CommandValidator.validate(.channelClear(channel: .number(2)), context: context))
    }

    // MARK: - Spec 2 §8, "A group validates as a whole: one bad command rejects the group, and the rejection names the command and the reason."

    func test_aGroupIsRejectedWholeNamingTheCommand() throws {
        let list = try XCTUnwrap(Self.library.list(number: 42))
        var commands = list.cues[0].commands.map(\.command)
        commands.append(.channelClear(channel: .number(9)))
        commands.append(.channelClear(channel: .number(1)))
        let group = CommandGroup(id: GroupID("g-test"), source: CommandSource(kind: .ui), commands: commands)
        let context = ValidationContext(library: Self.library, machine: Self.machine)
        let rejection = try XCTUnwrap(CommandValidator.validate(group, context: context))
        XCTAssertEqual(rejection.reason, .noSuchTarget)
        XCTAssertEqual(rejection.index, 2)
        XCTAssertEqual(rejection.text, "channel 9 clear")
        XCTAssertTrue(rejection.message.contains("command 3"), rejection.message)
        XCTAssertTrue(rejection.message.contains("channel 9"), rejection.message)

        let fine = CommandGroup(id: GroupID("g-test"), source: CommandSource(kind: .ui), commands: list.cues[0].commands.map(\.command))
        XCTAssertNil(CommandValidator.validate(fine, context: context))

        // A guard inside a cue-sourced group is the reserved case.
        let guarded = CommandGroup(id: GroupID("g-cue"), source: CommandSource(kind: .cue, list: list.uuid, cue: list.cues[0].uuid),
                                   commands: [GuardedCommand(.channelClear(channel: .number(1)), when: Guard(variable: "Timer 1", op: .isEmpty))])
        XCTAssertEqual(CommandValidator.validate(guarded, context: context)?.reason, .guardOnCue)
    }
}
